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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

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
      // 以前这里有 ABC News topstories：那是**美国国内**头条流，会把「某州弹药厂
      // 爆炸」这类美国地方事故当成国际新闻播（2026-11-25 用户反馈），已移除。
      // 现在按「真正跑国际新闻的通讯社 / 公共广播」组源，避免整段都是美国视角。
      { name: 'BBC World', url: 'https://feeds.bbci.co.uk/news/world/rss.xml' },
      // 亚洲视角：以前只有欧美源，国际综合听着像欧美台
      { name: 'CNA Asia', url: 'https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml' },
      { name: 'The Japan Times', url: 'https://www.japantimes.co.jp/feed/' },
      { name: 'Al Jazeera', url: 'https://www.aljazeera.com/xml/rss/all.xml' },
      { name: 'DW World', url: 'https://rss.dw.com/rdf/rss-en-world' },
      { name: 'France 24', url: 'https://www.france24.com/en/rss' },
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
      // 补两个非美国视角的科技源：上面四家全是美国媒体，只靠它们会「整段美国科技」
      { name: 'BBC Technology', url: 'https://feeds.bbci.co.uk/news/technology/rss.xml' },
      { name: 'The Register', url: 'https://www.theregister.com/headlines.atom' },
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
      // 非美国视角：BBC 商业覆盖欧洲 / 亚洲，避免整段都是美股美股
      { name: 'BBC Business', url: 'https://feeds.bbci.co.uk/news/business/rss.xml' },
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
  // 注意 `<item[^>]*>` 会把 RDF 的 `<items>` 容器也匹配进来（DW 就是 RDF），
  // 截到的是「容器开头 … 第一条真实 item 结尾」，标题取到的是 channel 图片的
  // `<title>DW</title>` —— 2026-11-26 「国际综合」里出现一条标题就叫「DW」的
  // 新闻就是它。必须要求 `<item` 后面紧跟空白或直接结束，不能是 `<items>`。
  for (const re of [
    /<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/gi,
    /<entry(?:\s[^>]*)?>([\s\S]*?)<\/entry>/gi,
  ]) {
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

/** 抓不到就退避重试：04:00 定时任务那会儿代理偶尔抖一下，一次失败就等于整类没素材 */
const FETCH_ATTEMPTS = 3;
const FETCH_RETRY_MS = [700, 2000];

/** 4xx（除 429 限流）是源本身的问题，重试只是白等，直接抛 */
function retriable(err: unknown): boolean {
  const msg = String((err as Error)?.message || err);
  const m = /^http (\d{3})$/.exec(msg);
  if (!m) return true;
  const code = Number(m[1]);
  return code === 429 || code >= 500;
}

async function fetchFeedOnce(url: string): Promise<string> {
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

async function fetchFeed(url: string): Promise<string> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < FETCH_ATTEMPTS; attempt += 1) {
    try {
      return await fetchFeedOnce(url);
    } catch (e) {
      lastErr = e;
      const wait = FETCH_RETRY_MS[attempt];
      if (wait == null || !retriable(e)) break;
      await sleep(wait);
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
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

/**
 * 美国地方新闻：标题点了 50 州里的某个州，又没有全球性关键词。
 *
 * 2026-11-25 用户反馈「国际综合」里播了美国某州弹药厂爆炸，这种本地事故
 * 对境外听众没有信息量。Georgia / Washington / New York 不列进来 ——
 * 它们要么是别的国家，要么常出现在全球政治 / 金融新闻里。
 */
const US_LOCAL_STATE =
  /\b(Alabama|Alaska|Arizona|Arkansas|California|Colorado|Connecticut|Delaware|Florida|Hawaii|Idaho|Illinois|Indiana|Iowa|Kansas|Kentucky|Louisiana|Maine|Maryland|Massachusetts|Michigan|Minnesota|Mississippi|Missouri|Montana|Nebraska|Nevada|Ohio|Oklahoma|Oregon|Pennsylvania|Tennessee|Texas|Utah|Vermont|Virginia|West Virginia|Wisconsin|Wyoming|North Carolina|South Carolina|North Dakota|South Dakota|Rhode Island|New Hampshire|New Jersey|New Mexico)\b/;

/** 出现这些词说明是全球性议题（或全球性公司），即使带州名也该保留 */
const WORLD_ANCHOR =
  /\b(China|Chinese|Russia|Russian|Ukraine|Europe|European|EU|NATO|UN|United Nations|Israel|Gaza|Palestin\w*|Iran|Iraq|Syria|India|Japan|Korea|Taiwan|Trump|White House|Congress|Senate|Pentagon|Fed|Federal Reserve|tariff|sanction|election|nuclear|AI|chip|semiconductor|SpaceX|NASA|OpenAI|Google|Apple|Microsoft|Meta|Amazon|Tesla|Nvidia|Texas Instruments|iPhone|Android|satellite|economy|inflation|market|trade)\b/i;

/** AI 类的内容相关性：一篇文章里没提到 AI / 模型 / 算力，就不是 AI 新闻（钛媒体的民生稿都在此列） */
const AI_TOKEN =
  /(人工智能|大模型|模型|算法|智能体|Agent|机器学习|深度学习|神经网络|算力|推理|训练|多模态|具身|机器人|语音|视觉|芯片|智能|\bAI\b|\bLLM\b|\bGPT|Gemini|Claude|Copilot|\bGPU\b)/i;

/** 国际类里的美国地方新闻：没有全球锚点就丢 */
function usLocalStory(key: CountKey, title: string): boolean {
  if (!key.startsWith('world')) return false;
  return US_LOCAL_STATE.test(title) && !WORLD_ANCHOR.test(title);
}

function domesticCandidate(title: string, summary: string): boolean {
  const head = title.slice(0, 80);
  if (FOREIGN_MARKER.test(head) && !CHINA_ANCHOR.test(head)) return false;
  // 标题没点明、摘要通篇境外时才丢
  if (!CHINA_ANCHOR.test(head) && FOREIGN_MARKER.test(summary) && !CHINA_ANCHOR.test(summary)) {
    return false;
  }
  return true;
}

export type ScreenReason = 'roundup' | 'promo' | 'irrelevant' | 'foreign' | 'usLocal';

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
  if (usLocalStory(key, title)) return 'usLocal';
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

/** 英文虚词：判断「是不是同一件事」时不该算分 */
const STOP_WORDS = new Set([
  'the', 'a', 'an', 'and', 'or', 'but', 'of', 'for', 'to', 'in', 'on', 'at', 'by',
  'with', 'from', 'as', 'is', 'are', 'was', 'were', 'be', 'been', 'it', 'its',
  'this', 'that', 'these', 'those', 'after', 'before', 'over', 'under', 'new',
  'says', 'say', 'said', 'amid', 'into', 'about', 'up', 'down', 'out', 'will',
  'would', 'can', 'could', 'has', 'have', 'had', 'more', 'than', 'one', 'two',
  'not', 'no', 'you', 'your', 'we', 'our', 'they', 'their', 'he', 'she', 'his',
  'her', 'us', 'who', 'what', 'when', 'where', 'why', 'how',
]);

/**
 * 英文标题的实词集合。
 *
 * 中文用 2-gram 足够，但英文经过 `titleKey` 去掉空格后只剩一长串字母，
 * 两家美国媒体写同一起事故（标题措辞不同）几乎不可能有 70% 的 2-gram 重合 ——
 * 这是「弹药厂爆炸」同一天播两次的直接原因之一。
 */
function wordsOf(title: string): Set<string> {
  const out = new Set<string>();
  for (const w of title.toLowerCase().match(/[a-z][a-z0-9'-]{2,}/g) ?? []) {
    if (!STOP_WORDS.has(w)) out.add(w);
  }
  return out;
}

/** 两条标题的实词重合率（只看英文实词，中文标题这里是空集） */
function sameWords(a: Set<string>, b: Set<string>): boolean {
  if (a.size < 3 || b.size < 3) return false;
  let hit = 0;
  for (const w of a) if (b.has(w)) hit += 1;
  return hit / Math.min(a.size, b.size) >= 0.6;
}

/**
 * 两条标题是不是同一件事。
 *
 * `titleKey` 只认一模一样的标题，压不住「同一事件不同标题」：
 * 中新网《第一批新车次列车车票 今起陆续发售》和 IT之家
 * 《铁路车次改革落地：…第一批新车次列车车票今起陆续发售》在稿件里各播了一遍
 * （2026-11-11 反馈）。用 2-gram 包含率兜住这种情况；英文再叠一层实词重合率。
 */
function sameEvent(
  aGrams: Set<string>,
  bGrams: Set<string>,
  aWords: Set<string>,
  bWords: Set<string>,
): boolean {
  if (sameWords(aWords, bWords)) return true;
  if (aGrams.size === 0 || bGrams.size === 0) return false;
  let hit = 0;
  for (const g of aGrams) if (bGrams.has(g)) hit += 1;
  return hit / Math.min(aGrams.size, bGrams.size) >= 0.7;
}

/** 链接指纹：同一条新闻在不同源里的链接可能带 utm / 尾斜杠 */
function linkKey(link: string): string {
  return String(link || '')
    .trim()
    .toLowerCase()
    .replace(/[?#].*$/, '')
    .replace(/\/+$/, '');
}

/** 近几天已经播过的素材（由调用方从往期稿件里读出来） */
export interface RecentNewsItem {
  title: string;
  link: string;
}

/**
 * 时效窗口：2 天 → 5 天 → 10 天，取够就停。
 *
 * 为什么必须放宽：OpenAI / DeepMind / Hugging Face 这类博客一周才更一篇，
 * 卡死 2 天会让整类空掉 —— 2026-11-15 / 16 / 17 连续三天「国际AI 只抓到 0~1/3」，
 * 成稿条数从 30 掉到 26 / 25 / 24 就是这个原因。放宽后仍按时间倒序取，最新的优先；
 * 且放宽只在**粗筛后条数不够**时发生（`composeScript` 会把提示词的时间窗口跟着放宽，
 * 否则模型按「素材不在窗口内不得使用」的规则照样一条不用）。
 */
const FRESH_WINDOWS = [5, 10];
const ALL_WINDOWS = [2, ...FRESH_WINDOWS];

/** 某类素材不够时，隔几秒把失败的源再抓一次（04:00 那期 13 个境外源同时抖动，几秒后就好了） */
const REFILL_PAUSE_MS = 4000;

interface PoolEntry extends ParsedEntry {
  source: string;
}

function datedWithin(pool: PoolEntry[], nowSec: number, days: number): PoolEntry[] {
  return pool.filter((e) => typeof e.published === 'number' && e.published > nowSec - days * 86400);
}

/** 抓一组源，失败不抛错：能用的进 pool，失败的分开收集（optional 只记日志，不算故障） */
async function fetchPool(
  sources: NewsSource[],
  log: ((msg: string) => void) | undefined,
  quiet = false,
): Promise<{ pool: PoolEntry[]; failed: string[]; failedSources: NewsSource[] }> {
  const settled = await Promise.allSettled(
    sources.map(async (src) => ({ src, entries: parseFeed(await fetchFeed(src.url)) })),
  );
  const pool: PoolEntry[] = [];
  const failed: string[] = [];
  const failedSources: NewsSource[] = [];
  settled.forEach((r, i) => {
    const src = sources[i];
    if (r.status === 'fulfilled') {
      for (const e of r.value.entries) pool.push({ ...e, source: src.name });
      return;
    }
    const why = String((r.reason as Error)?.message || r.reason);
    if (!src.optional) {
      failed.push(`${src.name}: ${why}`);
      failedSources.push(src);
    }
    if (!quiet) {
      log?.(`[blog] ${src.name} 抓取失败${src.optional ? '（已知失效源，忽略）' : ''}：${why}`);
    }
  });
  return { pool, failed, failedSources };
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
  /** 最近几天已经播过的素材：同一条新闻不再重复播 */
  recent: RecentNewsItem[] = [],
): Promise<{ items: NewsItem[]; failed: string[] }> {
  const failed: string[] = [];
  const items: NewsItem[] = [];
  // 跨类全局去重：同一个源会服务多个分类（界面新闻同时在「国内综合」和「国内财经」，
  // CGTN 也同时供国际综合 / 国外财经），只做类内去重会让同一条新闻在稿件里播两次。
  // 共享 seen 放在循环外；被跳过的条目由该类后续素材补足，不影响 want 条数。
  const seenGlobal = new Set<string>();
  // 已收录条目的 2-gram / 实词：用来识别「同一事件、不同标题」的重复
  const seenGlobalGrams: Array<Set<string>> = [];
  const seenGlobalWords: Array<Set<string>> = [];
  let dropped = 0;

  // 近几天（默认 7 天）播过的素材：链接 / 标题都做成指纹。
  // 以前去重只在「本期内部」做，昨天的稿子重播、今天手动再生成一遍又把同样几条
  // 播一次，都是这么来的（2026-11-25 用户反馈「弹药厂爆炸播了好几次」）。
  const recentLinks = new Set<string>();
  const recentKeys = new Set<string>();
  const recentGrams: Array<Set<string>> = [];
  const recentWords: Array<Set<string>> = [];
  for (const r of recent) {
    const lk = linkKey(r.link);
    if (lk) recentLinks.add(lk);
    const key = titleKey(r.title || '');
    if (!key) continue;
    recentKeys.add(key);
    recentGrams.push(bigrams(key));
    recentWords.push(wordsOf(r.title));
  }
  let recentDropped = 0;

  for (const cat of CATEGORIES) {
    const need = counts[cat.key] || 0;
    if (need <= 0) continue;
    // 模型要"挑"，所以多给素材；上限 15 条，别把 prompt 撑爆
    const want = Math.min(need * Math.max(1, multiplier), 15);
    const nowSec = Math.floor(Date.now() / 1000);

    const first = await fetchPool(cat.sources, log);
    let pool = first.pool;
    let bad = first.failed;
    const badSources = first.failedSources;

    // 三步粗筛（顺序有意义：聚合稿先剔，再看内容相关性，最后才看地域）：
    //   1. 早报 / 晨报 / 实时更新这类**聚合稿**——一篇里十几条不相关新闻，
    //      模型改写时会顺手把同篇的金鸡奖、纳指一起写进正文；
    //   2. 科技 / AI 类的**内容相关性**——「铁路车次」「送货上门新规」是 IT之家
    //      发的，但不是科技新闻；
    //   3. 国内类的**地域**——微软 / Anthropic / CoreWeave 的稿子不能播进「国内科技」。
    const rank = (entries: PoolEntry[], report: boolean): PoolEntry[] => {
      const reasons = { roundup: 0, promo: 0, irrelevant: 0, foreign: 0, usLocal: 0 };
      const screened = entries.filter((e) => {
        const why = screenItem(cat.key, e.title, e.summary);
        if (why) {
          reasons[why] += 1;
          return false;
        }
        return true;
      });
      if (report) {
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
        if (reasons.usLocal > 0) {
          log?.(`[blog] ${cat.spoken} 剔除 ${reasons.usLocal} 条美国地方新闻`);
        }
      }
      // 发布时间缺失的排在最后（不要因为没 pubDate 就丢掉）
      screened.sort((a, b) => (b.published ?? 0) - (a.published ?? 0));
      return screened;
    };

    let taken = 0;
    // 本类已经收下的标题：补抓后二次取用时跳过它们，别算进「全局去重丢弃」里
    const takenKeys = new Set<string>();
    const take = (screened: PoolEntry[]) => {
      for (const e of screened) {
        if (taken >= want) break;
        const key = titleKey(e.title);
        if (!key || takenKeys.has(key)) continue;
        const lk = linkKey(e.link);
        // 近几天已播过：链接相同，或标题归一化后相同，直接跳过
        if ((lk && recentLinks.has(lk)) || recentKeys.has(key)) {
          recentDropped += 1;
          continue;
        }
        // 同一条新闻不同媒体的写法不同（标题对不上），用 2-gram / 实词重合率再兜一层
        const grams = bigrams(key);
        const words = wordsOf(e.title);
        if (
          seenGlobal.has(key) ||
          seenGlobalGrams.some((g, i) => sameEvent(grams, g, words, seenGlobalWords[i]))
        ) {
          dropped += 1;
          continue;
        }
        if (recentGrams.some((g, i) => sameEvent(grams, g, words, recentWords[i]))) {
          recentDropped += 1;
          continue;
        }
        seenGlobal.add(key);
        takenKeys.add(key);
        seenGlobalGrams.push(grams);
        seenGlobalWords.push(words);
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
    };

    /**
     * 按来源轮流取：先按时间排，再跨源轮转。
     *
     * 以前是纯时间倒序，美国媒体发得勤就整段都是美国新闻
     * （2026-11-25 用户反馈「国外新闻全是美国的」）。轮转后每个源最多占 1/N，
     * 只有一个源可用时仍能取满，不影响兜底。
     */
    const interleave = (entries: PoolEntry[]): PoolEntry[] => {
      if (entries.length <= 1) return entries;
      const buckets = new Map<string, PoolEntry[]>();
      for (const e of entries) {
        const list = buckets.get(e.source);
        if (list) list.push(e);
        else buckets.set(e.source, [e]);
      }
      if (buckets.size <= 1) return entries;
      const queues = [...buckets.values()];
      const out: PoolEntry[] = [];
      for (let i = 0; queues.some((q) => q.length > 0); i += 1) {
        const q = queues[i % queues.length];
        const next = q.shift();
        if (next) out.push(next);
      }
      return out;
    };

    // 时效窗口从紧到松逐级试：[2, 5, 10] 天。
    //
    // 必须用「过完粗筛后实际取到的条数」判断够不够，不能用原始素材数：
    // 2 天窗口里常有 9 条，剔掉聚合稿 / 导购稿 / 不相关 / 境外之后只剩 5 条，
    // 2026-11-15 起「国外科技 1/3、国际AI 0/3」就是这么漏的。
    let windowDays: number = ALL_WINDOWS[0];
    const fill = () => {
      for (let i = 0; i < ALL_WINDOWS.length; i += 1) {
        windowDays = ALL_WINDOWS[i];
        const last = i === ALL_WINDOWS.length - 1;
        let list = datedWithin(pool, nowSec, windowDays);
        // 没有发布时间的条目判不了时效：只在最宽窗口仍不够时垫底（排序后自然落到最后，
        // 不会顶掉真·新新闻）。把它们整批丢掉了，和「不要因为没 pubDate 就丢掉」自相矛盾。
        if (last && list.length < want) {
          const undated = pool.filter((e) => e.published === null);
          if (undated.length) list = [...list, ...undated];
        }
        take(interleave(rank(list, i === 0)));
        if (taken >= want) return;
      }
    };
    fill();

    const datedCount = pool.filter((e) => typeof e.published === 'number').length;
    const stale = datedCount - datedWithin(pool, nowSec, windowDays).length;
    if (windowDays > 2) {
      log?.(`[blog] ${cat.spoken} 近两天不够 ${want} 条，时效放宽到 ${windowDays} 天（取到 ${taken} 条）`);
    }
    if (stale > 0) log?.(`[blog] ${cat.spoken} 丢弃 ${stale} 条过期素材`);
    if (taken === 0 && pool.length > 0) {
      failed.push(
        `${cat.spoken}: ${cat.sources.map((s) => s.name).join('/')} 的条目都超过 ${windowDays} 天`,
      );
    }

    // 还是不够 → 等几秒把刚才失败的源再抓一次（抖动型失败占绝大多数：
    // 2026-11-17 04:00 那期 13 个境外源同时 fetch failed，事后同一批地址全通）
    if (taken < want && badSources.length > 0) {
      log?.(`[blog] ${cat.spoken} 只取到 ${taken}/${want} 条，${REFILL_PAUSE_MS / 1000} 秒后补抓失败的源`);
      await sleep(REFILL_PAUSE_MS);
      const again = await fetchPool(badSources, log);
      if (again.pool.length > 0) {
        pool = [...pool, ...again.pool];
        const before = taken;
        fill();
        log?.(
          `[blog] ${cat.spoken} 补抓成功：取回 ${again.pool.length} 条素材，本类补进 ${taken - before} 条`,
        );
      }
      bad = again.failed;
    }
    failed.push(...bad);
    if (taken < need) failed.push(`${cat.spoken}: 只抓到 ${taken}/${need} 条`);
  }

  if (dropped > 0) log?.(`[blog] 全局去重：丢弃 ${dropped} 条重复素材`);
  if (recentDropped > 0) {
    log?.(`[blog] 近几天已播过：跳过 ${recentDropped} 条重复素材（不重复播旧闻）`);
  }
  return { items, failed };
}
