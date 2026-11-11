import crypto from 'node:crypto';
import path from 'node:path';

export const TAG = ['video'];
export interface MediaRow {
  id: string;
  library_id: string;
  rel_path: string;
  title: string;
  duration: number | null;
  width: number | null;
  height: number | null;
  video_codec: string | null;
  audio_codec: string | null;
  container: string;
  has_subtitle: number;
  size: number;
  mtime: number;
  series: string | null;
  season: number | null;
  episode: number | null;
  media_type?: string | null;
  taken_at?: number | null;
  code?: string | null;
  uncensored?: number | null;
  chinese_sub?: number | null;
  favorite?: number | null;
  is_4k?: number | null;
  hdr10?: number | null;
  hdr10plus?: number | null;
  hlg?: number | null;
  dolby_vision?: number | null;
  dolby_atmos?: number | null;
  // —— 媒体信息层（迁移 080_video_nfo）
  nfo_name?: string | null;
  nfo_original_name?: string | null;
  nfo_year?: number | null;
  nfo_score?: number | null;
  nfo_overview?: string | null;
  nfo_runtime?: number | null;
  nfo_release_date?: string | null;
  nfo_studio?: string | null;
  nfo_genres?: string | null;
  nfo_regions?: string | null;
  nfo_actors?: string | null;
  nfo_directors?: string | null;
  nfo_poster?: string | null;
  nfo_fanart?: string | null;
  nfo_thumb?: string | null;
  nfo_imdb_id?: string | null;
  nfo_douban_id?: string | null;
  nfo_tmdb_id?: number | null;
  nfo_source?: string | null;
  nfo_updated_at?: number | null;
  match_nfo?: number | null;
  /** 每用户已观看（查询时 left join video_watch 得到） */
  watched?: number | null;
}
export type VideoItemRow = MediaRow;
export function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}

/** 把 JSON 数组列安全读成字符串数组；坏数据一律当空数组，不让一条脏行炸掉整页 */
function jsonList(raw: string | null | undefined): string[] {
  const text = String(raw ?? '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    if (!Array.isArray(parsed)) return [];
    return parsed.map((v) => String(v ?? '').trim()).filter(Boolean);
  } catch {
    // 兼容早期「逗号分隔」写法
    return text
      .split(/[,，|]/)
      .map((v) => v.trim())
      .filter(Boolean);
  }
}

const CJK_TITLE = /[\u3400-\u9fff]/;

/** 发布名里自带的中文片名（未刮削时的兜底），没有中文返回空串 */
function zhFromFileTitle(raw: string): string {
  const s = String(raw || '');
  if (!CJK_TITLE.test(s)) return '';
  // \x5B/[ \x5D/] \u3010/【 \u3011/】：字符类里直接写 \[ 会被 no-useless-escape 报错
  const bracket = /[\x5B\u3010]([^\x5D\u3011]*[\u3400-\u9fff][^\x5D\u3011]*)[\x5D\u3011]/.exec(s);
  if (bracket && String(bracket[1] || '').trim().length >= 2) {
    return String(bracket[1]).trim();
  }
  const segs = s.match(/[\u3400-\u9fff][\u3400-\u9fff0-9A-Za-z·：:，,、\s]*/g) || [];
  let best = '';
  for (const seg of segs) {
    const t = seg.trim().replace(/[\s.,·:：，、]+$/, '').trim();
    if (t.length >= 2 && t.length <= 40 && t.length > best.length) best = t;
  }
  return best;
}

/** 对外展示用的片名：刮削名优先，没有才回退文件名去扩展名 */
export function displayTitleOf(r: MediaRow): string {
  const nfo = String(r.nfo_name ?? '').trim();
  if (nfo) return nfo;
  // 还没刮削时，文件名里自带的中文片名（国产 / 译制片很常见）优先展示，
  // 别把一整串英文发布名甩给用户；纯英文文件名保持原样，等刮削补中文名。
  const file = String(r.title ?? '').trim();
  return zhFromFileTitle(file) || file;
}

/**
 * 同一目录里多部影片共用的海报（常见于「一个演员一个目录，只有一张 poster.jpg」）。
 * 这种封面没有区分度，清掉后前端会回退到视频自己的首帧，每部片都不一样。
 */
export function dropSharedArtwork<T extends Record<string, any>>(rows: T[], minShared = 3): T[] {
  const counter = new Map<string, number>();
  for (const r of rows || []) {
    const dir = String(r?.rel_path || '').replace(/\\/g, '/').replace(/[^/]+$/, '');
    const poster = String(r?.nfo_poster || '').trim();
    if (!dir || !poster) continue;
    const key = `${dir}\u0000${poster}`;
    counter.set(key, (counter.get(key) || 0) + 1);
  }
  for (const r of rows || []) {
    const dir = String(r?.rel_path || '').replace(/\\/g, '/').replace(/[^/]+$/, '');
    const poster = String(r?.nfo_poster || '').trim();
    if (!dir || !poster) continue;
    if ((counter.get(`${dir}\u0000${poster}`) || 0) >= minShared) {
      (r as any).nfo_poster = null;
      (r as any).nfo_thumb = null;
      (r as any).nfo_fanart = null;
    }
  }
  return rows;
}

