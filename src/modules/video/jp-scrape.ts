import { proxyFetch } from '../../../kernel/proxy-fetch';

/**
 * 日本片库：**番号优先**刮削。
 *
 * 决策顺序：番号源（javdb → javbus → avsox）→ 失败才回退 TMDB。
 * 为什么番号优先：TMDB 上大量 AV 条目是「标题 == 搜索词 + overview 全是 1」的垃圾条目，
 * 先走番号源能避开这类脏数据；番号源全挂时才回退，且回退前用 `looksJunkTmdbMatch` 过滤。
 *
 * 站点结构随时会变，解析一律**宽松正则 + 精确番号比对**，任何异常都返回 null（不阻断扫描）。
 */
export type JpSource = 'javdb' | 'javbus' | 'avsox';

export const JP_SOURCE_ORDER: JpSource[] = ['javdb', 'javbus', 'avsox'];

export interface JpScrapeResult {
  source: JpSource;
  code: string;
  title: string;
  coverUrl: string | null;
  actors: string[];
  tags: string[];
  releasedAt: string | null;
  /** JavDB 评价人数（其它源没有，抓不到就是 0）—— 演员/作品综合排序的首要档位 */
  votes: number;
  /** JavDB 评分（0 = 没抓到） */
  score: number;
}

export interface JpScrapeOptions {
  timeoutMs?: number;
  /** 注入 fetch 便于测试；缺省用全局 fetch */
  fetchImpl?: typeof fetch;
  order?: JpSource[];
}

function searchUrl(source: JpSource, code: string): string {
  const q = encodeURIComponent(code);
  if (source === 'javdb') return `https://javdb.com/search?q=${q}&f=all`;
  if (source === 'javbus') return `https://www.javbus.com/${q}`;
  return `https://avsox.health/cn/search/${q}`;
}

/**
 * 从搜索结果页里挑「番号精确匹配」的详情链接。
 * javdb 的坑：搜索页第一行常是同一演员的其他作品，必须按链接文本/strong 里的番号精确比对，
 * 否则点进错误详情页，刮出来的标题和封面全是别人的。
 */
export function pickExactCodeLink(html: string, code: string): string | null {
  const norm = code.toUpperCase().replace(/[^A-Z0-9]/g, '');
  const re = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]{0,200}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const href = m[1];
    const text = m[2]
      .replace(/<[^>]+>/g, ' ')
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, '');
    if (text.includes(norm) && /\/v\/|\/movie\//.test(href)) {
      return href.startsWith('http') ? href : new URL(href, 'https://javdb.com').toString();
    }
  }
  return null;
}

/** TMDB 垃圾条目：标题与搜索词相同、且 overview 是「1111…」这类占位 */
export function looksJunkTmdbMatch(
  candidate: { title?: string | null; overview?: string | null },
  query: string,
): boolean {
  const title = String(candidate.title || '')
    .toLowerCase()
    .replace(/\s+/g, '');
  const q = String(query || '')
    .toLowerCase()
    .replace(/\s+/g, '');
  if (!title) return true;
  const placeholder = /^[0-9\W_]{0,}$/.test(String(candidate.overview || '').trim());
  return title === q && placeholder;
}

function meta(html: string, patterns: RegExp[]): string | null {
  for (const re of patterns) {
    const m = re.exec(html);
    if (m && m[1]) return m[1].trim();
  }
  return null;
}

function parseDetail(html: string, source: JpSource, code: string): JpScrapeResult | null {
  const title =
    meta(html, [
      /<h2[^>]*class="[^"]*title[^"]*"[^>]*>([\s\S]*?)<\/h2>/i,
      /<title>([\s\S]*?)<\/title>/i,
    ])?.replace(/<[^>]+>/g, '') ?? '';
  if (!title) return null;

  const coverUrl =
    meta(html, [
      /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i,
      /<img[^>]+class="[^"]*video-cover[^"]*"[^>]+src="([^"]+)"/i,
      /<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|webp))"/i,
    ]) ?? null;

  const actors = [...html.matchAll(/\/actors?\/[^"]+"[^>]*>([^<]{1,40})</gi)]
    .map((m) => m[1].trim())
    .filter(Boolean);
  const tags = [...html.matchAll(/\/tags?\/[^"]+"[^>]*>([^<]{1,40})</gi)]
    .map((m) => m[1].trim())
    .filter(Boolean);
  const releasedAt =
    meta(html, [/(\d{4}-\d{2}-\d{2})/, /(\d{4}\/\d{2}\/\d{2})/])?.replace(/\//g, '-') ?? null;

  const votes = parseVotes(html);
  const score = parseScore(html);

  return {
    source,
    code,
    title: title.replace(/\s+/g, ' ').slice(0, 200),
    coverUrl,
    actors: [...new Set(actors)].slice(0, 20),
    tags: [...new Set(tags)].slice(0, 20),
    releasedAt,
    votes,
    score,
  };
}

/**
 * 评价人数：JavDB 详情页是 `4.21分, 由4838人評價`（繁体）/ `由 4838 人评价`。
 * 只认带「人」字的那个数字 —— 页面上还有海报尺寸、时长等一堆数字，乱抓会把
 * 时长当热度，排序立刻变成「越长的片越热」。
 */
export function parseVotes(html: string): number {
  const m =
    /由\s*([\d,]{1,9})\s*人\s*(?:評價|评价|評分|评分)/i.exec(html) ??
    /([\d,]{1,9})\s*人\s*(?:評價|评价|評分|评分)/i.exec(html);
  if (!m) return 0;
  const n = Number(String(m[1]).replace(/,/g, ''));
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** 评分：`4.21分` / `score: 4.21`；超过 10 的当作误抓丢掉 */
export function parseScore(html: string): number {
  const m = /([\d.]{1,4})\s*分(?:,|\s|<)/.exec(html) ?? /"ratingValue"\s*:\s*"?([\d.]+)/i.exec(html);
  if (!m) return 0;
  const n = Number(m[1]);
  return Number.isFinite(n) && n > 0 && n <= 10 ? Math.round(n * 100) / 100 : 0;
}

async function fetchText(
  url: string,
  fetchImpl: typeof fetch,
  timeoutMs: number,
): Promise<string | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, {
      signal: controller.signal,
      headers: { 'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)' },
    });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 番号优先刮削：任一源成功即返回；全部失败返回 null（调用方回退 TMDB 或只保留文件名）。
 * 不做重试风暴：单源一次、超时即换下一个。
 */
export async function scrapeJp(
  code: string,
  opts: JpScrapeOptions = {},
): Promise<JpScrapeResult | null> {
  const clean = String(code || '')
    .trim()
    .toUpperCase();
  if (!clean) return null;
  const fetchImpl = opts.fetchImpl ?? (proxyFetch as unknown as typeof fetch);
  const timeoutMs = Math.max(1000, opts.timeoutMs ?? 8000);

  for (const source of opts.order ?? JP_SOURCE_ORDER) {
    const list = await fetchText(searchUrl(source, clean), fetchImpl, timeoutMs);
    if (!list) continue;
    const href = pickExactCodeLink(list, clean);
    if (!href) continue;
    const detail = await fetchText(href, fetchImpl, timeoutMs);
    if (!detail) continue;
    const parsed = parseDetail(detail, source, clean);
    if (parsed) return parsed;
  }
  return null;
}
