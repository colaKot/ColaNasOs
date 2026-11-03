import crypto from 'node:crypto';
import path from 'node:path';

export const TAG = ['music'];
export interface TrackRow {
  id: string;
  library_id: string;
  rel_path: string;
  title: string;
  artist: string | null;
  album: string | null;
  album_artist: string | null;
  genre: string | null;
  track_no: number | null;
  year: number | null;
  duration: number | null;
  bitrate: number | null;
  sample_rate: number | null;
  channels: string | null;
  codec: string | null;
  has_cover: number;
  size: number;
  mtime: number;
  created_at?: number;
}
export interface PlaylistRow {
  id: string;
  name: string;
  owner_id: string;
  created_at: number;
  tracks: number;
  cover_track_id: string | null;
}
export function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}
export function toTrack(r: TrackRow) {
  return {
    id: r.id,
    libraryId: r.library_id,
    path: r.rel_path,
    title: r.title,
    artist: r.artist,
    album: r.album,
    albumArtist: r.album_artist,
    genre: r.genre,
    trackNo: r.track_no,
    year: r.year,
    durationMs: r.duration,
    bitrate: r.bitrate,
    sampleRate: r.sample_rate,
    channels: r.channels,
    codec: r.codec,
    hasCover: r.has_cover === 1,
    size: r.size,
  };
}
export function toPlaylist(r: PlaylistRow) {
  return {
    id: r.id,
    name: r.name,
    tracks: Number(r.tracks) || 0,
    coverTrackId: r.cover_track_id,
    createdAt: r.created_at,
  };
}
export function encodeCursor(title: string, id: string): string {
  return Buffer.from(JSON.stringify({ t: title, i: id })).toString('base64url');
}
export function decodeCursor(cursor?: string): { title: string; id: string } | null {
  if (!cursor) return null;
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')) as {
      t?: unknown;
      i?: unknown;
    };
    if (typeof parsed.t !== 'string' || typeof parsed.i !== 'string') return null;
    return { title: parsed.t, id: parsed.i };
  } catch {
    return null;
  }
}

/**
 * 排序键 cursor（`{k, i}`）：`sort` 一旦可切，cursor 就不能再假定键是 title。
 * 数字键（时长 / 年份 / 入库时间）保持 number 类型，避免 "10" < "9" 的字典序错页。
 */
export function encodeSortCursor(key: string | number, id: string): string {
  return Buffer.from(JSON.stringify({ k: key, i: id })).toString('base64url');
}

export function decodeSortCursor(cursor?: string): { key: string | number; id: string } | null {
  if (!cursor) return null;
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')) as {
      k?: unknown;
      i?: unknown;
    };
    if ((typeof parsed.k !== 'string' && typeof parsed.k !== 'number') || typeof parsed.i !== 'string') {
      return null;
    }
    return { key: parsed.k, id: parsed.i };
  } catch {
    return null;
  }
}
export function likePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}
