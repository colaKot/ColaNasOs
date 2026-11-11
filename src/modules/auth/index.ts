import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { isSealed, openSecret, sealSecret } from '../../../kernel/secret-box';
import { readPolicy, writePolicy, type AccessPolicy } from '../../../kernel/access-policy';
import type { ServerModule } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import { hashApiToken, newApiToken } from './api-token';

/**
 * SP3-01 auth / user / security。
 *
 *   POST /api/v1/auth/login                账号密码（+ 可选 TOTP）换取 JWT（公开路由）
 *   POST /api/v1/accounts/users/create     子账号
 *   GET  /api/v1/accounts/users            列表
 *   POST /api/v1/accounts/users/disable    启用/禁用
 *   POST /api/v1/accounts/users/2fa/setup  生成 TOTP secret + otpauth URI
 *   POST /api/v1/accounts/users/2fa/enable 校验一次码后启用
 *   POST /api/v1/accounts/users/2fa/disable
 *   POST /api/v1/security/ip/add            加入黑名单（精确 IP 或 CIDR）
 *   GET  /api/v1/security/ip/list
 *   POST /api/v1/security/ip/remove
 *
 * 注意：TOTP secret 以 AES-256-GCM 密文落库（`kernel/secret-box.ts`，salt `colanas-totp-v1`）；
 * 历史明文数据仍可读取，下一次 `2fa/enable` 会回写成密文。
 */
const TAG = ['accounts'];

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const LoginBody = Type.Object({
  username: Type.String({ minLength: 1, maxLength: 64 }),
  password: Type.String({ minLength: 1, maxLength: 256 }),
  totp: Type.Optional(Type.String({ minLength: 6, maxLength: 6 })),
});

const LoginResponse = Type.Object({
  token: Type.String(),
  scopes: Type.Array(Type.String()),
  user: Type.Object({ id: Type.String(), username: Type.String() }),
});

/**
 * 账号名 / 密码一律不做格式限制（内网自用）。
 *
 * 之前用户名字符集是 ASCII 正则，建「小明」直接被 400 挡掉；密码还加了
 * 「不能连续数字」之类的强度校验 —— 内网自用没必要，只留「不能为空」
 * 和一条长度上限（防止把整段文本当用户名写进库）。
 */
const CreateBody = Type.Object({
  username: Type.String({ minLength: 1, maxLength: 64 }),
  password: Type.String({ minLength: 1, maxLength: 256 }),
  scopes: Type.Optional(Type.Array(Type.String({ maxLength: 32 }))),
  phone: Type.Optional(Type.String({ maxLength: 32 })),
  remark: Type.Optional(Type.String({ maxLength: 200 })),
});

const UpdateBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  username: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
  password: Type.Optional(Type.String({ minLength: 1, maxLength: 256 })),
  phone: Type.Optional(Type.String({ maxLength: 32 })),
  remark: Type.Optional(Type.String({ maxLength: 200 })),
  // 建号时可以先不配权限，之后再回来改 —— 之前 UpdateBody 没有这一项，
  // 建出来的空权限账号就只能删了重建。
  scopes: Type.Optional(Type.Array(Type.String({ maxLength: 32 }))),
});

const EventItem = Type.Object({
  id: Type.String(),
  type: Type.String(),
  uid: Type.String(),
  username: Type.String(),
  ip: Type.String(),
  userAgent: Type.String(),
  detail: Type.String(),
  createdAt: Type.Integer(),
});
const EventListResponse = Type.Object({
  items: Type.Array(EventItem),
  total: Type.Integer(),
});
const EventQuery = Type.Object({
  uid: Type.Optional(Type.String({ maxLength: 64 })),
  limit: Type.Optional(Type.String({ maxLength: 8 })),
});

const ApiTokenItem = Type.Object({
  id: Type.String(),
  name: Type.String(),
  scopes: Type.Array(Type.String()),
  createdAt: Type.Integer(),
  expiresAt: Type.Union([Type.Integer(), Type.Null()]),
  lastUsedAt: Type.Union([Type.Integer(), Type.Null()]),
  revoked: Type.Boolean(),
});
const ApiTokenListResponse = Type.Object({ items: Type.Array(ApiTokenItem) });
const ApiTokenCreateBody = Type.Object({
  uid: Type.Optional(Type.String({ maxLength: 64 })),
  name: Type.String({ minLength: 1, maxLength: 64 }),
  scopes: Type.Array(Type.String({ maxLength: 64 }), { minItems: 1, maxItems: 64 }),
  expiresInDays: Type.Optional(Type.Integer({ minimum: 0, maximum: 3650 })),
});
const ApiTokenRevokeBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  uid: Type.Optional(Type.String({ maxLength: 64 })),
});
const ApiTokenQuery = Type.Object({
  uid: Type.Optional(Type.String({ maxLength: 64 })),
});
const ApiTokenCreateResponse = Type.Object({
  token: Type.String(),
  item: ApiTokenItem,
});

interface EventRow {
  id: string;
  type: string;
  uid: string;
  username: string;
  ip: string;
  user_agent: string;
  detail: string;
  created_at: number;
}
const toEvent = (r: EventRow) => ({
  id: r.id,
  type: r.type,
  uid: r.uid,
  username: r.username,
  ip: r.ip,
  userAgent: r.user_agent,
  detail: r.detail,
  createdAt: Number(r.created_at),
});

