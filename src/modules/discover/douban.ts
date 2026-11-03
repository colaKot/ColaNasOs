/**
 * 豆瓣榜单与评分（只读、可选 Cookie）。
 *
 * 两条链路：
 * 1. **榜单**：`/j/search_subjects?type=movie&tag=热门` 返回 JSON（无需登录，必须带 UA）；
 * 2. **评分**：`/j/subject_suggest?q=<标题>` 精确匹配 → `m.douban.com/rexxar/api/v2/movie/<id>`
 *    （必须带 `Referer: https://m.douban.com/`，否则 403）。
 *
 * 全部「失败返回空 / null」，不阻断发现页；结果按查询缓存 10 分钟。
 */
export interface DoubanItem {
  id: string;
  title: string;
  rating: number | null;
  coverUrl: string | null;
  url: string | null;
  year: string | null;
}

export interface DoubanOptions {
  cookie?: string;
  userAgent?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

/** 榜单 JSON → 条目（`rate` 可能是空串，统一成 null） */
export function parseChart(json: unknown): DoubanItem[] {
  const subjects = (json as { subjects?: unknown })?.subjects;
  if (!Array.isArray(subjects)) return [];
  const out: DoubanItem[] = [];
  for (const raw of subjects) {
    const s = raw as Record<string, unknown>;
    const id = String(s.id || '').trim();
    const title = String(s.title || '').trim();
    if (!id || !title) continue;
    const rate = Number(s.rate);
    out.push({
      id,
      title,
      rating: Number.isFinite(rate) && rate > 0 ? rate : null,
      coverUrl: typeof s.cover === 'string' && s.cover ? s.cover : null,
      url: typeof s.url === 'string' && s.url ? s.url : `https://movie.douban.com/subject/${id}/`,
      year: null,
    });
  }
  return out;
}

/**
 * 从 suggest 结果里挑「标题完全一致（或包含）且年份一致」的条目。
 * 豆瓣 suggest 是模糊的：只取第一条会把「同名不同片」的评分挂到错误作品上。
 */
export function pickExactSubject(
  list: unknown,
  title: string,
  year?: string | null,
): { id: string; title: string; year: string | null } | null {
  if (!Array.isArray(list)) return null;
  const target = String(title || '')
    .replace(/\s+/g, '')
    .toLowerCase();
  if (!target) return null;
  const wantYear = String(year || '').slice(0, 4);

  let best: { id: string; title: string; year: string | null } | null = null;
  for (const raw of list) {
    const s = raw as Record<string, unknown>;
    const id = String(s.id || '').trim();
    const t = String(s.title || '').trim();
    if (!id || !t) continue;
    const norm = t.replace(/\s+/g, '').toLowerCase();
    const same = norm === target || norm.includes(target) || target.includes(norm);
    if (!same) continue;
    const itemYear = String(s.year || '').slice(0, 4) || null;
    if (wantYear && itemYear && itemYear !== wantYear) continue;
    if (!best) best = { id, title: t, year: itemYear };
  }
  return best;
}

export function parseRating(json: unknown): number | null {
  const value = (json as { rating?: { value?: unknown } })?.rating?.value;
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
}

const cache = new Map<string, { at: number; data: unknown }>();
const TTL_MS = 10 * 60 * 1000;

async function getJson(
  url: string,
  opts: DoubanOptions,
  extra: Record<string, string> = {},
): Promise<unknown> {
  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new globalThis.AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 10_000));
  try {
    const res = await doFetch(url, {
      signal: controller.signal,
      headers: {
        'user-agent': opts.userAgent || UA,
        ...(opts.cookie ? { cookie: opts.cookie } : {}),
        ...extra,
      },
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function fetchDoubanChart(
  tag: string,
  opts: DoubanOptions = {},
): Promise<DoubanItem[]> {
  const key = `chart:${tag}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at <= TTL_MS) return hit.data as DoubanItem[];

  const url =
    'https://movie.douban.com/j/search_subjects?type=movie&tag=' +
    encodeURIComponent(tag || '热门') +
    '&sort=recommend&page_limit=50&page_start=0';
  const json = await getJson(url, opts);
  const items = json ? parseChart(json) : [];
  cache.set(key, { at: Date.now(), data: items });
  return items;
}

/** 按标题（+年份）取豆瓣评分；匹配不到返回 null */
export async function fetchDoubanRating(
  title: string,
  year?: string | null,
  opts: DoubanOptions = {},
): Promise<number | null> {
  const key = `rating:${title}:${year ?? ''}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at <= TTL_MS) return hit.data as number | null;

  const suggest = await getJson(
    `https://movie.douban.com/j/subject_suggest?q=${encodeURIComponent(title)}`,
    opts,
  );
  const picked = pickExactSubject(suggest, title, year);
  if (!picked) {
    cache.set(key, { at: Date.now(), data: null });
    return null;
  }

  const detail = await getJson(`https://m.douban.com/rexxar/api/v2/movie/${picked.id}`, opts, {
    referer: 'https://m.douban.com/',
  });
  const rating = detail ? parseRating(detail) : null;
  cache.set(key, { at: Date.now(), data: rating });
  return rating;
}

export function clearDoubanCache(): void {
  cache.clear();
}

/** 把豆瓣榜单条目映射成「发现页」统一形状（与 TMDB catalog 对齐；不依赖 TMDB） */
export function toCatalogItem(item: DoubanItem): {
  id: string;
  title: string;
  year: string | null;
  rating: number | null;
  coverUrl: string | null;
  source: string;
} {
  return {
    id: `douban:${item.id}`,
    title: item.title,
    year: item.year,
    rating: item.rating,
    coverUrl: item.coverUrl,
    source: 'douban',
  };
}
