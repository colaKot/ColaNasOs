import { sql } from 'kysely';
import type { ServerModule } from '../../../kernel/types';
import { secured } from '../../../kernel/route';
import { Err } from '../../../kernel/errors';
import { filesRoot } from './fs-root';
import * as S from './schemas';
import { listHandler, type ListQuery } from './list';
import { downloadHandler, type DownloadQuery } from './download';
import {
  CHUNK_BODY_LIMIT,
  checkHandler,
  chunkHandler,
  mergeHandler,
  type CheckBody,
  type ChunkQuery,
  type MergeBody,
} from './upload';
import { thumbHandler, type ThumbQuery } from './thumb';
import {
  deleteHandler,
  mkdirHandler,
  moveHandler,
  renameHandler,
  trashEmptyHandler,
  trashListHandler,
  trashRestoreHandler,
} from './ops';
import { opLogListHandler, resolveActor, writeOpLogs, type OpLogQuery } from './oplog';

const TAG = ['files'];

/** Fastify schema $ref 语法：`<id>#` */
const ref = (id: string) => ({ $ref: `${id}#` });

export const files: ServerModule = {
  id: 'files',
  prefix: '/api/v1/files',
  permissions: ['files:read', 'files:write'],

  migrations: [
    {
      id: '010_files_meta',
      async up(db) {
        await sql`
          create table if not exists files_meta (
            path text primary key,
            size integer not null default 0,
            mtime integer not null default 0,
            updated_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '020_index_progress',
      async up(db) {
        await sql`
          create table if not exists index_progress (
            root text primary key,
            last_seq integer not null default 0,
            entries integer not null default 0,
            updated_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '103_file_op_logs',
      async up(db) {
        // 文件操作日志（U-F 余）：上传 / 下载 / 新建 / 改名 / 移动 / 删除 / 回收站
        await sql`
          create table if not exists file_op_logs (
            id text primary key,
            uid text not null default '',
            username text not null default '',
            action text not null,
            status text not null default 'ok',
            path text not null default '',
            detail text not null default '',
            ip text not null default '',
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_file_op_logs_uid
          on file_op_logs (uid, created_at desc)
        `.execute(db);
        await sql`
          create index if not exists idx_file_op_logs_action
          on file_op_logs (action, created_at desc)
        `.execute(db);
      },
    },
  ],

  async register(app, k) {
    // 注册到 Fastify schema 池 → @fastify/swagger 提升为 components.schemas
    for (const schema of [
      S.ListItem,
      S.ListQuery,
      S.ListResponse,
      S.CheckBody,
      S.CheckResponse,
      S.ChunkQuery,
      S.ChunkResponse,
      S.MergeBody,
      S.MergeResponse,
      S.DownloadQuery,
      S.ThumbQuery,
      S.ErrorResponse,
      S.IndexStartResponse,
      S.IndexStatusResponse,
      S.SearchQuery,
      S.SearchResponse,
      S.OpPathBody,
      S.MkdirResponse,
      S.RenameBody,
      S.RenameResponse,
      S.MoveBody,
      S.DeleteBody,
      S.OpFailure,
      S.OpResult,
      S.TrashItem,
      S.TrashBatch,
      S.TrashListResponse,
      S.TrashRestoreBody,
      S.TrashEmptyBody,
      S.TrashEmptyResponse,
      S.OpLogQuery,
      S.OpLogItem,
      S.OpLogListResponse,
    ]) {
      app.addSchema(schema);
    }

    app.addContentTypeParser(
      'application/octet-stream',
      { parseAs: 'buffer', bodyLimit: CHUNK_BODY_LIMIT },
      (_req, body, done) => done(null, body),
    );

    app.get(
      '/api/v1/files/list',
      secured('files:read', {
        config: { pathScope: 'read' },
        schema: {
          operationId: 'filesList',
          tags: TAG,
          summary: '列出目录（单层，目录优先）',
          querystring: ref('FilesListQuery'),
          response: { 200: ref('FilesListResponse') },
        },
      }),
      async (req) => listHandler((req.query || {}) as ListQuery, k.log),
    );

    app.post(
      '/api/v1/files/check',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesCheck',
          tags: TAG,
          summary: '分片上传预检（秒传判定 + 已收分片）',
          body: ref('FilesCheckBody'),
          response: { 200: ref('FilesCheckResponse') },
        },
      }),
      async (req) => checkHandler(k.paths.dataDir, (req.body || {}) as CheckBody),
    );

    app.post(
      '/api/v1/files/chunk',
      secured('files:write', {
        // 请求体是二进制，跳过 ajv（query 由 handler 自行校验）
        validatorCompiler: (() => () => true) as any,
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesChunk',
          tags: TAG,
          summary: '上传单个分片（application/octet-stream）',
          querystring: ref('FilesChunkQuery'),
          body: S.BinaryBody,
          response: { 200: ref('FilesChunkResponse') },
        },
      }),
      async (req) => chunkHandler(k.paths.dataDir, (req.query || {}) as ChunkQuery, req.body),
    );

    app.post(
      '/api/v1/files/merge',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesMerge',
          tags: TAG,
          summary: '合并分片（幂等）',
          body: ref('FilesMergeBody'),
          response: { 200: ref('FilesMergeResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as MergeBody;
        const actor = await resolveActor(k.db, req);
        try {
          const res = await mergeHandler(k.paths.dataDir, body, k.log);
          await writeOpLogs(k.db, actor, [
            {
              action: 'upload',
              status: 'ok',
              path: String(res.path || body.path || ''),
              detail: `size=${Number(res.size ?? body.size ?? 0)}${res.skipped ? ' skipped' : ''}`,
            },
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action: 'upload',
              status: 'failed',
              path: String(body.path || ''),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.get(
      '/api/v1/files/download',
      secured('files:read', {
        config: { pathScope: 'read' },
        schema: {
          operationId: 'filesDownload',
          tags: TAG,
          summary: '下载文件（Range / ETag）',
          querystring: ref('FilesDownloadQuery'),
        },
      }),
      async (req, reply) => {
        const query = (req.query || {}) as DownloadQuery;
        const actor = await resolveActor(k.db, req);
        try {
          const out = await downloadHandler(req, reply, query);
          await writeOpLogs(k.db, actor, [
            { action: 'download', status: 'ok', path: String(query.path || '') },
          ]);
          return out;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action: 'download',
              status: 'failed',
              path: String(query.path || ''),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.get(
      '/api/v1/files/thumb',
      secured('files:read', {
        config: { pathScope: 'read' },
        schema: {
          operationId: 'filesThumb',
          tags: TAG,
          summary: '图片缩略图（JPEG；懒生成 + 文件缓存，缺 ffmpeg 时 503）',
          querystring: ref('FilesThumbQuery'),
        },
      }),
      async (req, reply) => thumbHandler(req, reply, (req.query || {}) as ThumbQuery, k),
    );

    // ---------------------------------------------------------------- 索引 / 搜索（蓝图 §8/§9）
    // 索引走任务队列：sidecar 遍历 + 主进程单事务落 files_meta，重启后由 /tasks 可见、可重试。
    k.tasks.register('files.index', async (payload) => {
      const root = String((payload as { root?: string } | null)?.root || '') || filesRoot();
      return k.indexer.scan(root);
    });

    app.post(
      '/api/v1/files/index',
      secured('files:write', {
        schema: {
          operationId: 'filesIndex',
          tags: TAG,
          summary: '触发索引（入队，返回任务 id；同一时刻只跑一轮）',
          response: { 200: S.IndexStartResponse, 503: S.ErrorResponse },
        },
      }),
      async (req, reply) => {
        if (!k.indexer) return reply.code(503).send({ error: Err.unavailable, message: 'indexer unavailable' });
        const { id, reused } = await k.tasks.enqueueIfIdle('files.index', { root: filesRoot() }, { maxAttempts: 1 });
        return { taskId: id, reused };
      },
    );

    app.get(
      '/api/v1/files/index/status',
      secured('files:read', {
        schema: {
          operationId: 'filesIndexStatus',
          tags: TAG,
          summary: '索引进度（已索引条数 / 断点序号 / 最近事务耗时）',
          response: { 200: S.IndexStatusResponse },
        },
      }),
      async () => {
        const root = filesRoot();
        const rows = await sql<{ last_seq: number; entries: number; updated_at: number }>`
          select last_seq, entries, updated_at from index_progress where root = ${root}
        `.execute(k.db);
        const row = rows.rows[0];
        const stats = k.indexer.stats();
        return {
          root,
          indexed: Number(row?.entries) || 0,
          lastSeq: Number(row?.last_seq) || 0,
          updatedAt: row ? Number(row.updated_at) : null,
          running: k.indexer.running,
          batches: stats.batches,
          maxTxMs: Number(stats.maxTxMs.toFixed(2)),
        };
      },
    );

    app.get(
      '/api/v1/files/search',
      secured('files:read', {
        config: { pathScope: 'read' },
        schema: {
          operationId: 'filesSearch',
          tags: TAG,
          summary: '按路径关键词搜索已索引文件（先 POST /files/index）',
          querystring: S.SearchQuery,
          response: { 200: S.SearchResponse, 400: S.ErrorResponse },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { q?: string; limit?: number };
        const keyword = String(q.q || '').trim();
        if (keyword.length === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'q required' });
        }
        const limit = Math.max(1, Math.min(Number(q.limit || 50) || 50, 200));
        const escaped = keyword.replace(/[\\%_]/g, (m) => '\\' + m);
        const rows = await sql<{ path: string; size: number; mtime: number }>`
          select path, size, mtime from files_meta
           where path like ${'%' + escaped + '%'} escape '\\'
           order by path limit ${limit}
        `.execute(k.db);
        return { items: rows.rows.map((r) => ({ path: r.path, size: Number(r.size), mtime: Number(r.mtime) })) };
      },
    );

    // ---------------------------------------------------------------- 写操作
    // 此前文件域只能 list / 上传 / 下载 —— 一个 NAS 管理界面不能删、不能改名、不能移动。
    // 全部走 files:write + resolveInRoot（越界 403）；删除默认进回收站，不是直接 rm。

    app.post(
      '/api/v1/files/mkdir',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesMkdir',
          tags: TAG,
          summary: '新建目录（中间层自动补齐）',
          body: ref('FilesOpPathBody'),
          response: { 200: ref('FilesMkdirResponse'), 400: S.ErrorResponse, 409: S.ErrorResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { path?: string };
        const actor = await resolveActor(k.db, req);
        try {
          const res = await mkdirHandler(body);
          await writeOpLogs(k.db, actor, [
            { action: 'mkdir', status: 'ok', path: String(res.path || body.path || '') },
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action: 'mkdir',
              status: 'failed',
              path: String(body.path || ''),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.post(
      '/api/v1/files/rename',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesRename',
          tags: TAG,
          summary: '重命名（同目录改名，名称不允许含分隔符）',
          body: ref('FilesRenameBody'),
          response: {
            200: ref('FilesRenameResponse'),
            400: S.ErrorResponse,
            404: S.ErrorResponse,
            409: S.ErrorResponse,
          },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { path?: string; name?: string };
        const actor = await resolveActor(k.db, req);
        try {
          const res = await renameHandler(body, k.db);
          await writeOpLogs(k.db, actor, [
            {
              action: 'rename',
              status: 'ok',
              path: String(res.path || ''),
              detail: `from ${String(res.from || body.path || '')}`,
            },
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action: 'rename',
              status: 'failed',
              path: String(body.path || ''),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.post(
      '/api/v1/files/move',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesMove',
          tags: TAG,
          summary: '移动 / 复制（批量，单条失败不影响其它条）',
          body: ref('FilesMoveBody'),
          response: { 200: ref('FilesOpResult'), 400: S.ErrorResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { paths?: string[]; to?: string; copy?: boolean };
        const actor = await resolveActor(k.db, req);
        const action: 'copy' | 'move' = body.copy ? 'copy' : 'move';
        try {
          const res = await moveHandler(body, k.db);
          await writeOpLogs(k.db, actor, [
            ...res.done.map((p) => ({
              action,
              status: 'ok' as const,
              path: String(p),
              detail: `to ${String(body.to || '')}`,
            })),
            ...res.failed.map((f) => ({
              action,
              status: 'failed' as const,
              path: String(f.path),
              detail: String(f.error || ''),
            })),
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action,
              status: 'failed',
              path: (body.paths || []).join(', ').slice(0, 1000),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.post(
      '/api/v1/files/delete',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesDelete',
          tags: TAG,
          summary: '删除（默认移入回收站；permanent=true 才真删）',
          body: ref('FilesDeleteBody'),
          response: { 200: ref('FilesOpResult'), 400: S.ErrorResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { paths?: string[]; permanent?: boolean };
        const actor = await resolveActor(k.db, req);
        const action: 'delete' | 'trash' = body.permanent === true ? 'delete' : 'trash';
        try {
          const res = await deleteHandler(body, k.db);
          await writeOpLogs(k.db, actor, [
            ...res.done.map((p) => ({
              action,
              status: 'ok' as const,
              path: String(p),
              detail: res.trashedTo ? `batch ${res.trashedTo}` : 'permanent',
            })),
            ...res.failed.map((f) => ({
              action,
              status: 'failed' as const,
              path: String(f.path),
              detail: String(f.error || ''),
            })),
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action,
              status: 'failed',
              path: (body.paths || []).join(', ').slice(0, 1000),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.get(
      '/api/v1/files/trash',
      secured('files:read', {
        schema: {
          operationId: 'filesTrashList',
          tags: TAG,
          summary: '回收站批次与条目',
          response: { 200: ref('FilesTrashListResponse') },
        },
      }),
      async () => trashListHandler(),
    );

    app.post(
      '/api/v1/files/trash/restore',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesTrashRestore',
          tags: TAG,
          summary: '从回收站还原到原路径（目标已存在时该条失败）',
          body: ref('FilesTrashRestoreBody'),
          response: { 200: ref('FilesOpResult'), 400: S.ErrorResponse },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { batch?: string; paths?: string[] };
        const actor = await resolveActor(k.db, req);
        try {
          const res = await trashRestoreHandler(body);
          await writeOpLogs(k.db, actor, [
            ...res.done.map((p) => ({
              action: 'restore' as const,
              status: 'ok' as const,
              path: String(p),
              detail: `batch ${String(body.batch || '')}`,
            })),
            ...res.failed.map((f) => ({
              action: 'restore' as const,
              status: 'failed' as const,
              path: String(f.path),
              detail: String(f.error || ''),
            })),
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action: 'restore',
              status: 'failed',
              path: String(body.batch || ''),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.post(
      '/api/v1/files/trash/empty',
      secured('files:write', {
        config: { pathScope: 'write' },
        schema: {
          operationId: 'filesTrashEmpty',
          tags: TAG,
          summary: '清空回收站（可指定批次）',
          body: ref('FilesTrashEmptyBody'),
          response: { 200: ref('FilesTrashEmptyResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { batch?: string };
        const actor = await resolveActor(k.db, req);
        try {
          const res = await trashEmptyHandler(body);
          await writeOpLogs(k.db, actor, [
            {
              action: 'empty',
              status: 'ok',
              path: String(body.batch || '*'),
              detail: `removed ${Number(res.removed || 0)}`,
            },
          ]);
          return res;
        } catch (err) {
          await writeOpLogs(k.db, actor, [
            {
              action: 'empty',
              status: 'failed',
              path: String(body.batch || '*'),
              detail: (err as Error).message || String(err),
            },
          ]);
          throw err;
        }
      },
    );

    app.get(
      '/api/v1/files/op-logs',
      secured('files:read', {
        schema: {
          operationId: 'filesOpLogs',
          tags: TAG,
          summary: '文件操作日志（按用户 / 类型 / 状态 / 关键词过滤，分页）',
          querystring: ref('FilesOpLogQuery'),
          response: { 200: ref('FilesOpLogListResponse') },
        },
      }),
      async (req) => opLogListHandler(k.db, (req.query || {}) as OpLogQuery),
    );
  },
};
