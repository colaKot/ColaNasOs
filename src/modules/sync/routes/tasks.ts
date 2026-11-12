import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import {
  checkPathAccess,
  effectivePathRules,
  isFullAccess,
  readPolicy,
} from '../../../../kernel/access-policy';
import { filesRoot, resolveInRoot, resolveRemoteDir } from '../../files/fs-root';
import { buildPlan, inScope, type SyncEntry, type SyncMode } from '../plan';
import { Err } from '../../../../kernel/errors';
import type { FastifyRequest } from 'fastify';
import { TAG, ErrorResponse, OkResponse, TaskUpsertBody, TaskItem, TaskListResponse, TaskIdBody, PlanBody, PlanResponse, ReportBody, ReportResponse, DeleteRemoteBody, MkdirBody, ProbeBody, ProbeResponse, StatusBody, ClaimLegacyBody, ClaimLegacyResponse, SummaryResponse, scanRemote, toTask, parseFilter, parseTaskConfig, DEFAULT_FILTER, SyncTaskRow } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { SyncHelpers } from '../helpers';

/** 多端同步（三向比对） */
export async function registerSyncTasks(app: FastifyInstance, k: KernelApi, h: SyncHelpers): Promise<void> {
    // 按同步模式推导路径 ACL 动作：只读模式只需 read，其余需要 write
    const needOfMode = (mode: string): 'read' | 'write' =>
      mode === 'download_only' ? 'read' : 'write';
    const pathAllowed = (
      req: FastifyRequest,
      relPath: string,
      need: 'read' | 'write',
    ): boolean => {
      const policy = readPolicy(k.config, h.uidOf(req));
      // 没配目录 = 一个目录都不给（全权账号且从未配置过才放行），口径与内核中间件一致
      const rules = effectivePathRules(policy, isFullAccess(req.user));
      return checkPathAccess(rules, need, relPath).ok;
    };
    // ------------------------------------------------ 多端同步（三向比对）



    app.post(
      '/api/v1/sync/tasks/upsert',
      secured('sync:write', {
        schema: {
          operationId: 'syncTaskUpsert',
          tags: TAG,
          summary: '创建 / 更新同步任务（目录都在 files 根内）',
          body: TaskUpsertBody,
          response: { 200: TaskItem, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          id?: string;
          name?: string;
          deviceId?: string;
          deviceName?: string;
          mode?: SyncMode;
          localDir?: string;
          remoteDir?: string;
          include?: string[];
          exclude?: string[];
          filterConfig?: Record<string, unknown>;
          syncConfig?: Record<string, unknown>;
        };
        if (!body.deviceId || !body.localDir || !body.remoteDir) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'deviceId/localDir/remoteDir required' });
        }
        const taskName = (body.name ?? '').trim().slice(0, 32);

        let remoteAbs: string;
        try {
          remoteAbs = resolveRemoteDir(body.remoteDir);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'remoteDir escapes root' });
        }

        const mode: SyncMode =
          body.mode === 'download_only' || body.mode === 'upload_only'
            ? body.mode
            : 'bidirectional';
        const include = JSON.stringify(body.include ?? []);
        const exclude = JSON.stringify(body.exclude ?? []);
        const ts = h.now();

        // 路径级 ACL：只读账号不能对受限目录建上传任务
        if (!pathAllowed(req, body.remoteDir, needOfMode(mode))) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'remoteDir requires write/read permission' });
        }

        if (body.id) {
          const existing = await h.loadTask(req, body.id);
          if (!existing) {
            return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
          }
          // 未传字段保持不变（编辑旧任务不会把老配置重置成默认）
          const filterJson =
            body.filterConfig === undefined ? existing.filter_json : JSON.stringify(body.filterConfig);
          const syncJson =
            body.syncConfig === undefined ? existing.sync_json : JSON.stringify(body.syncConfig);
          await sql`
            update sync_tasks
               set name = ${taskName}, device_id = ${body.deviceId}, device_name = ${body.deviceName ?? ''},
                   mode = ${mode}, local_dir = ${body.localDir}, remote_dir = ${body.remoteDir},
                   include_json = ${include}, exclude_json = ${exclude},
                   filter_json = ${filterJson}, sync_json = ${syncJson}, updated_at = ${ts}
             where id = ${body.id} and uid = ${h.uidOf(req)}
          `.execute(k.db);
          return toTask((await h.loadTask(req, body.id))!);
        }

        const id = crypto.randomBytes(8).toString('base64url');
        const filterJson = JSON.stringify(body.filterConfig ?? {});
        const syncJson = JSON.stringify(body.syncConfig ?? {});
        await sql`
          insert into sync_tasks
            (id, uid, client_id, name, device_id, device_name, mode, status, local_dir, remote_dir,
             include_json, exclude_json, filter_json, sync_json, created_at, updated_at, last_run_at, last_error)
          values (${id}, ${h.uidOf(req)}, ${h.clientIdOf(req)}, ${taskName}, ${body.deviceId}, ${body.deviceName ?? ''}, ${mode}, 'idle',
                  ${body.localDir}, ${body.remoteDir}, ${include}, ${exclude}, ${filterJson}, ${syncJson},
                  ${ts}, ${ts}, null, null)
        `.execute(k.db);
        // 远端目录不存在时顺手创建（客户端首次同步不该因为「目录没建」失败）
        fs.mkdirSync(remoteAbs, { recursive: true });
        return toTask((await h.loadTask(req, id))!);
      },
    );

    app.get(
      '/api/v1/sync/tasks',
      secured('sync:read', {
        schema: {
          operationId: 'syncTaskList',
          tags: TAG,
          summary: '同步任务列表（当前用户）',
          response: { 200: TaskListResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const uid = h.uidOf(req);
        const cid = h.clientIdOf(req);
        // 老任务（client_id = ''）归第一个打开任务列表的客户端：认领之后
        // 同账号在别的机器上就看不到它们了 —— 这正是「每个客户端独立」的语义。
        if (cid) {
          await sql`
            update sync_tasks set client_id = ${cid}
             where uid = ${uid} and client_id = ''
          `.execute(k.db);
        }
        const rows = (
          await sql<SyncTaskRow>`
            select * from sync_tasks
             where uid = ${uid} and client_id = ${cid}
             order by updated_at desc limit 200
          `.execute(k.db)
        ).rows;
        return { items: rows.map(toTask) };
      },
    );

    app.post(
      '/api/v1/sync/tasks/delete',
      secured('sync:write', {
        schema: {
          operationId: 'syncTaskDelete',
          tags: TAG,
          summary: '删除同步任务（保留基线以备审计，不删远端文件）',
          body: TaskIdBody,
          response: { 200: OkResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply) => {
        const body = (req.body || {}) as { id?: string };
        const task = body.id ? await h.loadTask(req, body.id) : null;
        if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
        await k.db.transaction().execute(async (trx: any) => {
          await sql`delete from sync_tasks where id = ${task.id}`.execute(trx);
          await sql`delete from sync_baseline where task_id = ${task.id}`.execute(trx);
        });
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/sync/plan',
      secured('sync:write', {
        schema: {
          operationId: 'syncPlan',
          tags: TAG,
          summary: '三向比对：返回本轮要执行的动作（只读，不改文件）',
          body: PlanBody,
          response: { 200: PlanResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply) => {
        const body = (req.body || {}) as {
          taskId?: string;
          local?: SyncEntry[];
          baseline?: SyncEntry[];
        };
        const task = body.taskId ? await h.loadTask(req, body.taskId) : null;
        if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });

        const include = JSON.parse(task.include_json || '[]') as string[];
        const exclude = JSON.parse(task.exclude_json || '[]') as string[];
        const filter = parseFilter(task.filter_json);
        if (!pathAllowed(req, task.remote_dir, needOfMode(task.mode))) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'remoteDir requires write/read permission' });
        }

        let remote: SyncEntry[];
        try {
          remote = scanRemote(filesRoot(), task.remote_dir, include, exclude, filter);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'remoteDir escapes root' });
        }

        const baseline =
          body.baseline ??
          (
            await sql<{ rel_path: string; size: number; mtime_ms: number }>`
              select rel_path, size, mtime_ms from sync_baseline where task_id = ${task.id}
            `.execute(k.db)
          ).rows.map((r) => ({
            path: r.rel_path,
            size: Number(r.size),
            mtimeMs: Number(r.mtime_ms),
          }));

        const cfg = parseTaskConfig(task.sync_json);
        const plan = buildPlan(body.local ?? [], baseline, remote, task.mode as SyncMode, {
          conflictStrategy: cfg.conflictStrategy,
          deleteExtra: cfg.deleteExtra,
        });

        await sql`
          update sync_tasks set status = 'running', last_run_at = ${h.now()}, updated_at = ${h.now()}
           where id = ${task.id}
        `.execute(k.db);

        return {
          taskId: task.id,
          mode: task.mode,
          compared: plan.compared,
          remoteCount: remote.length,
          stats: plan.stats,
          actions: plan.actions,
        };
      },
    );

    app.post(
      '/api/v1/sync/report',
      secured('sync:write', {
        schema: {
          operationId: 'syncReport',
          tags: TAG,
          summary: '上报执行结果：刷新远端基线并落一次运行记录',
          body: ReportBody,
          response: { 200: ReportResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply) => {
        const body = (req.body || {}) as {
          taskId?: string;
          applied?: Array<{ path: string; kind: string; ok: boolean }>;
          bytes?: number;
          status?: 'done' | 'failed' | 'partial';
          error?: string;
        };
        const task = body.taskId ? await h.loadTask(req, body.taskId) : null;
        if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });

        const include = JSON.parse(task.include_json || '[]') as string[];
        const exclude = JSON.parse(task.exclude_json || '[]') as string[];
        const filter = parseFilter(task.filter_json);
        if (!pathAllowed(req, task.remote_dir, needOfMode(task.mode))) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'remoteDir requires write/read permission' });
        }

        let remote: SyncEntry[];
        try {
          remote = scanRemote(filesRoot(), task.remote_dir, include, exclude, filter);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'remoteDir escapes root' });
        }

        const applied = body.applied ?? [];
        const count = (kind: string) => applied.filter((a) => a.kind === kind && a.ok).length;
        const conflicts = applied.filter((a) => a.kind === 'conflict').length;
        const failedItems = applied.filter((a) => !a.ok);
        const runId = crypto.randomBytes(8).toString('base64url');
        const ts = h.now();
        const status = body.status ?? (body.error ? 'failed' : conflicts > 0 ? 'partial' : 'done');
        const runError = (body.error ?? '').slice(0, 2000);

        // 同步后的公共状态 = 远端当前状态；整表替换，避免残留「已删除但基线还在」
        await k.db.transaction().execute(async (trx: any) => {
          await sql`delete from sync_baseline where task_id = ${task.id}`.execute(trx);
          for (const e of remote) {
            await sql`
              insert into sync_baseline (task_id, rel_path, size, mtime_ms, updated_at)
              values (${task.id}, ${e.path}, ${e.size}, ${Math.round(e.mtimeMs)}, ${ts})
            `.execute(trx);
          }
          await sql`
            insert into sync_runs
              (id, task_id, started_at, finished_at, status, uploaded, downloaded,
               deleted_local, deleted_remote, skipped, conflicts, bytes, detail_json)
            values (${runId}, ${task.id}, ${task.last_run_at ?? ts}, ${ts}, ${status},
                    ${count('upload')}, ${count('download')}, ${count('deleteLocal')},
                    ${count('deleteRemote')}, ${count('skip')}, ${conflicts},
                    ${Number(body.bytes) || 0}, ${JSON.stringify({
                      applied: applied.slice(0, 5000),
                      // 失败原因要能在「同步记录」里看到 —— 只存 applied 的话，
                      // 用户只能看到红点，不知道是哪几个文件、为什么失败。
                      error: runError || null,
                      failed: failedItems.length,
                    })})
          `.execute(trx);
          await sql`
            update sync_tasks
               set status = ${status === 'failed' ? 'error' : 'idle'},
                   last_error = ${body.error ? body.error.slice(0, 500) : null},
                   updated_at = ${ts}
             where id = ${task.id}
          `.execute(trx);
        });

        return { runId, baseline: remote.length, conflicts };
      },
    );

    app.get(
      '/api/v1/sync/runs',
      secured('sync:read', {
        schema: {
          operationId: 'syncRuns',
          tags: TAG,
          summary: '同步运行记录',
          querystring: Type.Object({
            taskId: Type.Optional(Type.String()),
            limit: Type.Optional(Type.String()),
          }),
          response: {
            200: Type.Object(
              {
                items: Type.Array(
                  Type.Object(
                    {
                      id: Type.String(),
                      taskId: Type.String(),
                      status: Type.String(),
                      uploaded: Type.Integer(),
                      downloaded: Type.Integer(),
                      deletedLocal: Type.Integer(),
                      deletedRemote: Type.Integer(),
                      skipped: Type.Integer(),
                      conflicts: Type.Integer(),
                      bytes: Type.Integer(),
                      finishedAt: Type.Integer(),
                      failed: Type.Optional(Type.Integer({ description: '本轮失败的文件数' })),
                      error: Type.Optional(
                        Type.Union([Type.String(), Type.Null()], {
                          description: '本轮错误摘要（失败时非空）',
                        }),
                      ),
                    },
                    { additionalProperties: true },
                  ),
                ),
              },
              { additionalProperties: true },
            ),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const q = (req.query || {}) as { taskId?: string; limit?: string };
        const limit = Math.max(1, Math.min(Number(q.limit) || 50, 200));
        const rows = (
          q.taskId
            ? await sql`
                select r.* from sync_runs r join sync_tasks t on t.id = r.task_id
                 where r.task_id = ${q.taskId} and t.uid = ${h.uidOf(req)}
                   and t.client_id = ${h.clientIdOf(req)}
                 order by r.finished_at desc limit ${limit}
              `.execute(k.db)
            : await sql`
                select r.* from sync_runs r join sync_tasks t on t.id = r.task_id
                 where t.uid = ${h.uidOf(req)} and t.client_id = ${h.clientIdOf(req)}
                 order by r.finished_at desc limit ${limit}
              `.execute(k.db)
        ).rows as Array<Record<string, any>>;
        return {
          items: rows.map((r) => {
            // detail_json 里带 error / failed（见 /sync/report）；解析失败按无错处理
            let detail: { error?: unknown; failed?: unknown };
            try {
              detail = JSON.parse(String(r.detail_json ?? '{}'));
            } catch {
              detail = {};
            }
            return {
              id: r.id,
              taskId: r.task_id,
              status: r.status,
              uploaded: Number(r.uploaded),
              downloaded: Number(r.downloaded),
              deletedLocal: Number(r.deleted_local),
              deletedRemote: Number(r.deleted_remote),
              skipped: Number(r.skipped),
              conflicts: Number(r.conflicts),
              bytes: Number(r.bytes),
              finishedAt: Number(r.finished_at),
              failed: Number(detail.failed ?? 0),
              error: typeof detail.error === 'string' && detail.error ? detail.error : null,
            };
          }),
        };
      },
    );

    app.post(
      '/api/v1/sync/deleteRemote',
      secured('sync:write', {
        schema: {
          operationId: 'syncDeleteRemote',
          tags: TAG,
          summary: '按相对路径删除远端文件（仅文件，不删目录）',
          body: DeleteRemoteBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply) => {
        const body = (req.body || {}) as { taskId?: string; paths?: string[] };
        const task = body.taskId ? await h.loadTask(req, body.taskId) : null;
        if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
        if (!pathAllowed(req, task.remote_dir, needOfMode(task.mode))) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'remoteDir requires write/read permission' });
        }

        const root = filesRoot();
        let removed = 0;
        for (const rel of body.paths ?? []) {
          let abs: string;
          try {
            abs = resolveInRoot(resolveRemoteDir(task.remote_dir), rel);
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'path escapes remoteDir' });
          }
          try {
            if (fs.statSync(abs).isFile()) {
              fs.unlinkSync(abs);
              removed += 1;
            }
          } catch {
            /* 已经不存在：幂等 */
          }
        }
        return { ok: true, removed } as any;
      },
    );

    app.post(
      '/api/v1/sync/mkdir',
      secured('sync:write', {
        schema: {
          operationId: 'syncMkdir',
          tags: TAG,
          summary: '在远端目录下创建子目录',
          body: MkdirBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply) => {
        const body = (req.body || {}) as { taskId?: string; path?: string };
        const task = body.taskId ? await h.loadTask(req, body.taskId) : null;
        if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
        if (!pathAllowed(req, task.remote_dir, 'write')) {
          return reply
            .code(403)
            .send({ error: Err.forbidden, message: 'remoteDir requires write permission' });
        }
        try {
          const abs = resolveInRoot(resolveRemoteDir(task.remote_dir), body.path || '');
          fs.mkdirSync(abs, { recursive: true });
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path escapes remoteDir' });
        }
        return { ok: true };
      },
    );

    // ------------------------------------------------ 探测 / 汇总 / 状态 / 旧任务认领

    app.post(
      '/api/v1/sync/probe',
      secured('sync:read', {
        schema: {
          operationId: 'syncProbe',
          tags: TAG,
          summary: '探测远端目录（存在 / 可写 / 是否越界）',
          body: ProbeBody,
          response: { 200: ProbeResponse, 400: ErrorResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as { remoteDir?: string };
        let abs: string;
        try {
          abs = resolveRemoteDir(body.remoteDir || '');
        } catch {
          return { exists: false, writable: false, allowed: false, message: 'remoteDir escapes root' };
        }
        const exists = fs.existsSync(abs) && fs.statSync(abs).isDirectory();
        let writable = false;
        if (exists) {
          try {
            fs.accessSync(abs, fs.constants.W_OK);
            writable = true;
          } catch {
            writable = false;
          }
        }
        return {
          exists,
          writable,
          allowed: true,
          message: !exists ? 'missing' : writable ? 'ok' : 'readonly',
        };
      },
    );

    app.post(
      '/api/v1/sync/summary',
      secured('sync:read', {
        schema: {
          operationId: 'syncSummary',
          tags: TAG,
          summary: '同步任务汇总（按状态 / 设备）',
          response: { 200: SummaryResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const rows = (
          await sql<{
            status: string;
            device_id: string;
            device_name: string;
            last_run_at: number | null;
          }>`
            select status, device_id, device_name, last_run_at
              from sync_tasks
             where uid = ${h.uidOf(req)} and client_id = ${h.clientIdOf(req)}
          `.execute(k.db)
        ).rows;
        const byStatus: Record<string, number> = {};
        const devices = new Map<
          string,
          { deviceId: string; deviceName: string; tasks: number; lastRunAt: number | null }
        >();
        for (const r of rows) {
          byStatus[r.status] = (byStatus[r.status] ?? 0) + 1;
          const d =
            devices.get(r.device_id) ??
            {
              deviceId: r.device_id,
              deviceName: r.device_name || r.device_id,
              tasks: 0,
              lastRunAt: null,
            };
          d.tasks += 1;
          if (r.last_run_at !== null) {
            d.lastRunAt = Math.max(d.lastRunAt ?? 0, Number(r.last_run_at));
          }
          devices.set(r.device_id, d);
        }
        return { tasks: rows.length, byStatus, byDevice: [...devices.values()] };
      },
    );

    app.post(
      '/api/v1/sync/status',
      secured('sync:write', {
        schema: {
          operationId: 'syncStatus',
          tags: TAG,
          summary: '客户端回写任务状态（idle / running / paused / error）',
          body: StatusBody,
          response: { 200: OkResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply) => {
        const body = (req.body || {}) as { id?: string; status?: string };
        const task = body.id ? await h.loadTask(req, body.id) : null;
        if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
        const status = ['idle', 'running', 'paused', 'error'].includes(String(body.status))
          ? String(body.status)
          : 'idle';
        await sql`
          update sync_tasks set status = ${status}, updated_at = ${h.now()}
           where id = ${task.id} and uid = ${h.uidOf(req)}
             and client_id = ${h.clientIdOf(req)}
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/sync/device/claimLegacy',
      secured('sync:write', {
        schema: {
          operationId: 'syncClaimLegacy',
          tags: TAG,
          summary: '认领升级前的无主任务（uid 为空的同设备任务）',
          body: ClaimLegacyBody,
          response: { 200: ClaimLegacyResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as { deviceId?: string };
        const res = await sql`
          update sync_tasks
             set uid = ${h.uidOf(req)}, client_id = ${h.clientIdOf(req)}, updated_at = ${h.now()}
           where device_id = ${body.deviceId || ''} and (uid = '' or uid is null)
        `.execute(k.db);
        return { claimed: Number(res.numAffectedRows ?? 0) };
      },
    );
}
