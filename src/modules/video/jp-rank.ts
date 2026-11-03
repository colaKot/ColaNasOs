/**
 * 日本片榜单（日 / 周 / 月 × 影片 / 演员）。
 *
 * 站点结构会变，解析一律「宽松正则 + 失败返回空」；**10 分钟新鲜期**，
 * 避免用户切 tab 时把站点打爆（JavDB 对并发很敏感，记忆中实测并发 3 即静默失败——
 * 所以这里串行抓取，不做并行）。
 *
 * 落库（`media_catalog`）：此前只有内存缓存，重启后榜单全空。现在抓到的结果会写成快照，
 * 重启后仍可读；站点抽风时回退到最近一次快照，并标记 `stale`。
 */
import { sql } from 'kysely';
import { isFresh, listSnapshots, readSnapshot, writeSnapshot } from '../../../kernel/catalog-store';
export type JpRankKind = 'movie' | 'actor';
export type JpRankPeriod = 'daily' | 'weekly' | 'monthly';

export interface JpRankItem {
  rank: number;
  code: string | null;
  title: string;
  coverUrl: string | null;
  url: string | null;
  score: number | null;
  votes: number | null;
}

const PERIOD_P = { daily: 'daily', weekly: 'weekly', monthly: 'monthly' } as const;
const KIND_T = { movie: 'movies', actor: 'actors' } as const;

/** 榜单地址（可被配置覆盖；默认 JavDB） */
export function rankUrl(base: string, kind: JpRankKind, period: JpRankPeriod): string {
  const root = String(base || 'https://javdb.com').replace(/\/$/, '');
  return `${root}/rankings/${KIND_T[kind]}?p=${PERIOD_P[period]}&t=all`;
}

/** 去水印：JavDB 部分封面被站方压了半透明水印；这里只做 URL 清洗，不保证无水印 */
export function cleanCoverUrl(url: string | null | undefined): string | null {
  const u = String(url || '').trim();
  if (!u) return null;
  if (!/^https?:\/\//i.test(u)) return null;
  return u.replace(/^http:\/\//i, 'https://');
}

export function parseRanking(html: string, base = 'https://javdb.com'): JpRankItem[] {
  const out: JpRankItem[] = [];
  const seen = new Set<string>();
  const re = /<a[^>]+href="(\/v\/[^"]+)"[^>]*>([\s\S]{0,600}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const href = m[1];
    if (seen.has(href)) continue;
    const block = m[0];
    const img = /<img[^>]+src="([^"]+)"/i.exec(m[2]);
    const rawTitle = /title="([^"]{2,200})"/i.exec(block)?.[1] ?? m[2].replace(/<[^>]+>/g, ' ');
    const title = String(rawTitle).replace(/\s+/g, ' ').trim();
    if (!title) continue;
    const codeMatch = /\b([A-Z]{2,6}[-_ ]?\d{2,5})\b/.exec(title.toUpperCase());
    seen.add(href);
    out.push({
      rank: out.length + 1,
      code: codeMatch ? codeMatch[1].replace(/[_ ]/g, '-') : null,
      title,
      coverUrl: cleanCoverUrl(img?.[1]),
      url: href.startsWith('http') ? href : `${base}${href}`,
      score: null,
      votes: null,
    });
  }
  return out.slice(0, 50);
}

interface CacheEntry {
  at: number;
  items: JpRankItem[];
}

const cache = new Map<string, CacheEntry>();
/** 进程内新鲜期：10 分钟（JavDB 对并发敏感，不要打太勤） */
const TTL_SEC = 10 * 60;
/** 落库后过期快照保留 7 天，用于站点抽风时兜底 */
const RETAIN_SEC = 7 * 24 * 3600;

export interface JpRankResult {
  items: JpRankItem[];
  /** true = 本次是"抓取失败，回退到最近一次快照" */
  stale: boolean;
  /** 这份数据的抓取时间（Unix 秒）；0 表示既没抓到也没快照 */
  snapshotAt: number;
}

export interface FetchRankOptions {
  base?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
  /** 测试绕过缓存 */
  noCache?: boolean;
  /**
   * 传了才落库（`media_catalog`，catalog_type = jp_rank）。
   * 不传时退化为纯内存缓存 —— 单元测试不需要建库。
   */
  db?: any;
  /** 新鲜期（秒），默认 10 分钟 */
  ttlSec?: number;
  retainSec?: number;
}

const nowSec = () => Math.floor(Date.now() / 1000);

function itemsOf(payload: unknown): JpRankItem[] {
  if (Array.isArray(payload)) return payload as JpRankItem[];
  const nested = (payload as { items?: unknown })?.items;
  return Array.isArray(nested) ? (nested as JpRankItem[]) : [];
}

