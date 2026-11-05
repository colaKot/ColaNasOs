import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import type { KernelApi } from '../../../kernel/types';
import {
  decodeSubtitleText,
  parseSubtitle,
  toWebVtt,
  type SubtitleCue,
  type SubtitleFile,
} from './subtitles';

/**
 * 内嵌字幕轨（容器里的 `subrip` / `ass` / `mov_text` 等文本字幕）。
 *
 * 对外复用外挂字幕的契约：列表里用伪文件名 `#embedded:<index>` 暴露，
 * 播放器按同一个 `/video/subtitle` 读取。真正的内容由 media sidecar 用
 * `ffmpeg -map 0:s:<index>` 抽成 SRT 落到 `dataDir/subtitles` 缓存。
 *
 * 边界：
 *   - **图形字幕**（PGS / DVD）不列出来：它们没法直接转文本，硬转只会得到空白；
 *     烧录图形字幕是另一条路（需要滤镜 / OCR），不在本迭代范围内。
 *   - 轨道列表按「绝对路径 + mtime」缓存，避免每次打开播放器都起一次 ffmpeg。
 *   - 抽取失败（轨道不存在 / 编码不支持）按「没有这条字幕」处理，不抛给前端。
 */

interface EmbeddedTrack {
  index: number;
  lang: string | null;
  codec: string;
  text: boolean;
}

export const EMBEDDED_PREFIX = '#embedded:';

const TRACK_CACHE_MAX = 256;
const trackCache = new Map<string, EmbeddedTrack[]>();

/** 伪文件名 → 轨道序号；不是内嵌字幕返回 null */
export function embeddedIndex(name: string): number | null {
  const m = /^#embedded:(\d+)$/.exec(String(name || ''));
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

export const embeddedName = (index: number): string => `${EMBEDDED_PREFIX}${index}`;

/**
 * 缓存路径按「源 + mtime + 轨道」算：源文件换了就会得到新 key，旧缓存自然失效，
 * 不需要额外的清理任务。
 */
function cachePathOf(k: KernelApi, src: string, mtime: number, index: number): string {
  const hash = crypto
    .createHash('sha1')
    .update(`${src}|${mtime}|${index}`)
    .digest('hex')
    .slice(0, 32);
  return path.join(k.paths.dataDir, 'subtitles', `emb-${hash}.srt`);
}

async function tracksOf(k: KernelApi, src: string, mtime: number): Promise<EmbeddedTrack[]> {
  if (!k.media.available()) return [];
  const key = `${src}|${mtime}`;
  const hit = trackCache.get(key);
  if (hit) return hit;
  const tracks = await k.media.subtitleTracks(src).catch(() => [] as EmbeddedTrack[]);
  if (trackCache.size >= TRACK_CACHE_MAX) {
    const oldest = trackCache.keys().next().value;
    if (oldest !== undefined) trackCache.delete(oldest);
  }
  trackCache.set(key, tracks);
  return tracks;
}

/** 内嵌字幕列表（只返回文本轨），供 `/video/subtitles` 与外挂字幕合并返回 */
export async function embeddedSubtitleFiles(
  k: KernelApi,
  src: string,
  mtime: number,
): Promise<SubtitleFile[]> {
  const tracks = await tracksOf(k, src, mtime);
  return tracks
    .filter((t) => t.text)
    .map((t) => ({
      name: embeddedName(t.index),
      lang: t.lang,
      format: 'vtt' as const,
      size: 0,
    }));
}

/** 确保某条内嵌字幕已抽成 SRT；失败返回 null（调用方按「没有」处理） */
export async function ensureEmbeddedFile(
  k: KernelApi,
  src: string,
  mtime: number,
  index: number,
): Promise<string | null> {
  const tracks = await tracksOf(k, src, mtime);
  const track = tracks.find((t) => t.index === index);
  if (!track || !track.text) return null;

  const dst = cachePathOf(k, src, mtime, index);
  try {
    if (fs.existsSync(dst) && fs.statSync(dst).size > 0) return dst;
  } catch {
    // 缓存不可读：重新抽一次
  }

  try {
    await k.media.extractSubtitle(src, index, dst, 'srt');
    return fs.existsSync(dst) && fs.statSync(dst).size > 0 ? dst : null;
  } catch {
    return null;
  }
}

/** 读取一条内嵌字幕（结构与外挂字幕一致） */
export async function readEmbeddedSubtitle(
  k: KernelApi,
  src: string,
  mtime: number,
  index: number,
): Promise<{ file: SubtitleFile; cues: SubtitleCue[]; vtt: string } | null> {
  const abs = await ensureEmbeddedFile(k, src, mtime, index);
  if (!abs) return null;

  let raw: string;
  let size: number;
  try {
    raw = decodeSubtitleText(fs.readFileSync(abs));
    size = fs.statSync(abs).size;
  } catch {
    return null;
  }
  const cues = parseSubtitle(raw, 'srt');
  const tracks = await tracksOf(k, src, mtime);
  const track = tracks.find((t) => t.index === index);
  return {
    file: { name: embeddedName(index), lang: track?.lang ?? null, format: 'vtt', size },
    cues,
    vtt: toWebVtt(cues),
  };
}
