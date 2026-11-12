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
  /** TMDB popularity：同名 / 同年的小成本纪录片与正片只能靠它区分 */
  popularity?: number | null;
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
      popularity: Number(r.popularity) || 0,
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

// ------------------------------------------------------------ 手动搜索的「编号」写法

/**
 * 手动搜索框里能直接定位到一条的写法。
 *
 * 用户经常手里已经有 TMDB / IMDb 的编号或链接，靠片名搜同名片（纪录片、翻拍）
 * 很容易挑错，所以这些写法必须直连：
 * - IMDb：`tt0137523`、`https://www.imdb.com/title/tt0137523/`
 * - TMDB 链接：`https://www.themoviedb.org/movie/550`、`/tv/1399`
 * - 前缀：`tmdb:550`、`movie:550`、`tv:1399`
 * - 纯数字：当 TMDB id，类型先按调用方的来，404 再试另一种
 */
export type TmdbQueryRef =
  | { kind: 'text'; q: string }
  | { kind: 'imdb'; imdbId: string }
  | { kind: 'id'; tmdbId: number; mediaType?: 'movie' | 'tv' };

export function parseTmdbQuery(raw: unknown): TmdbQueryRef {
  const q = String(raw ?? '').trim();
  if (!q) return { kind: 'text', q };

  // IMDb 编号优先：任何带 tt 编号的链接都算
  const imdb = /\btt\d{6,10}\b/i.exec(q);
  if (imdb) return { kind: 'imdb', imdbId: imdb[0].toLowerCase() };

  // TMDB 链接：https://www.themoviedb.org/movie/550-the-fight-club
  const link = /\b(movie|tv)\/(\d{1,9})\b/i.exec(q);
  if (link) {
    return {
      kind: 'id',
      tmdbId: Number(link[2]),
      mediaType: link[1].toLowerCase() === 'tv' ? 'tv' : 'movie',
    };
  }

  // 前缀写法：tmdb:550 / movie:550 / tv:1399（全角冒号也认）
  const prefix = /^(tmdb|movie|tv)\s*[:：]\s*(\d{1,9})$/i.exec(q);
  if (prefix) {
    const tag = prefix[1].toLowerCase();
    return {
      kind: 'id',
      tmdbId: Number(prefix[2]),
      mediaType: tag === 'tv' ? 'tv' : tag === 'movie' ? 'movie' : undefined,
    };
  }

  // 纯数字：当 TMDB id
  if (/^\d{1,9}$/.test(q)) return { kind: 'id', tmdbId: Number(q) };

  return { kind: 'text', q };
}

/** 详情 / find 结果 → 候选（手动匹配列表里的一行） */
function candidateOf(
  data: Record<string, unknown>,
  mediaType: 'movie' | 'tv',
): TmdbCandidate | null {
  const id = Number(data?.id) || 0;
  if (!id) return null;
  return {
    tmdbId: id,
    mediaType,
    title: String(data.title ?? data.name ?? '').trim(),
    originalTitle: String(data.original_title ?? data.original_name ?? '').trim(),
    year: yearOf(data.release_date ?? data.first_air_date),
    score: num(data.vote_average) ?? null,
    overview: String(data.overview ?? '').trim(),
    posterPath: (data.poster_path as string) || null,
  };
}

/** 按 id 取详情当候选；404 返回 null，好让调用方换另一种类型再试一次。 */
async function candidateById(
  cfg: TmdbConfig,
  id: number,
  mediaType: 'movie' | 'tv',
): Promise<TmdbCandidate | null> {
  try {
    const data = (await tmdbGet(cfg, `/${mediaType}/${id}`)) as Record<string, unknown>;
    return candidateOf(data, mediaType);
  } catch (err) {
    // 只有 404 才是「这个 id 不属于这种类型」，网络错误必须往上抛
    if (/HTTP 404/.test(String((err as Error)?.message ?? err))) return null;
    throw err;
  }
}

