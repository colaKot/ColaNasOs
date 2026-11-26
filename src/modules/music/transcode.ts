import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createLimiter } from '../media/ffmpeg-run';
import { registerExtraRoot } from '../files/fs-root';
import { extensionOf } from './ffmpeg';
import type { KernelApi } from '../../../kernel/types';
import type { TrackRow } from './util';

/**
 * 音频按需转码（SP3-04 二期）。
 *
 * 浏览器 / WebAudio 只稳定支持 mp3 / aac / flac / ogg 等常见格式，
 * APE、WMA、ALAC、AIFF 这类在 Web 端打不开；桌面端 libmpv 则全都支持。
 * 因此客户端在 Web 上请求 `format=auto`：服务端按扩展名 / 探测到的 codec 判断，
 * 需要时用 media sidecar 转码并缓存，再交给原来的 Range 下载接口；
 * 转码失败就回退原始文件，不阻断播放。
 *
 * 输出格式按源质量决定：
 * - 无损源（APE / ALAC / AIFF / WavPack / TTA / DSD …）→ FLAC，浏览器原生可解，
 *   不做有损压缩，保住「高品质音乐」；
 * - 有损源或浏览器不认的编码（WMA / AC3 / DTS …）→ AAC 192k。
 */
const WEB_UNSAFE_EXTENSIONS = new Set(['ape', 'wma', 'aiff', 'aif', 'alac']);
const WEB_UNSAFE_CODECS = new Set([
  'ape',
  'wmalossless',
  'wmav1',
  'wmav2',
  'wmapro',
  'alac',
  'tta',
  'wavpack',
  'pcm_s16be',
  'pcm_s24be',
  'pcm_s32be',
  'dsd_lsbf',
  'dsd_msbf',
  'ac3',
  'eac3',
  'dts',
  'truehd',
]);

/** 无损来源：转 FLAC 而不是 AAC，避免为了兼容浏览器牺牲音质 */
const LOSSLESS_EXTENSIONS = new Set(['ape', 'alac', 'aiff', 'aif', 'tta', 'wv', 'tak', 'shn']);
const LOSSLESS_CODECS = new Set([
  'ape',
  'alac',
  'wmalossless',
  'tta',
  'wavpack',
  'pcm_s16be',
  'pcm_s24be',
  'pcm_s32be',
  'dsd_lsbf',
  'dsd_msbf',
]);

/** 是否需要为 Web 端转码（桌面端不需要） */
export function needsAudioTranscode(
  row: Pick<TrackRow, 'rel_path'> & { codec?: string | null },
): boolean {
  if (WEB_UNSAFE_EXTENSIONS.has(extensionOf(row.rel_path))) return true;
  const codec = (row.codec ?? '').toLowerCase();
  return codec ? WEB_UNSAFE_CODECS.has(codec) : false;
}

/** Web 端转码是否应输出无损 FLAC（源本身是无损 / PCM） */
export function prefersLosslessTranscode(
  row: Pick<TrackRow, 'rel_path'> & { codec?: string | null },
): boolean {
  if (LOSSLESS_EXTENSIONS.has(extensionOf(row.rel_path))) return true;
  const codec = (row.codec ?? '').toLowerCase();
  return codec ? LOSSLESS_CODECS.has(codec) : false;
}

export function transcodeCacheKey(row: Pick<TrackRow, 'rel_path' | 'mtime'>): string {
  return crypto
    .createHash('sha1')
    .update(`${row.rel_path}:${row.mtime}:audio`)
    .digest('hex')
    .slice(0, 32);
}

export function transcodeCacheDir(k: KernelApi): string {
  return path.join(k.paths.dataDir, 'music-transcode');
}

/** 同时只跑 2 个转码，避免和封面 / 视频转码抢满 CPU */
const withTranscodeSlot = createLimiter(2);
/** 缓存上限：超出后删最旧的 */
const MAX_CACHE_FILES = 300;

function prune(dir: string): void {
  try {
    const names = fs
      .readdirSync(dir)
      .filter((n) => n.endsWith('.m4a') || n.endsWith('.flac'));
    if (names.length <= MAX_CACHE_FILES) return;
    const stats = names
      .map((n) => {
        const p = path.join(dir, n);
        try {
          return { p, ms: fs.statSync(p).mtimeMs };
        } catch {
          return { p, ms: 0 };
        }
      })
      .sort((a, b) => a.ms - b.ms);
    for (const victim of stats.slice(0, stats.length - MAX_CACHE_FILES)) {
      fs.rmSync(victim.p, { force: true });
    }
  } catch {
    // 清理失败不影响播放
  }
}

/**
 * 确保有可播放的缓存（无损源 → FLAC，其它 → AAC），
 * 返回缓存文件绝对路径；ffmpeg 不可用或转码失败返回 null。
 */
export async function ensureTranscoded(
  k: KernelApi,
  src: string,
  row: Pick<TrackRow, 'rel_path' | 'mtime'> & { codec?: string | null },
): Promise<string | null> {
  const dir = transcodeCacheDir(k);
  fs.mkdirSync(dir, { recursive: true });
  // 让 downloadHandler 的绝对路径白名单覆盖缓存目录
  registerExtraRoot(dir);

  const lossless = prefersLosslessTranscode(row);
  const out = path.join(dir, `${transcodeCacheKey(row)}.${lossless ? 'flac' : 'm4a'}`);
  try {
    if (fs.statSync(out).size > 0) {
      k.cache.record('music.transcode', true);
      return out;
    }
  } catch {
    // 缓存不存在，走转码
  }

  k.cache.record('music.transcode', false);
  const ok = await withTranscodeSlot(async () => {
    try {
      if (lossless) {
        await k.media.transcode(src, out, 'audio', { mode: 'audio', format: 'flac' });
      } else {
        await k.media.transcode(src, out, 'audio');
      }
      return fs.statSync(out).size > 0;
    } catch {
      fs.rmSync(out, { force: true });
      return false;
    }
  });
  if (!ok) return null;
  prune(dir);
  return out;
}
