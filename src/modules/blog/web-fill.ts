import { proxyFetch } from '../../../kernel/proxy-fetch';
import type { NewsItem } from './news';
import { CATEGORIES } from './news';
import type { BlogCounts, CountKey } from './settings';

/**
 * RSS 抓完后，对「缺口类别」用 DeepSeek 内置联网搜索（`deepseek_web_search`）补素材。
 *
 * 设计取舍（2026-11-26 实测后定）：
 *   - **只补缺口**：RSS 已够的类别不联网。缺几类搜几次，token 增量最小。
 *   - **只取素材、不在此改写**：素材仍交给 `composeScript` 走 json_object 强约束改写，
 *     格式 / 校验 / 去重全保留。联网工具链做不到的 json 约束，这里就不做。
 *   - **text 模式**：带 `deepseek_web_search` 时 `response_format` 必须为 text（否则 400），
 *     所以这里让模型把素材包成 `{"articles":[...]}` 再用容错解析，不依赖 json_object。
 *   - **服务端搜索免费**：只按模型 Token 计费，工具调用本身不计费（2026-11-18 起）。
 *
 * 素材摘要要求 120-150 字、含 3-5 个事实点：实测摘要太短（40 字）会让下游改写写不长。
 */

export interface WebFillConfig {
  apiKey: string;
  apiBase: string;
  apiModel: string;
}

export interface WebFillUsage {
  calls: number;
  promptTokens: number;
  completionTokens: number;
  /** 服务端联网搜索次数（免费，仅统计） */
  searchCalls: number;
}

export interface WebFillResult {
  items: NewsItem[];
  usage: WebFillUsage;
  /** 每类实际补了几条 */
  filled: Partial<Record<CountKey, number>>;
  warnings: string[];
}

const TIMEOUT_MS = 180_000;

function chatUrl(base: string): string {
  const b = (base || 'https://api.deepseek.com').replace(/\/+$/, '');
  if (/\/chat\/completions$/i.test(b)) return b;
  return `${b}/chat/completions`;
}

