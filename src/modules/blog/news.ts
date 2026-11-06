import { proxyFetch } from '../../../kernel/proxy-fetch';
import type { BlogCounts, CountKey } from './settings';

/**
 * 8 类新闻的来源与抓取。源清单来自用户提供的 OPML（`Daily News RSS Pool for Local LLM`）。
 *
 * 设计取舍：
 *   - **每类给多个源**。新闻站随时改版 / 限流，单源方案一旦挂了整类就空；
 *     多源合并后按时间排序取前 N 条。
 *   - **抓取失败不抛错**，记进 `failed` 让前端提示，其余类别照常生成。
 *   - 走 `proxyFetch`（设置页里的全局代理），否则国内网络环境抓不到国外源。
 *
 * 2026-11-06 用真实网络逐个体检了 OPML 的 29 个地址，16 个直接可用。
 * 对失效但**存在等价地址**的源做了修复（界面 / CGTN / The Conversation / Ars /
 * 华尔街见闻），并保留原 OPML 里那些暂时返回 HTML / 404 / 429 的地址
 * （澎湃 / 环球 / 机器之心 / 中国经济网 / HBR / VentureBeat），上游恢复即可自动生效；
 * 每一类都至少有两个已验证可用的源，不会出现整类空白。
 */

export interface NewsSource {
  name: string;
  url: string;
  /** 实测已失效但保留等上游恢复：失败不计入 failed，避免每天刷同样的告警 */
  optional?: boolean;
}

export interface CategoryDef {
  key: CountKey;
  /** 稿件里的播报用名（中文固定，不做 i18n：这是给耳朵听的稿件内容） */
  spoken: string;
  sources: NewsSource[];
}

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

const MAX_XML = 4 * 1024 * 1024;
const TIMEOUT_MS = 12_000;

/** 顺序即播报顺序：综合 → 科技 → AI → 财经（与 OPML 的 8 个分组一一对应） */
export const CATEGORIES: CategoryDef[] = [
  {
    key: 'domesticGeneral',
    spoken: '国内综合新闻',
    sources: [
      { name: '中国新闻网', url: 'https://www.chinanews.com.cn/rss/importnews.xml' },
      // 修复：OPML 的 /rss 是 404，官方 RSS 入口在 a 子域
      { name: '界面新闻', url: 'https://a.jiemian.com/index.php?m=article&a=rss' },
      // 保留原地址：实测返回 HTML（澎湃 / 环球已无公开 RSS），恢复后自动生效
      { name: '澎湃新闻', url: 'https://www.thepaper.cn/rss', optional: true },
      { name: '环球网', url: 'https://www.huanqiu.com/rss', optional: true },
    ],
  },
  {
    key: 'worldGeneral',
    spoken: '国际综合新闻',
    sources: [
      { name: 'ABC News', url: 'https://abcnews.go.com/abcnews/topstories' },
      { name: 'NPR World', url: 'https://feeds.npr.org/1004/rss.xml' },
      // 修复：/rss/world 是 403，订阅页的真实 XML 在 subscribe/rss/section/
      { name: 'CGTN World', url: 'https://www.cgtn.com/subscribe/rss/section/world.xml' },
      // 修复：/global/rss 是 404，Atom 版在 global/articles.atom
      { name: 'The Conversation', url: 'https://theconversation.com/global/articles.atom' },
    ],
  },
  {
    key: 'domesticTech',
    spoken: '国内科技新闻',
    sources: [
      { name: 'IT之家', url: 'https://www.ithome.com/rss' },
      { name: 'InfoQ 中文', url: 'https://www.infoq.cn/feed' },
    ],
  },
  {
    key: 'worldTech',
    spoken: '国外科技新闻',
    sources: [
      { name: 'TechCrunch', url: 'https://techcrunch.com/feed/' },
      { name: 'The Verge', url: 'https://www.theverge.com/rss/index.xml' },
      // 修复：feedburner 那份现在是空壳，官方源在 feeds.arstechnica.com
      { name: 'Ars Technica', url: 'https://feeds.arstechnica.com/arstechnica/index' },
      { name: 'Wired', url: 'https://www.wired.com/feed/rss' },
    ],
  },
  {
    key: 'domesticAi',
    spoken: '国内人工智能新闻',
    sources: [
      { name: '量子位', url: 'https://www.qbitai.com/rss' },
      { name: '钛媒体', url: 'https://www.tmtpost.com/rss' },
      // 保留原地址：/rss 返回 HTML，恢复后自动生效
      { name: '机器之心', url: 'https://www.jiqizhixin.com/rss', optional: true },
    ],
  },
  {
    key: 'worldAi',
    spoken: '国际人工智能新闻',
    sources: [
      { name: 'OpenAI News', url: 'https://openai.com/blog/rss.xml' },
      { name: 'MIT Technology Review', url: 'https://www.technologyreview.com/feed/' },
      { name: 'Hugging Face Blog', url: 'https://huggingface.co/blog/feed.xml' },
      { name: 'Google DeepMind Blog', url: 'https://deepmind.google/blog/feed/basic/' },
      // 429 是间歇限流，留着：其他 4 个源足够撑起本类
      { name: 'VentureBeat AI', url: 'https://venturebeat.com/category/ai/feed/', optional: true },
    ],
  },
  {
    key: 'domesticFinance',
    spoken: '国内财经新闻',
    sources: [
      // 修复：wallstreetcn.com/rss 是 404，实际 XML 在 dedicated 子域
      { name: '华尔街见闻', url: 'https://dedicated.wallstreetcn.com/rss.xml' },
      { name: '界面新闻（财经）', url: 'https://a.jiemian.com/index.php?m=article&a=rss' },
      // 保留原地址：/rss 是 404
      { name: '中国经济网', url: 'https://www.ce.cn/rss', optional: true },
    ],
  },
  {
    key: 'worldFinance',
    spoken: '国外财经新闻',
    sources: [
      { name: 'MarketWatch', url: 'https://feeds.marketwatch.com/marketwatch/topstories/' },
      { name: 'CNBC', url: 'https://www.cnbc.com/id/100003114/device/rss/rss.html' },
      { name: 'CGTN Business', url: 'https://www.cgtn.com/subscribe/rss/section/business.xml' },
      // 保留原地址：hbr.org/feed 是 404
      { name: 'HBR', url: 'https://hbr.org/feed', optional: true },
    ],
  },
];

