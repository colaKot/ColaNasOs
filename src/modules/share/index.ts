import crypto from 'node:crypto';
import fs from 'node:fs';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { ServerModule } from '../../../kernel/types';
import { downloadHandler } from '../files/download';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { Err } from '../../../kernel/errors';

/**
 * SP3-08 fileServer / quickShare：对外分享链接。
 *
 * 安全边界：
 *   - 创建 / 列表 / 撤销需要 `share:*` scope（内部用户）
 *   - `info` / `download` 是**公开**路由（无 scope），靠链接 id + 可选密码保护
 *   - 路径必须落在 files 根内（resolveInRoot），杜绝越界
 *   - 过期返回 410，撤销后 404
 */
const TAG = ['share'];
const MAX_TTL = 30 * 24 * 3600;
const DEFAULT_TTL = 7 * 24 * 3600;

const CreateBody = Type.Object({
  path: Type.String({ minLength: 1 }),
  expiresInSec: Type.Optional(Type.Integer({ minimum: 60, maximum: MAX_TTL })),
  password: Type.Optional(Type.String({ minLength: 4, maxLength: 64 })),
});

const CreateResponse = Type.Object({
  id: Type.String(),
  url: Type.String(),
  expiresAt: Type.Union([Type.Integer(), Type.Null()]),
});

const Item = Type.Object({
  id: Type.String(),
  path: Type.String(),
  createdAt: Type.Integer(),
  expiresAt: Type.Union([Type.Integer(), Type.Null()]),
  downloads: Type.Integer(),
  hasPassword: Type.Boolean(),
});

const ListResponse = Type.Object({ items: Type.Array(Item) });
const IdQuery = Type.Object({ id: Type.String({ minLength: 6 }) });
const IdBody = Type.Object({ id: Type.String({ minLength: 6 }) });

const InfoResponse = Type.Object({
  id: Type.String(),
  fileName: Type.String(),
  expiresAt: Type.Union([Type.Integer(), Type.Null()]),
  hasPassword: Type.Boolean(),
  downloads: Type.Integer(),
});

const OkResponse = Type.Object({ ok: Type.Boolean() });

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

interface ShareRow {
  id: string;
  path: string;
  salt: string;
  password_hash: string | null;
  created_at: number;
  expires_at: number | null;
  downloads: number;
}

function hashPassword(salt: string, password: string): string {
  return crypto.createHash('sha256').update(`${salt}:${password}`).digest('hex');
}

function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}

export const share: ServerModule = {
  id: 'share',
  prefix: '/api/v1/share',
  permissions: ['share:read', 'share:write'],

  migrations: [
    {
      id: '001_share_links',
      async up(db) {
        await sql`
          create table if not exists share_links (
            id text primary key,
            path text not null,
            salt text not null,
            password_hash text,
            created_at integer not null,
            expires_at integer,
            downloads integer not null default 0
          )
        `.execute(db);
        await sql`create index if not exists idx_share_expires on share_links(expires_at)`.execute(db);
      },
    },
  ],

  async register(app, k) {
    const load = async (id: string): Promise<ShareRow | null> => {
      const res = await sql<ShareRow>`select * from share_links where id = ${id}`.execute(k.db);
      return res.rows[0] ?? null;
    };

    app.post(
      '/api/v1/share/create',
      secured('share:write', {
        schema: {
          operationId: 'shareCreate',
          tags: TAG,
          summary: '创建分享链接（可选过期与密码）',
          body: CreateBody,
          response: { 200: CreateResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { path?: string; expiresInSec?: number; password?: string };
        if (!body.path) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });

        let abs: string;
        try {
          abs = resolveInRoot(filesRoot(), body.path);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path escapes root' });
        }
        if (!fs.existsSync(abs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source not found' });
        }

        const ttl = Math.min(Math.max(body.expiresInSec ?? DEFAULT_TTL, 60), MAX_TTL);
        const id = newId();
        const salt = crypto.randomBytes(8).toString('hex');
        const now = Math.floor(Date.now() / 1000);
        const expiresAt = body.expiresInSec === 0 ? null : now + ttl;

        await sql`
          insert into share_links (id, path, salt, password_hash, created_at, expires_at, downloads)
          values (${id}, ${body.path}, ${salt}, ${
            body.password ? hashPassword(salt, body.password) : null
          }, ${now}, ${expiresAt}, 0)
        `.execute(k.db);

        return { id, url: `/api/v1/share/download?id=${id}`, expiresAt };
      },
    );

    app.get(
      '/api/v1/share/list',
      secured('share:read', {
        schema: {
          operationId: 'shareList',
          tags: TAG,
          summary: '列出分享链接',
          response: { 200: ListResponse },
        },
      }),
      async () => {
        const res = await sql<ShareRow>`
          select * from share_links order by created_at desc limit 500
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            path: r.path,
            createdAt: r.created_at,
            expiresAt: r.expires_at,
            downloads: r.downloads,
            hasPassword: r.password_hash !== null,
          })),
        };
      },
    );

    app.post(
      '/api/v1/share/revoke',
      secured('share:write', {
        schema: {
          operationId: 'shareRevoke',
          tags: TAG,
          summary: '撤销分享链接',
          body: IdBody,
          response: { 200: OkResponse, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        if (!body.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
        await sql`delete from share_links where id = ${body.id}`.execute(k.db);
        return { ok: true };
      },
    );

    // 公开：链接元信息（不含真实路径）
    app.get(
      '/api/v1/share/info',
      {
        schema: {
          operationId: 'shareInfo',
          tags: TAG,
          summary: '查看分享链接信息（公开）',
          querystring: IdQuery,
          response: { 200: InfoResponse, 404: ErrorResponse, 410: ErrorResponse },
        },
      },
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await load(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'link not found' });
        if (row.expires_at !== null && Date.now() / 1000 > row.expires_at) {
          return reply.code(410).send({ error: Err.gone, message: 'link expired' });
        }
        return {
          id: row.id,
          fileName: row.path.split(/[\\/]/).pop() || row.path,
          expiresAt: row.expires_at,
          hasPassword: row.password_hash !== null,
          downloads: row.downloads,
        };
      },
    );

    // 公开：下载（Range / ETag 复用 files 的实现）
    app.get(
      '/api/v1/share/download',
      {
        schema: {
          operationId: 'shareDownload',
          tags: TAG,
          summary: '通过分享链接下载（公开，支持 Range）',
          querystring: Type.Object({
            id: Type.String({ minLength: 6 }),
            password: Type.Optional(Type.String()),
          }),
          response: { 403: ErrorResponse, 404: ErrorResponse, 410: ErrorResponse },
        },
      },
      async (req, reply: FastifyReplyAlias) => {
        const q = (req.query || {}) as { id?: string; password?: string };
        const row = q.id ? await load(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'link not found' });

        const nowSec = Date.now() / 1000;
        if (row.expires_at !== null && nowSec > row.expires_at) {
          return reply.code(410).send({ error: Err.gone, message: 'link expired' });
        }
        if (row.password_hash !== null) {
          const given = q.password ? hashPassword(row.salt, q.password) : '';
          if (given !== row.password_hash) {
            return reply.code(403).send({ error: Err.forbidden, message: 'password required' });
          }
        }

        await sql`update share_links set downloads = downloads + 1 where id = ${row.id}`.execute(k.db);
        return downloadHandler(req, reply, { path: row.path });
      },
    );
  },
};

/** 仅用于类型标注，避免在参数处引入 fastify 的完整类型 */
type FastifyReplyAlias = Parameters<typeof downloadHandler>[1];