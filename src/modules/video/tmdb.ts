import type { TmdbConfig } from '../discover/tmdb';
import { fetchImageTo, isConfigured, tmdbGet } from '../discover/tmdb';
import type { NfoMeta } from './nfo';

/**
 * 影视库刮削用的 TMDB 客户端。
 *
 * 与 `discover/tmdb.ts` 的分工：那边只负责「发现页浏览」（榜单 / 搜索卡片），
 * 这边负责「把一部片子的完整元数据搬进来」——多取 `credits` / `external_ids` /
 * `production_countries`，并把结果归一成 `NfoMeta`，与本地 NFO 走同一条入库路径。
 *
 * 这样做的意义：**本地 nfo 与在线刮削产出同构**，谁先到谁写库，不需要两套落库代码。
 */
export interface TmdbCandidate {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  title: string;
  originalTitle: string;
  year: number | null;
  score: number | null;
  overview: string;
  posterPath: string | null;
}

export interface ScrapedMeta extends NfoMeta {
  posterPath?: string | null;
  backdropPath?: string | null;
}

export function tmdbReady(cfg: TmdbConfig): boolean {
  return isConfigured(cfg);
}

function yearOf(date: unknown): number | null {
  const text = String(date ?? '');
  return /^\d{4}/.test(text) ? Number(text.slice(0, 4)) : null;
}

function num(v: unknown): number | undefined {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

function names(list: unknown, key = 'name', limit = 30): string[] {
  if (!Array.isArray(list)) return [];
  const out = list
    .map((item) => String((item as Record<string, unknown>)?.[key] ?? '').trim())
    .filter(Boolean);
  return [...new Set(out)].slice(0, limit);
}

/** 搜索结果 → 候选列表（给「手动匹配」对话框用） */
export function toCandidates(payload: unknown, mediaType: 'movie' | 'tv'): TmdbCandidate[] {
  const results = (payload as { results?: unknown })?.results;
  if (!Array.isArray(results)) return [];
  return results.slice(0, 20).map((raw) => {
    const r = raw as Record<string, unknown>;
    return {
      tmdbId: Number(r.id) || 0,
      mediaType,
      title: String(r.title ?? r.name ?? '').trim(),
      originalTitle: String(r.original_title ?? r.original_name ?? '').trim(),
      year: yearOf(r.release_date ?? r.first_air_date),
      score: num(r.vote_average) ?? null,
      overview: String(r.overview ?? '').trim(),
      posterPath: (r.poster_path as string) || null,
    };
  });
}

export async function searchTmdb(
  cfg: TmdbConfig,
  query: string,
  mediaType: 'movie' | 'tv',
  year?: number,
): Promise<TmdbCandidate[]> {
  const q = String(query ?? '').trim();
  if (!q) return [];
  const params: Record<string, string | number | undefined> = { query: q, include_adult: 'false' };
  if (year && year > 1800) {
    if (mediaType === 'tv') params.first_air_date_year = year;
    else params.year = year;
  }
  const payload = await tmdbGet(cfg, `/search/${mediaType}`, params);
  return toCandidates(payload, mediaType);
}

/**
 * 详情 → NfoMeta。`mediaType` 与 `tmdbId` 必须匹配（TMDB 的 movie / tv id 空间独立）。
 */
export async function detailTmdb(
  cfg: TmdbConfig,
  tmdbId: number,
  mediaType: 'movie' | 'tv',
): Promise<ScrapedMeta | null> {
  if (!tmdbId) return null;
  const append = mediaType === 'tv' ? 'credits,external_ids,aggregate_credits' : 'credits,external_ids';
  const data = (await tmdbGet(cfg, `/${mediaType}/${tmdbId}`, {
    append_to_response: append,
  })) as Record<string, unknown>;
  if (!data || !data.id) return null;

  const isTv = mediaType === 'tv';
  const credits = (data.credits ?? {}) as Record<string, unknown>;
  const cast = Array.isArray(credits.cast) ? credits.cast : [];
  const crew = Array.isArray(credits.crew) ? credits.crew : [];
  const directors = [
    ...names(
      crew.filter((c) => String((c as Record<string, unknown>).job ?? '') === 'Director'),
    ),
    // 剧集：主创（created_by）比 crew 更准
    ...names(data.created_by),
  ];
  const external = (data.external_ids ?? {}) as Record<string, unknown>;

  const runtime = isTv
    ? num((Array.isArray(data.episode_run_time) ? data.episode_run_time[0] : undefined) as unknown)
    : num(data.runtime);

  const studio = names(data.production_companies)[0];

  return {
    title: String(data.title ?? data.name ?? '').trim() || undefined,
    originalTitle: String(data.original_title ?? data.original_name ?? '').trim() || undefined,
    year: yearOf(data.release_date ?? data.first_air_date) ?? undefined,
    score: num(data.vote_average),
    overview: String(data.overview ?? '').trim() || undefined,
    runtimeMin: runtime,
    releaseDate:
      String(data.release_date ?? data.first_air_date ?? '').trim() || undefined,
    studio,
    genres: names(data.genres),
    regions: names(data.production_countries),
    actors: names(cast, 'name', 15),
    directors: [...new Set(directors)],
    posterPath: (data.poster_path as string) || null,
    backdropPath: (data.backdrop_path as string) || null,
    imdbId: String(external.imdb_id ?? data.imdb_id ?? '').trim() || undefined,
    tmdbId: Number(data.id) || tmdbId,
    source: 'tmdb',
  };
}

/**
 * 把 TMDB 的图片下载到本地目录，返回绝对路径。
 * 下载失败返回 null —— 调用方据此决定是否退回首帧海报，而不是写一个坏路径。
 */
export async function downloadTmdbImage(
  cfg: TmdbConfig,
  filePath: string | null | undefined,
  size: string,
  dir: string,
): Promise<string | null> {
  const p = String(filePath ?? '').trim();
  if (!p) return null;
  const got = await fetchImageTo(cfg, p, size, dir);
  return got?.file ?? null;
}

// ---------------------------------------------------------------- 标题猜测

/** 发布组 / 画质 / 编码 / 语言等噪声，用于把文件名还原成「可以拿去搜的片名」 */
const NOISE = [
  /\[[^\]]*\]/g,
  /\([^)]*\)/g,
  /\b(2160p|1440p|1080p|1080i|720p|576p|480p|4k|8k|uhd)\b/gi,
  /\b(x264|x265|h264|h265|hevc|avc|av1|10bit|8bit|12bit)\b/gi,
  /\b(hdr10\+?|hdr|sdr|dolby\s*vision|dv|hlg)\b/gi,
  /\b(remux|bluray|blu-ray|bdrip|brrip|web-dl|webdl|webrip|web|hdtv|dvdrip|hdrip|hdcam)\b/gi,
  /\b(aac|ac3|eac3|dts(-hd)?|truehd|atmos|flac|ddp?5\.1|dd5\.1|5\.1|7\.1)\b/gi,
  /\b(proper|repack|internal|extended|uncut|limited|remastered|directors?\.cut)\b/gi,
  /\b(中字|中文字幕|简中|繁中|双字|字幕|无码|流出|破解)\b/gi,
  /\b(chs|cht|gb|big5|eng|jpn)\b/gi,
];
const GROUP_TAIL = /\s-\s*[A-Za-z0-9@._]+$/;
const SEASON_EP = /\bS\d{1,2}(E\d{1,3})?\b/gi;