/** IMDb → TMDB `/find`；期望的类型排前面，另一种也带上（同一部片可能两种都有） */
async function findByImdb(
  cfg: TmdbConfig,
  imdbId: string,
  prefer: 'movie' | 'tv',
): Promise<TmdbCandidate[]> {
  const payload = (await tmdbGet(cfg, `/find/${imdbId}`, {
    external_source: 'imdb_id',
  })) as Record<string, unknown>;
  const pick = (list: unknown, type: 'movie' | 'tv') => {
    const rows = Array.isArray(list) ? (list as Record<string, unknown>[]) : [];
    return rows
      .slice(0, 3)
      .map((r) => candidateOf(r, type))
      .filter((c): c is TmdbCandidate => c != null);
  };
  const movies = pick(payload.movie_results, 'movie');
  const tvs = pick(payload.tv_results, 'tv');
  return prefer === 'tv' ? [...tvs, ...movies] : [...movies, ...tvs];
}

/**
 * 手动搜索的统一入口：编号 / 链接直连，其余走原来的关键字搜索。
 */
export async function resolveTmdbQuery(
  cfg: TmdbConfig,
  raw: unknown,
  mediaType: 'movie' | 'tv',
  year?: number,
): Promise<TmdbCandidate[]> {
  const parsed = parseTmdbQuery(raw);
  if (parsed.kind === 'text') return searchTmdb(cfg, parsed.q, mediaType, year);
  if (parsed.kind === 'imdb') return findByImdb(cfg, parsed.imdbId, mediaType);
  const types: ('movie' | 'tv')[] = parsed.mediaType
    ? [parsed.mediaType]
    : [mediaType, mediaType === 'tv' ? 'movie' : 'tv'];
  for (const t of types) {
    const hit = await candidateById(cfg, parsed.tmdbId, t);
    if (hit) return [hit];
  }
  // 纯数字也可能是片名 / 年份（"1984"）：id 查不到就退回关键字搜索。
  // 明确写了 movie:/tv: 前缀的不退，那是用户点名要这个 id。
  if (!parsed.mediaType) return searchTmdb(cfg, String(raw).trim(), mediaType, year);
  return [];
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
  // 音频规格写在**最前面**：`DTS-HDMA7.1` 里的 `DTS` 会被下面那条短的
  // `\b(...|dts(-hd)?|...)\b` 先吃掉一半，剩 `-HDMA7.1` 再也匹配不到任何规则，
  // 结果片名里留着 `-HDMA7 1`，拿去搜 TMDB 命中 0 条（2026-11-11 实测）。
  /(?:^|[\s._-])(?:dts[- .]?hd(?:[- .]?ma)?|truehd|ddp|eac3|ac3|aac|flac|atmos|opus)[\s.-]*\d(?:[.\s]\d)?/gi,
  /\b(2160p|1440p|1080p|1080i|720p|576p|480p|4k|8k|uhd|muhd)\b/gi,
  /\b(x264|x265|h264|h265|hevc|avc|av1|10bit|8bit|12bit)\b/gi,
  // `H.265` / `H 265` 这种带分隔符的写法
  /\b[hb][ ._-]?26[45]\b/gi,
  /\b(hdr10\+?|hdr|sdr|dolby\s*vision|dv|hlg)\b/gi,
  // 源标签顺序敏感：下面 MA 与 iTunes 两条都必须排在再下面的 `web` 那条**前面**：
  // 否则 `WEB` 先被清掉，前瞻里就找不到 web 了。带前瞻限定是为了不误删片名《It》。
  // `DTS-HD.MA.5.1` 之外还会有**裸 `MA`**（`2160p.MA.WEB-DL`）。留在片名里搜 TMDB
  // 会直接 0 命中（实测 `Resident Evil MA` / `The Odyssey MA`）。
  // 只在后面紧跟 WEB / 编码 / 音轨标记时才删，避免误伤片名《Ma》。
  /(?:^|[\s._-])ma(?=[\s._-]+(?:web[- .]?dl|webrip|web|x26[45]|h26[45]|hevc|avc|dts|truehd|ddp|atmos|aac|ac3)\b)/gi,
  /\bit(?=[\s._-]?web)/gi,
  /\b(remux|bluray|blu-ray|bdrip|brrip|web-dl|webdl|webrip|web|hdtv|dvdrip|hdrip|hdcam)\b/gi,
  /\b(aac|ac3|eac3|dts(-hd)?|truehd|atmos|flac|ddp?5\.1|dd5\.1|5\.1|7\.1)\b/gi,
  // 杜比视界的常见缩写写法（`DoVi` / `Do.Vi`）
  /\b(?:dovi|dolby[ .-]?vision)\b/gi,
  /\b(proper|repack|internal|extended|uncut|limited|remastered|directors?\.cut)\b/gi,
  // 国家 / 地区缩写是发布名里的固定标签，留在片名里搜不到东西。
  // 刻意不收 `us`（会把《Us》这种片名整个删掉），也不收两位的 `it`（《It》）。
  /\b(?:usa|eur|ger|ita|fra|jpn|chn|hk|tw|kor|rus)\b/gi,
  /\b(中字|中文字幕|简中|繁中|双字|字幕|无码|流出|破解)\b/gi,
  /\b(chs|cht|gb|big5|eng|jpn)\b/gi,
  // 半截括号：`(2026)` 被年份逻辑整段摘走后，留着孤零零的 `)` 会进片名
  /[()[\]{}]+/g,
];
const GROUP_TAIL = /\s-\s*[A-Za-z0-9@._]+$/;
// 发布组尾巴跟 `10bit-CHD` 连在一起时上面那条（要求「空格 + -」）匹配不到，
// 清完标签会剩一个 `-CHD`。只吃「空格 + 连字符 + 全大写/数字」，
// 片名里的 `Spider-Man`、`- Fallout` 这种带小写或空格的不会被误删。
const GROUP_TAIL_GLUED = /\s-[A-Z0-9]{2,10}$/;
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
  // `S01.E01` 被分隔符切成两半时，SEASON_EP 只吃掉了 `S01`，剩一个裸集号
  s = s.replace(/\bE\d{1,3}\b/gi, ' ');
  for (const re of NOISE) s = s.replace(re, ' ');
  s = s.replace(GROUP_TAIL, ' ');
  s = s.replace(GROUP_TAIL_GLUED, ' ');
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
 *   +1 候选有海报        +评分/10        +min(2, log10(popularity+1))
 * 都为 0 分时返回第一条（有结果就比没有强），由调用方决定是否接受低分结果。
 *
 * 为什么要 popularity：TMDB 里同名条目很多，而且「幕后纪录片」常常和正片同年上映
 * （《奥德赛》2026 的纪录片《…: The Making of an Epic》就有独立条目）。
 * 只按年份 + 标题打分会把低热度纪录片排到正片前面，热度项把这类误配压下去。
 */
