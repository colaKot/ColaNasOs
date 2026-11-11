import type { ConfigStore } from './config';

/**
 * 全局服务器配置（设置页「服务器 / 网络 / 个性化」）。
 *
 * 存在 `config` 表的单键 `system.settings` 里：读一次即全部命中，
 * 避免多个键之间出现半保存状态。**端口与并发只在重启后生效**，
 * 代理则立即生效（调用 `configureProxy`）。
 */
export const SYSTEM_SETTINGS_KEY = 'system.settings';

/**
 * 大模型（AI 改写）配置。**唯一真源**：系统设置与 AI 播客页读写的是同一份，
 * 因此「在设置里填的 Key」和「播客页填的 Key」永远一致，不存在两处各存一份的问题。
 */
export interface LlmSettings {
  /** 开关：关掉就只用素材拼接，不调模型（省 token / 断网也能出稿） */
  enabled: boolean;
  /** deepseek / openai / custom（仅展示与默认值带出，真正生效的是 baseUrl + model） */
  provider: string;
  baseUrl: string;
  model: string;
  /** 明文保存（用户要求可查看、可复制） */
  apiKey: string;
  /**
   * 联网搜索（阿里百炼的搜索插件）。
   * 打开后请求体会带 `enable_search: true`，模型可以自己检索新闻——
   * 这样即使 RSS 一条都没抓到，也能出稿（素材只作为锚点）。
   */
  webSearch: boolean;
}

export interface SystemSettings {
  /** HTTP 监听端口（默认 7788；`PORT` 环境变量优先） */
  httpPort: number;
  /** HTTPS 额外入口端口（证书由用户上传；重启后生效） */
  httpsPort: number;
  /** 是否启用 HTTPS 入口（需要已上传证书，否则启动时只告警） */
  httpsEnabled: boolean;
  /** 任务 worker 并发（1–8，默认 1） */
  apiConcurrency: number;
  /** 自定义主机名（≤10 字，仅展示） */
  hostname: string;
  /** 首页欢迎语（≤100 字） */
  welcome: string;
  /** 全局网络代理；空 = 直连 */
  proxy: string;
  /** 日系刮削兜底（TMDB/IMDb 都识别不了时按番号抓） */
  javFallback: boolean;
  /** 大模型改写（AI 新闻播客等） */
  llm: LlmSettings;
}

const defaultPort = Number(process.env.PORT) || 7788;
const defaultConcurrency = Math.max(
  1,
  Math.min(Number(process.env.COLANAS_TASK_CONCURRENCY) || 1, 8),
);

export const DEFAULT_SYSTEM_SETTINGS: SystemSettings = {
  httpPort: defaultPort,
  httpsPort: 8443,
  httpsEnabled: false,
  apiConcurrency: defaultConcurrency,
  hostname: '',
  welcome: '',
  proxy: '',
  javFallback: true,
  llm: {
    enabled: true,
    provider: 'deepseek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
    apiKey: '',
    webSearch: false,
  },
};

function intIn(value: unknown, fallback: number, min: number, max: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(Math.trunc(n), max));
}

function text(value: unknown, max: number): string {
  return String(value ?? '').trim().slice(0, max);
}

/** 大模型的默认值（模型名随服务商走；用户改了 baseUrl 自己填 model 即可） */
export function defaultLlm(provider: string): LlmSettings {
  const p = provider.trim().toLowerCase();
  const base = { enabled: true, apiKey: '', webSearch: false };
  // 阿里百炼：DeepSeek 走 OpenAI 兼容模式，且是唯一带「联网搜索插件」的。
  // base/model 是本工程在百炼上创建的专属部署（换成自己账号时在设置里改）。
  if (p === 'bailian' || p === 'dashscope') {
    return {
      ...base,
      provider: 'bailian',
      baseUrl: 'https://llm-l47j92cn6251pgfv.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
      model: 'deepseek-v4.1-flash-1017',
      webSearch: true,
    };
  }
  if (p === 'openai') {
    return {
      ...base,
      provider: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
    };
  }
  return {
    ...base,
    provider: 'deepseek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
  };
}

/**
 * DeepSeek 官方 2026-07-24 下线的模型名 → 现在的 Flash 名。
 * 只认这两个精确名字：百炼 / 自建兼容端点上的模型名由部署方决定，一律不碰
 * （比如百炼的 `deepseek-v4.1-flash-1017` 改成 `deepseek-flash` 会直接 404）。
 */
const DEPRECATED_DEEPSEEK_MODELS = new Set(['deepseek-chat', 'deepseek-reasoner']);

function isDeepseekOfficial(provider: string, baseUrl: string): boolean {
  if (provider.trim().toLowerCase() === 'deepseek') return true;
  try {
    const host = new URL(baseUrl).hostname.toLowerCase();
    return host === 'api.deepseek.com' || host.endsWith('.deepseek.com');
  } catch {
    return false;
  }
}

/** 已保存配置里的废弃模型名换成当前可用的；其余原样返回 */
export function migrateLlmModel(model: string, provider: string, baseUrl: string): string {
  const m = String(model ?? '').trim();
  return DEPRECATED_DEEPSEEK_MODELS.has(m.toLowerCase()) && isDeepseekOfficial(provider, baseUrl)
    ? DEFAULT_SYSTEM_SETTINGS.llm.model
    : m;
}

