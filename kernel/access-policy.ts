import type { ConfigStore } from './config';

/**
 * 子账号的「应用级 + 路径级」双层授权（服务端强制）。
 *
 * 语义（与 UI 无关，HTTP 调用同样受约束）：
 * - **应用级**：`apps` 未配置（`null`/`undefined`）= 不限制（向后兼容）；配置了数组 = 只允许数组内的 appKey。
 * - **路径级**：见 [effectivePathRules] —— **没配目录 = 一个目录都不授权**（用户 2026-11-11 要求：
 *   子账号必须被明确授权目录才能用，不能靠「没配=全开」白拿）。全权账号（`*`）且从未配置过
 *   策略时才视为不限制，管理员开箱即用。
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

/**
 * 路径上允许的动作：
 * - view     看目录 / 缩略图 / 搜索（只读浏览）
 * - download 下载原文件（含 Range 拖动）
 * - update   改名 / 移动 / 新建目录（改结构但不毁数据）
 * - delete   删除（进回收站 / 彻底删 / 清空回收站）
 * - upload   往这个路径写新文件（上传分片 / 合并 / 秒传校验）
 */
export type PathAction = 'view' | 'download' | 'update' | 'delete' | 'upload';

export const PATH_ACTIONS: PathAction[] = [
  'view',
  'download',
  'update',
  'delete',
  'upload',
];

export interface PathRule {
  /** 相对 files 根的路径；`/` 表示全部 */
  path: string;
  /** 允许的动作；空/未传时按旧的 access 折算 */
  actions?: PathAction[];
  /** @deprecated 旧数据的 ro/rw；读取时折算成 actions，写入一律落 actions */
  access?: 'ro' | 'rw';
}

/** 旧数据的 ro/rw → 动作集合（ro 只读浏览+下载，rw 全放行） */
const LEGACY_ACTIONS: Record<'ro' | 'rw', PathAction[]> = {
  ro: ['view', 'download'],
  rw: PATH_ACTIONS,
};

/** 一条规则实际生效的动作（顺序固定，方便 UI 展示与比较） */
export function actionsOfRule(rule: PathRule): PathAction[] {
  const raw = Array.isArray(rule.actions) ? rule.actions : null;
  if (raw && raw.length > 0) {
    const set = new Set(raw.map((a) => String(a).trim()));
    const picked = PATH_ACTIONS.filter((a) => set.has(a));
    if (picked.length > 0) return picked;
  }
  return LEGACY_ACTIONS[rule.access === 'rw' ? 'rw' : 'ro'];
}

export interface AccessPolicy {
  /** 允许的 appKey；未配置 = 不限制 */
  apps?: string[] | null;
  /** 路径规则；空 = 看 effectivePathRules（普通账号全拒 / 全权账号不限制） */
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
  return { path: normalizePath(rule.path), actions: actionsOfRule(rule) };
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

/**
 * 一个请求主体实际生效的路径规则：`null` = 不限制，`[]` = 一个目录都不给。
 *
 * 只有两种结果：
 * - 有规则 → 按规则（取最深的一条前缀匹配）；
 * - 没规则 → **普通账号一个目录都不给**，全权账号（`*`）不限制。
 *
 * 「没规则」这条是本轮的核心（用户 2026-11-11：「用户如果没有添加目录，是完全
 * 不能访问任何目录的，必须要添加目录才能用」）。以前空策略 = 全放行，新建子账号
 * 天然拿到整盘权限。
 *
 * 全权账号不限制是**开箱即用**的兜底：管理员从没配过、或者把规则全删了，
 * 都当他「不管了」，否则新装的机器上管理员自己都打不开「文件」，系统没法用。
 */
export function effectivePathRules(
  policy: AccessPolicy,
  fullAccess: boolean,
): PathRule[] | null {
  const rules = policy.paths ?? [];
  if (rules.length > 0) return rules;
  return fullAccess ? null : [];
}

/**
 * 请求主体是否全权（`scopes` 里有 `*`）。
 *
 * 访问令牌的 scopes 是令牌自己的，全权与否要看**签发它的账号**，
 * 所以 `resolveApiToken` 会额外带一个 `ownerAdmin`（见 api-token.ts）。
 */
export function isFullAccess(user: unknown): boolean {
  const u = user as { scopes?: unknown; ownerAdmin?: unknown } | null | undefined;
  if (!u) return false;
  if (Array.isArray(u.scopes) && u.scopes.includes('*')) return true;
  return u.ownerAdmin === true;
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

/**
 * 路径 ACL 判定。`need` 兼容旧的 read / write（分别折算成 view / update），
 * 新代码直接传具体动作 —— 只给「上传」权限的账号不该能删文件。
 *
 * `rules` 三态：`null` = 不限制；`[]` = **一个目录都不授权**（默认拒绝）；
 * 非空 = 按前缀匹配，取最深的一条。调用方要先经 [effectivePathRules] 折算，
 * 别直接把 `policy.paths` 传进来（没配置过的账号会变成全拒）。
 */
export function checkPathAccess(
  rules: PathRule[] | null | undefined,
  need: PathAction | 'read' | 'write',
  requestPath: string,
): PathAccessDecision {
  if (!rules) return { ok: true, rule: null };
  if (rules.length === 0) return { ok: false, rule: null };
  const action: PathAction = need === 'read' ? 'view' : need === 'write' ? 'update' : need;

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
  if (!actionsOfRule(deepest).includes(action)) return { ok: false, rule: deepest.path };
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

/**
 * 收集一个请求里**所有**需要过 ACL 的路径。
 *
 * 批量接口（delete / move）的 `paths[]` 以前只查了第一条 —— 只要有任意一条
 * 落在禁区内就该整单拒绝，所以这里全收上来逐条判定。
 * `target` 单独返回：移动 / 复制的目标目录要的是 upload 动作，和源路径不同。
 */
export function requestPathsOf(req: { query?: unknown; body?: unknown }): {
  paths: string[];
  target: string | null;
} {
  const out: string[] = [];
  const q = (req.query || {}) as { path?: unknown };
  if (typeof q.path === 'string' && q.path.trim()) out.push(q.path);
  const b = (req.body || {}) as { path?: unknown; paths?: unknown; to?: unknown; target?: unknown };
  if (typeof b.path === 'string' && b.path.trim()) out.push(b.path);
  if (Array.isArray(b.paths)) {
    for (const p of b.paths) if (typeof p === 'string' && p.trim()) out.push(p);
  }
  const rawTarget =
    typeof b.to === 'string' && b.to.trim()
      ? b.to
      : typeof b.target === 'string' && b.target.trim()
        ? b.target
        : null;
  return { paths: [...new Set(out)], target: rawTarget };
}
