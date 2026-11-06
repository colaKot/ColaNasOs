import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import {
  llmApiKey,
  readSystemSettings,
  writeSystemSettings,
  type LlmSettings,
} from '../../../../kernel/system-settings';
import { proxyFetch } from '../../../../kernel/proxy-fetch';
import type { KernelApi } from '../../../../kernel/types';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { ref } from './schemas';
import { hotSuggestions } from '../retrieval';

/**
 * 相册 AI 助手 + 模型 API：单轮问答与掩码配置项。
 *
 * 与参考实现的两点不同（刻意）：
 * 1. Key 不另存 `agent_model_api`，直接复用 `system.settings#llm` —— 全局设置页和
 *    相册 AI 设置页写的是同一份，不会出现「这里填了、那边还是空」的两套真源。
 * 2. 读取只回 `hasKey` / `keyTail`（尾 4 位），不回明文；明文只在提交的那一刻经手。
 *
 * 问答是**单轮、非流式**：把只读库统计塞进 system prompt，让模型只能依据统计回答。
 * 没配模型（或调不通）时退回本地规则，保证「没网也能问」，与参考的 mode:'rule' 一致。
 */
const TAG = ['photo'];

interface StatItem {
  label: string;
  n: number;
}

interface AskContext {
  total: number;
  activeDays: number;
  firstAt: number | null;
  lastAt: number | null;
  withGps: number;
  years: StatItem[];
  topScenes: StatItem[];
  topActivities: StatItem[];
  topPeople: StatItem[];
  places: StatItem[];
}

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function day(sec: number | null): string {
  if (!sec) return '';
  const d = new Date(sec * 1000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

async function stats(k: KernelApi, uid: string, table: 'photo_scenes' | 'photo_activities') {
  const rows = (
    await sql<{ label: string; n: number }>`
      select s.label as label, count(*) as n
        from ${sql.raw(table)} s
        join photo_items i on i.id = s.photo_id
         and i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${uid})
       group by s.label order by n desc limit 8
    `.execute(k.db)
  ).rows;
  return rows.map((r) => ({ label: String(r.label), n: num(r.n) }));
}

/** 只读库统计：问答的唯一事实来源，模型不许越过它编数字 */
async function askContext(k: KernelApi, uid: string): Promise<AskContext> {
  const owner = sql`i.in_trash = 0 and i.library_id in (select id from photo_libraries where owner_id = ${uid})`;
  const base = (
    await sql<{ total: number; active_days: number; first_at: number | null; last_at: number | null; gps: number }>`
      select count(*) as total,
             count(distinct date(taken_at, 'unixepoch')) as active_days,
             min(taken_at) as first_at,
             max(taken_at) as last_at,
             sum(case when geohash is not null and geohash <> '' then 1 else 0 end) as gps
        from photo_items i where ${owner}
    `.execute(k.db)
  ).rows[0];

  const years = (
    await sql<{ label: string; n: number }>`
      select strftime('%Y', taken_at, 'unixepoch') as label, count(*) as n
        from photo_items i where ${owner} and taken_at > 0
       group by label order by n desc limit 10
    `.execute(k.db)
  ).rows.map((r) => ({ label: String(r.label), n: num(r.n) }));

  const people = (
    await sql<{ label: string; n: number }>`
      select name as label, size as n from photo_face_clusters
       where name is not null and name <> '' order by size desc limit 8
    `.execute(k.db)
  ).rows.map((r) => ({ label: String(r.label), n: num(r.n) }));

  const places = (
    await sql<{ label: string; n: number }>`
      select place as label, count(*) as n from photo_memories
       where owner_id = ${uid} and place is not null and place <> ''
       group by place order by n desc limit 8
    `.execute(k.db)
  ).rows.map((r) => ({ label: String(r.label), n: num(r.n) }));

  return {
    total: num(base?.total),
    activeDays: num(base?.active_days),
    firstAt: base?.first_at ?? null,
    lastAt: base?.last_at ?? null,
    withGps: num(base?.gps),
    years,
    topScenes: await stats(k, uid, 'photo_scenes'),
    topActivities: await stats(k, uid, 'photo_activities'),
    topPeople: people,
    places,
  };
}

const topLine = (items: StatItem[]): string =>
  items.length ? items.map((x) => `${x.label}（${x.n}）`).join('、') : '暂无数据';

/** 没配模型时的本地兜底：只回答统计能答的四类问题，其余如实说答不了 */
function ruleAnswer(question: string, c: AskContext): string {
  const q = question.replace(/\s+/g, '');
  const span = c.firstAt && c.lastAt ? `${day(c.firstAt)} 到 ${day(c.lastAt)}` : '暂无时间信息';
  if (/多少|总共|几张|数量|拍了|一共/.test(q)) {
    return `你的相册一共索引了 ${c.total} 张照片，拍摄跨度 ${span}，覆盖 ${c.activeDays} 个不同的拍摄日；其中 ${c.withGps} 张带 GPS 坐标。`;
  }
  if (/最常拍|拍得最多|什么内容|什么题材|场景|活动/.test(q)) {
    return `按识别结果看：最常见的场景是 ${topLine(c.topScenes.slice(0, 3))}；最常见的活动是 ${topLine(c.topActivities.slice(0, 3))}。`;
  }
  if (/去过|地方|地点|城市|哪里/.test(q)) {
    return c.places.length
      ? `已确认记忆里出现的地点：${topLine(c.places)}。另有 ${c.withGps} 张照片带 GPS 坐标，可以在足迹地图里看。`
      : `库统计里还没有确认过的地点。有 ${c.withGps} 张照片带 GPS 坐标，可以去足迹地图看看。`;
  }
  if (/哪一年|哪年|年份|年度/.test(q)) {
    return c.years.length
      ? `拍得最多的是 ${c.years[0].label} 年，共 ${c.years[0].n} 张。按年份顺序：${topLine(c.years.slice(0, 5))}。`
      : '库统计里还没有可用的年份数据。';
  }
  return `本地统计只能回答「拍了多少 / 最常拍什么 / 去过哪些地方 / 哪一年最多」这四类。当前库里共 ${c.total} 张照片、${c.activeDays} 个拍摄日。想自由提问，请先在「AI 设置 → 模型 API」里配置模型。`;
}

function chatUrl(base: string): string {
  const b = (base || '').replace(/\/+$/, '');
  if (/\/chat\/completions$/i.test(b)) return b;
  return `${b}/chat/completions`;
}

async function askLlm(llm: LlmSettings, question: string, ctx: AskContext): Promise<string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  try {
    const res = await proxyFetch(chatUrl(llm.baseUrl), {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${llmApiKey(llm)}`,
      },
      body: JSON.stringify({
        model: llm.model,
        messages: [
          {
            role: 'system',
            content:
              '你是相册助手。只能依据下面给出的「库统计」回答，不得编造数字，不得编造照片内容。' +
              '统计里没有的就说没有。回答用中文，简短，不要罗列 JSON。\n\n库统计：\n' +
              JSON.stringify(ctx),
          },
          { role: 'user', content: question },
        ],
        temperature: 0.3,
        max_tokens: 600,
      }),
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${(await res.text()).slice(0, 160)}`);
    }
    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || !content.trim()) throw new Error('模型返回空内容');
    return content.trim();
  } finally {
    clearTimeout(timer);
  }
}