/** image_items 行 → 与视频同构的 MediaRow（列表 / 文件夹封面共用） */
export function imageToMediaRow(r: {
  id: string;
  library_id: string;
  rel_path: string;
  title: string;
  size: number;
  mtime: number;
  width?: number | null;
  height?: number | null;
  taken_at?: number | null;
  mime?: string | null;
}): MediaRow {
  return {
    id: r.id,
    library_id: r.library_id,
    rel_path: r.rel_path,
    title: r.title,
    duration: null,
    width: r.width ?? null,
    height: r.height ?? null,
    video_codec: null,
    audio_codec: null,
    container: String(r.mime || ''),
    has_subtitle: 0,
    size: r.size,
    mtime: r.mtime,
    series: null,
    season: null,
    episode: null,
    media_type: 'image',
    taken_at: r.taken_at ?? null,
  };
}

export function toItem(r: MediaRow) {
  const mediaType = String(r.media_type || 'video');
  return {
    id: r.id,
    libraryId: r.library_id,
    mediaType,
    path: r.rel_path,
    // title 保持「可直接显示」的语义：刮削名优先
    title: displayTitleOf(r),
    /** 文件名派生的原名（刮削前 / 想按文件名找回时用） */
    fileTitle: r.title,
    durationMs: r.duration,
    width: r.width,
    height: r.height,
    videoCodec: r.video_codec,
    audioCodec: r.audio_codec,
    container: r.container,
    hasSubtitle: r.has_subtitle === 1,
    size: r.size,
    series: r.series,
    season: r.season,
    episode: r.episode,
    takenAt: r.taken_at == null ? null : Number(r.taken_at),
    code: r.code ?? null,
    uncensored: Number(r.uncensored) === 1,
    chineseSub: Number(r.chinese_sub) === 1,
    favorite: Number(r.favorite) === 1,
    is4k: Number(r.is_4k) === 1,
    hdr10: Number(r.hdr10) === 1,
    hdr10plus: Number(r.hdr10plus) === 1,
    hlg: Number(r.hlg) === 1,
    dolbyVision: Number(r.dolby_vision) === 1,
    dolbyAtmos: Number(r.dolby_atmos) === 1,
    // —— 媒体信息
    originalName: r.nfo_original_name ?? null,
    year: r.nfo_year == null || Number(r.nfo_year) <= 0 ? null : Number(r.nfo_year),
    score: r.nfo_score == null ? null : Number(r.nfo_score),
    overview: r.nfo_overview ?? null,
    runtimeMin: r.nfo_runtime == null || Number(r.nfo_runtime) <= 0 ? null : Number(r.nfo_runtime),
    releaseDate: r.nfo_release_date ?? null,
    studio: r.nfo_studio ?? null,
    genres: jsonList(r.nfo_genres),
    regions: jsonList(r.nfo_regions),
    actors: jsonList(r.nfo_actors),
    directors: jsonList(r.nfo_directors),
    /** 有值即「已刮削」；客户端据此决定海报走 /video/art 还是首帧回退 */
    hasArt: !!(String(r.nfo_poster ?? '').trim() || String(r.nfo_thumb ?? '').trim()),
    imdbId: r.nfo_imdb_id ?? null,
    doubanId: r.nfo_douban_id ?? null,
    tmdbId: r.nfo_tmdb_id == null ? null : Number(r.nfo_tmdb_id),
    nfoSource: r.nfo_source ?? null,
    watched: Number(r.watched) === 1,
  };
}

/**
 * 排序键 → SQL。`nfo_name` 为空时回退 `title`，保证未刮削的条目也能参与排序。
 * 返回 `{ expr, numeric }`：numeric 决定 cursor 里存数字还是字符串。
 */
export const SORT_KEYS = [
  'name',
  'createTime',
  'viewTime',
  'year',
  'score',
  'takenTime',
  'duration',
] as const;
export type SortKey = (typeof SORT_KEYS)[number];

export function isSortKey(v: unknown): v is SortKey {
  return (SORT_KEYS as readonly string[]).includes(String(v ?? ''));
}

/** 排序键 cursor：`{title, id}` JSON → base64url（标题可含任意字符，不能用分隔符拼接） */
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
export function likePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}
/** 时间游标：`takenAt|id` → base64url（图片 / 混合库用；纯视频库仍用标题游标） */
export function encodeTimeCursor(takenAt: number, id: string): string {
  return Buffer.from(`${takenAt}|${id}`).toString('base64url');
}
export function decodeTimeCursor(cursor?: string): { takenAt: number; id: string } | null {
  if (!cursor) return null;
  try {
    const text = Buffer.from(cursor, 'base64url').toString('utf8');
    const [taken, id] = text.split('|');
    const takenAt = Number(taken);
    if (!Number.isFinite(takenAt) || !id) return null;
    return { takenAt, id };
  } catch {
    return null;
  }
}

/**
 * 排序游标：`{v: 排序键的值, i: id}` → base64url。
 *
 * 与标题游标的区别：排序键可能是数字（年份 / 评分 / 时间）也可能是字符串（名字），
 * 所以值原样存进 JSON，不做类型假设。`{t,i}` / `|` 两种老格式仍能被
 * `decodeCursor` / `decodeTimeCursor` 认出来，老客户端的分页不会因为这次扩展而失效。
 */
export function encodeSortCursor(value: string | number, id: string): string {
  return Buffer.from(JSON.stringify({ v: value, i: id })).toString('base64url');
}

export function decodeSortCursor(
  cursor?: string,
): { value: string | number; id: string } | null {
  if (!cursor) return null;
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')) as {
      v?: unknown;
      i?: unknown;
    };
    if (typeof parsed.i !== 'string' || parsed.i === '') return null;
    if (typeof parsed.v === 'number' || typeof parsed.v === 'string') {
      return { value: parsed.v, id: parsed.i };
    }
    // 排序键可能是 NULL（比如没有 created_at），当成空串参与比较
    return { value: '', id: parsed.i };
  } catch {
    return null;
  }
}
