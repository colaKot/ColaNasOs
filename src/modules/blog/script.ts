import { proxyFetch } from '../../../kernel/proxy-fetch';
import type { NewsItem } from './news';
import { CATEGORIES } from './news';
import type { BlogCounts, BlogSettings, CountKey } from './settings';

/**
 * 新闻素材 → 播报稿。
 *
 * 按「两段式」做，这是用户明确要求的流程，别简化成一次调用：
 *   1. 外部抓素材（news.ts，带标题/时间/来源/摘要）；
 *   2. **每类单独调用一次**模型，只让它做筛选 / 分类 / 改写成朗读稿，绝不让它凭空生成事实；
 *   3. **程序硬校验**（字数、日期窗口、重复、条数），不合格把错误回传重试；
 *   4. 合并成稿，点评单独生成。
 *
 * 为什么按类分批而不是一次 30 条：
 *   一次输出 7500 字很容易被 max_tokens 截断，且字数、分类排他都会漂；
 *   按类给 3~5 条，模型能稳定落在 230~270 字，重试也只重跑那一类。
 *
 * 【省钱约束】2026-11-06 重做，背景是一晚烧掉 84 万 token：
 *   1. 输出预算按条数给（不再一律 12000）——思考型模型会把上限全花在推理上；
 *   2. **截断不重试**：JSON 都不完整，再发一遍还是同样的结果，纯烧钱；
 *   3. **字数/日期/重复校验不通过也不重试**：差 10 个字不值得整类重发，接受并记 warning；
 *      只有「一条都没产出」或「JSON 解析失败」才允许再试一次；
 *   4. 兼容层记住服务端不认的参数，不再每次调用都先吃一个 400 再重发；
 *   5. 每次调用记账（prompt / completion token），汇总后落 `blog_llm_usage`；
 *   6. 联网搜索只在**本类零素材**时开（按次收费）。
 *
 * 没有 Key 或开关关闭时退化成「标题 + 摘要」拼接：**没有 Key 也必须能出稿**。
 */

/**
 * 每条的目标字数 = **一句话总结 + 正文**合计（用户方案：230~270）。
 *
 * 校验放宽到 210~285，避免为 1 个字反复重试；加了总结之后正文相应缩短，
 * 所以总时长和以前一致，不会因为多一句总结变长。
 */
const MIN_CHARS = 210;
const MAX_CHARS = 285;
/** 单类最多重试一次，且只对「空结果 / JSON 解析失败」生效 */
const MAX_RETRY = 1;

/**
 * 输出预算：N 条 × 250 汉字 ≈ N×350 token，留 1500 给 JSON 字段与模型自检。
 * 旧值一律 12000：思考型模型把上限当推理预算烧光后 content 为空、finish_reason=length。
 */
function outputBudget(want: number): number {
  return Math.min(6000, 1500 + want * 700);
}

/** 一次生成里所有模型调用的累计用量（用于与账单对账） */
export interface TokenUsage {
  calls: number;
  promptTokens: number;
  completionTokens: number;
  /** 带联网搜索的调用次数（百炼按次另收费） */
  searchCalls: number;
  /** 因参数不兼容而重发的次数 */
  compatRetries: number;
}

function newUsage(): TokenUsage {
  return { calls: 0, promptTokens: 0, completionTokens: 0, searchCalls: 0, compatRetries: 0 };
}

export interface ScriptStats {
  total: number;
  chars: number;
  categories: number;
  retries: number;
  usage: TokenUsage;
}

export interface ScriptResult {
  text: string;
  usedLlm: boolean;
  warnings: string[];
  stats: ScriptStats;
}