export function pickBestCandidate(
  candidates: TmdbCandidate[],
  wanted: { title: string; titles?: readonly string[]; year: number | null },
): { best: TmdbCandidate | null; score: number } {
  if (candidates.length === 0) return { best: null, score: 0 };
  const norm = (s: string) => String(s ?? '').toLowerCase().replace(/[\s:：·,，.。'’\-_]+/g, '');
  // 一次刮削会用多个查询词（NFO 片名 / 文件名），候选只要匹配其中任意一个即可
  const wantTitles = [...new Set([wanted.title, ...(wanted.titles ?? [])].map(norm).filter(Boolean))];
  let best: TmdbCandidate | null = null;
  let bestScore = -1;
  for (const c of candidates) {
    let score = 0;
    if (wanted.year && c.year) {
      if (wanted.year === c.year) score += 3;
      else if (Math.abs(wanted.year - c.year) <= 1) score += 1;
    }
    let titleScore = 0;
    for (const wantTitle of wantTitles) {
      const exact = norm(c.title) === wantTitle || norm(c.originalTitle) === wantTitle;
      const partial = norm(c.title).includes(wantTitle) || norm(c.originalTitle).includes(wantTitle);
      titleScore = Math.max(titleScore, exact ? 2 : partial ? 1 : 0);
    }
    score += titleScore;
    if (c.posterPath) score += 1;
    score += Math.min(1, (c.score ?? 0) / 10);
    score += Math.min(2, Math.log10((c.popularity ?? 0) + 1));
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return { best, score: bestScore };
}
