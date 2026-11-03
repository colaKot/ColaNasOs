import type { ConfigStore } from './config';

/**
 * 子账号的「应用级 + 路径级」双层授权（服务端强制）。
 *
 * 语义（与 UI 无关，HTTP 调用同样受约束）：
 * - **应用级**：`apps` 未配置（`null`/`undefined`）= 不限制（向后兼容）；配置了数组 = 只允许数组内的 appKey。
 * - **路径级**：`paths` 为空 = 不限制；非空时按规则前缀匹配，`ro` 只允许读、`rw` 读写都允许。
 * - 未登记前缀**一律放行**——新增模块必须同步登记到 `APP_API_PREFIXES`，否则应用白名单对它无效。
 *
 * 存储：`config` 表键 `accessPolicy.<uid>`，靠 `ConfigStore` 的内存缓存实现每请求 O(1) 读取。
 */
export const POLICY_KEY_PREFIX = 'accessPolicy.';

/** appKey → API 前缀（appKey 以 `contracts/apps.json` 的 id 为准） */
export const APP_API_PREFIXES: Record<string, string[]> = {
  files: ['/api/v1/files'],
  photo: ['/api/v1/photo'],
  video: ['/api/v1/video', '/api/v1/player'],
  discover: ['/api/v1/discover'],
  music: ['/api/v1/music'],
  book: ['/api/v1/book'],
  notes: ['/api/v1/notes'],
  netdisk: ['/api/v1/mount'],
  sync: ['/api/v1/sync'],
  share: ['/api/v1/share'],
  backup: ['/api/v1/safety'],
  ai: ['/api/v1/photo/ai'],
  monitor: ['/api/v1/system'],
  settings: ['/api/v1/accounts', '/api/v1/security', '/api/v1/tasks'],
};

/** 基础通道：登录、健康检查、契约、MCP 独立令牌通道 */
export const PUBLIC_API_PREFIXES = [
  '/health',
  '/ready',
  '/openapi.json',
  '/api/v1/auth',
  '/api/v1/share/info',
  '/api/v1/share/download',
  '/api/v1/mcp',
];

export interface PathRule {
  /** 相对 files 根的路径；`/` 表示全部 */
  path: string;
  access: 'ro' | 'rw';
}

export interface AccessPolicy {
  /** 允许的 appKey；未配置 = 不限制 */
  apps?: string[] | null;
  /** 路径规则；空 = 不限制 */
  paths?: PathRule[];
}

const EMPTY_POLICY: AccessPolicy = { apps: null, paths: [] };

function normalizePath(value: string): string {
  const raw = String(value ?? '')
    .trim()
    .replace(/\\/g, '/');
  const withRoot = raw.startsWith('/') ? raw : `/${raw}`;
  const trimmed = withRoot.length > 1 ? withRoot.replace(/\/+$/, '') : withRoot;
  const parts = trimmed.split('/').filter((p) => p.length > 0 && p !== '.');
  if (parts.some((p) => p === '..')) {
    throw Object.assign(new Error('path escapes root'), { code: 'E_PATH_ESCAPE' });
  }
  return parts.length === 0 ? '/' : `/${parts.join('/')}`;
}

/** 规则归一 + 校验；非法路径直接抛错（不做静默降级） */
export function normalizePathRule(rule: PathRule): PathRule {
  const access = rule.access === 'rw' ? 'rw' : 'ro';
  return { path: normalizePath(rule.path), access };
}

export function readPolicy(config: ConfigStore, uid: string): AccessPolicy {
  const raw = config.get<AccessPolicy>(POLICY_KEY_PREFIX + uid);
  if (!raw) return EMPTY_POLICY;
  const apps = Array.isArray(raw.apps) ? raw.apps.filter((a) => typeof a === 'string') : null;
  const paths = Array.isArray(raw.paths)
    ? raw.paths
        .filter((p) => p && typeof p.path === 'string')
        .map((p) => normalizePathRule(p as PathRule))
    : [];
  return { apps: apps && apps.length > 0 ? apps : null, paths };
}

export async function writePolicy(
  config: ConfigStore,
  uid: string,
  next: AccessPolicy,
): Promise<AccessPolicy> {
  const apps = Array.isArray(next.apps)
    ? [...new Set(next.apps.map((a) => String(a).trim()).filter(Boolean))]
    : null;
  const paths = Array.isArray(next.paths) ? next.paths.map(normalizePathRule) : [];
  const value: AccessPolicy = { apps: apps && apps.length > 0 ? apps : null, paths };
  await config.set(POLICY_KEY_PREFIX + uid, value);
  return value;
}

/** 请求路径命中的 appKey 集合（多前缀重叠时返回全部，命中任一即通过） */
export function appKeysForPath(urlPath: string): string[] {
  if (PUBLIC_API_PREFIXES.some((p) => matchesPrefix(urlPath, p))) return [];
  const hits: string[] = [];
  for (const [appKey, prefixes] of Object.entries(APP_API_PREFIXES)) {
    if (prefixes.some((p) => matchesPrefix(urlPath, p))) hits.push(appKey);
  }
  return hits;
}

function matchesPrefix(urlPath: string, prefix: string): boolean {
  return urlPath === prefix || urlPath.startsWith(prefix.endsWith('/') ? prefix : `${prefix}/`);
}

export interface AppAccessDecision {
  ok: boolean;
  /** 命中的 appKey（拒绝时用于回传与日志） */
  appKey: string | null;
}

export function checkAppAccess(
  allowedApps: string[] | null | undefined,
  urlPath: string,
): AppAccessDecision {
  if (!allowedApps || allowedApps.length === 0) return { ok: true, appKey: null };
  const hits = appKeysForPath(urlPath);
  // 未登记前缀：放行（新增模块忘登记不能把老用户锁死）
  if (hits.length === 0) return { ok: true, appKey: null };
  const allowed = new Set(allowedApps);
  const hit = hits.find((k) => allowed.has(k)) ?? hits[0];
  return { ok: hits.some((k) => allowed.has(k)), appKey: hit };
}

export interface PathAccessDecision {
  ok: boolean;
  /** 命中的规则路径（拒绝时用于回传） */
  rule: string | null;
}

export function checkPathAccess(
  rules: PathRule[] | null | undefined,
  need: 'read' | 'write',
  requestPath: string,
): PathAccessDecision {
  if (!rules || rules.length === 0) return { ok: true, rule: null };

  let target: string;
  try {
    target = normalizePath(requestPath);
  } catch {
    return { ok: false, rule: null };
  }

  let deepest: PathRule | null = null;
  for (const rule of rules) {
    const covers = rule.path === '/' || target === rule.path || target.startsWith(`${rule.path}/`);
    if (!covers) continue;
    if (!deepest || rule.path.length > deepest.path.length) deepest = rule;
  }
  if (!deepest) return { ok: false, rule: null };
  if (need === 'write' && deepest.access !== 'rw') return { ok: false, rule: deepest.path };
  return { ok: true, rule: deepest.path };
}
/** 从请求里取路径参数（query.path 优先，其次 body.path）；取不到返回 null = 不做路径校验 */
export function requestPathOf(req: { query?: unknown; body?: unknown }): string | null {
  const q = (req.query || {}) as { path?: unknown };
  if (typeof q.path === 'string' && q.path.trim()) return q.path;
  const b = (req.body || {}) as { path?: unknown; target?: unknown };
  if (typeof b.path === 'string' && b.path.trim()) return b.path;
  if (typeof b.target === 'string' && b.target.trim()) return b.target;
  return null;
}
