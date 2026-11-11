import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import {
  llmApiKey,
  migrateLlmModel,
  readSystemSettings,
  writeSystemSettings,
} from '../../../kernel/system-settings';

/** 8 类新闻。顺序与 UI 一致，也是稿件里播报的顺序。 */
export const COUNT_KEYS = [
  'domesticGeneral',
  'worldGeneral',
  'domesticTech',
  'worldTech',
  'domesticAi',
  'worldAi',
  'domesticFinance',
  'worldFinance',
] as const;

export type CountKey = (typeof COUNT_KEYS)[number];
export type BlogCounts = Record<CountKey, number>;

/** 用户描述里的默认口味：每类 1~2 条，10 条约 15 分钟一期 */
export const DEFAULT_COUNTS: BlogCounts = {
  domesticGeneral: 2,
  worldGeneral: 2,
  domesticTech: 1,
  worldTech: 1,
  domesticAi: 1,
  worldAi: 1,
  domesticFinance: 1,
  worldFinance: 1,
};

/**
 * 默认音色 = `vendor/voices/default.wav` 的 id。
 *
 * 换成 Qwen3-TTS（声音克隆）之后，音色不再是固定的 speaker id，而是磁盘上的一段参考音；
 * 清单由 `kernel/tts/voices.ts` 扫目录得到，这里只记住"上次选的是哪个"。
 */
export const DEFAULT_VOICE = 'default';

/**
 * 每条的估算时长：稿面 400 字 ≈ 90 秒音频。
 * 这是**音频时长**的估算，和用哪个合成引擎无关（语速由模型决定）。
 */
export const SECONDS_PER_ITEM = 90;

export interface BlogSettings {
  voice: string;
  speed: number;
  counts: BlogCounts;
  planHour: number;
  planMinute: number;
  planEnabled: boolean;
  apiProvider: string;
  apiKey: string;
  apiBase: string;
  apiModel: string;
  /** 大模型改写开关（与系统设置共用同一份 llm 配置） */
  llmEnabled: boolean;
  /** 联网搜索（百炼搜索插件）：打开后没抓到 RSS 素材也能出稿 */
  webSearch: boolean;
  lastPlanDate: string | null;
}

export const DEFAULT_SETTINGS: BlogSettings = {
  voice: DEFAULT_VOICE,
  speed: 1,
  counts: DEFAULT_COUNTS,
  planHour: 4,
  planMinute: 0,
  planEnabled: true,
  apiProvider: 'deepseek',
  apiKey: '',
  apiBase: 'https://api.deepseek.com',
  apiModel: 'deepseek-flash',
  llmEnabled: true,
  webSearch: false,
  lastPlanDate: null,
};

/**
 * 音色 id 只做**格式**校验；是否真实存在由 `kernel/tts/voices.ts` 在用到时判定
 * （音色来自磁盘上的参考音，可增可删，不能在设置模块里写死清单）。
 */
export function cleanVoice(raw: unknown): string {
  const s = String(raw ?? '').trim();
  // 换 Qwen3-TTS 之前是 Kokoro 的固定 speaker id（zf_001…），换栈后磁盘上已没有这些音色。
  // 老库 / 老客户端传上来时回落到内置音色，否则前端下拉框的 value 不在 items 里会 assert 崩溃。
  if (/^zf_\d+$/i.test(s)) return DEFAULT_VOICE;
  return /^[A-Za-z0-9_-]{1,40}$/.test(s) ? s : DEFAULT_VOICE;
}

function intIn(value: unknown, fallback: number, min: number, max: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(Math.trunc(n), max));
}

export function normalizeCounts(raw: unknown): BlogCounts {
  const src = (raw || {}) as Record<string, unknown>;
  const out = {} as BlogCounts;
  for (const key of COUNT_KEYS) out[key] = intIn(src[key], DEFAULT_COUNTS[key], 0, 10);
  return out;
}

export function totalItems(counts: BlogCounts): number {
  return COUNT_KEYS.reduce((sum, key) => sum + (counts[key] || 0), 0);
}

