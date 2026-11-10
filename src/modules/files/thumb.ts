import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import type { FastifyReply, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../kernel/types';
import { createLimiter } from '../media/ffmpeg-run';
import {
  absoluteInput,
  filesRoot,
  httpError,
  isAbsoluteInput,
  relativeInRoot,
  resolveAnyPath,
} from './fs-root';
import { matchesEtag } from './download';
import { Err } from '../../../kernel/errors';

/**
 * GET /api/v1/files/thumb：图片缩略图（JPEG）。
 *
 * - 走 media sidecar（ffmpeg `scale=size:-2:lanczos`，一次只出首帧）
 * - 文件缓存：`<dataDir>/thumbs/<sha1(rel|size|fileSize|mtimeMs)>.jpg`，源文件一变 key 就变
 * - 并发闸门 4：缩略图不比转码重要，避免一次滚动把 CPU 打满
 * - 未就绪（缺 ffmpeg / sidecar）返回 503，客户端按占位图处理
 */

/**
 * 缩略图源：图片 + 视频。
 * 视频走 ffmpeg 抽帧（`at` 指定位置），相册网格的视频封面也走这里，
 * 不再需要单独一套 poster 管道。
 */
const IMAGE_EXT = new Set([
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
  'tif',
  'tiff',
  'avif',
  'heic',
  'heif',
]);

const VIDEO_EXT = new Set([
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'avi',
  'wmv',
  'flv',
  '3gp',
  'mpg',
  'mpeg',
  'mts',
  'm2ts',
  'ogv',
]);

/** 视频默认抽帧位置（秒）：首帧常是黑场/过渡，往后一点更像个封面 */
const DEFAULT_VIDEO_AT = 0.5;

const DEFAULT_SIZE = 256;
const MIN_SIZE = 32;
const MAX_SIZE = 2048;

export interface ThumbQuery {
  path?: string;
  size?: number;
  /** 视频抽帧位置（秒）；缺省 0.5 */
  at?: number;
}

const limit = createLimiter(4);

/** target 是否在 base 目录内（含 base 本身） */
function isInsideDir(base: string, target: string): boolean {
  const rel = path.relative(path.resolve(base), path.resolve(target));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

/** 同一张图的并发请求共享一次 ffmpeg（避免滚动时重复转码） */
const inflight = new Map<string, Promise<void>>();

export function clampThumbSize(input: unknown): number {
  const n = Math.round(Number(input));
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_SIZE;
  return Math.min(Math.max(n, MIN_SIZE), MAX_SIZE);
}

async function generate(
  k: KernelApi,
  src: string,
  out: string,
  size: number,
  atSec: number,
): Promise<void> {
  const existing = inflight.get(out);
  if (existing) return existing;

  const job = (async () => {
    const tmp = `${out}.${process.pid}-${Date.now()}.tmp.jpg`;
    try {
      await limit(() => k.media.thumb(src, tmp, size, atSec));
      await fsp.rename(tmp, out);
    } catch (err) {
      await fsp.rm(tmp, { force: true }).catch(() => undefined);
      throw err;
    }
  })();

  inflight.set(out, job);
  try {
    await job;
  } finally {
    inflight.delete(out);
  }
}

export async function thumbHandler(
  req: FastifyRequest,
  reply: FastifyReply,
  q: ThumbQuery,
  k: KernelApi,
): Promise<unknown> {
  if (!q.path) throw httpError(400, 'path required');

  const size = clampThumbSize(q.size);
  const root = filesRoot();
  // 越界 403、"没有指向文件" 400 由 relativeInRoot 统一给出；
  // 相册来源可以登记 filesRoot 之外的目录，这里再兜一次白名单
  let abs: string;
  let rel: string;
  /** 是否服务端自己的缓存文件（扩展名不可信：TMDB 图缓存是 `<hash>.img`） */
  let ownCache = false;
  try {
    ({ abs, rel } = relativeInRoot(root, q.path));
  } catch (err) {
    if (!isAbsoluteInput(q.path)) throw err;
    const direct = path.resolve(absoluteInput(q.path));
    // 服务端**自己写的缓存**（视频抽帧 / 刮削海报 `dataDir/video-art`、音乐封面、
    // 相册缓存）既不在 filesRoot 也不在来源白名单里 —— 以前这里直接走
    // resolveAnyPath，结果 `?size=` 一传就 403 `path outside allowed root`，
    // 表现是影视列表整片裂图。这些路径由本进程落盘，直接放行；
    // 其它绝对路径仍然走白名单（相册来源 / SMB 共享根），越界照旧 403。
    ownCache = isInsideDir(k.paths.dataDir, direct);
    if (!ownCache) {
      resolveAnyPath(root, q.path);
    }
    abs = direct;
    rel = path.relative(root, abs).split(path.sep).join('/');
  }

  const ext = path.extname(abs).slice(1).toLowerCase();
  // 自建缓存不按扩展名卡（`w500/<hash>.img` 实际是 jpg）；真的不是图片时
  // ffmpeg 会失败并返回 503，不会读出错内容。
  if (!ownCache && !IMAGE_EXT.has(ext) && !VIDEO_EXT.has(ext)) {
    throw httpError(400, `unsupported thumbnail source: .${ext || 'unknown'}`);
  }
  const isVideo = VIDEO_EXT.has(ext);
  // `at` 只对视频生效；夹到 3 小时以内，避免被当成离谱的 seek 目标
  const rawAt = Number(q.at);
  const atSec = isVideo
    ? Number.isFinite(rawAt) && rawAt > 0
      ? Math.min(rawAt, 10800)
      : DEFAULT_VIDEO_AT
    : 0;

  let st;
  try {
    st = await fsp.stat(abs);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') throw httpError(404, 'path not found');
    if (code === 'EACCES') throw httpError(403, 'permission denied');
    throw err;
  }
  if (st.isDirectory()) throw httpError(400, 'path is a directory');

  const key = crypto
    .createHash('sha1')
    .update(`${rel}|${size}|${st.size}|${Math.floor(st.mtimeMs)}|${atSec}`)
    .digest('hex');
  const dir = path.join(k.paths.dataDir, 'thumbs');
  const out = path.join(dir, `${key}.jpg`);
  const etag = `"${key}"`;

  reply.header('ETag', etag).header('Cache-Control', 'private, max-age=86400');

  const cached = fs.existsSync(out);
  k.cache.record('files.thumb', cached);

  const ifNoneMatch = req.headers['if-none-match'];
  if (cached && typeof ifNoneMatch === 'string' && matchesEtag(ifNoneMatch, etag)) {
    return reply.code(304).send();
  }

  if (!cached) {
    if (!k.media.available()) {
      return reply.code(503).send({
        error: Err.unavailable,
        message: '缩略图不可用：未找到 ffmpeg 或 media sidecar（npm run ffmpeg:fetch）',
      });
    }
    await fsp.mkdir(dir, { recursive: true });
    try {
      await generate(k, abs, out, size, atSec);
    } catch (err) {
      const message = String((err as Error).message || err);
      k.log.warn({ err: message, path: rel, size }, 'thumbnail generation failed');
      return reply.code(503).send({ error: Err.unavailable, message: `缩略图生成失败：${message}` });
    }
  }

  let outStat;
  try {
    outStat = await fsp.stat(out);
  } catch {
    return reply.code(503).send({ error: Err.unavailable, message: '缩略图生成失败' });
  }

  reply
    .code(200)
    .header('Content-Type', 'image/jpeg')
    .header('Content-Length', String(outStat.size));
  return reply.send(fs.createReadStream(out));
}