/** 字数口径与用户方案一致：不计标点、空格、`//` 与「（本条约X字）」标注 */
export function countChars(text: string): number {
  const cleaned = String(text || '')
    .replace(/（本条约?\s*\d+\s*字）/g, '')
    .replace(/（约?\s*\d+\s*字）/g, '')
    .replace(/\/\//g, '');
  return (cleaned.match(/[\u4e00-\u9fff0-9A-Za-z]/g) || []).length;
}

export function todayLabel(now = new Date()): string {
  return `${now.getFullYear()}年${now.getMonth() + 1}月${now.getDate()}日`;
}

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** 昨日 00:00 ~ 现在（素材事件必须落在这个窗口里） */
export function dateWindow(now = new Date()): { from: string; to: string } {
  const y = new Date(now);
  y.setDate(y.getDate() - 1);
  return { from: ymd(y), to: ymd(now) };
}

const SYSTEM_PROMPT = `你是一名资深新闻主编、播客朗读稿撰稿人和质检员。你的任务不是编新闻，而是基于用户提供的【目标日期】和【新闻素材】生成可朗读的中文新闻稿。

【最高优先级】
1. 只使用用户提供的素材中的事实。不得虚构任何数字、人名、机构名、事件结果、引语。
2. 如果素材不足以支撑该分类的指定条数，不要用旧闻或编造补位；在 gaps 中列出缺口，正文可以少于指定条数。
3. 所有新闻事件必须发生在给定时间窗口内；素材时间不在窗口内的不得使用。
4. 同一事件只能出现一次，不得跨类复用。

【地域口径（最高优先级，先看这一条）】
- 「国内」= **中国国内（含港澳台地区）**；「国际 / 国外」= 中国境外。
- 分类名带「国内」的（国内综合 / 国内科技 / 国内人工智能 / 国内财经）：
  **只写核心事件发生在中国、或核心主体为中国机构 / 中国企业 / 中国市场的新闻**。
- 素材里核心是境外事件、外国政府、外国企业、外国市场的（例如埃及列车脱轨、胡塞武装打击沙特、
  苹果换 CEO、美联储官员表态、美股 / 日经行情），**一律剔除**，在 gaps 里说明「境外素材已剔除」，
  不得改写后塞进国内类，也不得用它凑条数。
- 例外：境外主体但核心新闻点在中国（例如「某外企在华建厂」「中国市场贡献其营收」）可以写，
  但必须把中国这条主线写成新闻点。
- 国内财经不写美联储 / 美股 / 特朗普 / 海外央行这类境外市场动态；
  国内科技不写苹果、微软、OpenAI 等外国公司的产品发布（除非核心是中国产业链或中国市场）。

【分类规则】
- 国内综合/国际综合是**兜底分类**：收政策、民生、社会事件、灾害、交通、外交、司法、教育、医疗、突发事件；凡是不属于下面更具体分类的新闻，都放这里。
- 国内科技/国外科技：**科技产业与技术**——芯片、通信、航天、量子、生物、物理、能源、材料、计算硬件、消费电子、平台技术、科研成果。不收大模型 / AI 应用 / AI 公司融资（归 AI 类）。
- 国内 AI/国际 AI：模型发布、政策治理、产业应用、AI 公司动态、AI 安全。
- 国内财经/国外财经：金融市场、宏观数据、商品价格、贸易、货币政策、公司财报。不收科技产品发布。
- 一条素材同时沾边两类时，按**核心新闻点**归类；实在拿不准就归综合类，并在 notes 里说明。

【重要】不要把素材"筛空"：只要有一条素材与本类沾边，就按核心新闻点写进本类。
但**地域不符的素材不算沾边**（见上面的地域口径），该剔就剔，不要用境外新闻凑数。
素材不够指定条数时，写够现有条数并在 gaps 说明缺口；只有确实一条都不沾边时，articles 才允许为空。

【每条正文格式与字数】
1. 每条拆成两个字段："summary"（一句话总结，15—25 字）和 "text"（正文）。
   **两者合计**严格控制在 230—270 字（按汉字、数字、英文缩写计，不计标点、空格与"//"）。
   加了总结之后正文相应缩短，**总字数不要变多**。
   **宁多勿少，下限 240 字**；写完自己数字数，不到 230 就补背景、数据或影响，不要用一句话交差。
2. "summary" 要能独立成句：听这一句就知道这条新闻讲了什么（谁 + 发生了什么 + 关键结果/数字），
   但**不要照抄正文第一句**，也不要和正文重复叙述。
3. "text" 结构：一句导语概括事件 + 2—3 句关键事实（时间、主体、数据/结果）+ 一句简短意义或影响收束。
4. 不得用短句堆砌凑字数，也不得压缩成一句话新闻。
5. 禁止出现 URL、"来源："、"本报讯"、"记者获悉"。

【朗读稿要求】
1. 用"//"标记停顿点；每句不超过 40 字。
2. 百分比读"百分之 X"；大额数字加"约"；日期读"11月5日"而不是"11.5"。
3. 播客口播语气，句子短、能一口气读完。

【输出格式】
只输出一个 JSON 对象（不要 markdown 代码块、不要解释）：
{
  "articles": [
    { "index": 1, "summary": "一句话总结", "text": "带//停顿标记的正文", "char_count": 248, "source": "素材里的媒体名", "event_date": "YYYY-MM-DD" }
  ],
  "gaps": ["素材不足的说明，没有就空数组"],
  "notes": ""
}`;

/**
 * 进 prompt 的素材：只给模型用得上的字段。
 *
 * - **不给 url**：system prompt 明令禁止正文出现 URL，给了纯属输入 token 浪费；
 * - **摘要裁到 180 字（句末边界）**：这是抽取式截断，不是让模型改写，
 *   所以不会引入新事实；400 字的原始摘要里有大半是「点击查看原文」之类的噪声；
 * - **紧凑 JSON**：之前 `JSON.stringify(..., null, 1)` 的缩进 + 换行占了两成输入。
 */
function clipSummary(s: string, limit = 180): string {
  const text = String(s || '').replace(/\s+/g, ' ').trim();
  if (text.length <= limit) return text;
  const head = text.slice(0, limit);
  const cut = Math.max(head.lastIndexOf('。'), head.lastIndexOf('，'), head.lastIndexOf('. '));
  return cut > limit * 0.6 ? head.slice(0, cut + 1) : head;
}

function materialOf(items: NewsItem[]): string {
  return JSON.stringify(
    items.map((it) => ({
      title: it.title,
      published_at: it.published
        ? new Date(it.published * 1000).toISOString().slice(0, 16).replace('T', ' ')
        : '',
      source: it.source,
      summary: clipSummary(it.summary),
    })),
  );
}

function chatUrl(base: string): string {
  const b = (base || 'https://api.deepseek.com').replace(/\/+$/, '');
  if (/\/chat\/completions$/i.test(b)) return b;
  return `${b}/chat/completions`;
}

/** 从模型回复里抠出 JSON（有的模型会裹 ```json 或前后加话） */
export function extractJson(raw: string): unknown {
  const text = String(raw || '').trim();
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(text);
  const body = fenced ? fenced[1] : text;
  try {
    return JSON.parse(body);
  } catch {
    const start = body.indexOf('{');
    const end = body.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return JSON.parse(body.slice(start, end + 1));
    }
    throw new Error(`模型没有返回 JSON：${text.slice(0, 160)}`);
  }
}