export function normalizeSettings(raw: unknown): BlogSettings {
  const src = (raw || {}) as Record<string, unknown>;
  const speed = Number(src.speed ?? 1);
  return {
    voice: cleanVoice(src.voice),
    speed: Number.isFinite(speed) ? Math.max(0.5, Math.min(speed, 2)) : 1,
    counts: normalizeCounts(src.counts),
    planHour: intIn(src.planHour, 4, 0, 23),
    planMinute: intIn(src.planMinute, 0, 0, 59),
    planEnabled: src.planEnabled !== false,
    apiProvider: String(src.apiProvider ?? 'deepseek').trim().slice(0, 40) || 'deepseek',
    // 明文保存（用户要求「明码的」，能看见、能复制）；只裁掉换行与首尾空白
    apiKey: String(src.apiKey ?? '').trim().slice(0, 400),
    apiBase: String(src.apiBase ?? '').trim().slice(0, 300) || DEFAULT_SETTINGS.apiBase,
    apiModel: String(src.apiModel ?? '').trim().slice(0, 120) || DEFAULT_SETTINGS.apiModel,
    llmEnabled: src.llmEnabled !== false,
    webSearch: src.webSearch === true,
    lastPlanDate: src.lastPlanDate ? String(src.lastPlanDate).slice(0, 10) : null,
  };
}

interface SettingRow {
  voice: string;
  speed: number;
  counts_json: string;
  plan_hour: number;
  plan_minute: number;
  plan_enabled: number;
  api_provider: string;
  api_key: string;
  api_base: string;
  api_model: string;
  last_plan_date: string | null;
}

export async function readSettings(k: KernelApi): Promise<BlogSettings> {
  const row = (
    await sql<SettingRow>`select * from blog_settings where id = 1`.execute(k.db)
  ).rows[0];
  // Key / 地址 / 模型以**全局系统设置**为准（与设置页同一份，两处互通）
  const llm = readSystemSettings(k.config).llm;
  if (!row) {
    return normalizeSettings({
      ...DEFAULT_SETTINGS,
      counts: { ...DEFAULT_COUNTS },
      apiProvider: llm.provider,
      apiKey: llmApiKey(llm),
      apiBase: llm.baseUrl,
      apiModel: llm.model,
      llmEnabled: llm.enabled,
      webSearch: llm.webSearch,
    });
  }

  // 库里的 counts_json 可能是手改坏的值：解析失败就当空对象，让 normalizeCounts 用默认值
  let counts: unknown;
  try {
    counts = JSON.parse(row.counts_json || '{}');
  } catch {
    counts = {};
  }
  return normalizeSettings({
    voice: row.voice,
    speed: row.speed,
    counts,
    planHour: row.plan_hour,
    planMinute: row.plan_minute,
    planEnabled: Number(row.plan_enabled) === 1,
    apiProvider: llm.provider || row.api_provider,
    apiKey: llmApiKey(llm) || row.api_key, // 全局还没填时回落到老列（一次性迁移的读路径）
    apiBase: llm.baseUrl || row.api_base,
    apiModel: llm.model || row.api_model,
    llmEnabled: llm.enabled,
    webSearch: llm.webSearch,
    lastPlanDate: row.last_plan_date,
  });
}

/**
 * 启动时保证单行设置存在：定时任务要写 `last_plan_date`，
 * 表是空的话 update 影响 0 行，会出现「每分钟都判定今天还没生成」的死循环。
 */
/** 一次性迁移：早期版本 Key 存在 blog_settings.api_key，现在真源在 system.settings#llm */
export async function migrateLegacyLlmKey(k: KernelApi): Promise<void> {
  const row = (
    await sql<{ api_key: string; api_base: string; api_model: string; api_provider: string }>`
      select api_key, api_base, api_model, api_provider from blog_settings where id = 1
    `.execute(k.db)
  ).rows[0];
  if (!row || !row.api_key) return;
  const cur = readSystemSettings(k.config).llm;
  if (cur.apiKey) return;
  await writeSystemSettings(k.config, {
    llm: {
      enabled: cur.enabled,
      provider: row.api_provider || cur.provider,
      baseUrl: row.api_base || cur.baseUrl,
      model: row.api_model || cur.model,
      apiKey: row.api_key,
      webSearch: cur.webSearch,
    },
  });
}

