import crypto from 'node:crypto';
import { sql } from 'kysely';

/**
 * 长期访问令牌（Scoped Token）：给外部脚本 / 播放器 / MCP 客户端用，
 * 与登录 JWT 分离——JWT 无法单独撤销，这里可以。
 *
 * 约束：
 * - 明文只在创建响应里出现一次，库里只存 SHA-256；
 * - 令牌前缀 `cnt_`，便于日志脱敏与误用排查；
 * - 每次使用时按 hash 点查，顺带刷新 `last_used_at`（SQLite 点查，成本可忽略）；
 * - 过期 / 已撤销 / 用户被禁用 → 视为无效。
 */
export const API_TOKEN_PREFIX = 'cnt_';

export function hashApiToken(raw: string): string {
  return crypto.createHash('sha256').update(raw).digest('hex');
}

export function newApiToken(): string {
  return API_TOKEN_PREFIX + crypto.randomBytes(24).toString('base64url');
}

export interface ApiTokenPayload {
  sub: string;
  scopes: string[];
  /** 与 JWT payload 对齐；访问令牌用签发时间 / 过期时间 */
  iat: number;
  exp: number;
  /**
   * 签发它的账号是否全权（`scopes` 含 `*`）。
   *
   * 路径 ACL 的默认拒绝规则要看这个：管理员用自己的令牌跑脚本时不该因为
   * 「配置文件里没有目录规则」被 403（见 `access-policy.effectivePathRules`）。
   * 令牌自己的 scopes 通常是子集，看不出账号本身是不是全权。
   */
  ownerAdmin?: boolean;
}

interface TokenRow {
  id: string;
  uid: string;
  scopes_json: string;
  expires_at: number | null;
  revoked_at: number | null;
  created_at: number;
}

/** 解析访问令牌；无效返回 null。有效时刷新 last_used_at。 */
export async function resolveApiToken(db: any, raw: string): Promise<ApiTokenPayload | null> {
  if (!raw.startsWith(API_TOKEN_PREFIX)) return null;
  const now = Math.floor(Date.now() / 1000);
  const row = (
    await sql<TokenRow>`
      select id, uid, scopes_json, expires_at, revoked_at, created_at
        from auth_api_tokens where token_hash = ${hashApiToken(raw)} limit 1
    `.execute(db)
  ).rows[0];
  if (!row) return null;
  if (row.revoked_at !== null) return null;
  if (row.expires_at !== null && Number(row.expires_at) <= now) return null;

  const user = (
    await sql<{ disabled: number; scopes: string | null }>`
      select disabled, scopes from auth_users where id = ${row.uid}
    `.execute(db)
  ).rows[0];
  if (!user || Number(user.disabled) === 1) return null;

  await sql`
    update auth_api_tokens set last_used_at = ${now} where id = ${row.id}
  `.execute(db).catch(() => undefined);

  const scopes = JSON.parse(row.scopes_json || '[]') as string[];
  return {
    sub: row.uid,
    scopes: Array.isArray(scopes) ? scopes : [],
    iat: Number(row.created_at),
    exp: row.expires_at === null ? 0 : Number(row.expires_at),
    // 账号是不是 `*`：用户表里 scopes 是 JSON 文本，`"*"` 一定带引号
    ownerAdmin: String(user.scopes ?? '').includes('"*"'),
  };
}