/**
 * 启动时把**已经落库**的旧模型名改掉（只改 llm.model，其它键原样保留）。
 * 光改代码默认值救不了老库：`normalizeLlm` 只在 model 为空时才用 fallback，
 * 存着 `deepseek-chat` 的配置会一直拿废弃名去请求、每期都 400。
 * 返回是否真的改过，供启动日志用。
 */
export async function migrateDeprecatedLlmModel(config: ConfigStore): Promise<boolean> {
  const stored = config.get<Record<string, unknown>>(SYSTEM_SETTINGS_KEY);
  const llm = (stored?.llm ?? {}) as Record<string, unknown>;
  const old = String(llm.model ?? '').trim();
  if (!old) return false;
  const provider = String(llm.provider ?? '').trim() || DEFAULT_SYSTEM_SETTINGS.llm.provider;
  const baseUrl = String(llm.baseUrl ?? '').trim() || DEFAULT_SYSTEM_SETTINGS.llm.baseUrl;
  const next = migrateLlmModel(old, provider, baseUrl);
  if (next === old) return false;
  await config.set(SYSTEM_SETTINGS_KEY, { ...(stored ?? {}), llm: { ...llm, model: next } });
  return true;
}

function normalizeLlm(raw: unknown, fallback: LlmSettings): LlmSettings {
  const src = (raw || {}) as Record<string, unknown>;
  const provider = text(src.provider, 40) || fallback.provider;
  const baseUrl = text(src.baseUrl, 300) || fallback.baseUrl;
  return {
    enabled: src.enabled === undefined ? fallback.enabled : src.enabled !== false,
    provider,
    baseUrl,
    // 老库可能仍存着已下线的名字：读时就修正，即使启动迁移没跑
    // （契约生成器只装配不监听）也不会拿废弃名去请求。
    model: migrateLlmModel(text(src.model, 120) || fallback.model, provider, baseUrl),
    // 只裁首尾空白；中间不处理（Key 里可能有符号，别自作聪明）
    apiKey: String(src.apiKey ?? fallback.apiKey ?? '').trim().slice(0, 400),
    webSearch: src.webSearch === undefined ? fallback.webSearch : src.webSearch === true,
  };
}

/**
 * 实际用的 Key：设置页填的优先；没填时读 `DASHSCOPE_API_KEY`（百炼官方 SDK 的习惯）。
 * 这样用环境变量配置的人不用再把 Key 抄一遍到界面上。
 */
export function llmApiKey(llm: LlmSettings): string {
  if (llm.apiKey) return llm.apiKey;
  if (llm.provider === 'bailian') return (process.env.DASHSCOPE_API_KEY || '').trim();
  return '';
}

export function normalizeSystemSettings(input: unknown): SystemSettings {
  const raw = (input || {}) as Record<string, unknown>;
  const proxy = text(raw.proxy, 200);
  return {
    httpPort: intIn(raw.httpPort, defaultPort, 1, 65535),
    httpsPort: intIn(raw.httpsPort, 8443, 1, 65535),
    httpsEnabled: raw.httpsEnabled === true,
    apiConcurrency: intIn(raw.apiConcurrency, defaultConcurrency, 1, 8),
    hostname: text(raw.hostname, 10),
    welcome: text(raw.welcome, 100),
    // 只接受 http(s)://；非法值不静默落库，交由路由层报错
    proxy: /^https?:\/\//i.test(proxy) ? proxy : '',
    // 默认开启：没写过这个键的老配置也算开（用户要求「删掉按钮，默认打开」）
    javFallback: raw.javFallback !== false,
    llm: normalizeLlm(raw.llm, DEFAULT_SYSTEM_SETTINGS.llm),
  };
}

export function readSystemSettings(config: ConfigStore): SystemSettings {
  const stored = config.get<Record<string, unknown>>(SYSTEM_SETTINGS_KEY) ?? {};
  return normalizeSystemSettings({ ...DEFAULT_SYSTEM_SETTINGS, ...stored });
}

export async function writeSystemSettings(
  config: ConfigStore,
  patch: Record<string, unknown>,
): Promise<SystemSettings> {
  const cur = readSystemSettings(config);
  // llm 是嵌套对象：浅合并会把没传的字段（比如只改 model）冲成默认值，
  // 这里先按字段合并，再交给 normalize
  const merged: Record<string, unknown> = { ...cur, ...patch } as unknown as Record<string, unknown>;
  if (patch.llm && typeof patch.llm === 'object') {
    merged.llm = { ...cur.llm, ...(patch.llm as Record<string, unknown>) };
  }
  const next = normalizeSystemSettings(merged);
  if (patch.proxy !== undefined) {
    const raw = String(patch.proxy ?? '').trim();
    if (raw && next.proxy !== raw) {
      throw Object.assign(new Error('proxy must be an http(s) URL'), { code: 'E_PROXY' });
    }
  }
  await config.set(SYSTEM_SETTINGS_KEY, next);
  return next;
}