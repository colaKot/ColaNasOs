import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { ServerModule } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';

/**
 * SP3-06 notes / editor 的服务端部分（yjs 实时协同未做）。
 *
 *   POST /api/v1/notes/create            新建
 *   GET  /api/v1/notes                   列表（关键词搜索 / 标签 / 置顶优先）
 *   GET  /api/v1/notes/get               详情
 *   POST /api/v1/notes/update            更新（每次写入前存一版历史）
 *   POST /api/v1/notes/remove            软删除
 *   GET  /api/v1/notes/versions          版本历史
 *   POST /api/v1/notes/restore           恢复到指定版本（生成新版本）
 *
 * 所有读写都按 JWT `sub` 隔离。
 */
const TAG = ['notes'];

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const CreateBody = Type.Object({
  title: Type.String({ minLength: 1, maxLength: 200 }),
  body: Type.String({ maxLength: 500_000 }),
  tags: Type.Optional(Type.Array(Type.String({ maxLength: 32 }), { maxItems: 20 })),
});

const NoteItem = Type.Object({
  id: Type.String(),
  title: Type.String(),
  body: Type.String(),
  tags: Type.Array(Type.String()),
  pinned: Type.Boolean(),
  createdAt: Type.Integer(),
  updatedAt: Type.Integer(),
  /** 乐观锁版本号：每次保存 +1，客户端保存时带回 baseVersion */
  version: Type.Integer(),
});

const NoteSummary = Type.Object({
  id: Type.String(),
  title: Type.String(),
  tags: Type.Array(Type.String()),
  pinned: Type.Boolean(),
  createdAt: Type.Integer(),
  updatedAt: Type.Integer(),
  excerpt: Type.String(),
});

const ListResponse = Type.Object({ items: Type.Array(NoteSummary), total: Type.Integer() });
const UpdateBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  title: Type.Optional(Type.String({ minLength: 1, maxLength: 200 })),
  body: Type.Optional(Type.String({ maxLength: 500_000 })),
  tags: Type.Optional(Type.Array(Type.String({ maxLength: 32 }), { maxItems: 20 })),
  pinned: Type.Optional(Type.Boolean()),
  /** 客户端读取时的版本号；与服务端不一致说明别人先改了，返回 409 + 最新内容 */
  baseVersion: Type.Optional(Type.Integer({ minimum: 1 })),
});

const ConflictResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  details: Type.Optional(
    Type.Object({
      version: Type.Integer(),
      title: Type.String(),
      body: Type.String(),
      tags: Type.Array(Type.String()),
      pinned: Type.Boolean(),
      updatedAt: Type.Integer(),
    }),
  ),
});

const IdBody = Type.Object({ id: Type.String({ minLength: 1 }) });

const VersionItem = Type.Object({
  id: Type.String(),
  title: Type.String(),
  body: Type.String(),
  createdAt: Type.Integer(),
  author: Type.String(),
});

const VersionListResponse = Type.Object({ items: Type.Array(VersionItem) });

const RestoreBody = Type.Object({ id: Type.String({ minLength: 1 }), versionId: Type.String({ minLength: 1 }) });
const OkResponse = Type.Object({ ok: Type.Boolean() });

interface NoteRow {
  id: string;
  owner_id: string;
  title: string;
  body: string;
  tags: string;
  pinned: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
  version: number;
}

interface VersionRow {
  id: string;
  note_id: string;
  title: string;
  body: string;
  created_at: number;
  author: string;
}

