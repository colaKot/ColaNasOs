import crypto from 'node:crypto';

import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import type { FastifyRequest } from 'fastify';
import { secured } from '../../../kernel/route';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { MEDIA_TOOL_SCHEMAS } from './schemas';
import { Err } from '../../../kernel/errors';
import {
  registerMediaTaskRoutes,
  pumpTasks,
  MEDIA_TASK_MIGRATION,
  type MediaTaskRow,
} from './tasks';

const TAG = ['mediatool'];
const ref = (id: string) => ({ $ref: `${id}#` });
const now = () => Math.floor(Date.now() / 1000);
const uidOf = (req: FastifyRequest): string => String(req.user?.sub ?? '');

/**
 * SP3-10 / M1 的 mediaTool：
 *   - 统一任务表 `media_tool_tasks`（新接口 `/media-tool/tasks/*`）；
 *   - 旧接口 `/jobs`、`/thumbnails`、`/transcode`、`/jobs/cancel` 保留兼容，
 *     内部改读写同一张表，避免出现两套互不可见的任务；
 *   - 实际执行由 `tasks.ts` 的单泵完成（ffmpeg 走 media sidecar）。
 */
export const mediaTool: ServerModule = {
  id: 'mediaTool',
  prefix: '/api/v1/media-tool',
  permissions: ['mediatool:read', 'mediatool:write'],

  migrations: [
    {
      id: '040_media_tool',
      async up(db) {
        await sql`
          create table if not exists media_tool_jobs (
            id text primary key,
            kind text not null,
            source text not null,
            target text not null,
            params text not null default '{}',
            status text not null default 'pending',
            total integer not null default 0,
            done integer not null default 0,
            failed integer not null default 0,
            error text,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_media_tool_jobs_status
          on media_tool_jobs (status, created_at)
        `.execute(db);
      },
    },
    MEDIA_TASK_MIGRATION,
  ],

  async register(app, k) {
    for (const schema of MEDIA_TOOL_SCHEMAS) app.addSchema(schema);
    // 进程重启：running 没有意义（ffmpeg 已随进程终止），回滚为 pending 重跑
    await sql`update media_tool_tasks set status = 'pending' where status = 'running'`.execute(k.db);
    pumpTasks(k).catch((err) => k.log.warn({ err: String(err) }, 'media-tool pump stopped'));
    registerMediaTaskRoutes(app, k);

    // ------------------------------------------------ 旧接口（兼容）
    app.get(
      '/api/v1/media-tool/jobs',
      secured('mediatool:read', {
        schema: {
          operationId: 'mediaToolJobs',
          tags: TAG,
          summary: '媒体工具任务列表（state / 进度 / 失败数）',
          querystring: ref('MediaToolJobListQuery'),
          response: { 200: ref('MediaToolJobListResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { status?: string; limit?: number };
        const limit = Math.min(Number(q.limit || 50) || 50, 200);
        const rows = (
          q.status
            ? await sql<MediaTaskRow>`
                select * from media_tool_tasks
                 where status = ${q.status}
                 order by created_at desc limit ${limit}
              `.execute(k.db)
            : await sql<MediaTaskRow>`
                select * from media_tool_tasks
                 order by created_at desc limit ${limit}
              `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            id: r.id,
            // 旧契约只有 thumbnails / transcode；新工具在旧入口统一显示为 transcode
            kind: r.kind === 'thumbnails' ? 'thumbnails' : 'transcode',
            source: r.source,
            target: r.target,
            // 旧契约没有 stopped，映射成 canceled
            status: r.status === 'stopped' ? 'canceled' : r.status,
            total: Number(r.total),
            done: Number(r.done),
            failed: Number(r.failed),
            error: r.last_error,
            createdAt: Number(r.created_at),
            updatedAt: Number(r.updated_at),
          })),
        };
      },
    );

    app.post(
      '/api/v1/media-tool/thumbnails',
      secured('mediatool:write', {
        schema: {
          operationId: 'mediaToolThumbnails',
          tags: TAG,
          summary: '批量生成缩略图（目录 → JPEG，保留子目录结构）',
          body: ref('MediaToolThumbnailsBody'),
          response: {
            200: ref('MediaToolJobCreated'),
            400: ref('MediaToolErrorResponse'),
            503: ref('MediaToolErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { source?: string; target?: string; size?: number };
        if (!Array.isArray(req.user?.scopes) || !req.user.scopes.includes('*')) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'this tool requires an administrator' });
        }
        const root = filesRoot();
        const srcAbs = resolveInRoot(root, body.source);
        const stat = await fsp.stat(srcAbs).catch(() => null);
        if (!stat || !stat.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'source 必须是目录' });
        }
        if (!k.media.available()) {
          return reply
            .code(503)
            .send({ error: Err.mediaUnavailable, message: '缺少 ffmpeg / media sidecar' });
        }

        const id = crypto.randomUUID();
        const target = body.target?.trim() || `media-thumbnails/${id}`;
        resolveInRoot(root, target);

        const ts = now();
        await sql`
          insert into media_tool_tasks
            (id, uid, kind, source, target, config_json, status,
             total, done, processed, skipped, non_media, failed, in_bytes, out_bytes,
             progress, last_error, start_at, end_at, created_at, updated_at)
          values (${id}, ${uidOf(req)}, 'thumbnails', ${body.source || ''}, ${target},
                  ${JSON.stringify({ size: body.size ?? 256 })}, 'pending',
                  0, 0, 0, 0, 0, 0, 0, 0, 0, null, null, null, ${ts}, ${ts})
        `.execute(k.db);
        pumpTasks(k).catch((err) => k.log.warn({ err: String(err) }, 'media-tool pump stopped'));
        return { id };
      },
    );

    app.post(
      '/api/v1/media-tool/transcode',
      secured('mediatool:write', {
        schema: {
          operationId: 'mediaToolTranscode',
          tags: TAG,
          summary: '单文件转码（audio AAC / web720 / copy）',
          body: ref('MediaToolTranscodeBody'),
          response: {
            200: ref('MediaToolJobCreated'),
            400: ref('MediaToolErrorResponse'),
            503: ref('MediaToolErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { source?: string; target?: string; preset?: string };
        if (!Array.isArray(req.user?.scopes) || !req.user.scopes.includes('*')) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'this tool requires an administrator' });
        }
        const root = filesRoot();
        const srcAbs = resolveInRoot(root, body.source);
        const dstAbs = resolveInRoot(root, body.target);
        if (srcAbs === dstAbs) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'target 不能与 source 相同' });
        }
        const stat = await fsp.stat(srcAbs).catch(() => null);
        if (!stat || stat.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'source 必须是文件' });
        }
        if (!k.media.available()) {
          return reply
            .code(503)
            .send({ error: Err.mediaUnavailable, message: '缺少 ffmpeg / media sidecar' });
        }

        const id = crypto.randomUUID();
        const preset = body.preset || 'audio';
        const ext = path.extname(body.target || '').replace('.', '').toLowerCase();
        const targetDir = path.relative(root, path.dirname(dstAbs)).replace(/\\/g, '/');
        const srcExt = path.extname(srcAbs).slice(1).toLowerCase();
        const imageExt = new Set([
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
          'bmp',
          'tif',
          'tiff',
          'avif',
          'heic',
          'heif',
        ]);
        const audioExt = new Set(['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'wma']);
        const kind = imageExt.has(srcExt)
          ? 'image'
          : audioExt.has(srcExt) || preset === 'audio'
            ? 'audio'
            : 'video';
        const config =
          kind === 'image'
            ? { mode: 'image', format: ext || 'jpg', quality: 80 }
            : kind === 'audio'
              ? { mode: 'audio', format: ext || 'm4a' }
              : preset === 'web720'
                ? {
                    mode: 'video',
                    format: ext || 'mp4',
                    resolution: '720p',
                    vcodec: 'h264',
                    acodec: 'aac',
                  }
                : { mode: 'video', format: ext || 'mp4', vcodec: 'copy', acodec: 'copy' };
        const ts = now();
        await sql`
          insert into media_tool_tasks
            (id, uid, kind, source, target, config_json, status,
             total, done, processed, skipped, non_media, failed, in_bytes, out_bytes,
             progress, last_error, start_at, end_at, created_at, updated_at)
          values (${id}, ${uidOf(req)}, ${kind}, ${body.source || ''}, ${targetDir || '.'},
                  ${JSON.stringify(config)}, 'pending',
                  0, 0, 0, 0, 0, 0, 0, 0, 0, null, null, null, ${ts}, ${ts})
        `.execute(k.db);
        pumpTasks(k).catch((err) => k.log.warn({ err: String(err) }, 'media-tool pump stopped'));
        return { id };
      },
    );

    app.post(
      '/api/v1/media-tool/jobs/cancel',
      secured('mediatool:write', {
        schema: {
          operationId: 'mediaToolJobCancel',
          tags: TAG,
          summary: '取消任务（运行中的在下一批检查点停）',
          body: ref('MediaToolIdBody'),
          response: { 200: ref('MediaToolOkResponse'), 404: ref('MediaToolErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const rows = (
          await sql<{ status: string }>`
            select status from media_tool_tasks where id = ${body.id} and uid = ${uidOf(req)}
          `.execute(k.db)
        ).rows;
        if (!rows[0]) return reply.code(404).send({ error: Err.notFound, message: 'job not found' });
        if (rows[0].status === 'done' || rows[0].status === 'failed') return { ok: true };

        await sql`
          update media_tool_tasks set status = 'canceled', updated_at = ${now()}
          where id = ${body.id} and status in ('pending', 'running')
        `.execute(k.db);
        return { ok: true };
      },
    );

  },
};