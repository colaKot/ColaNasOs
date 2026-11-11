import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { ServerModule } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';

/**
 * SP3-14 开放集成（Webhook）。
 *
 *   POST /api/v1/integration/webhooks         创建（返回一次 secret）
 *   GET  /api/v1/integration/webhooks         列表（不回传 secret）
 *   POST /api/v1/integration/webhooks/remove  删除
 *   POST /api/v1/integration/webhooks/test    发一条 test 事件
 *   POST /api/v1/integration/emit             触发事件（供内部模块/调试）
 *   GET  /api/v1/integration/deliveries       投递记录
 *
 * 投递：HMAC-SHA256 签名（`x-colanas-signature: sha256=<hex>`），最多 3 次，
 * 5 s 超时；每次投递写一行记录，失败原因落库。
 */
const TAG = ['integration'];
const MAX_ATTEMPTS = 3;
const TOPICS = ['task.done', 'task.failed', 'file.changed', 'security.alert'];

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const CreateHookBody = Type.Object({
  url: Type.String({ minLength: 8, maxLength: 2048 }),
  events: Type.Array(Type.String({ maxLength: 64 }), { minItems: 1, maxItems: 16 }),
  secret: Type.Optional(Type.String({ minLength: 8, maxLength: 128 })),
});

const HookItem = Type.Object({
  id: Type.String(),
  url: Type.String(),
  events: Type.Array(Type.String()),
  enabled: Type.Boolean(),
  createdAt: Type.Integer(),
});

const HookCreated = Type.Object({
  id: Type.String(),
  url: Type.String(),
  events: Type.Array(Type.String()),
  secret: Type.String(),
  createdAt: Type.Integer(),
});

const HookListResponse = Type.Object({ items: Type.Array(HookItem) });

const IdBody = Type.Object({ id: Type.String({ minLength: 1 }) });

const EmitBody = Type.Object({
  event: Type.String({ minLength: 1, maxLength: 64 }),
  payload: Type.Optional(Type.Unknown()),
});

const DeliveryItem = Type.Object({
  id: Type.String(),
  hookId: Type.String(),
  event: Type.String(),
  status: Type.String(),
  attempts: Type.Integer(),
  error: Type.Union([Type.String(), Type.Null()]),
  createdAt: Type.Integer(),
});

const DeliveryListResponse = Type.Object({ items: Type.Array(DeliveryItem) });
const OkResponse = Type.Object({ ok: Type.Boolean() });
const DeliverResponse = Type.Object({ hooks: Type.Integer(), delivered: Type.Integer(), failed: Type.Integer() });

interface HookRow {
  id: string;
  url: string;
  events: string;
  secret: string;
  enabled: number;
  created_at: number;
}

export function signature(secret: string, body: string): string {
  return 'sha256=' + crypto.createHmac('sha256', secret).update(body).digest('hex');
}