export const notes: ServerModule = {
  id: 'notes',
  prefix: '/api/v1/notes',
  permissions: ['notes:read', 'notes:write'],

  migrations: [
    {
      id: '009_notes',
      async up(db) {
        await sql`
          create table if not exists notes (
            id text primary key,
            owner_id text not null,
            title text not null,
            body text not null default '',
            tags text not null default '[]',
            pinned integer not null default 0,
            created_at integer not null,
            updated_at integer not null,
            deleted_at integer
          )
        `.execute(db);
        await sql`
          create table if not exists note_versions (
            id text primary key,
            note_id text not null,
            title text not null,
            body text not null,
            created_at integer not null,
            author text not null
          )
        `.execute(db);
        await sql`create index if not exists idx_notes_owner on notes(owner_id, updated_at desc)`.execute(db);
      },
    },
    {
      // 乐观锁：保存时带 baseVersion，服务端版本不一致返回 409 + 最新内容
      id: '077_notes_version',
      async up(db) {
        await sql`alter table notes add column version integer not null default 1`.execute(db);
      },
    },
  ],

  async register(app, k) {
    const now = () => Math.floor(Date.now() / 1000);
    const me = (req: { user?: { sub: string } }) => req.user?.sub || '';

    const toItem = (r: NoteRow) => ({
      id: r.id,
      title: r.title,
      body: r.body,
      tags: JSON.parse(r.tags || '[]') as string[],
      pinned: r.pinned === 1,
      createdAt: r.created_at,
      updatedAt: r.updated_at,
      version: r.version,
    });

    const snapshot = async (row: NoteRow, author: string) => {
      await sql`
        insert into note_versions (id, note_id, title, body, created_at, author)
        values (${crypto.randomBytes(8).toString('base64url')}, ${row.id}, ${row.title}, ${row.body}, ${now()}, ${author})
      `.execute(k.db);
    };

    app.post(
      '/api/v1/notes/create',
      secured('notes:write', {
        schema: {
          operationId: 'noteCreate',
          tags: TAG,
          summary: '新建笔记',
          body: CreateBody,
          response: { 200: NoteItem },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { title?: string; body?: string; tags?: string[] };
        const id = crypto.randomBytes(8).toString('base64url');
        await sql`
          insert into notes (id, owner_id, title, body, tags, pinned, created_at, updated_at, deleted_at)
          values (${id}, ${me(req)}, ${body.title || ''}, ${body.body || ''},
                  ${JSON.stringify(body.tags || [])}, 0, ${now()}, ${now()}, null)
        `.execute(k.db);
        return {
          id,
          title: body.title || '',
          body: body.body || '',
          tags: body.tags || [],
          pinned: false,
          createdAt: now(),
          updatedAt: now(),
          version: 1,
        };
      },
    );

    app.get(
      '/api/v1/notes',
      secured('notes:read', {
        schema: {
          operationId: 'noteList',
          tags: TAG,
          summary: '笔记列表（关键词 / 标签 / 置顶优先）',
          querystring: Type.Object({
            q: Type.Optional(Type.String({ maxLength: 100 })),
            tag: Type.Optional(Type.String({ maxLength: 32 })),
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
          }),
          response: { 200: ListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { q?: string; tag?: string; limit?: number };
        const limit = Math.min(Math.max(q.limit ?? 50, 1), 200);
        const ownerId = me(req);
        const like = q.q ? `%${q.q}%` : null;

        const res = await sql<NoteRow>`
          select * from notes
          where owner_id = ${ownerId} and deleted_at is null
            ${like ? sql`and (title like ${like} or body like ${like})` : sql``}
            ${q.tag ? sql`and tags like ${'%"' + q.tag + '"%'}` : sql``}
          order by pinned desc, updated_at desc
          limit ${limit}
        `.execute(k.db);

        const total = await sql<{ n: number }>`
          select count(*) as n from notes where owner_id = ${ownerId} and deleted_at is null
        `.execute(k.db);

        return {
          items: res.rows.map((r) => ({
            id: r.id,
            title: r.title,
            tags: JSON.parse(r.tags || '[]') as string[],
            pinned: r.pinned === 1,
            createdAt: r.created_at,
            updatedAt: r.updated_at,
            excerpt: r.body.replace(/\s+/g, ' ').slice(0, 120),
          })),
          total: total.rows[0]?.n ?? 0,
        };
      },
    );

    app.get(
      '/api/v1/notes/get',
      secured('notes:read', {
        schema: {
          operationId: 'noteGet',
          tags: TAG,
          summary: '笔记详情',
          querystring: IdBody,
          response: { 200: NoteItem, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const res = await sql<NoteRow>`
          select * from notes where id = ${q.id || ''} and owner_id = ${me(req)} and deleted_at is null
        `.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'note not found' });
        return toItem(row);
      },
    );

    app.post(
      '/api/v1/notes/update',
      secured('notes:write', {
        schema: {
          operationId: 'noteUpdate',
          tags: TAG,
          summary: '更新笔记（先存历史版本；baseVersion 不一致返回 409）',
          body: UpdateBody,
          response: { 200: NoteItem, 404: ErrorResponse, 409: ConflictResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          id?: string;
          title?: string;
          body?: string;
          tags?: string[];
          pinned?: boolean;
          baseVersion?: number;
        };
        const res = await sql<NoteRow>`
          select * from notes where id = ${body.id || ''} and owner_id = ${me(req)} and deleted_at is null
        `.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'note not found' });

        // 乐观锁：客户端基于的版本已被别人改过 → 409 + 最新内容，由客户端决定覆盖还是放弃
        if (body.baseVersion != null && body.baseVersion !== row.version) {
          return reply.code(409).send({
            error: Err.conflict,
            message: 'note was modified by another session',
            details: {
              version: row.version,
              title: row.title,
              body: row.body,
              tags: JSON.parse(row.tags || '[]'),
              pinned: row.pinned === 1,
              updatedAt: row.updated_at,
            },
          });
        }

        await snapshot(row, me(req));

        const title = body.title ?? row.title;
        const text = body.body ?? row.body;
        const tags = body.tags ? JSON.stringify(body.tags) : row.tags;
        const pinned = body.pinned === undefined ? row.pinned : body.pinned ? 1 : 0;
        const version = row.version + 1;
        await sql`
          update notes set title = ${title}, body = ${text}, tags = ${tags}, pinned = ${pinned},
                           updated_at = ${now()}, version = ${version}
          where id = ${row.id}
        `.execute(k.db);

        return {
          id: row.id,
          title,
          body: text,
          tags: JSON.parse(tags),
          pinned: pinned === 1,
          createdAt: row.created_at,
          updatedAt: now(),
          version,
        };
      },
    );

    app.get(
      '/api/v1/notes/versions',
      secured('notes:read', {
        schema: {
          operationId: 'noteVersions',
          tags: TAG,
          summary: '版本历史（新→旧）',
          querystring: IdBody,
          response: { 200: VersionListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { id?: string };
        const res = await sql<VersionRow>`
          select v.* from note_versions v
          join notes n on n.id = v.note_id
          where v.note_id = ${q.id || ''} and n.owner_id = ${me(req)}
          order by v.created_at desc
          limit 100
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            title: r.title,
            body: r.body,
            createdAt: r.created_at,
            author: r.author,
          })),
        };
      },
    );

    app.post(
      '/api/v1/notes/restore',
      secured('notes:write', {
        schema: {
          operationId: 'noteRestore',
          tags: TAG,
          summary: '恢复到历史版本（生成新版本）',
          body: RestoreBody,
          response: { 200: NoteItem, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; versionId?: string };
        const res = await sql<NoteRow>`
          select * from notes where id = ${body.id || ''} and owner_id = ${me(req)} and deleted_at is null
        `.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'note not found' });

        const vres = await sql<VersionRow>`
          select * from note_versions where id = ${body.versionId || ''} and note_id = ${row.id}
        `.execute(k.db);
        const version = vres.rows[0];
        if (!version) return reply.code(404).send({ error: Err.notFound, message: 'version not found' });

        await snapshot(row, me(req));
        await sql`
          update notes set title = ${version.title}, body = ${version.body},
                           updated_at = ${now()}, version = ${row.version + 1}
          where id = ${row.id}
        `.execute(k.db);

        return {
          id: row.id,
          title: version.title,
          body: version.body,
          tags: JSON.parse(row.tags || '[]'),
          pinned: row.pinned === 1,
          createdAt: row.created_at,
          updatedAt: now(),
          version: row.version + 1,
        };
      },
    );

    app.post(
      '/api/v1/notes/remove',
      secured('notes:write', {
        schema: {
          operationId: 'noteRemove',
          tags: TAG,
          summary: '软删除笔记',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string };
        await sql`
          update notes set deleted_at = ${now()}
          where id = ${body.id || ''} and owner_id = ${me(req)} and deleted_at is null
        `.execute(k.db);
        return { ok: true };
      },
    );
  },
};