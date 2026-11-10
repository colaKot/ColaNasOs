import type { ServerModule } from '../../../kernel/types';
import { secured } from '../../../kernel/route';
import { Err } from '../../../kernel/errors';
import { createTransferStore, type TransferDirection, type TransferState } from '../../../kernel/transfer-store';
import { TRANSFER_MIGRATIONS } from './migrations';
import * as S from './schemas';

const TAG = ['transfer'];
const ref = (id: string) => ({ $ref: `${id}#` });

const VALID_DIRECTIONS: TransferDirection[] = ['upload', 'download'];
const VALID_STATES: TransferState[] = [
  'pending',
  'active',
  'paused',
  'done',
  'failed',
  'canceled',
];

/** 从请求取发起端标识：客户端用两个轻量 header 自报，缺省算作未知端 */
function originOf(req: { headers: Record<string, unknown> }): { origin: string; device: string } {
  const pick = (name: string): string => {
    const raw = req.headers[name];
    const value = Array.isArray(raw) ? raw[0] : raw;
    return typeof value === 'string' ? decodeURIComponent(value).slice(0, 64) : '';
  };
  return { origin: pick('x-colanas-client'), device: pick('x-colanas-device') };
}

/**
 * 传输中心。
 *
 * 解决的问题：原先「传输」页的任务列表是页面私有的一个 List，只装「我刚在这个页面选的文件」。
 * 换个设备、换个人、甚至关掉页面再进来，全都看不到。这里把会话落到库里，任何一端轮询
 * `GET /transfer/sessions` 都能看到**整机所有来源**的上传与下载。
 *
 * 权限只复用 `files:read` / `files:write`，不新增 scope：传输本身就是文件读写，
 * 再造一套 `transfer:read/write` 只会让权限矩阵多两格而没有任何隔离收益。
 */
export const transfer: ServerModule = {
  id: 'transfer',
  prefix: '/api/v1/transfer',
  permissions: ['files:read', 'files:write'],
  migrations: TRANSFER_MIGRATIONS,

  async register(app, k) {
    const store = createTransferStore(k.db);

    // 注册到 Fastify schema 池 → @fastify/swagger 提升为 components.schemas。
    // 不注册的话 `$ref: 'TransferListQuery#'` 会解析失败（启动期直接抛 FastifyError）。
    for (const schema of [
      S.TransferSession,
      S.TransferStats,
      S.SessionsResponse,
      S.ListQuery,
      S.BeginBody,
      S.BeginResponse,
      S.IdBody,
      S.OkResponse,
    ]) {
      app.addSchema(schema);
    }

    app.get(
      '/api/v1/transfer/sessions',
      secured('files:read', {
        schema: {
          operationId: 'transferSessions',
          tags: TAG,
          summary: '传输会话列表（全部来源：本机 / 其他设备 / 其他用户）',
          querystring: ref('TransferListQuery'),
          response: { 200: ref('TransferSessionsResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as Record<string, unknown>;
        const { items, total } = await store.list({
          state: q.state === undefined ? undefined : String(q.state),
          direction: q.direction === undefined ? undefined : String(q.direction),
          owner: q.owner === undefined ? undefined : String(q.owner),
          q: q.q === undefined ? undefined : String(q.q),
          limit: q.limit === undefined ? 50 : Number(q.limit),
          offset: q.offset === undefined ? 0 : Number(q.offset),
        });
        return {
          items: await store.fillOwnerNames(items),
          total,
          stats: await store.stats(),
        };
      },
    );

    app.get(
      '/api/v1/transfer/sessions/:id',
      secured('files:read', {
        schema: {
          operationId: 'transferSessionGet',
          tags: TAG,
          summary: '单个传输会话',
        },
      }),
      async (req, reply) => {
        const id = String((req.params as { id?: string }).id || '');
        const session = await store.get(id);
        if (!session) return reply.code(404).send({ error: Err.notFound, message: 'session not found' });
        return session;
      },
    );

    app.post(
      '/api/v1/transfer/begin',
      secured('files:write', {
        schema: {
          operationId: 'transferBegin',
          tags: TAG,
          summary: '开启或续传一个传输会话（同路径活跃会话直接复用）',
          body: ref('TransferBeginBody'),
          response: { 200: ref('TransferBeginResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as Record<string, unknown>;
        const owner = String(req.user?.sub || 'anonymous');
        const wanted = String(body.direction || 'upload');
        const direction: TransferDirection = VALID_DIRECTIONS.includes(wanted as TransferDirection)
          ? (wanted as TransferDirection)
          : 'upload';
        const { origin, device } = originOf(req);
        const session = await store.begin({
          id: body.id === undefined ? undefined : String(body.id),
          owner,
          direction,
          path: String(body.path || ''),
          size: body.size === undefined ? 0 : Number(body.size),
          totalChunks: body.totalChunks === undefined ? 0 : Number(body.totalChunks),
          origin: body.origin === undefined ? origin : String(body.origin),
          device: body.device === undefined ? device : String(body.device),
        });
        // 事件总线只放小对象：面板拿到就能局部刷新，不用等下一次轮询
        k.events.emit('transfer.session', {
          id: session.id,
          state: session.state,
          direction: session.direction,
          path: session.path,
        });
        return { session };
      },
    );

    app.post(
      '/api/v1/transfer/finish',
      secured('files:write', {
        schema: {
          operationId: 'transferFinish',
          tags: TAG,
          summary: '标记会话完成（幂等）',
          body: ref('TransferIdBody'),
          response: { 200: ref('TransferOkResponse') },
        },
      }),
      async (req, reply) => {
        const id = String((req.body as { id?: string })?.id || '');
        if (!id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
        const session = await store.get(id);
        if (!session) return reply.code(404).send({ error: Err.notFound, message: 'session not found' });
        await store.finish(id, { size: session.size });
        k.events.emit('transfer.session', { id, state: 'done', direction: session.direction, path: session.path });
        return { ok: true };
      },
    );

    // 取消 / 暂停 / 恢复：语义一致，只有目标状态不同
    for (const [op, opId, state, summary] of [
      ['cancel', 'transferCancel', 'canceled', '取消传输（已传分片保留，可再次续传）'],
      ['pause', 'transferPause', 'paused', '暂停传输'],
      ['resume', 'transferResume', 'active', '恢复传输'],
    ] as const) {
      if (!VALID_STATES.includes(state)) continue;
      app.post(
        `/api/v1/transfer/${op}`,
        secured('files:write', {
          schema: {
            operationId: opId,
            tags: TAG,
            summary,
            body: ref('TransferIdBody'),
            response: { 200: ref('TransferOkResponse') },
          },
        }),
        async (req, reply) => {
          const id = String((req.body as { id?: string })?.id || '');
          if (!id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
          const session = await store.get(id);
          if (!session) return reply.code(404).send({ error: Err.notFound, message: 'session not found' });
          await store.setState(id, state as TransferState);
          k.events.emit('transfer.session', { id, state, direction: session.direction, path: session.path });
          return { ok: true };
        },
      );
    }

    app.post(
      '/api/v1/transfer/prune',
      secured('files:write', {
        schema: {
          operationId: 'transferPrune',
          tags: TAG,
          summary: '清理已结束的旧会话记录（不碰磁盘文件）',
        },
      }),
      async () => ({ ok: true, affected: await store.prune() }),
    );
  },
};
