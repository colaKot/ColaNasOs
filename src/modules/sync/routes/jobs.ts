import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { resolveRemoteDir } from '../../files/fs-root';
import { Err } from '../../../../kernel/errors';
import { TAG, ErrorResponse, RunBody, RunResponse, JobListResponse, DiffResponse, ConflictListResponse, ResolveBody, OkResponse, sha256File, walk, JobRow, ConflictRow } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { SyncHelpers } from '../helpers';

/** 主注册 */
export async function registerSyncJobs(app: FastifyInstance, k: KernelApi, h: SyncHelpers): Promise<void> {

    /** source/target 都必须在 files 根内 */

    app.get(
      '/api/v1/sync/diff',
      secured('sync:read', {
        schema: {
          operationId: 'syncDiff',
          tags: TAG,
          summary: '差异预览（只读）',
          querystring: Type.Object({ source: Type.String(), target: Type.String() }),
          response: { 200: DiffResponse, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { source?: string; target?: string };
        let src: string;
        let dst: string;
        try {
          ({ src, dst } = h.roots(q));
        } catch {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'source/target escape root' });
        }
        const a = fs.existsSync(src) ? walk(src) : [];
        const b = fs.existsSync(dst) ? walk(dst) : [];
        const setA = new Set(a);
        const setB = new Set(b);
        const onlySource = a.filter((p) => !setB.has(p));
        const onlyTarget = b.filter((p) => !setA.has(p));
        const changed = a.filter(
          (p) => setB.has(p) && sha256File(path.join(src, p)) !== sha256File(path.join(dst, p)),
        );
        return { onlySource, onlyTarget, changed };
      },
    );

    app.post(
      '/api/v1/sync/run',
      secured('sync:write', {
        schema: {
          operationId: 'syncRun',
          tags: TAG,
          summary: '执行一次同步（merge，不删除目标多余文件）',
          body: RunBody,
          response: { 200: RunResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          source?: string;
          target?: string;
          policy?: 'overwrite' | 'skip' | 'rename';
        };
        let src: string;
        let dst: string;
        try {
          ({ src, dst } = h.roots(body));
        } catch {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'source/target escape root' });
        }
        if (!fs.existsSync(src) || !fs.statSync(src).isDirectory()) {
          return reply.code(404).send({ error: Err.notFound, message: 'source dir not found' });
        }

        const policy = body.policy || 'skip';
        const id = crypto.randomBytes(8).toString('base64url');
        let copied = 0;
        let skipped = 0;
        let conflicts = 0;
        let bytes = 0;

        fs.mkdirSync(dst, { recursive: true });
        for (const rel of walk(src)) {
          const from = path.join(src, rel);
          const to = path.join(dst, rel);

          if (!fs.existsSync(to)) {
            fs.mkdirSync(path.dirname(to), { recursive: true });
            fs.copyFileSync(from, to);
            copied += 1;
            bytes += fs.statSync(to).size;
            continue;
          }

          if (sha256File(from) === sha256File(to)) {
            skipped += 1;
            continue;
          }

          if (policy === 'overwrite') {
            fs.copyFileSync(from, to);
            copied += 1;
            bytes += fs.statSync(to).size;
          } else if (policy === 'rename') {
            const renamed = `${to}.conflict-${Date.now()}`;
            fs.renameSync(to, renamed);
            fs.copyFileSync(from, to);
            copied += 1;
            bytes += fs.statSync(to).size;
            conflicts += 1;
          } else {
            conflicts += 1;
            await sql`
              insert into sync_conflicts (id, job_id, path, created_at, resolved, resolution)
              values (${crypto.randomBytes(8).toString('base64url')}, ${id}, ${rel}, ${h.now()}, 0, null)
            `.execute(k.db);
          }
        }

        await sql`
          insert into sync_jobs (id, source, target, policy, copied, skipped, conflicts, bytes, created_at)
          values (${id}, ${body.source}, ${body.target}, ${policy}, ${copied}, ${skipped}, ${conflicts}, ${bytes}, ${h.now()})
        `.execute(k.db);

        return { id, copied, skipped, conflicts, bytes };
      },
    );

    app.get(
      '/api/v1/sync/jobs',
      secured('sync:read', {
        schema: {
          operationId: 'syncJobs',
          tags: TAG,
          summary: '同步任务历史',
          response: { 200: JobListResponse },
        },
      }),
      async () => {
        const res =
          await sql<JobRow>`select * from sync_jobs order by created_at desc limit 200`.execute(
            k.db,
          );
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            source: r.source,
            target: r.target,
            policy: r.policy,
            copied: r.copied,
            skipped: r.skipped,
            conflicts: r.conflicts,
            bytes: r.bytes,
            createdAt: r.created_at,
          })),
        };
      },
    );

    app.get(
      '/api/v1/sync/conflicts',
      secured('sync:read', {
        schema: {
          operationId: 'syncConflicts',
          tags: TAG,
          summary: '冲突列表',
          querystring: Type.Object({ jobId: Type.Optional(Type.String()) }),
          response: { 200: ConflictListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { jobId?: string };
        const res = q.jobId
          ? await sql<ConflictRow>`select * from sync_conflicts where job_id = ${q.jobId} order by created_at desc`.execute(
              k.db,
            )
          : await sql<ConflictRow>`select * from sync_conflicts order by created_at desc limit 500`.execute(
              k.db,
            );
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            jobId: r.job_id,
            path: r.path,
            createdAt: r.created_at,
            resolved: r.resolved === 1,
            resolution: r.resolution,
          })),
        };
      },
    );

    app.post(
      '/api/v1/sync/conflicts/resolve',
      secured('sync:write', {
        schema: {
          operationId: 'syncResolve',
          tags: TAG,
          summary: '冲突裁决：source 用源覆盖目标，target 保留目标',
          body: ResolveBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; action?: 'source' | 'target' };
        if (!body.id || !body.action) {
          return reply.code(400).send({ error: Err.badRequest, message: 'id/action required' });
        }
        const res =
          await sql<ConflictRow>`select * from sync_conflicts where id = ${body.id}`.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'conflict not found' });

        const jobRes = await sql<JobRow>`select * from sync_jobs where id = ${row.job_id}`.execute(
          k.db,
        );
        const job = jobRes.rows[0];
        if (!job) return reply.code(404).send({ error: Err.notFound, message: 'job not found' });

        if (body.action === 'source') {
          let src: string;
          let dst: string;
          try {
            src = resolveRemoteDir(job.source);
            dst = resolveRemoteDir(job.target);
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'path escapes root' });
          }
          const from = path.join(src, row.path);
          const to = path.join(dst, row.path);
          if (fs.existsSync(from)) {
            fs.mkdirSync(path.dirname(to), { recursive: true });
            fs.copyFileSync(from, to);
          }
        }

        await sql`
          update sync_conflicts set resolved = 1, resolution = ${body.action} where id = ${row.id}
        `.execute(k.db);
        return { ok: true };
      },
    );

}