export async function fetchJpRank(
  kind: JpRankKind,
  period: JpRankPeriod,
  opts: FetchRankOptions = {},
): Promise<JpRankResult> {
  const base = (opts.base || 'https://javdb.com').replace(/\/$/, '');
  const url = rankUrl(base, kind, period);
  const cacheKey = `${kind}:${period}:${base}`;
  const ttl = Math.max(30, Number(opts.ttlSec) || TTL_SEC);

  // ① 进程内
  const hit = cache.get(cacheKey);
  if (!opts.noCache && hit && Date.now() - hit.at <= ttl * 1000) {
    return { items: hit.items, stale: false, snapshotAt: Math.floor(hit.at / 1000) };
  }

  // ② 数据库快照：新鲜就直接用，完全不联网
  if (opts.db) {
    const snap = await readSnapshot(opts.db, 'jp_rank', cacheKey).catch(() => null);
    if (snap && isFresh(snap.snapshotAt, ttl)) {
      const items = itemsOf(snap.payload);
      if (items.length > 0) {
        cache.set(cacheKey, { at: Date.now(), items });
        return { items, stale: false, snapshotAt: snap.snapshotAt };
      }
    }
  }

  // ③ 上游
  const doFetch = opts.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 10_000));
  try {
    const res = await doFetch(url, {
      signal: controller.signal,
      headers: {
        // JavDB 需要年龄确认 + 中文 locale
        cookie: 'over18=1; locale=zh',
        'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)',
      },
    });
    if (!res.ok) return await fallback(opts, cacheKey);
    const html = await res.text();
    const items = parseRanking(html, base);
    // 解析出空（站点结构变了 / 被限流）也走兜底，别把"抓到了但空"当成新数据覆盖旧快照
    if (items.length === 0) return await fallback(opts, cacheKey);
    cache.set(cacheKey, { at: Date.now(), items });
    if (opts.db) {
      await writeSnapshot(opts.db, 'jp_rank', cacheKey, items, {
        itemCount: items.length,
        retainSec: opts.retainSec ?? RETAIN_SEC,
      }).catch(() => undefined);
    }
    return { items, stale: false, snapshotAt: nowSec() };
  } catch {
    return await fallback(opts, cacheKey);
  } finally {
    clearTimeout(timer);
  }
}

/** 上游失败：有快照就给它，没有就空 —— 绝不抛错打断列表页 */
async function fallback(opts: FetchRankOptions, cacheKey: string): Promise<JpRankResult> {
  if (!opts.db) return { items: [], stale: false, snapshotAt: 0 };
  const snap = await readSnapshot(opts.db, 'jp_rank', cacheKey).catch(() => null);
  if (!snap) return { items: [], stale: false, snapshotAt: 0 };
  return { items: itemsOf(snap.payload), stale: true, snapshotAt: snap.snapshotAt };
}

export function clearRankCache(): void {
  cache.clear();
}

/** 连同落库的快照一起清掉（设置页"清空榜单缓存"用） */
export async function clearRankSnapshots(db: any): Promise<number> {
  cache.clear();
  marksCache.clear();
  const res = await sql`delete from media_catalog where catalog_type = 'jp_rank'`.execute(db);
  return Number(res.numAffectedRows || 0);
}

/** code → 名次 的映射缓存（列表每页都要用，别每次读 payload） */
const marksCache = new Map<string, { at: number; map: Map<string, number> }>();

/**
 * 最新一期榜单的 `番号 → 名次` 映射，用于在列表卡片上标「日榜第 3」。
 *
 * 读的是落库快照（不联网）；没有快照就返回空 Map，卡片自然不显示角标。
 * 只在列表里真的存在 `code` 时才会被调用，普通影视库不打这份数据。
 */
export async function rankMarksOf(
  db: any,
  period: JpRankPeriod = 'daily',
  ttlSec = 60,
): Promise<Map<string, number>> {
  const hit = marksCache.get(period);
  if (hit && Date.now() - hit.at < ttlSec * 1000) return hit.map;

  const snaps = (await listSnapshots(db, 'jp_rank').catch(() => [])).filter((r) =>
    r.key.startsWith(`movie:${period}:`),
  );
  if (snaps.length === 0) return new Map();
  const snap = await readSnapshot(db, 'jp_rank', snaps[0].key).catch(() => null);
  const map = new Map<string, number>();
  for (const it of itemsOf(snap?.payload)) {
    const code = String(it.code ?? '').trim().toUpperCase();
    if (code && it.rank > 0) map.set(code, it.rank);
  }
  marksCache.set(period, { at: Date.now(), map });
  return map;
}
