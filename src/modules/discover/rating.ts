/**
 * 评分体系（TMDB / 豆瓣）与豆瓣数据补齐。
 *
 * 既有实现（既有实现）的设计口径：
 *  - 榜单/浏览/搜索始终由 TMDB 出「骨架」（海报、简介、演员都能用）；
 *  - 评分体系切到豆瓣后，卡片上的分数换成豆瓣分（`rating_douban`），TMDB 分保留；
 *  - 补齐是**惰性 + 缓存**的：同一 id 只查一次豆瓣，落 `douban_ratings` 表，
 *    之后列表直接带出来，不会再发网络请求；
 *  - 豆瓣榜单是另一条链路：豆瓣给排名/评分，海报靠 TMDB 反查（按标题搜）。
 *
 * 全部失败可降级（返回空 map / 空列表），绝不 500。
 */
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { fetchDoubanChart, fetchDoubanRating, type DoubanItem } from './douban';
import { tmdbGet, type TmdbConfig } from './tmdb';

export type RatingProvider = 'tmdb' | 'douban';

/** 豆瓣榜单 code → 豆瓣 tag（与前端 kDoubanCatalogDefs 一一对应，不许私自改名） */
export const DOUBAN_CATALOGS: Record<string, { movie: string; tv: string }> = {
  showing: { movie: 'movie_showing', tv: '' },
  hot: { movie: 'movie_hot_gaia', tv: 'tv_hot' },
  top250: { movie: 'movie_top250', tv: '' },
  weekly: { movie: 'movie_weekly_best', tv: 'tv_chinese_best_weekly' },
  weekly_global: { movie: '', tv: 'tv_global_best_weekly' },
  domestic: { movie: '', tv: 'tv_domestic' },
  american: { movie: '', tv: 'tv_american' },
  korean: { movie: '', tv: 'tv_korean' },
  japanese: { movie: '', tv: 'tv_japanese' },
  variety: { movie: '', tv: 'tv_variety_show' },
  documentary: { movie: '', tv: 'tv_documentary' },
};

/** 反查 TMDB 的并发上限：豆瓣侧没有硬限流，但打太猛会被风控 */
const ENRICH_CONCURRENCY = 4;
/** 单次补齐最多处理多少个 id（一次翻页 20~40 张卡） */
const ENRICH_MAX = 40;
/** 缓存多久算过期：豆瓣评分变化很慢，7 天足够 */
const RATING_TTL_SEC = 7 * 24 * 60 * 60;
/** 补齐失败也落一条空记录，避免每次都重试同一部片子把页面拖死 */
const MISS_TTL_SEC = 6 * 60 * 60;

export interface DoubanRatingRow {
  mediaId: number;
  mediaType: string;
  doubanId: string | null;
  rating: number | null;
  voteCount: number | null;
  url: string | null;
  updatedAt: number;
}

export function ratingProviderOf(k: KernelApi): RatingProvider {
  const raw = String(k.config.get('discover.ratingProvider') || 'tmdb');
  return raw === 'douban' ? 'douban' : 'tmdb';
}

export async function setRatingProvider(k: KernelApi, provider: unknown): Promise<RatingProvider> {
  const next: RatingProvider = String(provider) === 'douban' ? 'douban' : 'tmdb';
  await k.config.set('discover.ratingProvider', next);
  return next;
}

/** 该 (媒体类型, 榜单 code) 对应的豆瓣 tag；不可用返回空串 */
export function doubanTagOf(kind: string, code: string): string {
  const def = DOUBAN_CATALOGS[code];
  if (!def) return '';
  return String((kind === 'tv' ? def.tv : def.movie) || '');
}

const now = () => Math.floor(Date.now() / 1000);