/** 首次安装引导（蓝图 §50）：库里一个用户都没有时，允许匿名创建第一个管理员 */
const BootstrapBody = Type.Object({
  username: Type.String({ pattern: '^[a-zA-Z0-9_.-]{3,64}$' }),
  password: Type.String({ minLength: 8, maxLength: 256 }),
});

const BootstrapStatus = Type.Object({
  needsSetup: Type.Boolean(),
  users: Type.Integer(),
});

const UserItem = Type.Object({
  id: Type.String(),
  username: Type.String(),
  scopes: Type.Array(Type.String()),
  totpEnabled: Type.Boolean(),
  disabled: Type.Boolean(),
  phone: Type.String(),
  remark: Type.String(),
  lastLoginAt: Type.Union([Type.Integer(), Type.Null()]),
  createdAt: Type.Integer(),
});

const UserListResponse = Type.Object({ items: Type.Array(UserItem) });

const DisableBody = Type.Object({ id: Type.String({ minLength: 1 }), disabled: Type.Boolean() });
const IdBody = Type.Object({ id: Type.String({ minLength: 1 }) });
const TotpEnableBody = Type.Object({ id: Type.String({ minLength: 1 }), code: Type.String({ minLength: 6, maxLength: 6 }) });

const TotpSetupResponse = Type.Object({ secret: Type.String(), uri: Type.String() });

const IpRuleBody = Type.Object({ rule: Type.String({ minLength: 3, maxLength: 64 }) });
const IpRuleItem = Type.Object({ rule: Type.String(), createdAt: Type.Integer() });
const IpRuleListResponse = Type.Object({ items: Type.Array(IpRuleItem) });

const OkResponse = Type.Object({ ok: Type.Boolean() });

const PolicyQuery = Type.Object({ uid: Type.String({ minLength: 1 }) });

const PathActionSchema = Type.Union([
  Type.Literal('view'),
  Type.Literal('download'),
  Type.Literal('update'),
  Type.Literal('delete'),
  Type.Literal('upload'),
]);

const PathRuleSchema = Type.Object({
  path: Type.String({ minLength: 1, maxLength: 1024 }),
  /** 允许的动作（view 浏览 / download 下载 / update 改名移动 / delete 删除 / upload 上传） */
  actions: Type.Optional(Type.Array(PathActionSchema, { maxItems: 5 })),
  /** @deprecated 旧的 ro/rw 写法；不传 actions 时按它折算，写入一律落 actions */
  access: Type.Optional(Type.Union([Type.Literal('ro'), Type.Literal('rw')])),
});

const PolicyBody = Type.Object({
  uid: Type.String({ minLength: 1 }),
  /** 未传 = 保持不变；传 null / 空数组 = 不限制 */
  allowedApps: Type.Optional(
    Type.Union([Type.Array(Type.String({ maxLength: 32 })), Type.Null()]),
  ),
  /** 未传 = 保持不变；传空数组 = 不限制 */
  paths: Type.Optional(Type.Array(PathRuleSchema, { maxItems: 200 })),
});