interface ChatResult {
  content: string;
  truncated: boolean;
  promptTokens: number;
  completionTokens: number;
}

type OptionalParam = 'response_format' | 'reasoning_effort' | 'enable_search' | 'thinking';
const OPTIONAL_PARAMS: OptionalParam[] = [
  'response_format',
  'reasoning_effort',
  'enable_search',
  'thinking',
];

/**
 * 进程内记住服务端不认的参数。老实现是「每次调用都先带齐三个可选项 → 吃 400 →
 * 剥一个再发」，8 个分类就是 8 次白请求；现在只第一次会撞，之后直接不带。
 */
const unsupportedParams = new Set<OptionalParam>();

function paramFromError(detail: string): OptionalParam | null {
  if (/response_format|json_object/i.test(detail)) return 'response_format';
  if (/reasoning|effort/i.test(detail)) return 'reasoning_effort';
  if (/enable_search|search_options|search/i.test(detail)) return 'enable_search';
  if (/thinking/i.test(detail)) return 'thinking';
  return null;
}

function dropParam(body: Record<string, unknown>, key: OptionalParam): void {
  delete body[key];
  if (key === 'enable_search') delete body.search_options;
}

async function callChat(
  settings: BlogSettings,
  system: string,
  user: string,
  maxTokens: number,
  enableSearch = false,
  usage?: TokenUsage,
): Promise<ChatResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 180_000);
  const body: Record<string, unknown> = {
    model: settings.apiModel,
    temperature: 0.3,
    max_tokens: maxTokens,
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: user },
    ],
    response_format: { type: 'json_object' },
    // 思考型模型（deepseek-flash 默认开思考）会把 max_tokens 全花在推理上：
    // 实测 content 是空串、finish_reason=length。改写类任务不需要推理，直接关掉；
    // 服务端不认这个参数时，下面的兼容层会自动剥掉并记住。
    thinking: { type: 'disabled' },
    reasoning_effort: 'low',
  };
  if (enableSearch) {
    // 阿里百炼的搜索插件：**按次收费**，只在「本类一条素材都没有」时才打开。
    body.enable_search = true;
    body.search_options = { forced_search: true, search_strategy: 'pro' };
  }
  for (const key of unsupportedParams) dropParam(body, key);

  const send = () =>
    proxyFetch(chatUrl(settings.apiBase), {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${settings.apiKey}`,
      },
      body: JSON.stringify(body),
    });

  try {
    let res = await send();
    // 兼容层：只在真的撞到 400 时剥参数；剥掉的永久记住
    for (let i = 0; i < OPTIONAL_PARAMS.length + 1 && !res.ok; i += 1) {
      const detail = await res.text().catch(() => '');
      if (res.status !== 400) throw new Error(`HTTP ${res.status} ${detail.slice(0, 240)}`);
      let key = paramFromError(detail);
      if (!key) {
        // 有些网关只回一句「invalid parameter」。只要不是鉴权 / 模型名问题，
        // 就按序剥掉一个还在请求里、且本次尚未被判定过不兼容的可选项再试。
        if (/api.?key|unauthorized|invalid model|model not found|quota/i.test(detail)) {
          throw new Error(`HTTP 400 ${detail.slice(0, 240)}`);
        }
        key = OPTIONAL_PARAMS.find((p) => p in body && !unsupportedParams.has(p)) ?? null;
      }
      if (!key) throw new Error(`HTTP 400 ${detail.slice(0, 240)}`);
      // 并发时别的请求可能已经记下这个参数不兼容：照样剥掉重发，别当成致命错误
      if (!unsupportedParams.has(key)) {
        unsupportedParams.add(key);
        if (usage) usage.compatRetries += 1;
      }
      dropParam(body, key);
      res = await send();
    }
    if (!res.ok) throw new Error(`HTTP ${res.status} ${(await res.text()).slice(0, 240)}`);

    const out = readChoice(await res.json());
    if (usage) {
      usage.calls += 1;
      usage.promptTokens += out.promptTokens;
      usage.completionTokens += out.completionTokens;
      if (enableSearch && body.enable_search) usage.searchCalls += 1;
    }
    return out;
  } finally {
    clearTimeout(timer);
  }
}

function readChoice(json: unknown): ChatResult {
  const j = json as {
    choices?: Array<{
      message?: { content?: string; reasoning_content?: string };
      finish_reason?: string;
    }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };
  const choice = j.choices?.[0];
  const content = (choice?.message?.content || '').trim();
  return {
    content,
    // 截断时 JSON 一定不完整，内容非空也不能用
    truncated: choice?.finish_reason === 'length',
    promptTokens: Number(j.usage?.prompt_tokens) || 0,
    completionTokens: Number(j.usage?.completion_tokens) || 0,
  };
}

interface Article {
  index: number;
  /** 一句话总结（15—25 字）：播在正文前，让人一听就知道换新闻了 */
  summary: string;
  text: string;
  charCount: number;
  source: string;
  eventDate: string;
}

interface CategoryResult {
  key: CountKey;
  spoken: string;
  articles: Article[];
  gaps: string[];
}

function parseArticles(raw: unknown): { articles: Article[]; gaps: string[] } {
  const obj = (raw || {}) as { articles?: unknown; gaps?: unknown };
  const list = Array.isArray(obj.articles) ? obj.articles : [];
  const articles: Article[] = [];
  for (const [i, item] of list.entries()) {
    const a = (item || {}) as Record<string, unknown>;
    const text = String(a.text ?? '').trim();
    if (!text) continue;
    // 总结是可选的：模型偶尔会漏，漏了也不算错（字数校验会只用正文兜底），
    // 只是那一条听感上少了一句导语。
    const summary = String(a.summary ?? '').trim();
    articles.push({
      index: Number(a.index) || i + 1,
      summary,
      text,
      // 字数口径：总结 + 正文合计（用户要求总字数不变，加了总结正文就相应缩短）
      charCount: countChars(`${summary}${text}`),
      source: String(a.source ?? '').slice(0, 40),
      eventDate: String(a.event_date ?? '').slice(0, 10),
    });
  }
  return {
    articles,
    gaps: Array.isArray(obj.gaps) ? obj.gaps.map((g) => String(g).slice(0, 160)) : [],
  };
}

/** 硬校验：字数 / 日期窗口 / 重复 / 条数（模型自检只当辅助） */
export function validateCategory(
  articles: Article[],
  want: number,
  win: { from: string; to: string },
  gaps: string[],
): string[] {
  const errors: string[] = [];
  if (articles.length === 0) errors.push('这一条都没生成');
  if (articles.length > want) errors.push(`条数 ${articles.length} 超过要求 ${want}`);

  for (const a of articles) {
    if (a.charCount < MIN_CHARS || a.charCount > MAX_CHARS) {
      errors.push(`第${a.index}条字数 ${a.charCount}（要求 230—270）`);
    }
    if (a.eventDate && (a.eventDate < win.from || a.eventDate > win.to)) {
      errors.push(`第${a.index}条事件日期 ${a.eventDate} 不在 ${win.from}~${win.to}`);
    }
    if (/https?:\/\//i.test(a.text)) errors.push(`第${a.index}条正文里有 URL`);
  }
  // 重复：取前 40 个有效字符做指纹
  const seen = new Set<string>();
  for (const a of articles) {
    const fp = a.text.replace(/[\s，。、；：！？"']/g, '').slice(0, 40);
    if (fp && seen.has(fp)) errors.push(`第${a.index}条与前面重复`);
    seen.add(fp);
  }
  // 条数不足**不算错**：RSS 一天可能就只有两三条，逼模型补齐只会让它编造。
  // 只在一条都没有时才重试（上面已判）。
  return errors;
}

function categoryPrompt(
  cat: { spoken: string },
  items: NewsItem[],
  want: number,
  win: { from: string; to: string },
  target: string,
  webSearch = false,
): string {
  if (items.length === 0) {
    return [
      `目标日期：${target}（时区 Asia/Shanghai）`,
      `时间窗口：${win.from} 00:00 至 ${win.to} 23:59`,
      '',
      `分类：${cat.spoken}`,
      `条数要求：${want} 条`,
      '',
      '【本类没有预抓素材】',
      webSearch
        ? '请使用**联网搜索**检索上述时间窗口内、属于本分类的真实新闻，逐条注明媒体名与事件日期；检索不到就返回空数组并写 gaps，绝不编造。'
        : '没有可用的新闻素材。不要编造，直接返回 {"articles":[],"gaps":["无素材"]}。',
    ].join('\n');
  }
  return [
    `目标日期：${target}（时区 Asia/Shanghai）`,
    `时间窗口：${win.from} 00:00 至 ${win.to} 23:59`,
    '',
    `分类：${cat.spoken}`,
    `条数要求：${want} 条（素材不足时按 gaps 说明，不要编造）`,
    '',
    '【新闻素材】（唯一事实来源）',
    materialOf(items),
    '',
    '【输出】只输出 JSON：{"articles":[{"index":1,"summary":"一句话总结","text":"……","char_count":248,"source":"媒体名","event_date":"YYYY-MM-DD"}],"gaps":[],"notes":""}',
    `summary 15—25 字，text 是正文；**两者合计** 230—270 字（宁多勿少，目标 250 字），用"//"标停顿；条数不超过 ${want}。`,
  ].join('\n');
}

/** 单类：调用 → 校验。**只有空结果 / JSON 解析失败才重试**，其余一律接受 */
async function composeCategory(
  settings: BlogSettings,
  cat: { key: CountKey; spoken: string },
  items: NewsItem[],
  want: number,
  win: { from: string; to: string },
  target: string,
  usage: TokenUsage,
  log?: (msg: string) => void,
): Promise<{ result: CategoryResult; retries: number; warnings: string[] }> {
  const warnings: string[] = [];
  let lastErrors: string[] = [];
  let retries = 0;

  // 没有任何素材、又不允许联网：别白花一次请求，直接记缺口
  if (items.length === 0 && !settings.webSearch) {
    return {
      result: { key: cat.key, spoken: cat.spoken, articles: [], gaps: ['无素材'] },
      retries: 0,
      warnings,
    };
  }
  // 搜索按次收费：只要本类还有一条素材，就靠素材改写，不联网
  const needSearch = settings.webSearch && items.length === 0;

  for (let attempt = 0; attempt <= MAX_RETRY; attempt += 1) {
    const user =
      attempt === 0
        ? categoryPrompt(cat, items, want, win, target, settings.webSearch)
        : [
            categoryPrompt(cat, items, want, win, target, settings.webSearch),
            '',
            '【上一版未通过外部校验】',
            lastErrors.map((e) => `- ${e}`).join('\n'),
            '请重新输出完整 JSON，正文事实不得改动。',
          ].join('\n');

    let chat: ChatResult;
    try {
      chat = await callChat(settings, SYSTEM_PROMPT, user, outputBudget(want), needSearch, usage);
    } catch (e) {
      warnings.push(`${cat.spoken}：调用失败 ${String((e as Error).message || e).slice(0, 160)}`);
      break;
    }

    // 截断 = 预算不够或思考烧光了预算。整类重发一次还是同样结果，不重试。
    if (chat.truncated) {
      lastErrors = [`输出被 max_tokens(${outputBudget(want)}) 截断，本类跳过`];
      warnings.push(`${cat.spoken}：${lastErrors[0]}（不重试以省 token）`);
      break;
    }

    let parsed: { articles: Article[]; gaps: string[] };
    try {
      parsed = parseArticles(extractJson(chat.content));
    } catch (e) {
      lastErrors = [`JSON 解析失败：${String((e as Error).message || e)}`];
      if (attempt < MAX_RETRY) {
        retries += 1;
        continue;
      }
      break;
    }

    const result: CategoryResult = {
      key: cat.key,
      spoken: cat.spoken,
      articles: parsed.articles.slice(0, want),
      gaps: parsed.gaps,
    };
    if (result.articles.length === 0) {
      log?.(`[blog] ${cat.spoken} 返回空条目，原始内容：${chat.content.slice(0, 300)}`);
      lastErrors = ['这一条都没生成'];
      if (attempt < MAX_RETRY) {
        retries += 1;
        continue;
      }
      break;
    }
    const errors = validateCategory(result.articles, want, win, result.gaps);
    if (errors.length === 0) return { result, retries, warnings };
    // 字数差几个、日期偏一天、条目重复……再花一整次调用去修正不划算，
    // 直接接受这一版，问题写进 warnings 让人能看见。
    log?.(`[blog] ${cat.spoken} 校验未过但已接受：${errors.slice(0, 3).join('；')}`);
    warnings.push(`${cat.spoken}：${errors.slice(0, 3).join('；')}（已接受，未重发）`);
    return { result, retries, warnings };
  }

  warnings.push(`${cat.spoken}：${lastErrors.slice(0, 3).join('；') || '无可用输出'}`);
  return {
    result: { key: cat.key, spoken: cat.spoken, articles: [], gaps: ['多次重试仍不合格'] },
    retries,
    warnings,
  };
}

async function composeCommentary(
  settings: BlogSettings,
  categories: CategoryResult[],
  target: string,
  usage: TokenUsage,
): Promise<string | null> {
  const digest = categories
    .flatMap((c) => c.articles.map((a) => `【${c.spoken}】${a.text.replace(/\/\//g, '')}`))
    .join('\n')
    // 点评只需要「今天播了什么」的梗概，全量稿件 6000 字是纯输入浪费
    .slice(0, 3000);
  const user = [
    `目标日期：${target}`,
    '下面是今天节目的全部条目，请写一段 150—200 字的今日点评：只做观察与串联，不添加新事实。',
    '用"//"标停顿，每句不超过 40 字。只输出 JSON：{"text":"……","char_count":180}',
    '',
    digest,
  ].join('\n');

  try {
    // 一次调用就够：以前字数不达标会重发整份 6000 字 digest，为了 10 个字花 2 倍钱
    const { content, truncated } = await callChat(
      settings,
      '你是一位克制、具体的新闻播客主播，只基于给定条目做点评，不编造事实。',
      user,
      1200,
      false, // 点评只基于已有条目，不联网（搜索按次收费）
      usage,
    );
    if (truncated) return null;
    const obj = extractJson(content) as { text?: string };
    return String(obj.text || '').trim() || null;
  } catch {
    return null;
  }
}

/** 兜底稿件：不依赖网络与 Key，永远能出稿 */
export function composeFallbackScript(items: NewsItem[], now = new Date()): string {
  const parts: string[] = [`${todayLabel(now)}，欢迎收听今天的 AI 新闻播报。`];
  let currentKey = '';
  // 和正式稿件同一套播报头：先报序号，再用标题当一句话总结，最后才是摘要。
  // 兜底稿没有模型写总结，标题本身就承担「一听知道是哪条」的作用。
  let no = 0;
  for (const item of items) {
    if (item.key !== currentKey) {
      currentKey = item.key;
      parts.push(`下面是${item.spoken}。`);
    }
    no += 1;
    parts.push(`第${cnNumber(no)}，${item.title.replace(/[。！？；，、\s]+$/g, '')}。`);
    const summary = item.summary.replace(/\s+/g, ' ').slice(0, 220);
    if (summary) parts.push(summary);
  }
  parts.push('以上就是今天的全部内容，感谢收听，我们明天见。');
  return parts.join('\n\n');
}

/** `//` 是给模型看的停顿标记，TTS 会念成斜杠；合并时换成逗号 */
function speakable(text: string): string {
  return text
    // 模型常在句号后面也标 //：先吃掉句末标点后的停顿标记，否则会变成「。，」
    .replace(/([。！？；、，：])\s*\/\/\s*/g, '$1')
    .replace(/\s*\/\/\s*/g, '，')
    .replace(/，{2,}/g, '，')
    .replace(/（本条约?\s*\d+\s*字）/g, '')
    .trim();
}

const CN_DIGITS = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

/** 1 → 一，11 → 十一，23 → 二十三（播报序号用，1~99 足够） */
export function cnNumber(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '零';
  const v = Math.trunc(n);
  if (v < 10) return CN_DIGITS[v];
  if (v < 20) return `十${v % 10 ? CN_DIGITS[v % 10] : ''}`;
  if (v < 100) return `${CN_DIGITS[Math.floor(v / 10)]}十${v % 10 ? CN_DIGITS[v % 10] : ''}`;
  return String(v);
}

/**
 * 一条新闻的播报头：`第一，<一句话总结>。`
 *
 * 以前整篇只有「下面是国内科技。」分段，同一分类下连着好几条，听众根本分不清
 * 什么时候换了一条新闻（2026-11-08 用户反馈）。现在每条前面先报序号 + 一句总结，
 * 再进正文；总结的字数算在每条 230—270 之内，所以总时长不变。
 */
function leadOf(no: number, summary: string): string {
  // 总结末尾的标点先去掉，避免拼出「。，」
  const s = speakable(summary).replace(/[。！？；，、\s]+$/g, '');
  const ord = `第${cnNumber(no)}`;
  return s ? `${ord}，${s}。` : `${ord}条。`;
}

export function renderScript(
  categories: CategoryResult[],
  commentary: string | null,
  target: string,
): string {
  const parts: string[] = [`${target}，欢迎收听今天的 AI 新闻播报。`];
  // 序号全篇连续（不按分类重置）：跨分类也数得下去，才知道「今天一共听了多少条」
  let no = 0;
  for (const cat of categories) {
    if (cat.articles.length === 0) continue;
    parts.push(`下面是${cat.spoken}。`);
    for (const a of cat.articles) {
      no += 1;
      parts.push(leadOf(no, a.summary));
      parts.push(speakable(a.text));
    }
  }
  if (commentary) {
    parts.push('最后是今天的点评。');
    parts.push(speakable(commentary));
  }
  parts.push('以上就是今天的全部内容，感谢收听，我们明天见。');
  return parts.join('\n\n');
}

/** 并发池：按类调用时同时开 3 个，太快容易被限流 */
async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (;;) {
      const i = next;
      next += 1;
      if (i >= items.length) return;
      out[i] = await fn(items[i]);
    }
  });
  await Promise.all(workers);
  return out;
}