/**
 * 从文件名猜「片名 + 年份」。
 *
 * 这是**尽力而为**，猜错了用户可以手动搜索匹配（`/video/tmdb/search`）。
 * 宁可多搜一次，也不要在猜不准时静默写错元数据——所以这里只负责给候选，
 * 最终是否采纳由调用方（自动模式取分数最高且同年）决定。
 */
export function guessTitle(fileStem: string): { title: string; year: number | null } {
  let s = String(fileStem ?? '').trim();
  // 先摘年份。**取最后一个**合规年份，不是第一个：
  //   `Blade.Runner.2049.2017.2160p` 的第一个 4 位数是片名的一部分（2049），
  //   上映年份在片名之后、画质标记之前 —— 从右往左找才稳。
  const maxYear = new Date().getFullYear() + 2;
  let year: number | null = null;
  let lastMatch: { text: string; year: number } | null = null;
  const yearRe = /(?:^|[.\s_[［(（-])((?:18|19|20)\d{2})(?=[.\s_\])）］-]|$)/g;
  let ym: RegExpExecArray | null;
  while ((ym = yearRe.exec(s)) !== null) {
    const n = Number(ym[1]);
    if (n >= 1900 && n <= maxYear) lastMatch = { text: ym[0], year: n };
  }
  if (lastMatch) {
    year = lastMatch.year;
    // 只删这一个年份，别把片名里的数字一起删掉
    const idx = s.lastIndexOf(lastMatch.text);
    if (idx >= 0) s = `${s.slice(0, idx)} ${s.slice(idx + lastMatch.text.length)}`;
    else s = s.replace(lastMatch.text, ' ');
  }
  s = s.replace(SEASON_EP, ' ');
  for (const re of NOISE) s = s.replace(re, ' ');
  s = s.replace(GROUP_TAIL, ' ');
  // 分隔符（`.` `_`）还原成空格；连字符保留（很多片名里带 -）
  s = s.replace(/[._]+/g, ' ').replace(/\s+/g, ' ').trim();
  s = s.replace(/^[-–—\s]+|[-–—\s]+$/g, '').trim();
  return { title: s, year };
}

/**
 * 在候选里挑「最可能是这部片」的一条。
 *
 * 打分规则（刻意简单，可解释）：
 *   +3 年份完全匹配      +1 年份差 <= 1
 *   +2 标题（忽略大小写与空格）完全一致
 *   +1 候选有海报        +评分/10
 * 都为 0 分时返回第一条（有结果就比没有强），由调用方决定是否接受低分结果。
 */
export function pickBestCandidate(
  candidates: TmdbCandidate[],
  wanted: { title: string; year: number | null },
): { best: TmdbCandidate | null; score: number } {
  if (candidates.length === 0) return { best: null, score: 0 };
  const norm = (s: string) => String(s ?? '').toLowerCase().replace(/[\s:：·,，.。'’\-_]+/g, '');
  const wantTitle = norm(wanted.title);
  let best: TmdbCandidate | null = null;
  let bestScore = -1;
  for (const c of candidates) {
    let score = 0;
    if (wanted.year && c.year) {
      if (wanted.year === c.year) score += 3;
      else if (Math.abs(wanted.year - c.year) <= 1) score += 1;
    }
    if (wantTitle && (norm(c.title) === wantTitle || norm(c.originalTitle) === wantTitle)) score += 2;
    else if (wantTitle && norm(c.title).includes(wantTitle)) score += 1;
    if (c.posterPath) score += 1;
    score += Math.min(1, (c.score ?? 0) / 10);
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return { best, score: bestScore };
}
