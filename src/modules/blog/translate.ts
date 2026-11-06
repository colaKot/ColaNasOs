import crypto from 'node:crypto';
import path from 'node:path';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { LocalLlm } from '../../../kernel/llm/engine';
import { resolveLlmPaths } from '../../../kernel/llm/paths';
import type { NewsItem } from './news';

/**
 * 素材中文化：把英文源的标题与摘要用**本地小模型**译成中文，再交给写稿模型。
 *
 * 为什么要在进 prompt 之前翻译（而不是让云端模型顺手翻）：
 *   1. 英文原文进 prompt 后，模型既要翻译又要改写还要压到 230~270 汉字，
 *      字数校验极容易不达标 → 整类重跑，一期能烧掉十几万 token；
 *   2. 没有 API Key 时会退化成「标题 + 摘要」拼接稿，那稿子里就是英文原文
 *      （2026-11-06 04:00 那期实测就是这样），根本不能听。
 *
 * 为什么是 1.7B 而不是 0.6B（实测，同一批 6 条 CGTN 素材）：
 *   0.6B：`Republicans, Democrats` → 「美国和德国」、`Foreign political party representatives`
 *        → 「中国外政代表」，专名基本不可用。
 *   1.7B：可用于「看懂事实」这一层，单条约 1 秒；个别人名地名仍会错
 *        （`Wuzhen` → 「温州」），但云端改写会以中文素材重写，错译不会原样播出去。
 *
 * 缓存：同一条新闻（`link + title` 哈希）只翻一次，落 `blog_translations`。
 * 每天真正新增的英文素材只有几十条，缓存命中后整条流程几乎零成本。
 */

export interface TranslateStats {
  /** 需要翻译的条数 */
  candidates: number;
  /** 本次真的调用了模型 */
  translated: number;
  /** 命中缓存 */
  cached: number;
  /** 翻译失败（保留原文） */
  failed: number;
  ms: number;
}

const CJK = /[\u4e00-\u9fff]/g;
const ASCII_WORD = /[A-Za-z]{3,}/g;

/** 判断一条素材是不是英文：几乎没有汉字、又有成串的英文单词 */
export function isEnglish(text: string): boolean {
  const s = String(text || '');
  const cjk = (s.match(CJK) || []).length;
  if (cjk >= 4) return false;
  return (s.match(ASCII_WORD) || []).length >= 2;
}

function hashOf(item: NewsItem): string {
  // 只用 link：翻译会改写 title，用 title 做键会导致「同一进程内二次调用」算不出同一个哈希
  return crypto.createHash('sha1').update(item.link || item.title).digest('hex').slice(0, 20);
}