/** 掩码视图：明文 Key 永不回前端 */
function modelApiView(k: KernelApi) {
  const llm = readSystemSettings(k.config).llm;
  const key = llmApiKey(llm);
  return {
    enabled: llm.enabled,
    provider: llm.provider,
    baseUrl: llm.baseUrl,
    model: llm.model,
    webSearch: llm.webSearch,
    hasKey: key.length > 0,
    keyTail: key ? key.slice(-4) : '',
  };
}

export async function registerPhotoAssistant(
  app: FastifyInstance,
  k: KernelApi,
): Promise<void> {
  // ---------------------------------------------------------------- 模型 API
  app.get(
    '/api/v1/photo/ai/model-api',
    secured('photo:read', {
      schema: {
        operationId: 'photoAiModelApi',
        tags: TAG,
        summary: '模型 API 配置（只读掩码视图，与全局 AI 服务共用一份）',
        response: { 200: ref('PhotoModelApi') },
      },
    }),
    () => modelApiView(k),
  );

  app.post(
    '/api/v1/photo/ai/model-api',
    secured('system:write', {
      schema: {
        operationId: 'photoAiModelApiSet',
        tags: TAG,
        summary: '保存模型 API（apiKey 留空 = 保留已保存的密钥）',
        body: ref('PhotoModelApiBody'),
        response: { 200: ref('PhotoModelApi') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const patch: Record<string, unknown> = {};
      if (typeof body.baseUrl === 'string') patch.baseUrl = body.baseUrl.trim().slice(0, 300);
      if (typeof body.model === 'string') patch.model = body.model.trim().slice(0, 120);
      if (typeof body.enabled === 'boolean') patch.enabled = body.enabled;
      if (typeof body.apiKey === 'string' && body.apiKey.trim()) {
        patch.apiKey = body.apiKey.trim().slice(0, 400);
      }
      await writeSystemSettings(k.config, { llm: patch });
      return modelApiView(k);
    },
  );

  app.post(
    '/api/v1/photo/ai/model-api/test',
    secured('photo:read', {
      schema: {
        operationId: 'photoAiModelApiTest',
        tags: TAG,
        summary: '测试模型 API 连通性（先 /models，失败再兜底最小 chat 请求）',
        body: ref('PhotoModelApiTestBody'),
        response: { 200: ref('PhotoModelApiTestResult') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const cur = readSystemSettings(k.config).llm;
      const baseUrl = String(body.baseUrl ?? cur.baseUrl).trim() || cur.baseUrl;
      const model = String(body.model ?? cur.model).trim() || cur.model;
      // 留空 = 用已保存的 Key（前端输入框是掩码，不可能把明文带回来）
      const apiKey = String(body.apiKey ?? '').trim() || llmApiKey(cur);
      const started = Date.now();
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 10_000);
      const headers = {
        'content-type': 'application/json',
        authorization: `Bearer ${apiKey}`,
      };
      const models: string[] = [];
      let ok = false;
      let message = '';
      try {
        if (!apiKey) {
          message = '未配置 API Key';
        } else {
          const base = baseUrl.replace(/\/+$/, '');
          const res = await proxyFetch(`${base}/models`, {
            headers,
            signal: controller.signal,
          });
          if (res.ok) {
            const data = (await res.json()) as { data?: Array<{ id?: string }> };
            for (const m of data?.data ?? []) {
              if (typeof m?.id === 'string' && models.length < 50) models.push(m.id);
            }
            ok = true;
          } else {
            // 有些网关不开放 /models：按参考实现兜底打一次最小 chat 请求
            const chat = await proxyFetch(chatUrl(base), {
              method: 'POST',
              headers,
              signal: controller.signal,
              body: JSON.stringify({
                model,
                messages: [{ role: 'user', content: 'ping' }],
                max_tokens: 1,
              }),
            });
            ok = chat.ok;
            if (!ok) message = `HTTP ${chat.status}`;
          }
        }
      } catch (err) {
        message = String((err as Error)?.message || err).slice(0, 200);
      } finally {
        clearTimeout(timer);
      }
      return {
        ok,
        latencyMs: Date.now() - started,
        models,
        modelExists: models.includes(model),
        message: ok ? '' : message || '连接失败',
      };
    },
  );

  // ---------------------------------------------------------------- 相册助手
  app.post(
    '/api/v1/photo/ai/ask',
    secured('photo:read', {
      schema: {
        operationId: 'photoAiAsk',
        tags: TAG,
        summary: '相册助手问答（配了模型走模型，没配走本地统计规则）',
        body: ref('PhotoAskBody'),
        response: { 200: ref('PhotoAskResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { question?: string };
      const question = String(body.question || '').trim().slice(0, 400);
      const uid = String((req as any).user?.sub || '');
      const ctx = await askContext(k, uid);
      const llm = readSystemSettings(k.config).llm;
      if (question && llm.enabled && llmApiKey(llm)) {
        try {
          return { mode: 'llm', answer: await askLlm(llm, question, ctx), reason: '' };
        } catch (err) {
          // 模型挂了不能让问答整体失败：退回规则，并把原因回给前端
          return {
            mode: 'rule',
            answer: ruleAnswer(question, ctx),
            reason: String((err as Error)?.message || err).slice(0, 200),
          };
        }
      }
      return {
        mode: 'rule',
        answer: question ? ruleAnswer(question, ctx) : '',
        reason: 'no_model',
      };
    },
  );

  // ---------------------------------------------------------------- 热搜推荐
  app.post(
    '/api/v1/photo/search/hot',
    secured('photo:read', {
      schema: {
        operationId: 'photoSearchHot',
        tags: TAG,
        summary: '热门推荐（人物 / 场景 / 活动 / 年份，给「随便看看」用）',
        body: ref('PhotoSearchHotBody'),
        response: { 200: ref('PhotoSearchHotResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(num(body.limit) || 6, 20));
      return { items: await hotSuggestions(k, limit) };
    },
  );
}
