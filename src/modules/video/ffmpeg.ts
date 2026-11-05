import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createLimiter, runFfmpeg, runFfprobe } from '../media/ffmpeg-run';

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
/**
 * 纯函数：`ffmpeg -i` 的 stderr → 元数据。抽出来是为了能直接拿一段文本单测，
 * 不必为了验「DV 标签有没有被认出来」去起一个 ffmpeg 进程。
 */
export function parseProbeStderr(stderr: string): VideoMeta {
  const video = streamLine(stderr, 'Video');
  const audio = streamLine(stderr, 'Audio');
  const size = video ? /\b(\d{2,5})x(\d{2,5})\b/.exec(video) : null;
  const width = size ? Number(size[1]) : null;
  const height = size ? Number(size[2]) : null;

  // HDR 标记：ffmpeg 会在 Video 行尾输出 `(..., smpte2084, ...)`，更准确的
  // 信息在紧随其后的缩进子行里：
  //     Side data:
  //       DOVI configuration record: version: 1.0, profile: 5, ...
  //       Mastering display metadata: ...
  // 这些子行**既不含 `Stream #` 也不含 `Side data:`**。早前只保留含这两个
  // 关键字的行，等于把整块 Side data 的内容丢掉 → 所有 DV / HDR10 片源都被
  // 标成 SDR（`dolby_vision=0`），播放时 `hdrToSdr=false`、tonemap 整条不启用，
  // DV P5 的 IPTPQc2 就当普通 BT.2020 直出，画面偏绿偏紫。
  // 现在只剔除 `Input #0, ..., from '<路径>'` 这一行：文件名里常带 HDR / DV 字样，
  // 留着会误判；Duration / Stream / Metadata / Side data 全部参与匹配。
  const videoSection = stderr
    .split('\n')
    .filter((line) => !/^\s*Input #\d/.test(line))
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

/**
 * `ffmpeg -i <file>` 没有输出文件时退出码为 1，但 stderr 已含完整元数据，
 * 因此这里不把退出码当失败判据。
 */
export async function probeVideo(abs: string, timeoutMs = 10_000): Promise<VideoMeta> {
  const { stderr } = await runFfmpeg(['-hide_banner', '-i', abs], timeoutMs);
  return parseProbeStderr(stderr);
}

/** 源文件里的一条音轨。`index` 是**音频轨的序号**（0 起），与转码的 `-map 0:a:N` 对齐。 */
export interface SourceAudioTrack {
  index: number;
  codec: string | null;
  language: string | null;
  title: string | null;
  channels: number | null;
  channelLayout: string | null;
  isDefault: boolean;
}

/**
 * `ffprobe -of json` → 音轨清单。纯函数，便于单测（不必起进程）。
 *
 * 为什么不用 `ffmpeg -i` 的 stderr：多轨时每条 Audio 后面的
 * `    Metadata:` / `      title : …` 缩进块是顺序挂靠的，解析容易串行；
 * ffprobe 的 JSON 里 language / title 直接挂在各自 stream 下。
 */
export function parseAudioTracks(json: string): SourceAudioTrack[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return [];
  }
  const streams = (parsed as { streams?: unknown }).streams;
  if (!Array.isArray(streams)) return [];
  const out: SourceAudioTrack[] = [];
  for (const s of streams) {
    const st = (s || {}) as Record<string, unknown>;
    const tags = (st.tags || {}) as Record<string, unknown>;
    const disp = (st.disposition || {}) as Record<string, unknown>;
    const str = (v: unknown): string | null => {
      const t = v == null ? '' : String(v).trim();
      return t === '' ? null : t;
    };
    const num = (v: unknown): number | null => {
      const n = Number(v);
      return Number.isFinite(n) && n > 0 ? n : null;
    };
    out.push({
      // 不能用 st.index：那是全局流序号（音轨前面还有视频轨），
      // 转码要的是「第几条音频」，就是数组下标。
      index: out.length,
      codec: str(st.codec_name),
      language: str(tags.language),
      title: str(tags.title),
      channels: num(st.channels),
      channelLayout: str(st.channel_layout),
      isDefault: Number(disp.default) === 1,
    });
  }
  return out;
}

/** 探源文件的所有音轨（播放器音轨菜单用）；探测失败返回空数组，不抛错。 */
export async function probeAudioTracks(
  abs: string,
  timeoutMs = 10_000,
): Promise<SourceAudioTrack[]> {
  const { stdout } = await runFfprobe(
    [
      '-v',
      'error',
      '-select_streams',
      'a',
      '-show_entries',
      'stream=codec_name,channels,channel_layout:stream_tags=language,title:stream_disposition=default',
      '-of',
      'json',
      abs,
    ],
    timeoutMs,
  );
  return parseAudioTracks(stdout);
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