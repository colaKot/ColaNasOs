import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createLimiter, runFfmpeg } from '../media/ffmpeg-run';

/**
 * 音乐元数据与封面（依赖 jellyfin-ffmpeg）。
 *
 * `ffmpeg -i` 的 stderr 已包含容器级 tags（title/artist/album/track/date）与音频流参数，
 * 不需要额外依赖；内嵌封面从 `(attached pic)` 视频流抽一帧。
 */
export const AUDIO_EXTENSIONS = new Set([
  'mp3',
  'flac',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'opus',
  'wma',
  'ape',
  'alac',
  'aiff',
  'aif',
]);

export interface AudioMeta {
  durationMs: number | null;
  bitrate: number | null;
  sampleRate: number | null;
  channels: string | null;
  codec: string | null;
  title: string | null;
  artist: string | null;
  album: string | null;
  albumArtist: string | null;
  genre: string | null;
  trackNo: number | null;
  year: number | null;
  hasCover: boolean;
}

export function extensionOf(file: string): string {
  const base = file.split(/[\\/]/).pop() || '';
  const idx = base.lastIndexOf('.');
  return idx < 0 ? '' : base.slice(idx + 1).toLowerCase();
}

export function isAudioFile(file: string): boolean {
  return AUDIO_EXTENSIONS.has(extensionOf(file));
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

/** 只取第一个 Metadata 块（容器级），后续流级 tags 不覆盖 */
function parseContainerTags(stderr: string): Record<string, string> {
  const tags: Record<string, string> = {};
  const lines = stderr.split('\n');
  let inBlock = false;
  for (const raw of lines) {
    const line = raw.replace(/\r$/, '');
    if (/^\s+Metadata:\s*$/.test(line)) {
      if (inBlock) break; // 第二个 Metadata（流级）跳过
      inBlock = true;
      continue;
    }
    if (!inBlock) continue;
    if (/^\S/.test(line)) break; // 块结束（Duration / Stream #）
    const m = /^\s{2,}([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
    if (m) tags[m[1].toLowerCase()] = m[2].trim();
  }
  return tags;
}

function parseYear(date: string | undefined): number | null {
  if (!date) return null;
  const m = /\b(19|20)\d{2}\b/.exec(date);
  return m ? Number(m[0]) : null;
}

function parseTrackNo(track: string | undefined): number | null {
  if (!track) return null;
  const m = /^(\d{1,3})/.exec(track.trim());
  return m ? Number(m[1]) : null;
}

export async function probeAudio(abs: string, timeoutMs = 10_000): Promise<AudioMeta> {
  const { stderr } = await runFfmpeg(['-hide_banner', '-i', abs], timeoutMs);

  const tags = parseContainerTags(stderr);
  const audioLine = stderr.split('\n').find((l) => l.includes('Audio:')) ?? '';
  const bitrateMatch = /bitrate:\s*(\d+)\s*kb\/s/.exec(stderr);
  const rateMatch = /Audio:.*?(\d{3,6})\s*Hz/.exec(audioLine);
  const channelMatch = /Audio:.*?Hz,\s*([^,]+),/.exec(audioLine);
  const codecMatch = /Audio:\s*([^\s,]+)/.exec(audioLine);

  return {
    durationMs: parseDuration(stderr),
    bitrate: bitrateMatch ? Number(bitrateMatch[1]) : null,
    sampleRate: rateMatch ? Number(rateMatch[1]) : null,
    channels: channelMatch ? channelMatch[1].trim() : null,
    codec: codecMatch ? codecMatch[1] : null,
    title: tags.title || null,
    artist: tags.artist || null,
    album: tags.album || null,
    albumArtist: tags.album_artist || tags.albumartist || null,
    genre: tags.genre || null,
    trackNo: parseTrackNo(tags.track),
    year: parseYear(tags.date || tags.year),
    hasCover: stderr.includes('(attached pic)'),
  };
}

const withCoverSlot = createLimiter(2);

/** 抽取内嵌封面；无封面或失败返回 false（调用方回 404） */
export async function writeCover(abs: string, out: string, size = 320): Promise<boolean> {
  const ok = await withCoverSlot(async () => {
    const { code } = await runFfmpeg(
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        abs,
        '-map',
        '0:v:0',
        '-frames:v',
        '1',
        '-vf',
        `scale=${size}:-2`,
        '-q:v',
        '3',
        out,
      ],
      20_000,
    );
    return code === 0;
  });

  if (!ok) {
    fs.rmSync(out, { force: true });
    return false;
  }
  try {
    const st = await fsp.stat(out);
    if (st.size > 0) return true;
  } catch {
    /* 落到下面清理 */
  }
  fs.rmSync(out, { force: true });
  return false;
}