/** 逐条并发跑，默认 2：模型端 -np 1 会串行处理，客户端别堆太多 */
async function mapLimit<T, R>(list: T[], limit: number, fn: (item: T, i: number) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(list.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, list.length) }, async () => {
    for (;;) {
      const i = next;
      next += 1;
      if (i >= list.length) return;
      out[i] = await fn(list[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

const SYSTEM = '你是新闻翻译，把英文新闻译成简体中文。不增删事实，不解释不评论。只输出 JSON。';

function userPrompt(item: NewsItem, strict: boolean): string {
  const lines = [
    '把下面这条英文新闻译成中文。',
    '标题要**完整逐句译出**，不得概括、不得省略后半句、不得丢掉人名地名与数字。',
    '摘要保留全部事实，可裁到 100 字以内；没有摘要就留空。',
    `TITLE: ${item.title}`,
    item.summary && item.summary !== item.title ? `SUMMARY: ${item.summary}` : 'SUMMARY: (无)',
    '',
  ];
  if (strict) {
    lines.push('上一次译文里还留着英文，这次**必须全部译成中文**，专有名词音译或保留通行译名。');
  }
  lines.push('只输出这个 JSON（不要代码块、不要解释）：{"title":"完整标题译文","summary":"摘要译文"}');
  return lines.join('\n');
}

function extractJson(raw: string): { title?: string; summary?: string } | null {
  const text = String(raw || '').trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
  const tries = [text];
  const s = text.indexOf('{');
  const e = text.lastIndexOf('}');
  if (s >= 0 && e > s) tries.push(text.slice(s, e + 1));
  for (const t of tries) {
    try {
      const obj = JSON.parse(t) as { title?: unknown; summary?: unknown };
      if (obj && typeof obj === 'object') {
        return { title: String(obj.title ?? ''), summary: String(obj.summary ?? '') };
      }
    } catch {
      // 下一个
    }
  }
  return null;
}

// ---------------------------------------------------------------- 单例

let engine: LocalLlm | null = null;
/** 不可用原因（只记一次日志，别每条新闻刷屏） */
let unusable: string | null = null;

export async function resetLocalLlm(): Promise<void> {
  const cur = engine;
  engine = null;
  unusable = null;
  if (cur) await cur.stop();
}

function llmOf(k: KernelApi): LocalLlm {
  if (engine) return engine;
  const paths = resolveLlmPaths(k.paths.dataDir);
  if (!paths.bin || !paths.model) {
    const miss = [!paths.bin && 'llama-server', !paths.model && 'GGUF 模型'].filter(Boolean).join(' / ');
    throw new Error(`缺少本地翻译模型（${miss}），执行 npm run mt:model 下载`);
  }
  engine = new LocalLlm({
    binPath: paths.bin,
    modelPath: paths.model,
    log: (level, message) => {
      // 冒烟脚本直接用 startKernel 的返回值（没有 k.log），这里要能退化到 console
      const logger = k.log as Record<string, ((m: string) => void) | undefined> | undefined;
      const fn = logger?.[level] ?? logger?.info;
      if (typeof fn === 'function') fn.call(logger, `[mt] ${message}`);
      else if (level === 'warn' || level === 'error') console.warn(`[mt] ${message}`);
    },
  });
  return engine;
}

export function localLlmAvailable(k: KernelApi): boolean {
  const paths = resolveLlmPaths(k.paths.dataDir);
  return Boolean(paths.bin && paths.model) && process.env.COLANAS_LLM_DISABLED !== '1';
}

// ---------------------------------------------------------------- 主流程

/**
 * 就地改写 `items` 的 title / summary 为中文。
 * **失败不抛错**：翻不出来就保留英文，整期照常生成（不能因为翻译挂了就没新闻听）。
 *
 * `warm=false` 用于「新闻预览」接口：模型没起来就不为它单独加载 1GB，
 * 只有正在跑（刚生成过）时才顺手翻译。生成流程必须用 `warm=true`。
 */
export async function translateNews(
  k: KernelApi,
  items: NewsItem[],
  log?: (msg: string) => void,
  opts: { warm?: boolean } = {},
): Promise<TranslateStats> {
  const stats: TranslateStats = { candidates: 0, translated: 0, cached: 0, failed: 0, ms: 0 };
  const t0 = Date.now();

  const targets = items.filter((it) => isEnglish(it.title) || isEnglish(it.summary));
  stats.candidates = targets.length;
  if (targets.length === 0) {
    stats.ms = Date.now() - t0;
    return stats;
  }

  if (!localLlmAvailable(k)) {
    if (!unusable) {
      unusable = '未找到 llama-server 或 GGUF 模型，英文素材保持原文（npm run mt:model）';
      log?.(`[blog] ${unusable}`);
    }
    stats.ms = Date.now() - t0;
    return stats;
  }

  // 1. 缓存命中
  const hashes = targets.map(hashOf);
  const rows = (
    await sql<{ hash: string; title: string; summary: string }>`
      select hash, title, summary from blog_translations
       where hash in (${sql.join(
         hashes.map((h) => sql`${h}`),
         sql`, `,
       )})
    `.execute(k.db)
  ).rows;
  const cache = new Map(rows.map((r) => [r.hash, r]));
  for (const [i, item] of targets.entries()) {
    const hit = cache.get(hashes[i]);
    if (!hit) continue;
    item.title = hit.title;
    item.summary = hit.summary;
    stats.cached += 1;
  }

  // 2. 剩下的走模型
  const todo = targets.filter((it) => !cache.has(hashOf(it)));
  if (todo.length === 0) {
    stats.ms = Date.now() - t0;
    return stats;
  }

  let llm: LocalLlm;
  try {
    // 预览接口不为它单独拉起模型：多等 6 秒只为了看原文列表不值得
    if (opts.warm === false && (!engine || engine.state === 'stopped')) {
      stats.ms = Date.now() - t0;
      return stats;
    }
    llm = llmOf(k);
    await llm.warmup();
  } catch (e) {
    stats.failed += todo.length;
    if (!unusable) {
      unusable = `本地翻译模型不可用：${String((e as Error).message || e).slice(0, 160)}`;
      log?.(`[blog] ${unusable}（英文素材保持原文）`);
    }
    stats.ms = Date.now() - t0;
    return stats;
  }

  const done = await mapLimit(todo, 2, async (item) => {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const res = await llm.chat(
          [
            { role: 'system', content: SYSTEM },
            { role: 'user', content: userPrompt(item, attempt > 0) },
          ],
          { temperature: 0, maxTokens: 400, jsonObject: true, timeoutMs: 90_000 },
        );
        const obj = extractJson(res.content);
        if (!obj?.title?.trim()) continue;
        const title = obj.title.trim();
        const summary = (obj.summary || '').trim();
        // 校验：标题必须真的变成中文，否则当作失败重试
        if (isEnglish(title)) {
          if (attempt === 0) continue;
          return null;
        }
        return { hash: hashOf(item), title, summary: summary && summary !== title ? summary : '' };
      } catch {
        // 超时 / 5xx：换下一次尝试
      }
    }
    return null;
  });

  const model = path.basename(resolveLlmPaths(k.paths.dataDir).model || '');
  const now = Math.floor(Date.now() / 1000);
  for (const [i, hit] of done.entries()) {
    if (!hit) {
      stats.failed += 1;
      continue;
    }
    const item = todo[i];
    item.title = hit.title;
    // 无条件覆盖：模型给不出摘要时也要清掉英文原文，否则它又会混进 prompt / 兜底稿。
    // 只有标题也够云端模型改写（它会从标题 + 来源写 230~270 字）。
    item.summary = hit.summary;
    stats.translated += 1;
    try {
      await sql`
        insert or replace into blog_translations (hash, title, summary, model, created_at)
        values (${hit.hash}, ${hit.title}, ${hit.summary}, ${model}, ${now})
      `.execute(k.db);
    } catch {
      // 缓存写失败不影响这一期
    }
  }

  stats.ms = Date.now() - t0;
  log?.(
    `[blog] 英转中：${stats.translated} 条新译 / ${stats.cached} 条命中缓存 / ${stats.failed} 条失败，${(
      stats.ms / 1000
    ).toFixed(1)}s`,
  );
  return stats;
}