export async function composeScript(
  items: NewsItem[],
  counts: BlogCounts,
  settings: BlogSettings,
  log?: (msg: string) => void,
): Promise<ScriptResult> {
  const now = new Date();
  const target = todayLabel(now);
  const win = dateWindow(now);
  const warnings: string[] = [];
  const usage = newUsage();

  const useLlm = settings.llmEnabled && Boolean(settings.apiKey);
  if (!useLlm) {
    return {
      text: composeFallbackScript(items, now),
      usedLlm: false,
      warnings: settings.llmEnabled ? [] : ['大模型改写已关闭，使用素材拼接'],
      stats: { total: items.length, chars: 0, categories: 0, retries: 0, usage },
    };
  }

  // 按类别分桶；`want` 用用户设置的条数（素材可能抓了 2 倍让模型挑）
  const buckets = CATEGORIES.map((cat) => ({
    key: cat.key,
    spoken: cat.spoken,
    want: counts[cat.key] || 0,
    items: items.filter((it) => it.key === cat.key),
  })).filter((b) => b.want > 0);

  if (buckets.length === 0) {
    throw new Error('没有可用的新闻素材（所有源都失败了）');
  }
  const hasMaterial = buckets.some((b) => b.items.length > 0);
  if (!hasMaterial && !settings.webSearch) {
    throw new Error('没有可用的新闻素材（所有源都失败了），且未开启联网搜索');
  }

  log?.(`[blog] 开始改写：${buckets.length} 个分类，模型 ${settings.apiModel}`);

  const results = await mapLimit(buckets, 3, async (bucket) => {
    try {
      return await composeCategory(
        settings,
        bucket,
        bucket.items,
        bucket.want,
        win,
        target,
        usage,
        log,
      );
    } catch (e) {
      return {
        result: { key: bucket.key, spoken: bucket.spoken, articles: [], gaps: [] } as CategoryResult,
        retries: 0,
        warnings: [`${bucket.spoken}：调用失败 ${String((e as Error).message || e).slice(0, 160)}`],
      };
    }
  });

  const categories = results.map((r) => r.result);
  for (const r of results) warnings.push(...r.warnings);
  const retries = results.reduce((n, r) => n + r.retries, 0);

  const produced = categories.reduce((n, c) => n + c.articles.length, 0);
  if (produced === 0) {
    // 一条都没成：宁可退化成拼接稿，也别让用户拿到空节目
    warnings.push('模型没有产出可用条目，已退化为素材拼接');
    return {
      text: composeFallbackScript(items, now),
      usedLlm: false,
      warnings,
      stats: { total: items.length, chars: 0, categories: 0, retries, usage },
    };
  }

  const commentary = await composeCommentary(settings, categories, target, usage).catch(() => null);
  const text = renderScript(categories, commentary, target);
  const chars = countChars(text);

  log?.(
    `[blog] 稿件完成：${produced} 条 / ${chars} 字 / 重试 ${retries} 次 / ` +
      `${usage.calls} 次调用 · 输入 ${usage.promptTokens} · 输出 ${usage.completionTokens} · ` +
      `合计 ${usage.promptTokens + usage.completionTokens} token` +
      (usage.searchCalls ? ` / 联网搜索 ${usage.searchCalls} 次` : '') +
      (usage.compatRetries ? ` / 参数兼容重发 ${usage.compatRetries} 次` : ''),
  );

  return {
    text,
    usedLlm: true,
    warnings,
    stats: { total: produced, chars, categories: categories.length, retries, usage },
  };
}
