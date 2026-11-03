import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import type { FastifyReply, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../kernel/types';
import { createLimiter } from '../media/ffmpeg-run';
import { filesRoot, httpError, isAbsoluteInput, relativeInRoot, resolveAnyPath } from './fs-root';
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

/** 只对图片做缩略图；视频海报走 `/video/poster`，音频封面走 `/music/cover` */
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

const DEFAULT_SIZE = 256;
const MIN_SIZE = 32;
const MAX_SIZE = 2048;

export interface ThumbQuery {
  path?: string;
  size?: number;
}

const limit = createLimiter(4);

/** 同一张图的并发请求共享一次 ffmpeg（避免滚动时重复转码） */
const inflight = new Map<string, Promise<void>>();

export function clampThumbSize(input: unknown): number {
  const n = Math.round(Number(input));
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_SIZE;
  return Math.min(Math.max(n, MIN_SIZE), MAX_SIZE);
}

async function generate(k: KernelApi, src: string, out: string, size: number): Promise<void> {
  const existing = inflight.get(out);
  if (existing) return existing;

  const job = (async () => {
    const tmp = `${out}.${process.pid}-${Date.now()}.tmp.jpg`;
    try {
      await limit(() => k.media.thumb(src, tmp, size));
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
  try {
    ({ abs, rel } = relativeInRoot(root, q.path));
  } catch (err) {
    if (!isAbsoluteInput(q.path)) throw err;
    abs = resolveAnyPath(root, q.path);
    rel = path.relative(root, abs).split(path.sep).join('/');
  }

  const ext = path.extname(abs).slice(1).toLowerCase();
  if (!IMAGE_EXT.has(ext)) {
    throw httpError(400, `unsupported thumbnail source: .${ext || 'unknown'}`);
  }

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
    .update(`${rel}|${size}|${st.size}|${Math.floor(st.mtimeMs)}`)
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
      await generate(k, abs, out, size);
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
