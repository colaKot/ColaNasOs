import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { ServerModule } from '../../../kernel/types';

/**
 * SP3-13 的 message 子集（mediaTool 复用 media sidecar，未在此实现）。
 *
 *   POST /api/v1/messages/send        发送（message:write）
 *   GET  /api/v1/messages             我的消息（message:read，可按未读过滤）
 *   GET  /api/v1/messages/unread-count 未读数
 *   POST /api/v1/messages/read         标记已读
 *   POST /api/v1/messages/read-all     全部已读
 *   POST /api/v1/messages/remove       删除自己的消息
 *
 * 隔离：消息按 JWT 的 `sub` 归属，读写都带 owner 条件，跨用户不可见。
 * 事件联动：`security.alert` 事件会给操作者写一条站内消息。
 */
const TAG = ['messages'];

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const SendBody = Type.Object({
  userId: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
  title: Type.String({ minLength: 1, maxLength: 200 }),
  body: Type.String({ maxLength: 4000 }),
  level: Type.Optional(Type.Union([Type.Literal('info'), Type.Literal('warn'), Type.Literal('error')])),
});

const MessageItem = Type.Object({
  id: Type.String(),
  ownerId: Type.String(),
  title: Type.String(),
  body: Type.String(),
  level: Type.String(),
  readAt: Type.Union([Type.Integer(), Type.Null()]),
  createdAt: Type.Integer(),
});

const ListResponse = Type.Object({ items: Type.Array(MessageItem), total: Type.Integer() });
const UnreadResponse = Type.Object({ unread: Type.Integer() });
const IdBody = Type.Object({ id: Type.String({ minLength: 1 }) });
const OkResponse = Type.Object({ ok: Type.Boolean(), affected: Type.Integer() });

interface MessageRow {
  id: string;
  owner_id: string;
  title: string;
  body: string;
  level: string;
  read_at: number | null;
  created_at: number;
}

export const messages: ServerModule = {
  id: 'messages',
  prefix: '/api/v1/messages',
  permissions: ['message:read', 'message:write'],

  migrations: [
    {
      id: '008_messages',
      async up(db) {
        await sql`
          create table if not exists app_messages (
            id text primary key,
            owner_id text not null,
            title text not null,
            body text not null default '',
            level text not null default 'info',
            read_at integer,
            created_at integer not null
          )
        `.execute(db);
        await sql`create index if not exists idx_msg_owner on app_messages(owner_id, created_at desc)`.execute(db);
      },
    },
  ],

  async register(app, k) {
    const now = () => Math.floor(Date.now() / 1000);
    const owner = (req: { user?: { sub: string } }) => req.user?.sub || '';

    const toItem = (r: MessageRow) => ({
      id: r.id,
      ownerId: r.owner_id,
      title: r.title,
      body: r.body,
      level: r.level,
      readAt: r.read_at,
      createdAt: r.created_at,
    });

    app.post(
      '/api/v1/messages/send',
      secured('message:write', {
        schema: {
          operationId: 'messageSend',
          tags: TAG,
          summary: '发送站内消息',
          body: SendBody,
          response: { 200: MessageItem },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { userId?: string; title?: string; body?: string; level?: string };
        const id = crypto.randomBytes(8).toString('base64url');
        const ownerId = body.userId || owner(req);
        await sql`
          insert into app_messages (id, owner_id, title, body, level, read_at, created_at)
          values (${id}, ${ownerId}, ${body.title || ''}, ${body.body || ''}, ${body.level || 'info'}, null, ${now()})
        `.execute(k.db);
        return {
          id,
          ownerId,
          title: body.title || '',
          body: body.body || '',
          level: body.level || 'info',
          readAt: null,
          createdAt: now(),
        };
      },
    );

    app.get(
      '/api/v1/messages',
      secured('message:read', {
        schema: {
          operationId: 'messageList',
          tags: TAG,
          summary: '我的消息（可按未读过滤）',
          querystring: Type.Object({
            unreadOnly: Type.Optional(Type.Boolean()),
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
          }),
          response: { 200: ListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { unreadOnly?: boolean; limit?: number };
        const limit = Math.min(Math.max(q.limit ?? 50, 1), 200);
        const me = owner(req);
        const res = q.unreadOnly
          ? await sql<MessageRow>`
              select * from app_messages where owner_id = ${me} and read_at is null
              order by created_at desc limit ${limit}`
              .execute(k.db)
          : await sql<MessageRow>`
              select * from app_messages where owner_id = ${me}
              order by created_at desc limit ${limit}`
              .execute(k.db);
        const total = await sql<{ n: number }>`
          select count(*) as n from app_messages where owner_id = ${me}
        `.execute(k.db);
        return { items: res.rows.map(toItem), total: total.rows[0]?.n ?? 0 };
      },
    );

    app.get(
      '/api/v1/messages/unread-count',
      secured('message:read', {
        schema: {
          operationId: 'messageUnread',
          tags: TAG,
          summary: '未读数',
          response: { 200: UnreadResponse },
        },
      }),
      async (req) => {
        const res = await sql<{ n: number }>`
          select count(*) as n from app_messages where owner_id = ${owner(req)} and read_at is null
        `.execute(k.db);
        return { unread: res.rows[0]?.n ?? 0 };
      },
    );

    app.post(
      '/api/v1/messages/read',
      secured('message:read', {
        schema: {
          operationId: 'messageRead',
          tags: TAG,
          summary: '标记已读（仅自己的消息）',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string };
        const res = await sql`
          update app_messages set read_at = ${now()}
          where id = ${body.id || ''} and owner_id = ${owner(req)} and read_at is null
        `.execute(k.db);
        return { ok: true, affected: Number((res as unknown as { numUpdatedRows?: bigint | number }).numUpdatedRows ?? 0) };
      },
    );

    app.post(
      '/api/v1/messages/read-all',
      secured('message:read', {
        schema: {
          operationId: 'messageReadAll',
          tags: TAG,
          summary: '全部已读',
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const res = await sql`
          update app_messages set read_at = ${now()}
          where owner_id = ${owner(req)} and read_at is null
        `.execute(k.db);
        return { ok: true, affected: Number((res as unknown as { numUpdatedRows?: bigint | number }).numUpdatedRows ?? 0) };
      },
    );

    app.post(
      '/api/v1/messages/remove',
      secured('message:read', {
        schema: {
          operationId: 'messageRemove',
          tags: TAG,
          summary: '删除自己的消息',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string };
        const res = await sql`
          delete from app_messages where id = ${body.id || ''} and owner_id = ${owner(req)}
        `.execute(k.db);
        return { ok: true, affected: Number((res as unknown as { numDeletedRows?: bigint | number }).numDeletedRows ?? 0) };
      },
    );

    // 安全告警 → 站内消息（保持简单：写给事件携带的 userId，缺省 admin）
    k.events.on('security.alert', (payload) => {
      const p = (payload || {}) as { userId?: string; message?: string };
      const id = crypto.randomBytes(8).toString('base64url');
      void sql`
        insert into app_messages (id, owner_id, title, body, level, read_at, created_at)
        values (${id}, ${p.userId || 'admin'}, ${'安全告警'}, ${p.message || ''}, ${'warn'}, null, ${now()})
      `.execute(k.db);
    });
  },
};