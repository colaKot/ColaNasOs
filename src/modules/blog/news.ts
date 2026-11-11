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
      // 「国内」= 中国国内。importnews.xml 是中新网要闻（大量国际稿），
      // 实测 10 条里 6 条是埃及 / 美国 / 俄乌 / 日本——不能用它当国内源。
      // 改用中新网两个中国频道：时政 + 社会民生（均为当天更新的 RSS）。
      { name: '中新网国内', url: 'https://www.chinanews.com.cn/rss/china.xml' },
      { name: '中新网社会', url: 'https://www.chinanews.com.cn/rss/society.xml' },
      // 界面新闻**不再进综合类**：它的 RSS 是财经快讯流（软银股价、券商策略、
      // 日韩股市开盘），一条都不像综合新闻，还挤占了中新网的位置。
      // 它只在「国内财经」里出现（见下面 domesticFinance）。
      // 保留原地址：实测返回 HTML（澎湃已无公开 RSS），恢复后自动生效
      { name: '澎湃新闻', url: 'https://www.thepaper.cn/rss', optional: true },
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
      // 国内财经优先用中新网财经频道（国债 / 消费 / 国内政策），
      // 华尔街见闻放后面且只留中国相关条目（它默认满是美联储 / 特朗普 / 美股）。
      { name: '中新网财经', url: 'https://www.chinanews.com.cn/rss/finance.xml' },
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
    // 十六进制实体：MarketWatch / ABC 的标题里是 `&#x2018;` 这种引号，
    // 原来只认十进制，TTS 会把 `&#x2018;` 逐字符念出来（2026-11-11 顺手修掉）。
    .replace(/&#x([0-9a-f]+);/gi, (_, n: string) => codePoint(parseInt(n, 16)))
    .replace(/&#(\d+);/g, (_, n: string) => codePoint(Number(n)))
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

function codePoint(n: number): string {
  try {
    return Number.isFinite(n) && n >= 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '';
  } catch {
    return '';
  }
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

/**
 * 国内类的地域粗筛：境外事件 / 外国主体且没有中国锚点的一律不进国内素材池。
 *
 * 为什么需要：IT之家会报苹果、华尔街见闻会报美联储、中新网要闻会报埃及事故，
 * 光靠「这个源属于国内类」判断会把国外新闻播进「国内 XX」里（2026-11-10 反馈）。
 * 只做粗筛，模糊的留给模型按核心新闻点判断。
 */
const FOREIGN_MARKER =
  /(美国|美方|美军|白宫|特朗普|美联储|FBI|五角大楼|美众议院|美参议院|众议院|参议院|纳指|道指|标普|日经|日韩|软银|俄罗斯|乌克兰|泽连斯基|普京|克里姆林宫|俄乌|欧洲|以色列|巴勒斯坦|加沙|伊朗|伊拉克|埃及|沙特|也门|胡塞|土耳其|叙利亚|黎巴嫩|日本|韩国|朝鲜|印度|越南|菲律宾|英国|法国|德国|意大利|西班牙|葡萄牙|荷兰|瑞典|瑞士|加拿大|澳大利亚|新西兰|巴西|智利|阿根廷|墨西哥|委内瑞拉|南非|尼日利亚|肯尼亚|印尼|泰国|新加坡|马来西亚|巴基斯坦|阿富汗|欧盟|北约|联合国|欧佩克|OPEC|EIA|苹果|微软|谷歌|OpenAI|Anthropic|英伟达|Nvidia|特斯拉|Meta|亚马逊|三星|索尼|英特尔|高通|AMD|CoreWeave|Discord|Chrome|Netflix|Spotify|Uber|波音|空客|SpaceX|Gartner|Airbnb|彭博社|华尔街日报|路透社|法新社|CNN|BBC|CNBC|MarketWatch)/i;
// 单字的 `省|市|县` 不能当中国锚点：`上市`『超市』`城市` 都会命中，
// 于是「Anthropic 冲刺上市」被判成国内新闻（2026-11-11 实测漏进国内科技）。
const CHINA_ANCHOR =
  /(中国|我国|国内|内地|大陆|中方|国务院|中央|发改委|央行|人民银行|工信部|证监会|商务部|财政部|外交部|教育部|公安部|新华社|央视|中共|北京|上海|广东|浙江|江苏|山东|四川|湖北|湖南|河南|河北|福建|安徽|陕西|辽宁|吉林|黑龙江|重庆|天津|深圳|广州|杭州|成都|武汉|南京|苏州|香港|澳门|台湾|华为|小米|阿里|腾讯|字节|火山引擎|百度|比亚迪|格力|美的|中芯|大疆|京东|美团|拼多多|快手|滴滴|科大讯飞|商汤|旷视|蚂蚁|网易|联想|中兴|海尔|宁德|吉利|蔚来|小鹏|理想|鸿蒙|昇腾|寒武纪|地平线|智谱|月之暗面|百川|MiniMax|DeepSeek|通义|文心|豆包|Kimi|中国移动|中国电信|中国联通|国铁|中新网)/;

/**
 * 「早报 / 晨报 / 周报 / 实时更新」这类**聚合稿**：一篇里塞了十几条不相关新闻。
 *
 * 界面早报 = 算力规模 + 阿里分拆 + 金鸡奖 + 纳指 + 美联储表态，
 * 让它当某一条的素材，模型必然把同篇文章里的其它条目一起写进正文 ——
 * 2026-11-11 用户听到「国内综合」末尾突然冒出金鸡奖和美股行情，就是这一条进来的。
 */
const ROUNDUP_TITLE = /(早报|晨报|晚报|午报|午间|早餐|速览|一览|盘点|集锦|周报|简报|汇总|要闻|实时更新|滚动播报)/;

/**
 * 导购 / 促销稿：IT之家、界面这些源里混着「京东 1868 元直降」这类带货内容。
 * 它们的标题里往往带「双系统」「平台」等词，单靠技术词过滤会漏进来。
 */
const PROMO_TITLE =
  /(直降|到手价|立减|秒杀|券后|百亿补贴|补贴后|包邮|大促|低至|仅需|元起|元直降|折合|首发价|预售价|好价|促销|优惠\s*\d)/;

/** 科技类的内容相关性：标题里连一个技术词都没有，就不是科技新闻（铁路车次、送货上门都在此列） */
const TECH_TOKEN =
  /(芯片|半导体|光模块|算力|数据中心|服务器|GPU|CPU|NPU|内存|存储|操作系统|数据库|编程|编码|开源|代码|漏洞|安全|通信|5G|6G|卫星|航天|火箭|发射|量子|机器人|无人机|自动化|自动驾驶|传感器|电池|光伏|核聚变|新材料|算法|软件|硬件|云计算|边缘计算|浏览器|手机|电脑|笔记本|耳机|相机|显示|屏幕|显卡|制程|晶圆|封装|技术|研发|专利|互联网|平台|大模型|模型|训练|推理|系统|设备|App|收购|初创|人工智能|智能)/i;

/** AI 类的内容相关性：一篇文章里没提到 AI / 模型 / 算力，就不是 AI 新闻（钛媒体的民生稿都在此列） */
const AI_TOKEN =
  /(人工智能|大模型|模型|算法|智能体|Agent|机器学习|深度学习|神经网络|算力|推理|训练|多模态|具身|机器人|语音|视觉|芯片|智能|\bAI\b|\bLLM\b|\bGPT|Gemini|Claude|Copilot|\bGPU\b)/i;

function domesticCandidate(title: string, summary: string): boolean {
  const head = title.slice(0, 80);
  if (FOREIGN_MARKER.test(head) && !CHINA_ANCHOR.test(head)) return false;
  // 标题没点明、摘要通篇境外时才丢
  if (!CHINA_ANCHOR.test(head) && FOREIGN_MARKER.test(summary) && !CHINA_ANCHOR.test(summary)) {
    return false;
  }
  return true;
}

export type ScreenReason = 'roundup' | 'promo' | 'irrelevant' | 'foreign';

/**
 * 单条素材能不能进本类的素材池。纯函数、只读标题与摘要，方便离线核规则。
 *
 * 顺序：聚合稿 → 导购稿 → 内容相关性（科技 / AI 类）→ 地域（国内类）。
 * 前三条对国内外一视同仁（国外的「黑色星期五优惠盘点」同样不是科技新闻）。
 */
export function screenItem(
  key: CountKey,
  title: string,
  summary = '',
): ScreenReason | null {
  if (ROUNDUP_TITLE.test(title)) return 'roundup';
  if (PROMO_TITLE.test(title)) return 'promo';
  const isTech = key === 'domesticTech' || key === 'worldTech';
  const isAi = key === 'domesticAi' || key === 'worldAi';
  // 只看标题：摘要是整篇文章的节选，聚合稿的摘要里什么都有，拿它判相关性等于没判
  if (isTech && !TECH_TOKEN.test(title)) return 'irrelevant';
  if (isAi && !AI_TOKEN.test(title)) return 'irrelevant';
  if (key.startsWith('domestic') && !domesticCandidate(title, summary)) return 'foreign';
  return null;
}

/** 标题归一化去重：同一条新闻在多个源里可能只差标点 / 空格 */
function titleKey(title: string): string {
  return title.replace(/[\s\p{P}\p{S}]/gu, '').slice(0, 60);
}

/** 标题的 2-gram 集合：用来认「同一条新闻，不同媒体写法不同」 */
function bigrams(key: string): Set<string> {
  const out = new Set<string>();
  for (let i = 0; i + 1 < key.length; i += 1) out.add(key.slice(i, i + 2));
  return out;
}

/**
 * 两条标题是不是同一件事。
 *
 * `titleKey` 只认一模一样的标题，压不住「同一事件不同标题」：
 * 中新网《第一批新车次列车车票 今起陆续发售》和 IT之家
 * 《铁路车次改革落地：…第一批新车次列车车票今起陆续发售》在稿件里各播了一遍
 * （2026-11-11 反馈）。用 2-gram 包含率兜住这种情况。
 */
function sameEvent(a: Set<string>, b: Set<string>): boolean {
  if (a.size === 0 || b.size === 0) return false;
  let hit = 0;
  for (const g of a) if (b.has(g)) hit += 1;
  return hit / Math.min(a.size, b.size) >= 0.7;
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
  // 已收录条目的 2-gram：用来识别「同一事件、不同标题」的重复
  const seenGlobalGrams: Array<Set<string>> = [];
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

    // 三步粗筛（顺序有意义：聚合稿先剔，再看内容相关性，最后才看地域）：
    //   1. 早报 / 晨报 / 实时更新这类**聚合稿**——一篇里十几条不相关新闻，
    //      模型改写时会顺手把同篇的金鸡奖、纳指一起写进正文；
    //   2. 科技 / AI 类的**内容相关性**——「铁路车次」「送货上门新规」是 IT之家
    //      发的，但不是科技新闻；
    //   3. 国内类的**地域**——微软 / Anthropic / CoreWeave 的稿子不能播进「国内科技」。
    const reasons = { roundup: 0, promo: 0, irrelevant: 0, foreign: 0 };
    const screened = fresh.filter((e) => {
      const why = screenItem(cat.key, e.title, e.summary);
      if (why) {
        reasons[why] += 1;
        return false;
      }
      return true;
    });
    if (reasons.roundup > 0) {
      log?.(`[blog] ${cat.spoken} 剔除 ${reasons.roundup} 条聚合稿（早报/晨报/实时更新）`);
    }
    if (reasons.promo > 0) {
      log?.(`[blog] ${cat.spoken} 剔除 ${reasons.promo} 条导购/促销稿`);
    }
    if (reasons.irrelevant > 0) {
      log?.(`[blog] ${cat.spoken} 剔除 ${reasons.irrelevant} 条内容不相关素材`);
    }
    if (reasons.foreign > 0) {
      log?.(`[blog] ${cat.spoken} 剔除 ${reasons.foreign} 条境外素材`);
    }

    // 发布时间缺失的排在最后（不要因为没 pubDate 就丢掉）
    screened.sort((a, b) => (b.published ?? 0) - (a.published ?? 0));

    let taken = 0;
    for (const e of screened) {
      if (taken >= want) break;
      const k = titleKey(e.title);
      if (!k) continue;
      // 同一条新闻不同媒体的写法不同（标题对不上），用 2-gram 包含率再兜一层
      const grams = bigrams(k);
      if (seenGlobal.has(k) || seenGlobalGrams.some((g) => sameEvent(grams, g))) {
        dropped += 1;
        continue;
      }
      seenGlobal.add(k);
      seenGlobalGrams.push(grams);
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
