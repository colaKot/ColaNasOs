import type { ConfigStore } from './config';

/**
 * 全局服务器配置（设置页「服务器 / 网络 / 个性化」）。
 *
 * 存在 `config` 表的单键 `system.settings` 里：读一次即全部命中，
 * 避免多个键之间出现半保存状态。**端口与并发只在重启后生效**，
 * 代理则立即生效（调用 `configureProxy`）。
 */
export const SYSTEM_SETTINGS_KEY = 'system.settings';

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
  javFallback: false,
};

function intIn(value: unknown, fallback: number, min: number, max: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(Math.trunc(n), max));
}

function text(value: unknown, max: number): string {
  return String(value ?? '').trim().slice(0, max);
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
    javFallback: raw.javFallback === true,
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
  const next = normalizeSystemSettings({ ...readSystemSettings(config), ...patch });
  if (patch.proxy !== undefined) {
    const raw = String(patch.proxy ?? '').trim();
    if (raw && next.proxy !== raw) {
      throw Object.assign(new Error('proxy must be an http(s) URL'), { code: 'E_PROXY' });
    }
  }
  await config.set(SYSTEM_SETTINGS_KEY, next);
  return next;
}