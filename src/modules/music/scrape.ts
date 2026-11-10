import { proxyFetch } from '../../../kernel/proxy-fetch';
import { foldHan } from './search-equiv';

/**
 * 音乐在线元数据（歌词 / 封面）。
 *
 * 本地优先：歌词读旁挂 .lrc / 内嵌标签，封面抽文件内嵌流；**只有本地拿不到**
 * 才走这里。两者都是公开免 key 的接口，出站统一复用 `kernel/proxy-fetch`——
 * 设置页配的代理（或环境变量 HTTP(S)_PROXY）会自动生效，不用另配网络。
 *
 * 实测过的两个坑（别改回「一条查询走天下」）：
 * - LRCLIB 的 `q=` **词序敏感**：「鲜花 回春丹乐队」查不到，「鲜花」有 13 条、
 *   其中 6 条正好 341s 且带同步 LRC。前端拼的关键词是「标题 + 艺人」，
 *   所以原串失败后要按单词再查一轮。
 * - iTunes 用中文「艺人 + 标题」查 song 只出 Live / 英文版，而正确的单曲封面
 *   挂在 `entity=album` 的「鲜花 - Single」上。封面先走 album 通道，
 *   再退回 song 通道按时长严格打分。
 *
 * 只返回 / 缓存内容，不往音乐目录写图片；歌词落盘沿用已有的 `/compat/lyric/set`。
 */