/** 批量读缓存（只返回还在 TTL 内的） */
export async function cachedRatings(
  k: KernelApi,
  mediaType: string,
  ids: number[],
): Promise<Map<number, DoubanRatingRow>> {
  const out = new Map<number, DoubanRatingRow>();
  const list = [...new Set(ids.filter((n) => Number.isFinite(n) && n > 0))].slice(0, 200);
  if (list.length === 0) return out;
  try {
    const rows = (
      await sql<any>`
        select media_id, media_type, douban_id, rating, vote_count, url, updated_at
          from douban_ratings
         where media_type = ${mediaType} and media_id in (${sql.join(list.map((n) => sql`${n}`), sql`, `)})
      `.execute(k.db)
    ).rows;
    const floor = now() - RATING_TTL_SEC;
    for (const r of rows) {
      if (Number(r.updated_at) < floor) continue;
      out.set(Number(r.media_id), {
        mediaId: Number(r.media_id),
        mediaType: r.media_type,
        doubanId: r.douban_id ?? null,
        rating: r.rating === null ? null : Number(r.rating),
        voteCount: r.vote_count === null ? null : Number(r.vote_count),
        url: r.url ?? null,
        updatedAt: Number(r.updated_at),
      });
    }
  } catch {
    /* 缓存读失败不影响主流程 */
  }
  return out;
}

async function putRating(k: KernelApi, row: DoubanRatingRow): Promise<void> {
  try {
    await sql`
      insert into douban_ratings
        (media_id, media_type, douban_id, title, year, rating, vote_count, url, updated_at)
      values (${row.mediaId}, ${row.mediaType}, ${row.doubanId}, null, null,
              ${row.rating}, ${row.voteCount}, ${row.url}, ${row.updatedAt})
      on conflict(media_id, media_type) do update set
        douban_id = excluded.douban_id, rating = excluded.rating,
        vote_count = excluded.vote_count, url = excluded.url,
        updated_at = excluded.updated_at
    `.execute(k.db);
  } catch {
    /* 落库失败就当成没缓存，下次再补 */
  }
}

/** 把缓存里的豆瓣分贴到卡片上（不发网络请求） */
export async function attachCachedRatings<T extends { id: number }>(
  k: KernelApi,
  items: T[],
  mediaType: string,
): Promise<T[]> {
  if (items.length === 0) return items;
  const map = await cachedRatings(k, mediaType, items.map((i) => Number(i.id) || 0));
  if (map.size === 0) return items;
  return items.map((it) => {
    const hit = map.get(Number(it.id));
    if (!hit) return it;
    return {
      ...it,
      ratingDouban: hit.rating,
      doubanVoteCount: hit.voteCount,
      doubanId: hit.doubanId,
      doubanUrl: hit.url,
    };
  });
}