function ymd(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function windowOf(now = new Date()): { from: string; to: string } {
  const y = new Date(now);
  y.setDate(y.getDate() - 1);
  return { from: ymd(y), to: ymd(now) };
}

/** 从模型回复里抠出 JSON 对象（text 模式下可能裹 ```json 或前后带话） */
function extractJsonObj(raw: string): unknown {
  const text = String(raw || '').trim();
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(text);
  const body = fenced ? fenced[1] : text;
  try {
    return JSON.parse(body);
  } catch {
    const start = body.indexOf('{');
    const end = body.lastIndexOf('}');
    if (start >= 0 && end > start) return JSON.parse(body.slice(start, end + 1));
    throw new Error(`联网补缺没有返回 JSON：${text.slice(0, 160)}`);
  }
}

const SYSTEM = `你是新闻素材编辑。请使用联网搜索，为指定分类检索给定时间窗口内真实发生的新闻，整理成素材清单。
严格规则：
1. 只使用搜索结果中真实存在的新闻，不得编造任何事实、数字、人名、机构名、引语。
2. 每条素材给出 title（准确标题）、summary（120-150 字，必须包含时间、主体、具体数据或结果等 3-5 个事实点，便于后续改写成稿）、source（媒体名）、event_date（YYYY-MM-DD）。
3. 事件日期尽量落在给定的时间窗口内；确为近几日但非当天的，如实填写 event_date。
4. 只输出一个 JSON 对象，不要任何解释文字。格式：
{"articles":[{"title":"...","summary":"...","source":"...","event_date":"2026-11-25"}]}`;

interface RawItem {
  title?: unknown;
  summary?: unknown;
  source?: unknown;
  event_date?: unknown;
}

/** 搜一个分类，返回最多 gap 条素材（失败不抛错，返回空数组并记 warning） */
async function searchCategory(
  spoken: string,
  gap: number,
  win: { from: string; to: string },
  cfg: WebFillConfig,
  usage: WebFillUsage,
  log?: (msg: string) => void,
): Promise<NewsItem[]> {
  const user = [
    `分类：${spoken}`,
    `条数：${gap}`,
    `时间窗口：${win.from} 00:00 至 ${win.to} 23:59（Asia/Shanghai）`,
    '请联网检索并返回 JSON 素材清单。',
  ].join('\n');

  const body = {
    model: cfg.apiModel || 'deepseek-flash',
    temperature: 0.3,
    max_tokens: Math.min(6000, 900 + gap * 900),
    // 带 deepseek_web_search 时必须 text 模式：不能传 response_format / web_search_options，
    // tool_choice 也不能指定具体工具（否则 400）。是否搜索由模型判断。
    thinking: { type: 'disabled' },
    tools: [{ type: 'deepseek_web_search' }],
    messages: [
      { role: 'system', content: SYSTEM },
      { role: 'user', content: user },
    ],
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await proxyFetch(chatUrl(cfg.apiBase), {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${cfg.apiKey}`,
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      log?.(`[blog] 联网补缺 ${spoken} 失败：HTTP ${res.status} ${detail.slice(0, 160)}`);
      return [];
    }
    const json = (await res.json()) as {
      choices?: Array<{ message?: { content?: string }; finish_reason?: string }>;
      usage?: {
        prompt_tokens?: number;
        completion_tokens?: number;
        server_tool_use?: { tool_search?: number };
      };
    };
    usage.calls += 1;
    usage.promptTokens += Number(json.usage?.prompt_tokens) || 0;
    usage.completionTokens += Number(json.usage?.completion_tokens) || 0;
    usage.searchCalls += Number(json.usage?.server_tool_use?.tool_search) || 0;

    const content = json.choices?.[0]?.message?.content || '';
    let parsed: { articles?: unknown };
    try {
      parsed = extractJsonObj(content) as { articles?: unknown };
    } catch (e) {
      log?.(`[blog] 联网补缺 ${spoken} 解析失败：${String((e as Error).message || e).slice(0, 160)}`);
      return [];
    }
    const arr = Array.isArray(parsed.articles) ? (parsed.articles as RawItem[]) : [];
    const out: NewsItem[] = [];
    for (const it of arr) {
      const title = String(it.title ?? '').trim();
      if (!title) continue;
      const eventDate = String(it.event_date ?? '').slice(0, 10);
      const ts = eventDate ? Date.parse(`${eventDate}T12:00:00+08:00`) : NaN;
      out.push({
        key: '' as CountKey, // 由调用方回填
        spoken,
        title: title.slice(0, 200),
        summary: String(it.summary ?? '').replace(/\s+/g, ' ').trim().slice(0, 400),
        link: '',
        source: String(it.source ?? '').slice(0, 60),
        published: Number.isNaN(ts) ? null : Math.floor(ts / 1000),
      });
    }
    return out.slice(0, gap);
  } catch (e) {
    log?.(`[blog] 联网补缺 ${spoken} 异常：${String((e as Error).message || e).slice(0, 160)}`);
    return [];
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 对每类的缺口用联网补素材。只有「已抓条数 < 目标条数」的类别才会发起搜索。
 * 返回合并后的 items（原有 + 补齐）与用量。
 */
export async function fillGapsByWebSearch(
  items: NewsItem[],
  counts: BlogCounts,
  cfg: WebFillConfig,
  log?: (msg: string) => void,
): Promise<WebFillResult> {
  const usage: WebFillUsage = { calls: 0, promptTokens: 0, completionTokens: 0, searchCalls: 0 };
  const out = [...items];
  const filled: Partial<Record<CountKey, number>> = {};
  const warnings: string[] = [];
  if (!cfg.apiKey) return { items: out, usage, filled, warnings };

  const have: Partial<Record<CountKey, number>> = {};
  for (const it of items) have[it.key] = (have[it.key] || 0) + 1;

  const win = windowOf();
  const gaps = CATEGORIES.map((cat) => ({
    cat,
    gap: Math.max(0, (counts[cat.key] || 0) - (have[cat.key] || 0)),
  })).filter((g) => g.gap > 0);

  if (gaps.length === 0) {
    log?.('[blog] 联网补缺：所有分类素材充足，跳过');
    return { items: out, usage, filled, warnings };
  }
  log?.(
    `[blog] 联网补缺：${gaps.length} 类不足（${gaps
      .map((g) => `${g.cat.spoken}-${g.gap}`)
      .join('，')}），开始联网检索`,
  );

  for (const { cat, gap } of gaps) {
    const got = await searchCategory(cat.spoken, gap, win, cfg, usage, log);
    for (const g of got) g.key = cat.key;
    out.push(...got);
    filled[cat.key] = got.length;
    if (got.length < gap) {
      warnings.push(`${cat.spoken}：联网补 ${got.length}/${gap} 条`);
      log?.(`[blog] ${cat.spoken}：联网补到 ${got.length}/${gap} 条`);
    } else {
      log?.(`[blog] ${cat.spoken}：联网补足 ${got.length} 条`);
    }
  }

  const added = Object.values(filled).reduce((s, n) => s + (n || 0), 0);
  log?.(
    `[blog] 联网补缺完成：新增 ${added} 条素材 · ${usage.calls} 次调用 · ` +
      `输入 ${usage.promptTokens} · 输出 ${usage.completionTokens} · 搜索 ${usage.searchCalls} 次`,
  );
  return { items: out, usage, filled, warnings };
}