export const integrations: ServerModule = {
  id: 'integrations',
  prefix: '/api/v1/integration',
  permissions: ['system:read', 'system:write'],

  migrations: [
    {
      id: '007_webhooks',
      async up(db) {
        await sql`
          create table if not exists webhooks (
            id text primary key,
            url text not null,
            events text not null,
            secret text not null,
            enabled integer not null default 1,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists webhook_deliveries (
            id text primary key,
            hook_id text not null,
            event text not null,
            status text not null,
            attempts integer not null default 0,
            error text,
            created_at integer not null
          )
        `.execute(db);
      },
    },
  ],

  async register(app, k) {
    const now = () => Math.floor(Date.now() / 1000);
    let hooks: HookRow[] = [];

    const reload = async () => {
      const res = await sql<HookRow>`select * from webhooks where enabled = 1`.execute(k.db);
      hooks = res.rows;
    };
    await reload();

    const deliverOne = async (hook: HookRow, event: string, payload: unknown) => {
      const body = JSON.stringify({ event, payload: payload ?? null, at: Date.now() });
      const sig = signature(hook.secret, body);
      let attempts = 0;
      let error: string | null = null;

      for (let i = 1; i <= MAX_ATTEMPTS; i++) {
        attempts = i;
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 5000);
        try {
          const res = await fetch(hook.url, {
            method: 'POST',
            headers: {
              'content-type': 'application/json',
              'x-colanas-signature': sig,
              'x-colanas-event': event,
            },
            body,
            signal: controller.signal,
          });
          clearTimeout(timer);
          if (res.ok) {
            error = null;
            break;
          }
          error = `http ${res.status}`;
        } catch (err) {
          clearTimeout(timer);
          error = String((err as Error).message);
        }
        if (i < MAX_ATTEMPTS) await new Promise((r) => setTimeout(r, 200));
      }

      await sql`
        insert into webhook_deliveries (id, hook_id, event, status, attempts, error, created_at)
        values (${crypto.randomBytes(8).toString('base64url')}, ${hook.id}, ${event},
                ${error ? 'failed' : 'delivered'}, ${attempts}, ${error}, ${now()})
      `.execute(k.db);
      return { ok: !error, attempts, error };
    };

    const dispatch = async (event: string, payload?: unknown) => {
      let delivered = 0;
      let failed = 0;
      const targets = hooks.filter((h) => JSON.parse(h.events || '[]').includes(event) || h.events.includes('*'));
      for (const hook of targets) {
        const r = await deliverOne(hook, event, payload);
        if (r.ok) delivered += 1;
        else failed += 1;
      }
      return { hooks: targets.length, delivered, failed };
    };

    // 内核事件 → webhook
    for (const topic of TOPICS) {
      k.events.on(topic, (payload) => {
        void dispatch(topic, payload);
      });
    }

    app.post(
      '/api/v1/integration/webhooks',
      secured('system:write', {
        schema: {
          operationId: 'webhookCreate',
          tags: TAG,
          summary: '创建 Webhook（secret 仅本次返回）',
          body: CreateHookBody,
          response: { 200: HookCreated, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { url?: string; events?: string[]; secret?: string };
        try {
          const u = new URL(body.url || '');
          if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('protocol');
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid url' });
        }
        if (!body.events || body.events.length === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'events required' });
        }
        const id = crypto.randomBytes(8).toString('base64url');
        const secret = body.secret || crypto.randomBytes(24).toString('hex');
        await sql`
          insert into webhooks (id, url, events, secret, enabled, created_at)
          values (${id}, ${body.url}, ${JSON.stringify(body.events)}, ${secret}, 1, ${now()})
        `.execute(k.db);
        await reload();
        return { id, url: body.url!, events: body.events, secret, createdAt: now() };
      },
    );

    app.get(
      '/api/v1/integration/webhooks',
      secured('system:read', {
        schema: {
          operationId: 'webhookList',
          tags: TAG,
          summary: 'Webhook 列表（不含 secret）',
          response: { 200: HookListResponse },
        },
      }),
      async () => {
        const res = await sql<HookRow>`select * from webhooks order by created_at desc`.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            url: r.url,
            events: JSON.parse(r.events || '[]'),
            enabled: r.enabled === 1,
            createdAt: r.created_at,
          })),
        };
      },
    );

    app.post(
      '/api/v1/integration/webhooks/remove',
      secured('system:write', {
        schema: {
          operationId: 'webhookRemove',
          tags: TAG,
          summary: '删除 Webhook',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string };
        await sql`delete from webhooks where id = ${body.id || ''}`.execute(k.db);
        await reload();
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/integration/webhooks/test',
      secured('system:write', {
        schema: {
          operationId: 'webhookTest',
          tags: TAG,
          summary: '发送 test 事件',
          body: IdBody,
          response: { 200: DeliverResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const hook = hooks.find((h) => h.id === body.id);
        if (!hook) return reply.code(404).send({ error: Err.notFound, message: 'hook not found' });
        const r = await deliverOne(hook, 'test', { hello: 'world' });
        return { hooks: 1, delivered: r.ok ? 1 : 0, failed: r.ok ? 0 : 1 };
      },
    );

    app.post(
      '/api/v1/integration/emit',
      secured('system:write', {
        schema: {
          operationId: 'integrationEmit',
          tags: TAG,
          summary: '触发事件（内部/调试）',
          body: EmitBody,
          response: { 200: DeliverResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { event?: string; payload?: unknown };
        return dispatch(body.event || 'unknown', body.payload);
      },
    );

    app.get(
      '/api/v1/integration/deliveries',
      secured('system:read', {
        schema: {
          operationId: 'webhookDeliveries',
          tags: TAG,
          summary: '投递记录',
          querystring: Type.Object({ hookId: Type.Optional(Type.String()) }),
          response: { 200: DeliveryListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { hookId?: string };
        const res = q.hookId
          ? await sql<{ id: string; hook_id: string; event: string; status: string; attempts: number; error: string | null; created_at: number }>`
              select * from webhook_deliveries where hook_id = ${q.hookId} order by created_at desc limit 200`
              .execute(k.db)
          : await sql<{ id: string; hook_id: string; event: string; status: string; attempts: number; error: string | null; created_at: number }>`
              select * from webhook_deliveries order by created_at desc limit 200`
              .execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            hookId: r.hook_id,
            event: r.event,
            status: r.status,
            attempts: r.attempts,
            error: r.error,
            createdAt: r.created_at,
          })),
        };
      },
    );
  },
};