const PolicyResponse = Type.Object({
  uid: Type.String(),
  allowedApps: Type.Union([Type.Array(Type.String()), Type.Null()]),
  paths: Type.Array(PathRuleSchema),
});

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function b32encode(buf: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function b32decode(s: string): Buffer {
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, '');
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = B32.indexOf(ch);
    if (idx < 0) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** TOTP（RFC 6238，SHA-1 / 6 位 / 30 秒） */
export function totpAt(secret: Buffer, atSec: number): string {
  const counter = Math.floor(atSec / 30);
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const h = crypto.createHmac('sha1', secret).update(buf).digest();
  const off = h[h.length - 1] & 0x0f;
  const bin = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
  return String(bin % 1_000_000).padStart(6, '0');
}

export function verifyTotp(secretB32: string, code: string, atSec = Date.now() / 1000, window = 1): boolean {
  const secret = b32decode(secretB32);
  if (secret.length === 0) return false;
  for (let w = -window; w <= window; w++) {
    if (totpAt(secret, atSec + w * 30) === code) return true;
  }
  return false;
}

function ipToInt(ip: string): number | null {
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  let out = 0;
  for (const p of parts) {
    const n = Number(p);
    if (!Number.isInteger(n) || n < 0 || n > 255) return null;
    out = (out << 8) | n;
  }
  return out >>> 0;
}

/** 支持精确 IP 与 IPv4 CIDR */
export function isBlocked(ip: string, rules: string[]): boolean {
  const target = ipToInt(ip);
  if (target === null) return false;
  for (const rule of rules) {
    if (rule.includes('/')) {
      const [base, bitsRaw] = rule.split('/');
      const baseInt = ipToInt(base);
      const bits = Number(bitsRaw);
      if (baseInt === null || !Number.isInteger(bits) || bits < 0 || bits > 32) continue;
      const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
      if ((target & mask) === (baseInt & mask)) return true;
    } else if (ipToInt(rule) === target) {
      return true;
    }
  }
  return false;
}

function hashPassword(password: string, salt: string): string {
  return crypto.scryptSync(password, salt, 32).toString('hex');
}

interface UserRow {
  id: string;
  username: string;
  salt: string;
  hash: string;
  scopes: string;
  totp_secret: string | null;
  totp_enabled: number;
  disabled: number;
  phone: string;
  remark: string;
  last_login_at: number | null;
  created_at: number;
}

/**
 * TOTP secret 落库即加密（AES-256-GCM，salt `colanas-totp-v1`）：
 * secret 等价于第二因素的全部凭据，落盘明文等于把 2FA 降级成单因素。
 * 历史数据是 base32 明文，`openTotp` 仍按原样读取，`2fa/enable` 会顺手回写成密文。
 */
const TOTP_SALT = 'colanas-totp-v1';

function sealTotp(secret: string): string {
  return sealSecret(secret, TOTP_SALT);
}

function openTotp(stored: string | null): string | null {
  if (!stored) return null;
  return isSealed(stored) ? openSecret(stored, TOTP_SALT) : stored;
}

export const accounts: ServerModule = {
  id: 'accounts',
  prefix: '/api/v1',
  permissions: ['user:read', 'user:write'],

  migrations: [
    {
      id: '006_users',
      async up(db) {
        await sql`
          create table if not exists auth_users (
            id text primary key,
            username text not null unique,
            salt text not null,
            hash text not null,
            scopes text not null default '[]',
            totp_secret text,
            totp_enabled integer not null default 0,
            disabled integer not null default 0,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists ip_rules (
            rule text primary key,
            created_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '098_auth_user_profile',
      async up(db) {
        // 手机 / 备注 / 最近登录：账号详情与列表展示用（U-A/U-C）
        await sql`alter table auth_users add column phone text not null default ''`.execute(db);
        await sql`alter table auth_users add column remark text not null default ''`.execute(db);
        await sql`alter table auth_users add column last_login_at integer`.execute(db);
      },
    },
    {
      id: '099_auth_events',
      async up(db) {
        // 登录记录 + 用户管理审计（U-F）；文件操作日志仍由各文件域自己记录
        await sql`
          create table if not exists auth_events (
            id text primary key,
            type text not null,
            uid text not null default '',
            username text not null default '',
            ip text not null default '',
            user_agent text not null default '',
            detail text not null default '',
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_auth_events_uid
          on auth_events (uid, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '100_auth_api_tokens',
      async up(db) {
        // 长期访问令牌（U-H）：明文只在创建时返回一次，库里只存 SHA-256
        await sql`
          create table if not exists auth_api_tokens (
            id text primary key,
            uid text not null default '',
            name text not null default '',
            token_hash text not null unique,
            scopes_json text not null default '[]',
            expires_at integer,
            last_used_at integer,
            revoked_at integer,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_auth_api_tokens_uid
          on auth_api_tokens (uid, created_at desc)
        `.execute(db);
      },
    },
    {
      // 权限域合并（用户 2026-11-11）：
      //   player      → video   转码播放本来就是影视的一部分，给了影视就该能播
      //   security    → user    IP 黑名单属于「用户与权限」
      //   integration → system  Webhook 属于「系统与监控」
      //
      // 必须挂在模块迁移里、且排在 MIGRATION_ORDER 末尾：BASE_MIGRATIONS 在
      // registry.mount 之前就跑完，那时 auth_users / auth_api_tokens 还不存在。
      // 合并后 secured() 已不再有这三个域，存量账号 / 访问令牌里仍留着旧值；
      // 不迁移的话，只持有 `security:write` 的老账号升级后改 IP 规则直接 403。
      id: '175_scope_domain_merge',
      async up(db) {
        const merge = (list: string[]): string[] => {
          const map: Record<string, string> = {
            player: 'video',
            security: 'user',
            integration: 'system',
          };
          const out: string[] = [];
          for (const raw of list) {
            const s = String(raw || '').trim();
            if (!s) continue;
            const idx = s.indexOf(':');
            const domain = idx > 0 ? s.slice(0, idx) : s;
            const next = map[domain] ? map[domain] + s.slice(domain.length) : s;
            if (!out.includes(next)) out.push(next);
          }
          return out;
        };

        const rewrite = (raw: unknown): string | null => {
          if (typeof raw !== 'string' || !raw.trim()) return null;
          let list: unknown;
          try {
            list = JSON.parse(raw);
          } catch {
            return null;
          }
          if (!Array.isArray(list)) return null;
          const before = list.map((v) => String(v));
          const after = merge(before);
          if (after.length === before.length && after.every((v, i) => v === before[i])) {
            return null;
          }
          return JSON.stringify(after);
        };

        // 值改写是可跳过的：模块被裁掉 / 极老的库没建表时，宁可不动也别拦住启动。
        const tableExists = async (name: string): Promise<boolean> => {
          const rows = (
            await sql<{ n: number }>`
              select count(*) as n from sqlite_master where type = 'table' and name = ${name}
            `.execute(db)
          ).rows;
          return Number(rows[0]?.n ?? 0) > 0;
        };

        if (await tableExists('auth_users')) {
          const users = await sql<{ id: string; scopes: string | null }>`
            select id, scopes from auth_users
          `.execute(db);
          for (const row of users.rows) {
            const next = rewrite(row.scopes);
            if (next === null) continue;
            await sql`update auth_users set scopes = ${next} where id = ${row.id}`.execute(db);
          }
        }

        if (await tableExists('auth_api_tokens')) {
          const tokens = await sql<{ id: string; scopes_json: string | null }>`
            select id, scopes_json from auth_api_tokens
          `.execute(db);
          for (const row of tokens.rows) {
            const next = rewrite(row.scopes_json);
            if (next === null) continue;
            await sql`update auth_api_tokens set scopes_json = ${next} where id = ${row.id}`.execute(
              db,
            );
          }
        }
      },
    },
  ],

  async register(app, k) {
    const now = () => Math.floor(Date.now() / 1000);

    /** 审计 / 登录记录：失败不阻断业务 */
    const writeEvent = async (
      type: string,
      uid: string,
      username: string,
      req: { ip?: string; headers?: Record<string, unknown> },
      detail = '',
    ): Promise<void> => {
      try {
        await sql`
          insert into auth_events (id, type, uid, username, ip, user_agent, detail, created_at)
          values (${crypto.randomBytes(8).toString('base64url')}, ${type}, ${uid}, ${username},
                  ${String(req.ip || '')}, ${String(req.headers?.['user-agent'] || '')},
                  ${detail.slice(0, 500)}, ${now()})
        `.execute(k.db);
      } catch {
        /* 审计失败不影响登录 / 管理操作 */
      }
    };

    const loadRules = async (): Promise<Set<string>> => {
      const res = await sql<{ rule: string }>`select rule from ip_rules`.execute(k.db);
      return new Set(res.rows.map((r) => r.rule));
    };

    let blockList = await loadRules();

    // IP 黑名单在认证之前生效
    app.addHook('onRequest', async (req, reply) => {
      if (blockList.size === 0) return;
      if (isBlocked(req.ip, [...blockList])) {
        return reply.code(403).send({ error: Err.forbidden, message: 'ip blocked' });
      }
    });

    const toItem = (r: UserRow) => ({
      id: r.id,
      username: r.username,
      scopes: JSON.parse(r.scopes || '[]') as string[],
      totpEnabled: r.totp_enabled === 1,
      disabled: r.disabled === 1,
      phone: r.phone ?? '',
      remark: r.remark ?? '',
      lastLoginAt: r.last_login_at === null ? null : Number(r.last_login_at),
      createdAt: r.created_at,
    });

    app.post(
      '/api/v1/auth/login',
      {
        schema: {
          operationId: 'authLogin',
          tags: TAG,
          summary: '账号密码登录（可选 TOTP）',
          body: LoginBody,
          response: { 200: LoginResponse, 401: ErrorResponse },
        },
      },
      async (req, reply) => {
        const body = (req.body || {}) as { username?: string; password?: string; totp?: string };
        if (!body.username || !body.password) {
          return reply.code(401).send({ error: Err.unauthorized, message: 'username/password required' });
        }
        const res = await sql<UserRow>`select * from auth_users where username = ${body.username}`.execute(k.db);
        const user = res.rows[0];
        if (!user || user.disabled === 1 || hashPassword(body.password, user.salt) !== user.hash) {
          await writeEvent(
            'login_failed',
            '',
            body.username,
            req,
            user ? (user.disabled === 1 ? 'disabled' : 'bad credentials') : 'unknown user',
          );
          return reply.code(401).send({ error: Err.unauthorized, message: 'bad credentials' });
        }
        if (user.totp_enabled === 1) {
          if (!body.totp) {
            await writeEvent('login_failed', user.id, user.username, req, 'totp required');
            return reply.code(401).send({ error: 'totp_required', message: 'totp code required' });
          }
          const totpSecret = openTotp(user.totp_secret);
          if (!totpSecret || !verifyTotp(totpSecret, body.totp)) {
            await writeEvent('login_failed', user.id, user.username, req, 'totp invalid');
            return reply.code(401).send({ error: 'totp_invalid', message: 'bad totp code' });
          }
        }
        const scopes = JSON.parse(user.scopes || '[]') as string[];
        // 两个「所有登录用户的基础能力」，单独注入而不改响应里的 `scopes`（前端展示不变）：
        // - `events:read`：事件流只含「哪个域有扫描完成」的摘要，具体资源仍按 scope / owner 过滤；
        // - `tasks:read`：扫描 / 索引 / 刮削都改成入队了，界面必须能轮询 `/tasks/{id}` 拿进度，
        //   否则「点扫描 → 没有任何反馈」。注：`tasks.uid` 尚未落库，现在无法按用户隔离任务，
        //   单机个人云盘口径下可接受；多用户部署前应补 uid 列并按创建者过滤。
        const baseScopes = ['events:read', 'tasks:read'];
        const tokenScopes = scopes.includes('*')
          ? scopes
          : [...new Set([...scopes, ...baseScopes])];
        const token = k.auth.sign({ sub: user.id, scopes: tokenScopes }, 30 * 24 * 3600);
        await sql`
          update auth_users set last_login_at = ${now()} where id = ${user.id}
        `.execute(k.db);
        await writeEvent('login', user.id, user.username, req);
        return { token, scopes, user: { id: user.id, username: user.username } };
      },
    );

    // 首次安装引导（蓝图 §50）：库里没有任何账号时，允许匿名创建第一个管理员；
    // 一旦有账号就 409 —— 这样「dev-token 默认关闭」也不会让新装环境无法使用。
    const countUsers = async (): Promise<number> => {
      const r = await sql<{ n: number }>`select count(*) as n from auth_users`.execute(k.db);
      return Number(r.rows[0]?.n ?? 0);
    };

    app.get(
      '/api/v1/auth/bootstrap',
      {
        schema: {
          operationId: 'authBootstrapStatus',
          tags: TAG,
          summary: '首次安装状态（库里是否还没有任何账号）',
          response: { 200: BootstrapStatus },
        },
      },
      async () => {
        const users = await countUsers();
        return { needsSetup: users === 0, users };
      },
    );

    app.post(
      '/api/v1/auth/bootstrap',
      {
        schema: {
          operationId: 'authBootstrap',
          tags: TAG,
          summary: '首次安装：创建第一个管理员（仅在无任何账号时可用）',
          body: BootstrapBody,
          response: { 200: UserItem, 400: ErrorResponse, 409: ErrorResponse },
        },
      },
      async (req, reply) => {
        const body = (req.body || {}) as { username?: string; password?: string };
        if (!body.username || !body.password) {
          return reply.code(400).send({ error: Err.badRequest, message: 'username/password required' });
        }
        const salt = crypto.randomBytes(16).toString('hex');
        const id = crypto.randomBytes(8).toString('base64url');
        // 原子插入：`insert ... select ... where not exists` —— 两个人同时点「初始化」也只会成功一个
        const res = await sql`
          insert into auth_users (id, username, salt, hash, scopes, totp_secret, totp_enabled, disabled, created_at)
          select ${id}, ${body.username}, ${salt}, ${hashPassword(body.password, salt)}, ${'["*"]'}, ${null}, 0, 0, ${now()}
          where not exists (select 1 from auth_users)
        `.execute(k.db);
        if (Number(res.numAffectedRows ?? 0) === 0) {
          return reply.code(409).send({ error: Err.conflict, message: 'already initialized' });
        }
        return {
          id,
          username: body.username,
          scopes: ['*'],
          totpEnabled: false,
          disabled: false,
          phone: '',
          remark: '',
          lastLoginAt: null,
          createdAt: now(),
        };
      },
    );

    app.post(
      '/api/v1/accounts/users/create',
      secured('user:write', {
        schema: {
          operationId: 'userCreate',
          tags: TAG,
          summary: '创建子账号',
          body: CreateBody,
          response: { 200: UserItem, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          username?: string;
          password?: string;
          scopes?: string[];
          phone?: string;
          remark?: string;
        };
        if (!body.username || !body.password) {
          return reply.code(400).send({ error: Err.badRequest, message: '用户名和密码都要填' });
        }
        const username = String(body.username).trim();
        const exists = await sql`select 1 from auth_users where username = ${username}`.execute(k.db);
        if (exists.rows.length > 0) {
          return reply.code(400).send({ error: Err.conflict, message: '这个用户名已经有人用了' });
        }
        const salt = crypto.randomBytes(16).toString('hex');
        const id = crypto.randomBytes(8).toString('base64url');
        const scopes = body.scopes ?? [];
        const phone = String(body.phone ?? '').trim().slice(0, 32);
        const remark = String(body.remark ?? '').trim().slice(0, 200);
        await sql`
          insert into auth_users
            (id, username, salt, hash, scopes, totp_secret, totp_enabled, disabled, phone, remark, last_login_at, created_at)
          values (${id}, ${username}, ${salt}, ${hashPassword(body.password, salt)},
                  ${JSON.stringify(scopes)}, ${null}, 0, 0, ${phone}, ${remark}, null, ${now()})
        `.execute(k.db);
        await writeEvent('user_create', id, username, req, JSON.stringify({ scopes }));
        return {
          id,
          username,
          scopes,
          totpEnabled: false,
          disabled: false,
          phone,
          remark,
          lastLoginAt: null,
          createdAt: now(),
        };
      },
    );

    app.get(
      '/api/v1/accounts/users',
      secured('user:read', {
        schema: {
          operationId: 'userList',
          tags: TAG,
          summary: '账号列表',
          response: { 200: UserListResponse },
        },
      }),
      async () => {
        const res = await sql<UserRow>`select * from auth_users order by created_at`.execute(k.db);
        return { items: res.rows.map(toItem) };
      },
    );

    // ------------------------------------------------ 子账号双层授权策略
    const findUser = async (uid: string) => {
      const r = await sql<{ id: string }>`select id from auth_users where id = ${uid}`.execute(k.db);
      return r.rows[0] ?? null;
    };

    const loadUser = async (uid: string): Promise<UserRow | null> => {
      const r = await sql<UserRow>`select * from auth_users where id = ${uid}`.execute(k.db);
      return r.rows[0] ?? null;
    };

    app.get(
      '/api/v1/accounts/users/policy',
      secured('user:read', {
        schema: {
          operationId: 'userPolicyGet',
          tags: TAG,
          summary: '读取子账号的应用白名单与路径 ACL',
          querystring: PolicyQuery,
          response: { 200: PolicyResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { uid?: string };
        const uid = String(q.uid || '');
        if (!(await findUser(uid))) {
          return reply.code(404).send({ error: Err.notFound, message: 'user not found' });
        }
        const policy = readPolicy(k.config, uid);
        return { uid, allowedApps: policy.apps ?? null, paths: policy.paths ?? [] };
      },
    );

    app.post(
      '/api/v1/accounts/users/policy',
      secured('user:write', {
        schema: {
          operationId: 'userPolicySet',
          tags: TAG,
          summary: '设置子账号的应用白名单与路径 ACL（未传字段保持不变）',
          body: PolicyBody,
          response: { 200: PolicyResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          uid?: string;
          allowedApps?: string[] | null;
          paths?: Array<{ path: string; access: 'ro' | 'rw' }>;
        };
        const uid = String(body.uid || '');
        if (!(await findUser(uid))) {
          return reply.code(404).send({ error: Err.notFound, message: 'user not found' });
        }

        const current = readPolicy(k.config, uid);
        const next: AccessPolicy = {
          apps: body.allowedApps === undefined ? (current.apps ?? null) : body.allowedApps,
          paths: body.paths === undefined ? (current.paths ?? []) : body.paths,
        };

        let saved: AccessPolicy;
        try {
          saved = await writePolicy(k.config, uid, next);
        } catch (err) {
          // 路径含 `..` 等越界写法：直接 400，不静默降级
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: String((err as Error)?.message || err) });
        }
        await writeEvent('policy_update', uid, '', req);
        return { uid, allowedApps: saved.apps ?? null, paths: saved.paths ?? [] };
      },
    );

    app.post(
      '/api/v1/accounts/users/disable',
      secured('user:write', {
        schema: {
          operationId: 'userDisable',
          tags: TAG,
          summary: '启用 / 禁用账号',
          body: DisableBody,
          response: { 200: OkResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; disabled?: boolean };
        if (!body.id) return reply.code(404).send({ error: Err.notFound, message: 'id required' });
        await sql`update auth_users set disabled = ${body.disabled ? 1 : 0} where id = ${body.id}`.execute(k.db);
        return { ok: true };
      },
    );

    const toToken = (r: any) => ({
      id: String(r.id),
      name: String(r.name ?? ''),
      scopes: JSON.parse(r.scopes_json || '[]') as string[],
      createdAt: Number(r.created_at),
      expiresAt: r.expires_at === null ? null : Number(r.expires_at),
      lastUsedAt: r.last_used_at === null ? null : Number(r.last_used_at),
      revoked: r.revoked_at !== null,
    });

    app.get(
      '/api/v1/accounts/tokens',
      secured('user:read', {
        schema: {
          operationId: 'apiTokenList',
          tags: TAG,
          summary: '当前用户的长期访问令牌（不含明文）',
          querystring: ApiTokenQuery,
          response: { 200: ApiTokenListResponse },
        },
      }),
      async (req) => {
        const self = String(req.user?.sub || '');
        const admin = Array.isArray(req.user?.scopes) && req.user.scopes.includes('*');
        const q = (req.query || {}) as { uid?: string };
        const uid = admin && q.uid ? String(q.uid) : self;
        const rows = (
          await sql<any>`
            select * from auth_api_tokens where uid = ${uid}
             order by created_at desc limit 200
          `.execute(k.db)
        ).rows;
        return { items: rows.map(toToken) };
      },
    );

    app.post(
      '/api/v1/accounts/tokens',
      secured('user:write', {
        schema: {
          operationId: 'apiTokenCreate',
          tags: TAG,
          summary: '创建长期访问令牌（明文只返回一次）',
          body: ApiTokenCreateBody,
          response: { 200: ApiTokenCreateResponse, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const b = (req.body || {}) as {
          uid?: string;
          name?: string;
          scopes?: string[];
          expiresInDays?: number;
        };
        const self = String(req.user?.sub || '');
        const admin = Array.isArray(req.user?.scopes) && req.user.scopes.includes('*');
        const uid = admin && b.uid ? String(b.uid) : self;
        if (uid !== self && !(await findUser(uid))) {
          return reply.code(400).send({ error: Err.badRequest, message: 'user not found' });
        }
        const name = String(b.name || '').trim().slice(0, 64);
        if (!name) {
          return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
        }
        const scopes = [
          ...new Set(
            (b.scopes ?? []).map((s) => String(s).trim()).filter(Boolean),
          ),
        ].slice(0, 64);
        if (scopes.length === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'scopes required' });
        }
        const days = Math.max(0, Math.min(3650, Number(b.expiresInDays) || 0));
        const ts = now();
        const expiresAt = days > 0 ? ts + days * 86400 : null;
        const raw = newApiToken();
        const id = crypto.randomBytes(8).toString('base64url');
        await sql`
          insert into auth_api_tokens
            (id, uid, name, token_hash, scopes_json, expires_at, last_used_at, revoked_at, created_at)
          values (${id}, ${uid}, ${name}, ${hashApiToken(raw)}, ${JSON.stringify(scopes)},
                  ${expiresAt}, null, null, ${ts})
        `.execute(k.db);
        await writeEvent('token_create', uid, '', req, name);
        return {
          token: raw,
          item: {
            id,
            name,
            scopes,
            createdAt: ts,
            expiresAt,
            lastUsedAt: null,
            revoked: false,
          },
        };
      },
    );

    app.post(
      '/api/v1/accounts/tokens/revoke',
      secured('user:write', {
        schema: {
          operationId: 'apiTokenRevoke',
          tags: TAG,
          summary: '撤销长期访问令牌',
          body: ApiTokenRevokeBody,
          response: { 200: OkResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const b = (req.body || {}) as { id?: string; uid?: string };
        const self = String(req.user?.sub || '');
        const admin = Array.isArray(req.user?.scopes) && req.user.scopes.includes('*');
        const uid = admin && b.uid ? String(b.uid) : self;
        const res = await sql`
          update auth_api_tokens set revoked_at = ${now()}
           where id = ${b.id || ''} and uid = ${uid} and revoked_at is null
        `.execute(k.db);
        if (Number(res.numAffectedRows ?? 0) === 0) {
          return reply.code(404).send({ error: Err.notFound, message: 'token not found' });
        }
        await writeEvent('token_revoke', uid, '', req, String(b.id || ''));
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/accounts/users/update',
      secured('user:write', {
        schema: {
          operationId: 'userUpdate',
          tags: TAG,
          summary: '编辑账号（用户名 / 密码 / 手机 / 备注）',
          body: UpdateBody,
          response: { 200: UserItem, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          id?: string;
          username?: string;
          password?: string;
          phone?: string;
          remark?: string;
          scopes?: string[];
        };
        const row = body.id ? await loadUser(body.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'user not found' });

        const changes: string[] = [];
        if (body.username && body.username !== row.username) {
          const nextName = String(body.username).trim();
          const dup = await sql`
            select 1 from auth_users where username = ${nextName} and id <> ${row.id}
          `.execute(k.db);
          if (dup.rows.length > 0) {
            return reply.code(400).send({ error: Err.conflict, message: '这个用户名已经有人用了' });
          }
          await sql`update auth_users set username = ${nextName} where id = ${row.id}`.execute(k.db);
          changes.push('username');
        }
        if (body.password) {
          const salt = crypto.randomBytes(16).toString('hex');
          await sql`
            update auth_users set salt = ${salt}, hash = ${hashPassword(body.password, salt)}
             where id = ${row.id}
          `.execute(k.db);
          changes.push('password');
        }
        if (body.phone !== undefined) {
          await sql`
            update auth_users set phone = ${String(body.phone).trim().slice(0, 32)} where id = ${row.id}
          `.execute(k.db);
          changes.push('phone');
        }
        if (body.remark !== undefined) {
          await sql`
            update auth_users set remark = ${String(body.remark).trim().slice(0, 200)} where id = ${row.id}
          `.execute(k.db);
          changes.push('remark');
        }
        if (body.scopes !== undefined) {
          // 去重 + 去空，顺序保持用户勾选的先后（前端按域顺序提交，读起来更顺）
          const scopes = [
            ...new Set(
              (Array.isArray(body.scopes) ? body.scopes : [])
                .map((s) => String(s).trim())
                .filter(Boolean),
            ),
          ].slice(0, 64);
          // 拦住「改成空权限」：空权限账号登录后什么页都打不开，等于把自己锁死，
          // 却不会报任何错。要收回权限就删号，不要留一个看不见东西的空壳。
          if (scopes.length === 0) {
            return reply
              .code(400)
              .send({ error: Err.badRequest, message: 'scopes must not be empty' });
          }
          const prev = JSON.parse(row.scopes || '[]') as string[];
          const same =
            prev.length === scopes.length && scopes.every((s) => prev.includes(s));
          if (!same) {
            await sql`
              update auth_users set scopes = ${JSON.stringify(scopes)} where id = ${row.id}
            `.execute(k.db);
            changes.push('scopes');
          }
        }
        if (changes.length > 0) {
          await writeEvent(
            'user_update',
            row.id,
            body.username || row.username,
            req,
            changes.join(','),
          );
        }
        return toItem((await loadUser(row.id))!);
      },
    );

    app.post(
      '/api/v1/accounts/users/delete',
      secured('user:write', {
        schema: {
          operationId: 'userDelete',
          tags: TAG,
          summary: '删除账号（禁止删除自己与最后一个管理员）',
          body: IdBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const target = body.id ? await loadUser(body.id) : null;
        if (!target) return reply.code(404).send({ error: Err.notFound, message: 'user not found' });

        const self = String(req.user?.sub || '');
        if (target.id === self) {
          return reply.code(400).send({ error: Err.badRequest, message: 'cannot delete yourself' });
        }
        const scopes = JSON.parse(target.scopes || '[]') as string[];
        if (scopes.includes('*')) {
          const admins = await sql<{ n: number }>`
            select count(*) as n from auth_users where scopes like '%"*"%'
          `.execute(k.db);
          if (Number(admins.rows[0]?.n ?? 0) <= 1) {
            return reply
              .code(400)
              .send({ error: Err.badRequest, message: 'last administrator cannot be deleted' });
          }
        }

        await sql`delete from auth_users where id = ${target.id}`.execute(k.db);
        // 权限策略一并清掉，避免同名新账号继承旧目录授权
        await k.config.set(`accessPolicy.${target.id}`, { apps: null, paths: [] });
        await writeEvent('user_delete', self, target.username, req);
        return { ok: true };
      },
    );

    app.get(
      '/api/v1/accounts/users/login-records',
      secured('user:read', {
        schema: {
          operationId: 'userLoginRecords',
          tags: TAG,
          summary: '登录记录（成功 / 失败，按用户与时间倒序）',
          querystring: EventQuery,
          response: { 200: EventListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { uid?: string; limit?: string };
        const limit = Math.max(1, Math.min(Number(q.limit) || 50, 200));
        const uid = String(q.uid || '');
        const rows = (
          await sql<EventRow>`
            select * from auth_events
             where type in ('login', 'login_failed')
               ${uid ? sql`and uid = ${uid}` : sql``}
             order by created_at desc limit ${limit}
          `.execute(k.db)
        ).rows;
        return { items: rows.map(toEvent), total: rows.length };
      },
    );

    app.get(
      '/api/v1/accounts/users/audit-logs',
      secured('user:read', {
        schema: {
          operationId: 'userAuditLogs',
          tags: TAG,
          summary: '账号操作审计（创建 / 编辑 / 删除 / 2FA / 权限）',
          querystring: EventQuery,
          response: { 200: EventListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { uid?: string; limit?: string };
        const limit = Math.max(1, Math.min(Number(q.limit) || 50, 200));
        const uid = String(q.uid || '');
        const rows = (
          await sql<EventRow>`
            select * from auth_events
             where type in ('user_create', 'user_update', 'user_delete',
                            '2fa_enable', '2fa_disable', 'policy_update')
               ${uid ? sql`and uid = ${uid}` : sql``}
             order by created_at desc limit ${limit}
          `.execute(k.db)
        ).rows;
        return { items: rows.map(toEvent), total: rows.length };
      },
    );

    app.post(
      '/api/v1/accounts/users/2fa/setup',
      secured('user:write', {
        schema: {
          operationId: 'userTotpSetup',
          tags: TAG,
          summary: '生成 TOTP secret（未启用）',
          body: IdBody,
          response: { 200: TotpSetupResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const res = await sql<UserRow>`select * from auth_users where id = ${body.id}`.execute(k.db);
        const user = res.rows[0];
        if (!user) return reply.code(404).send({ error: Err.notFound, message: 'user not found' });
        const secret = b32encode(crypto.randomBytes(20));
        await sql`update auth_users set totp_secret = ${sealTotp(secret)}, totp_enabled = 0 where id = ${user.id}`.execute(k.db);
        const uri = `otpauth://totp/ColaNasOs:${encodeURIComponent(user.username)}?secret=${secret}&issuer=ColaNasOs&digits=6&period=30`;
        return { secret, uri };
      },
    );

    app.post(
      '/api/v1/accounts/users/2fa/enable',
      secured('user:write', {
        schema: {
          operationId: 'userTotpEnable',
          tags: TAG,
          summary: '用一次验证码启用 2FA',
          body: TotpEnableBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; code?: string };
        const res = await sql<UserRow>`select * from auth_users where id = ${body.id}`.execute(k.db);
        const user = res.rows[0];
        if (!user) return reply.code(404).send({ error: Err.notFound, message: 'user not found' });
        if (!user.totp_secret) return reply.code(400).send({ error: Err.badRequest, message: 'call setup first' });
        const totpSecret = openTotp(user.totp_secret);
        if (!body.code || !totpSecret || !verifyTotp(totpSecret, body.code)) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid code' });
        }
        // 历史明文 secret 在此回写为密文（懒迁移），已加密的不重复加密
        const sealed = isSealed(user.totp_secret) ? user.totp_secret : sealTotp(totpSecret);
        await sql`update auth_users set totp_enabled = 1, totp_secret = ${sealed} where id = ${user.id}`.execute(k.db);
        await writeEvent('2fa_enable', user.id, user.username, req);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/accounts/users/2fa/disable',
      secured('user:write', {
        schema: {
          operationId: 'userTotpDisable',
          tags: TAG,
          summary: '关闭 2FA',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string };
        await sql`update auth_users set totp_enabled = 0, totp_secret = null where id = ${body.id}`.execute(k.db);
        await writeEvent('2fa_disable', String(body.id || ''), '', req);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/security/ip/add',
      secured('user:write', {
        schema: {
          operationId: 'securityIpAdd',
          tags: TAG,
          summary: '加入 IP 黑名单（IP 或 CIDR）',
          body: IpRuleBody,
          response: { 200: OkResponse, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { rule?: string };
        const rule = (body.rule || '').trim();
        const ok = rule.includes('/') ? /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/.test(rule) : /^(\d{1,3}\.){3}\d{1,3}$/.test(rule);
        if (!ok) return reply.code(400).send({ error: Err.badRequest, message: 'invalid ip or cidr' });
        await sql`insert into ip_rules (rule, created_at) values (${rule}, ${now()}) on conflict(rule) do nothing`.execute(k.db);
        blockList = await loadRules();
        return { ok: true };
      },
    );

    app.get(
      '/api/v1/security/ip/list',
      secured('user:read', {
        schema: {
          operationId: 'securityIpList',
          tags: TAG,
          summary: 'IP 黑名单',
          response: { 200: IpRuleListResponse },
        },
      }),
      async () => {
        const res = await sql<{ rule: string; created_at: number }>`
          select * from ip_rules order by created_at desc
        `.execute(k.db);
        return { items: res.rows.map((r) => ({ rule: r.rule, createdAt: r.created_at })) };
      },
    );

    app.post(
      '/api/v1/security/ip/remove',
      secured('user:write', {
        schema: {
          operationId: 'securityIpRemove',
          tags: TAG,
          summary: '移出 IP 黑名单',
          body: IpRuleBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { rule?: string };
        await sql`delete from ip_rules where rule = ${body.rule || ''}`.execute(k.db);
        blockList = await loadRules();
        return { ok: true };
      },
    );
  },
};