export interface FetchResponse {
  ok: boolean;
  status: number;
  headers: { get(name: string): string | null };
  json(): Promise<unknown>;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export type FetchLike = (url: string, init?: Record<string, unknown>) => Promise<FetchResponse>;

const defaultFetch: FetchLike = (url, init) =>
  proxyFetch(url, init) as unknown as Promise<FetchResponse>;

let fetchImpl: FetchLike = defaultFetch;

/** 冒烟专用：替换出站请求实现；传 null 恢复真实 proxyFetch */
export function __setFetch(fn: FetchLike | null): void {
  fetchImpl = fn ?? defaultFetch;
}

// LRCLIB 要求带 User-Agent，否则直接 403
const UA = 'ColaNasOs/1.0 (personal NAS music metadata)';
const JSON_TIMEOUT_MS = 8000;
const IMAGE_TIMEOUT_MS = 10_000;
const MAX_LYRIC_RESULTS = 12;
const MAX_IMAGE_BYTES = 6 * 1024 * 1024;

/** 归一：简繁折叠 + 小写 + 去掉标点空格，供标题 / 艺人比较 */
const norm = (s: unknown) =>
  foldHan(String(s ?? '').toLowerCase()).replace(/[^a-z0-9\u4e00-\u9fff]+/g, '');

async function getJson(url: string): Promise<{ ok: boolean; data: unknown; status: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), JSON_TIMEOUT_MS);
  try {
    const res = await fetchImpl(url, {
      signal: controller.signal,
      headers: { 'user-agent': UA, accept: 'application/json' },
    });
    if (!res.ok) return { ok: false, data: null, status: res.status };
    return { ok: true, data: await res.json(), status: res.status };
  } catch {
    return { ok: false, data: null, status: 0 };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- 歌词

/** 与搬运壳 `_LyricSearchItem.fromMap` 的字段一一对应；duration 是**毫秒** */
export interface LyricHit {
  id: string;
  source: string;
  title: string;
  album: string;
  artist: string;
  duration: number;
  preview: string;
  lrc: string;
}

/** 原串优先，失败再按单词（前端拼的是「标题 艺人」，靠前的词更可能是标题） */
function lyricQueries(keyword: string): string[] {
  const out = [keyword];
  for (const w of keyword.split(/\s+/).filter((x) => [...x].length >= 2)) {
    if (!out.includes(w)) out.push(w);
  }
  return out.slice(0, 4);
}

function parseLyrics(data: unknown): LyricHit[] {
  if (!Array.isArray(data)) return [];
  const out: LyricHit[] = [];
  for (const raw of data as Record<string, unknown>[]) {
    if (!raw || typeof raw !== 'object') continue;
    // 只有纯文本歌词的条目不返回：写进 .lrc 后 parseLrc 解析不出时间轴，
    // 播放器依然显示「暂无歌词」，反而往音乐目录里塞一个没用的文件。
    const lrc = String(raw.syncedLyrics ?? '').trim();
    if (!lrc) continue;
    out.push({
      id: String(raw.id ?? ''),
      source: 'lrclib',
      title: String(raw.trackName ?? raw.name ?? ''),
      album: String(raw.albumName ?? ''),
      artist: String(raw.artistName ?? ''),
      duration: Math.round(Number(raw.duration ?? 0) * 1000),
      preview: String(raw.plainLyrics ?? lrc).replace(/\s+/g, ' ').slice(0, 120),
      lrc,
    });
    if (out.length >= MAX_LYRIC_RESULTS) break;
  }
  return out;
}

export async function searchLyrics(keyword: string): Promise<LyricHit[]> {
  const q = String(keyword ?? '').trim();
  if (!q) return [];
  for (const term of lyricQueries(q)) {
    const res = await getJson(`https://lrclib.net/api/search?q=${encodeURIComponent(term)}`);
    if (!res.ok) continue;
    const hits = parseLyrics(res.data);
    if (hits.length > 0) return hits;
  }
  // 源不可达 / 查无此词都退化成空列表：界面提示「没搜到」，不报错、不阻塞播放
  return [];
}

// ---------------------------------------------------------------- 封面

export interface CoverQuery {
  title: string;
  artist?: string | null;
  album?: string | null;
  /** 库里的时长，毫秒 */
  durationMs?: number | null;
}

/** error 与 empty 必须分开：网络抖动不能写「查无此图」哨兵，否则永久拉黑 */
export type CoverLookup =
  | { kind: 'ok'; url: string; source: string }
  | { kind: 'empty' }
  | { kind: 'error'; message: string };

const bigImage = (u: string) =>
  /\/\d+x\d+bb\./.test(u) ? u.replace(/\/\d+x\d+bb\./, '/600x600bb.') : u;

/** 专辑名优先（封面本来就是专辑封套），再退标题 / 艺人+标题 */
function coverQueries(q: CoverQuery): string[] {
  const title = String(q.title ?? '').trim();
  const album = String(q.album ?? '').trim();
  const artist = String(q.artist ?? '').trim();
  const raw = [album || title, title];
  if (artist) raw.push(`${artist} ${title}`);
  return [...new Set(raw.filter((x) => [...x].length >= 2))].slice(0, 3);
}

async function itunes(term: string, entity: 'album' | 'song') {
  const url = `https://itunes.apple.com/search?term=${encodeURIComponent(term)}&entity=${entity}&limit=20`;
  return getJson(url);
}

function rowsOf(data: unknown): Record<string, unknown>[] {
  const rows = (data as { results?: unknown } | null)?.results;
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : [];
}

/** 「鲜花 - Single」这类单曲专辑要剥掉尾巴再比，否则永远等不等于「鲜花」 */
function pickAlbumCover(data: unknown, q: CoverQuery, target: string): string | null {
  const artist = norm(q.artist);
  const scored: { url: string; score: number }[] = [];
  for (const r of rowsOf(data)) {
    const small = String(r?.artworkUrl100 ?? '');
    const name = norm(r?.collectionName);
    if (!small || !name) continue;
    const clean = name.replace(/(single|ep|album|live|remix|dj版)$/g, '');
    const hit = clean === target ? 5 : clean.includes(target) || target.includes(clean) ? 2 : -99;
    if (hit < 0) continue;
    const a = norm(r?.artistName);
    const artistOk = !!artist && !!a && (a.includes(artist) || artist.includes(a));
    scored.push({
      url: bigImage(small),
      score: hit + (artistOk ? 2 : 0) + (name.includes(target) ? 2 : 0),
    });
  }
  scored.sort((a, b) => b.score - a.score);
  return scored[0]?.url ?? null;
}

/** song 通道：同名现场版 / 翻奏很多，按时长与标题打分，不拿第一条就用 */
function pickSongCover(data: unknown, q: CoverQuery, title: string): string | null {
  const ms = Number(q.durationMs ?? 0);
  const artist = norm(q.artist);
  const scored: { url: string; score: number }[] = [];
  for (const r of rowsOf(data)) {
    const small = String(r?.artworkUrl100 ?? '');
    const t = norm(r?.trackName);
    if (!small || t.length < 2 || title.length < 2) continue;
    if (!(t === title || t.includes(title) || title.includes(t))) continue;
    const candMs = Number(r?.trackTimeMillis ?? 0);
    const durOk = ms > 0 && candMs > 0 && Math.abs(candMs - ms) <= 5000;
    const a = norm(r?.artistName);
    const artistOk = !!artist && !!a && (a.includes(artist) || artist.includes(a));
    const score =
      (t === title ? 2 : 0) +
      (durOk ? 3 : 0) +
      (artistOk ? 2 : 0) -
      (ms > 0 && candMs > 0 && !durOk ? 3 : 0);
    if (score < 2) continue;
    scored.push({ url: bigImage(small), score });
  }
  scored.sort((a, b) => b.score - a.score);
  return scored[0]?.url ?? null;
}

export async function findCoverUrl(q: CoverQuery): Promise<CoverLookup> {
  const title = norm(q.title);
  if (!title) return { kind: 'empty' };
  const target = norm(q.album) || title;
  const terms = coverQueries(q);
  let sawError = false;
  for (const entity of ['album', 'song'] as const) {
    for (const term of terms) {
      const res = await itunes(term, entity);
      if (!res.ok) {
        sawError = true;
        continue;
      }
      const url = entity === 'album'
        ? pickAlbumCover(res.data, q, target)
        : pickSongCover(res.data, q, title);
      if (url) return { kind: 'ok', url, source: `itunes.${entity}` };
    }
  }
  return sawError ? { kind: 'error', message: 'itunes unreachable' } : { kind: 'empty' };
}

export async function downloadCover(url: string): Promise<Buffer | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), IMAGE_TIMEOUT_MS);
  try {
    const res = await fetchImpl(url, {
      signal: controller.signal,
      headers: { 'user-agent': UA },
    });
    if (!res.ok) return null;
    if (!String(res.headers.get('content-type') || '').startsWith('image/')) return null;
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length === 0 || buf.length > MAX_IMAGE_BYTES) return null;
    return buf;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