/**
 * 老库的 `blog_settings.api_model` 列也可能存着下线模型名。
 * `generate.ts#readCfg` 在全局 llm.apiKey 为空时会回落到这一列，所以一并改掉；
 * 同样只动指向 DeepSeek 官方端点的行，百炼 / 自建部署原样保留。
 */
export async function migrateDeprecatedBlogModel(k: KernelApi): Promise<void> {
  const row = (
    await sql<{ api_model: string; api_provider: string; api_base: string }>`
      select api_model, api_provider, api_base from blog_settings where id = 1
    `.execute(k.db)
  ).rows[0];
  if (!row) return;
  const next = migrateLlmModel(row.api_model, row.api_provider, row.api_base);
  if (next === row.api_model) return;
  await sql`update blog_settings set api_model = ${next} where id = 1`.execute(k.db);
  k.log.info(`[blog] 已把下线的模型名 ${row.api_model} 迁移到 ${next}`);
}

/**
 * 老库 `blog_settings.voice` 里还存着 Kokoro 时代的固定 id（zf_001…）。
 * `cleanVoice()` 读时会兜底，但落库的旧值仍会被返回给旧客户端 / 第三方 SDK，
 * 所以启动时顺手改掉（只匹配旧 id 格式，不碰用户自己上传的音色）。
 */
export async function migrateLegacyVoice(k: KernelApi): Promise<void> {
  const changed = await sql`
    update blog_settings set voice = ${DEFAULT_VOICE}
     where id = 1 and voice glob 'zf_[0-9]*'
  `.execute(k.db);
  if (changed.numAffectedRows) {
    k.log.info(`[blog] 已把旧音色 id 迁移到 ${DEFAULT_VOICE}`);
  }
}

export async function ensureSettingsRow(k: KernelApi): Promise<void> {
  const d = DEFAULT_SETTINGS;
  await sql`
    insert into blog_settings
      (id, voice, speed, tts_engine, counts_json, plan_hour, plan_minute, plan_enabled,
       api_provider, api_key, api_base, api_model, last_plan_date, updated_at)
    values (1, ${d.voice}, ${d.speed}, 'local', ${JSON.stringify(d.counts)}, ${d.planHour},
            ${d.planMinute}, ${d.planEnabled ? 1 : 0}, ${d.apiProvider}, ${d.apiKey},
            ${d.apiBase}, ${d.apiModel}, ${null}, ${Math.floor(Date.now() / 1000)})
    on conflict (id) do nothing
  `.execute(k.db);
}

export async function writeSettings(k: KernelApi, next: BlogSettings): Promise<void> {
  // 大模型配置写回全局（唯一真源）；blog_settings 的 api_* 列保留但不再读取为准，
  // 这样从设置页改 Key，播客页刷新就是新值，反之亦然。
  await writeSystemSettings(k.config, {
    llm: {
      enabled: next.llmEnabled,
      provider: next.apiProvider,
      baseUrl: next.apiBase,
      model: next.apiModel,
      apiKey: next.apiKey,
      webSearch: next.webSearch,
    },
  });
  const now = Math.floor(Date.now() / 1000);
  await sql`
    insert into blog_settings
      (id, voice, speed, tts_engine, counts_json, plan_hour, plan_minute, plan_enabled,
       api_provider, api_key, api_base, api_model, last_plan_date, updated_at)
    values (1, ${next.voice}, ${next.speed}, 'local', ${JSON.stringify(next.counts)},
            ${next.planHour}, ${next.planMinute}, ${next.planEnabled ? 1 : 0},
            ${next.apiProvider}, ${next.apiKey}, ${next.apiBase}, ${next.apiModel},
            ${next.lastPlanDate}, ${now})
    on conflict (id) do update set
      voice = excluded.voice,
      speed = excluded.speed,
      counts_json = excluded.counts_json,
      plan_hour = excluded.plan_hour,
      plan_minute = excluded.plan_minute,
      plan_enabled = excluded.plan_enabled,
      api_provider = excluded.api_provider,
      api_key = excluded.api_key,
      api_base = excluded.api_base,
      api_model = excluded.api_model,
      last_plan_date = excluded.last_plan_date,
      updated_at = excluded.updated_at
  `.execute(k.db);
}