export interface NewsItem {
  key: CountKey;
  spoken: string;
  title: string;
  summary: string;
  link: string;
  source: string;
  published: number | null;
}

function decodeEntities(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCharCode(Number(n)))
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

/** 去掉 HTML 标签与多余空白。摘要只留纯文本，TTS 不会被标签念出来。 */
export function plainText(html: string): string {
  return decodeEntities(html.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function tagText(block: string, names: string[]): string {
  for (const name of names) {
    const m = new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, 'i').exec(block);
    if (m && m[1].trim()) return decodeEntities(m[1]);
  }
  return '';
}

function atomLink(block: string): string {
  // <link rel="alternate" href="..."/>；RSS 的 <link>url</link> 由 tagText 处理
  const m = /<link[^>]*href=["']([^"']+)["'][^>]*\/?>/i.exec(block);
  return m ? decodeEntities(m[1]).trim() : '';
}

export interface ParsedEntry {
  title: string;
  link: string;
  summary: string;
  published: number | null;
}

/** 同时认 RSS 2.0 `<item>` 与 Atom `<entry>`（The Verge 是 Atom） */
export function parseFeed(xml: string): ParsedEntry[] {
  const blocks: string[] = [];
  for (const re of [/<item[^>]*>([\s\S]*?)<\/item>/gi, /<entry[^>]*>([\s\S]*?)<\/entry>/gi]) {
    let m: RegExpExecArray | null;
    while ((m = re.exec(xml)) !== null) blocks.push(m[1]);
  }

  const out: ParsedEntry[] = [];
  for (const block of blocks) {
    const title = plainText(tagText(block, ['title']));
    if (!title) continue;
    const link = tagText(block, ['link']) || atomLink(block);
    const summary = plainText(
      tagText(block, ['description', 'summary', 'content:encoded', 'content']),
    ).slice(0, 400);
    const dateStr = tagText(block, ['pubDate', 'published', 'updated', 'dc:date', 'date']);
    const ts = dateStr ? Date.parse(dateStr) : NaN;
    out.push({
      title: title.slice(0, 200),
      link: link.trim().slice(0, 500),
      summary,
      published: Number.isNaN(ts) ? null : Math.floor(ts / 1000),
    });
  }
  return out;
}

async function fetchFeed(url: string): Promise<string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await proxyFetch(url, {
      signal: controller.signal,
      headers: {
        // 没有 UA 的请求会被不少站点直接 403（量子位就是）
        'user-agent': UA,
        accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
      },
      redirect: 'follow',
    });
    if (!res.ok) throw new Error(`http ${res.status}`);
    const text = await res.text();
    if (text.length > MAX_XML) throw new Error('feed too large');
    return text;
  } finally {
    clearTimeout(timer);
  }
}

