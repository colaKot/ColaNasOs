import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createLimiter, runFfmpeg } from '../media/ffmpeg-run';

export { resolvedFfmpeg } from '../media/ffmpeg-run';

/**
 * 视频元数据与海报（依赖 jellyfin-ffmpeg，二进制由 tool/fetch-ffmpeg.js 拉取）。
 *
 *   - `probeVideo`：`ffmpeg -i` 的 stderr 解析时长 / 宽高 / 编码 / 字幕（不真正解码，快）
 *   - `writePoster`：抽一帧存 JPEG，供海报墙使用（懒生成 + 文件缓存）
 */
export const VIDEO_EXTENSIONS = new Set([
  'mp4',
  'm4v',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'webm',
  'ts',
  'mpg',
  'mpeg',
  'rmvb',
  'rm',
]);

export interface VideoMeta {
  /** 毫秒；探测失败为 null */
  durationMs: number | null;
  width: number | null;
  height: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  hasSubtitle: boolean;
  /** 以下标记全部来自扫描期 stderr，不需要重扫库 */
  is4k: boolean;
  hdr10: boolean;
  hdr10plus: boolean;
  hlg: boolean;
  dolbyVision: boolean;
  dolbyAtmos: boolean;
}

export function extensionOf(file: string): string {
  const base = file.split(/[\\/]/).pop() || '';
  const idx = base.lastIndexOf('.');
  return idx < 0 ? '' : base.slice(idx + 1).toLowerCase();
}

export function isVideoFile(file: string): boolean {
  return VIDEO_EXTENSIONS.has(extensionOf(file));
}

export function titleOf(file: string): string {
  const base = file.split(/[\\/]/).pop() || '';
  const idx = base.lastIndexOf('.');
  return (idx < 0 ? base : base.slice(0, idx)).trim() || base;
}

function parseDuration(stderr: string): number | null {
  const m = /Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d{2})/.exec(stderr);
  if (!m) return null;
  const [, h, mi, s, cs] = m;
  const ms = (Number(h) * 3600 + Number(mi) * 60 + Number(s) + Number(cs) / 100) * 1000;
  return Number.isFinite(ms) && ms > 0 ? Math.round(ms) : null;
}

function streamLine(stderr: string, kind: string): string | null {
  return stderr.split('\n').find((line) => line.includes(`${kind}:`)) ?? null;
}

/**
 * `ffmpeg -i <file>` 没有输出文件时退出码为 1，但 stderr 已含完整元数据，
 * 因此这里不把退出码当失败判据。
 */
export async function probeVideo(abs: string, timeoutMs = 10_000): Promise<VideoMeta> {
  const { stderr } = await runFfmpeg(['-hide_banner', '-i', abs], timeoutMs);

  const video = streamLine(stderr, 'Video');
  const audio = streamLine(stderr, 'Audio');
  const size = video ? /\b(\d{2,5})x(\d{2,5})\b/.exec(video) : null;
  const width = size ? Number(size[1]) : null;
  const height = size ? Number(size[2]) : null;

  // HDR 标记：ffmpeg 会在 Video 行尾输出 `(..., smpte2084, ...)` 或
  // `Side data: Mastering display metadata / DOVI configuration record`。
  // 判据收窄到 stderr 的 Video/Stream 段落，避免文件名里带 "HDR" 误判。
  const videoSection = stderr
    .split('\n')
    .filter((line) => line.includes('Stream #') || line.includes('Side data:'))
    .join('\n');
  const dolbyVision = /DOVI configuration record|dv_profile|Dolby Vision/i.test(videoSection);
  const hdr10plus = /HDR10\+|SMPTE ST 2094|hdr10plus/i.test(videoSection);
  const hlg = /arib-std-b67|HLG/i.test(videoSection);
  const hdr10 = /smpte2084|Mastering display metadata/i.test(videoSection);

  return {
    durationMs: parseDuration(stderr),
    width,
    height,
    videoCodec: video ? (/Video:\s*([^\s,]+)/.exec(video)?.[1] ?? null) : null,
    audioCodec: audio ? (/Audio:\s*([^\s,]+)/.exec(audio)?.[1] ?? null) : null,
    hasSubtitle: stderr.includes('Subtitle:'),
    is4k: (width ?? 0) >= 3840 || (height ?? 0) >= 2160,
    hdr10,
    hdr10plus,
    hlg,
    dolbyVision,
    dolbyAtmos: /Atmos/i.test(audio ?? ''),
  };
}

/** 海报生成并发上限：不抢占转码 / 扫描的 CPU */
const withPosterSlot = createLimiter(2);

export async function writePoster(
  abs: string,
  out: string,
  durationMs: number | null,
  size = 640,
): Promise<boolean> {
  const seek = durationMs && durationMs > 6000 ? 3 : 0;
  const ok = await withPosterSlot(async () => {
    const { code } = await runFfmpeg(
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-ss',
        String(seek),
        '-i',
        abs,
        '-frames:v',
        '1',
        '-vf',
        `scale=${size}:-2`,
        '-q:v',
        '4',
        out,
      ],
      20_000,
    );
    return code === 0;
  });

  if (!ok) return false;
  try {
    const st = await fsp.stat(out);
    if (st.size > 0) return true;
  } catch {
    /* 落到下面清理 */
  }
  fs.rmSync(out, { force: true });
  return false;
}