/** 挑一个「标题最像」的 TMDB 搜索结果（豆瓣榜单里没有年份，只能靠标题） */
function pickTmdbResult(list: any[], title: string): any | null {
  const target = String(title || '')
    .replace(/[\s·:：,，.。!！?？'"“”‘’()（）\-—_]+/g, '')
    .toLowerCase();
  if (!target) return list[0] ?? null;
  let best: any = null;
  let bestScore = 0;
  for (const raw of list) {
    const name = String(raw?.title || raw?.name || '');
    const norm = name
      .replace(/[\s·:：,，.。!！?？'"“”‘’()（）\-—_]+/g, '')
      .toLowerCase();
    if (!norm) continue;
    let score = 0;
    if (norm === target) score = 3;
    else if (norm.includes(target) || target.includes(norm)) score = 2;
    if (score > bestScore) {
      bestScore = score;
      best = raw;
    }
  }
  return best ?? list[0] ?? null;
}

function cardOf(raw: any, mediaType: string): Record<string, unknown> {
  const date = String(raw?.release_date || raw?.first_air_date || '');
  return {
    id: Number(raw?.id) || 0,
    mediaType,
    title: String(raw?.title || raw?.name || ''),
    originalTitle: String(raw?.original_title || raw?.original_name || ''),
    overview: String(raw?.overview || ''),
    posterPath: raw?.poster_path ? String(raw.poster_path) : null,
    backdropPath: raw?.backdrop_path ? String(raw.backdrop_path) : null,
    year: /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null,
    rating: Number.isFinite(Number(raw?.vote_average)) ? Number(raw.vote_average) : null,
  };
}

/** 按标题把豆瓣条目反查成 TMDB 卡片（拿不到就返回 id=0 的占位，页面不崩） */
async function resolveTmdbCard(
  cfg: TmdbConfig,
  mediaType: string,
  item: DoubanItem,
): Promise<Record<string, unknown> | null> {
  try {
    const data = await tmdbGet(cfg, `/search/${mediaType === 'tv' ? 'tv' : 'movie'}`, {
      query: item.title,
      page: 1,
    });
    const list = Array.isArray(data?.results) ? data.results : [];
    const hit = pickTmdbResult(list, item.title);
    return hit ? cardOf(hit, mediaType) : null;
  } catch {
    return null;
  }
}

async function mapLimit<T, R>(
  list: T[],
  limit: number,
  fn: (v: T, i: number) => Promise<R>,
): Promise<R[]> {
  const out: R[] = new Array(list.length);
  let cursor = 0;
  const workers = Array.from({ length: Math.min(limit, list.length) }, async () => {
    for (;;) {
      const i = cursor++;
      if (i >= list.length) return;
      out[i] = await fn(list[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

export interface EnrichResult {
  items: Record<string, {
    rating: number | null;
    vote_count: number | null;
    douban_id: string | null;
    url: string | null;
  }>;
}

/**
 * 批量补齐豆瓣评分：先读缓存，缺失的按 TMDB 详情（标题/年份）→ 豆瓣 suggest 精确匹配。
 * `mediaIds` 以字符串键返回，前端按 int 读。
 */
export async function enrichDouban(
  k: KernelApi,
  cfg: TmdbConfig,
  mediaType: string,
  mediaIds: number[],
): Promise<EnrichResult> {
  const ids = [...new Set(mediaIds.filter((n) => Number.isFinite(n) && n > 0))].slice(0, ENRICH_MAX);
  const out: EnrichResult['items'] = {};
  if (ids.length === 0) return { items: out };

  const cached = await cachedRatings(k, mediaType, ids);
  const miss: number[] = [];
  for (const id of ids) {
    const hit = cached.get(id);
    if (hit) {
      out[String(id)] = {
        rating: hit.rating,
        vote_count: hit.voteCount,
        douban_id: hit.doubanId,
        url: hit.url,
      };
    } else {
      miss.push(id);
    }
  }
  if (miss.length === 0) return { items: out };

  const fetched = await mapLimit(miss, ENRICH_CONCURRENCY, async (id) => {
    let title = '';
    let year: string | null = null;
    try {
      const detail = await tmdbGet(cfg, `/${mediaType === 'tv' ? 'tv' : 'movie'}/${id}`);
      title = String(detail?.title || detail?.name || '');
      const date = String(detail?.release_date || detail?.first_air_date || '');
      year = /^\d{4}/.test(date) ? date.slice(0, 4) : null;
    } catch {
      /* 详情拿不到就没法查豆瓣，落空记录 */
    }
    if (!title) {
      await putRating(k, {
        mediaId: id,
        mediaType,
        doubanId: null,
        rating: null,
        voteCount: null,
        url: null,
        updatedAt: Math.floor(Date.now() / 1000) - RATING_TTL_SEC + MISS_TTL_SEC,
      });
      return { id, rating: null, voteCount: null, doubanId: null, url: null };
    }
    const rating = await fetchDoubanRating(title, year);
    const row: DoubanRatingRow = {
      mediaId: id,
      mediaType,
      doubanId: null,
      rating,
      voteCount: null,
      url: rating === null ? null : `https://movie.douban.com/subject_search?search_text=${encodeURIComponent(title)}`,
      updatedAt: Math.floor(Date.now() / 1000),
    };
    // 没查到也缓存（TTL 更短），避免每次翻页都重打豆瓣
    if (rating === null) row.updatedAt = now() - RATING_TTL_SEC + MISS_TTL_SEC;
    await putRating(k, row);
    return { id, rating, voteCount: null, doubanId: null, url: row.url };
  });

  for (const r of fetched) {
    out[String(r.id)] = {
      rating: r.rating,
      vote_count: r.voteCount,
      douban_id: r.doubanId,
      url: r.url,
    };
  }
  return { items: out };
}

export interface DoubanCatalogResult {
  items: Array<Record<string, unknown>>;
  degraded: boolean;
  reason: string;
  tag: string;
  cached: number;
}

/**
 * 豆瓣榜单：豆瓣给「标题 + 评分」，TMDB 反查补海报/简介/年份。
 * fast=true 时只回已经落库的条目（首屏秒开），未命中的给占位卡。
 */
export async function doubanCatalog(
  k: KernelApi,
  cfg: TmdbConfig,
  opts: { kind: string; code: string; count: number; fast: boolean; cookie?: string },
): Promise<DoubanCatalogResult> {
  const mediaType = opts.kind === 'tv' ? 'tv' : 'movie';
  const tag = doubanTagOf(mediaType, opts.code);
  if (!tag) {
    return { items: [], degraded: true, reason: `该榜单不支持 ${mediaType}`, tag: '', cached: 0 };
  }
  const count = Math.max(1, Math.min(opts.count || 20, 40));

  if (opts.fast) {
    const rows = (
      await sql<any>`
        select payload from douban_chart
         where kind = ${mediaType} and code = ${opts.code}
         order by rank asc limit ${count}
      `.execute(k.db)
    ).rows;
    const items = rows
      .map((r) => {
        try {
          return JSON.parse(r.payload) as Record<string, unknown>;
        } catch {
          return null;
        }
      })
      .filter((v): v is Record<string, unknown> => !!v);
    return { items, degraded: false, reason: '', tag, cached: items.length };
  }

  let chart: DoubanItem[];
  try {
    chart = await fetchDoubanChart(tag, opts.cookie ? { cookie: opts.cookie } : {});
  } catch (err) {
    // 网络失败：退回上次落库的结果，别把页面清空
    const rows = (
      await sql<any>`
        select payload from douban_chart
         where kind = ${mediaType} and code = ${opts.code}
         order by rank asc limit ${count}
      `.execute(k.db)
    ).rows;
    const items = rows
      .map((r) => {
        try {
          return JSON.parse(r.payload) as Record<string, unknown>;
        } catch {
          return null;
        }
      })
      .filter((v): v is Record<string, unknown> => !!v);
    return {
      items,
      degraded: true,
      reason: String((err as Error)?.message || err).slice(0, 200),
      tag,
      cached: items.length,
    };
  }
  if (chart.length === 0) {
    return { items: [], degraded: true, reason: '豆瓣榜单为空（Cookie 可能失效）', tag, cached: 0 };
  }

  const top = chart.slice(0, count);
  const cards = await mapLimit(top, ENRICH_CONCURRENCY, async (item, i) => {
    const card = await resolveTmdbCard(cfg, mediaType, item);
    const merged: Record<string, unknown> = card
      ? { ...card }
      : {
          id: 0,
          mediaType,
          title: item.title,
          originalTitle: item.title,
          overview: '',
          posterPath: null,
          backdropPath: null,
          year: item.year ? Number(String(item.year).slice(0, 4)) : null,
          rating: null,
        };
    return {
      ...merged,
      title: String(merged.title || item.title),
      // 占位卡也要能显示海报：豆瓣封面是绝对地址，前端会原样用
      posterUrl: item.coverUrl,
      ratingDouban: item.rating,
      doubanId: item.id,
      doubanUrl: item.url,
      rank: i + 1,
    };
  });

  // 落库供 fast 首屏用（同榜同片覆盖）
  const stamp = now();
  for (const [i, card] of cards.entries()) {
    const doubanId = String(card.doubanId || '');
    if (!doubanId) continue;
    try {
      await sql`
        insert into douban_chart (kind, code, douban_id, rank, title, rating, payload, updated_at)
        values (${mediaType}, ${opts.code}, ${doubanId}, ${i + 1},
                ${String(card.title || '')}, ${(card.ratingDouban as number | null) ?? null},
                ${JSON.stringify(card)}, ${stamp})
        on conflict(kind, code, douban_id) do update set
          rank = excluded.rank, title = excluded.title, rating = excluded.rating,
          payload = excluded.payload, updated_at = excluded.updated_at
      `.execute(k.db);
    } catch {
      /* 缓存写失败不影响本次返回 */
    }
  }

  return { items: cards, degraded: false, reason: '', tag, cached: 0 };
}

export interface DoubanTestResult {
  site: { ok: boolean; elapsed_ms: number; code: string };
  cookie: { provided: boolean; valid: boolean; user: string; elapsed_ms: number; code: string };
  tmdb_match: { total: number; matched: number; match_rate: number };
  sample: { title: string; rating: number | null } | null;
}

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

/** 用 Cookie 打一次豆瓣「我的」接口判断登录态；没有 Cookie 就不测 */
async function checkCookie(cookie: string): Promise<{ valid: boolean; user: string; code: string }> {
  if (!cookie.trim()) return { valid: false, user: '', code: 'no-cookie' };
  const controller = new globalThis.AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    const res = await fetch('https://m.douban.com/rexxar/api/v2/user/me', {
      signal: controller.signal,
      headers: {
        'user-agent': UA,
        referer: 'https://m.douban.com/',
        cookie,
      },
    });
    if (!res.ok) return { valid: false, user: '', code: String(res.status) };
    const json = (await res.json()) as any;
    const name = String(json?.name || json?.user?.name || '');
    // 有名字说明登录态有效；返回 200 但没名字（游客态）也当失败
    return { valid: name.length > 0, user: name, code: name ? '200' : '200-guest' };
  } catch (err) {
    const code = (err as Error)?.name === 'AbortError' ? 'timeout' : 'network';
    return { valid: false, user: '', code };
  } finally {
    clearTimeout(timer);
  }
}

/** 豆瓣连通性自检：网站 / Cookie / TMDB 反查命中率 三段结论 */
export async function doubanTest(
  cfg: TmdbConfig,
  cookie: string,
): Promise<DoubanTestResult> {
  const started = Date.now();
  let chart: DoubanItem[] = [];
  let siteCode = '200';
  try {
    chart = await fetchDoubanChart('热门', cookie ? { cookie } : {});
    if (chart.length === 0) siteCode = 'empty';
  } catch (err) {
    siteCode = String((err as Error)?.message || err).slice(0, 40) || 'error';
  }
  const siteMs = Date.now() - started;

  const ckStarted = Date.now();
  const ck = await checkCookie(cookie);
  const cookiePart = {
    provided: cookie.trim().length > 0,
    valid: ck.valid,
    user: ck.user,
    elapsed_ms: Date.now() - ckStarted,
    code: ck.code,
  };

  // 取前 5 条做 TMDB 反查，给出「豆瓣条目能对上 TMDB」的比例
  const probe = chart.slice(0, 5);
  let matched = 0;
  if (probe.length > 0) {
    const hits = await mapLimit(probe, ENRICH_CONCURRENCY, (item) =>
      resolveTmdbCard(cfg, 'movie', item),
    );
    matched = hits.filter((c) => Number(c?.id || 0) > 0).length;
  }

  const first = chart[0];
  return {
    site: { ok: siteCode === '200', elapsed_ms: siteMs, code: siteCode },
    cookie: cookiePart,
    tmdb_match: {
      total: probe.length,
      matched,
      match_rate: probe.length === 0 ? 0 : Math.round((matched / probe.length) * 100),
    },
    sample: first ? { title: first.title, rating: first.rating } : null,
  };
}

/** 缓存占用统计（设置页展示）：豆瓣评分条数 + 榜单条数 */
export async function doubanCacheStats(k: KernelApi): Promise<{
  ratingRows: number;
  chartRows: number;
}> {
  try {
    const a = (
      await sql<{ n: number }>`select count(*) as n from douban_ratings`.execute(k.db)
    ).rows[0];
    const b = (
      await sql<{ n: number }>`select count(*) as n from douban_chart`.execute(k.db)
    ).rows[0];
    return { ratingRows: Number(a?.n || 0), chartRows: Number(b?.n || 0) };
  } catch {
    return { ratingRows: 0, chartRows: 0 };
  }
}