/** 标题归一化去重：同一条新闻在多个源里可能只差标点 / 空格 */
function titleKey(title: string): string {
  return title.replace(/[\s\p{P}\p{S}]/gu, '').slice(0, 60);
}

/**
 * 按类别抓取。每类取 `counts[key]` 条，跨源去重、按发布时间倒序。
 * 返回的 items 顺序 = 播报顺序（与 CATEGORIES 一致）。
 */
export async function fetchNews(
  counts: BlogCounts,
  log?: (msg: string) => void,
  /** 抓取倍数：大模型改写时多抓一些让它挑，兜底拼接时 1 倍即可 */
  multiplier = 1,
): Promise<{ items: NewsItem[]; failed: string[] }> {
  const failed: string[] = [];
  const items: NewsItem[] = [];
  // 跨类全局去重：同一个源会服务多个分类（界面新闻同时在「国内综合」和「国内财经」，
  // CGTN 也同时供国际综合 / 国外财经），只做类内去重会让同一条新闻在稿件里播两次。
  // 共享 seen 放在循环外；被跳过的条目由该类后续素材补足，不影响 want 条数。
  const seenGlobal = new Set<string>();
  let dropped = 0;

  for (const cat of CATEGORIES) {
    const need = counts[cat.key] || 0;
    if (need <= 0) continue;
    // 模型要"挑"，所以多给素材；上限 15 条，别把 prompt 撑爆
    const want = Math.min(need * Math.max(1, multiplier), 15);

    const settled = await Promise.allSettled(
      cat.sources.map(async (src) => ({ src, entries: parseFeed(await fetchFeed(src.url)) })),
    );
    const pool: Array<ParsedEntry & { source: string }> = [];
    settled.forEach((r, i) => {
      const src = cat.sources[i];
      if (r.status === 'fulfilled') {
        for (const e of r.value.entries) pool.push({ ...e, source: src.name });
      } else {
        const msg = `${src.name}: ${String((r.reason as Error)?.message || r.reason)}`;
        if (!src.optional) failed.push(msg);
        log?.(`[blog] ${src.name} 抓取失败${src.optional ? '（已知失效源，忽略）' : ''}：${String(r.reason)}`);
      }
    });

    // 只保留近两天：有些源（新华网 politics.xml）是几年前的静态文件，
    // 不按时间过滤就会出现「2026 年的节目里播 2022 年新冠新闻」
    const nowSec = Math.floor(Date.now() / 1000);
    const fresh = pool.filter(
      (e) => typeof e.published === 'number' && e.published > nowSec - 2 * 86400,
    );
    const stale = pool.length - fresh.length;
    if (fresh.length === 0 && pool.length > 0) {
      failed.push(`${cat.spoken}: ${cat.sources.map((s) => s.name).join('/')} 的条目都超过 2 天`);
    }
    if (stale > 0) log?.(`[blog] ${cat.spoken} 丢弃 ${stale} 条过期素材`);

    // 发布时间缺失的排在最后（不要因为没 pubDate 就丢掉）
    fresh.sort((a, b) => (b.published ?? 0) - (a.published ?? 0));

    let taken = 0;
    for (const e of fresh) {
      if (taken >= want) break;
      const k = titleKey(e.title);
      if (!k) continue;
      if (seenGlobal.has(k)) {
        dropped += 1;
        continue;
      }
      seenGlobal.add(k);
      items.push({
        key: cat.key,
        spoken: cat.spoken,
        title: e.title,
        summary: e.summary,
        link: e.link,
        source: e.source,
        published: e.published,
      });
      taken += 1;
    }
    if (taken < need) failed.push(`${cat.spoken}: 只抓到 ${taken}/${need} 条`);
  }

  if (dropped > 0) log?.(`[blog] 全局去重：丢弃 ${dropped} 条重复素材`);
  return { items, failed };
}
