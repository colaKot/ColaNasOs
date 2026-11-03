import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import * as archiverMod from 'archiver';

type ZipArchiveCtor = new (options: Record<string, unknown>) => {
  pipe(dest: NodeJS.WritableStream): void;
  file(abs: string, data: { name: string }): void;
  finalize(): Promise<void>;
  on(event: 'error', cb: (err: Error) => void): void;
};
/** archiver v8 以 `ZipArchive` 类导出（旧版是可直接调用的工厂函数） */
const ZipArchive = (archiverMod as unknown as { ZipArchive: ZipArchiveCtor }).ZipArchive;
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { walkFiles } from '../files/walk';
import { Err } from '../../../kernel/errors';

/**
 * 媒体工具统一任务表（M1/M7）。
 *
 * 与旧 `media_tool_jobs` 的关系：
 *   - 迁移 `097_media_tool_tasks` 把旧任务复制进来（uid=''，仅管理员可见）；
 *   - 旧接口 `/media-tool/jobs` 与 `/thumbnails` / `/transcode` 改为读写这张表，
 *     避免出现两套互不可见的任务；
 *   - 新接口 `/media-tool/tasks/*` 提供 CRUD + start/stop + 统计字段。
 *
 * 执行仍是进程内单泵（ffmpeg 是 CPU 密集的），每种 kind 一个 runner。
 */

const TAG = ['mediatool'];
const MAX_FILES = 5000;
const IMAGE_EXT = new Set([
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
const VIDEO_EXT = new Set(['mp4', 'mkv', 'mov', 'avi', 'wmv', 'flv', 'ts', 'm4v', 'webm', 'mpg', 'mpeg']);
const AUDIO_EXT = new Set(['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'wma']);

const ref = (id: string) => ({ $ref: `${id}#` });
const now = () => Math.floor(Date.now() / 1000);
const isAdmin = (req: FastifyRequest): boolean =>
  Array.isArray(req.user?.scopes) && req.user.scopes.includes('*');
const uidOf = (req: FastifyRequest): string => String(req.user?.sub ?? '');

export interface MediaTaskRow {
  id: string;
  uid: string;
  kind: string;
  source: string;
  target: string;
  config_json: string;
  status: string;
  total: number;
  done: number;
  processed: number;
  skipped: number;
  non_media: number;
  failed: number;
  in_bytes: number;
  out_bytes: number;
  progress: number;
  last_error: string | null;
  start_at: number | null;
  end_at: number | null;
  created_at: number;
  updated_at: number;
}

function toItem(r: MediaTaskRow) {
  let config: Record<string, unknown>;
  try {
    config = JSON.parse(r.config_json || '{}') as Record<string, unknown>;
  } catch {
    config = {};
  }
  return {
    id: r.id,
    uid: r.uid,
    kind: r.kind,
    source: r.source,
    target: r.target,
    config,
    status: r.status,
    total: Number(r.total),
    done: Number(r.done),
    processed: Number(r.processed),
    skipped: Number(r.skipped),
    nonMedia: Number(r.non_media),
    failed: Number(r.failed),
    inBytes: Number(r.in_bytes),
    outBytes: Number(r.out_bytes),
    progress: Number(r.progress),
    lastError: r.last_error,
    startAt: r.start_at === null ? null : Number(r.start_at),
    endAt: r.end_at === null ? null : Number(r.end_at),
    createdAt: Number(r.created_at),
    updatedAt: Number(r.updated_at),
  };
}

// ---------------------------------------------------------------- schemas
const KindSchema = Type.Union([
  Type.Literal('thumbnails'),
  Type.Literal('video'),
  Type.Literal('audio'),
  Type.Literal('image'),
  Type.Literal('arrange'),
]);
export const MEDIA_TASK_SCHEMAS = [
  Type.Object(
    {
      id: Type.String(),
      uid: Type.String(),
      kind: Type.String(),
      source: Type.String(),
      target: Type.String(),
      config: Type.Record(Type.String(), Type.Unknown()),
      status: Type.String(),
      total: Type.Integer(),
      done: Type.Integer(),
      processed: Type.Integer(),
      skipped: Type.Integer(),
      nonMedia: Type.Integer(),
      failed: Type.Integer(),
      inBytes: Type.Integer(),
      outBytes: Type.Integer(),
      progress: Type.Number(),
      lastError: Type.Union([Type.String(), Type.Null()]),
      startAt: Type.Union([Type.Integer(), Type.Null()]),
      endAt: Type.Union([Type.Integer(), Type.Null()]),
      createdAt: Type.Integer(),
      updatedAt: Type.Integer(),
    },
    { $id: 'MediaToolTaskItem' },
  ),
  Type.Object(
    { items: Type.Array(Type.Ref('MediaToolTaskItem')) },
    { $id: 'MediaToolTaskListResponse' },
  ),
  Type.Object(
    {
      id: Type.Optional(Type.String({ maxLength: 64 })),
      kind: KindSchema,
      source: Type.String({ minLength: 1, maxLength: 1024 }),
      target: Type.String({ minLength: 1, maxLength: 1024 }),
      config: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
    },
    { $id: 'MediaToolTaskUpsertBody' },
  ),
  Type.Object(
    { id: Type.String({ minLength: 1 }) },
    { $id: 'MediaToolTaskIdBody' },
  ),
  Type.Object({ ok: Type.Boolean() }, { $id: 'MediaToolTaskOkResponse' }),
];

// ---------------------------------------------------------------- 执行器
async function statusOf(k: KernelApi, id: string): Promise<string | null> {
  const rows = (
    await sql<{ status: string }>`select status from media_tool_tasks where id = ${id}`.execute(k.db)
  ).rows;
  return rows[0]?.status ?? null;
}

async function updateStats(
  k: KernelApi,
  id: string,
  s: {
    total?: number;
    done?: number;
    processed?: number;
    skipped?: number;
    nonMedia?: number;
    failed?: number;
    inBytes?: number;
    outBytes?: number;
    progress?: number;
  },
): Promise<void> {
  await sql`
    update media_tool_tasks set
      total = coalesce(${s.total ?? null}, total),
      done = coalesce(${s.done ?? null}, done),
      processed = coalesce(${s.processed ?? null}, processed),
      skipped = coalesce(${s.skipped ?? null}, skipped),
      non_media = coalesce(${s.nonMedia ?? null}, non_media),
      failed = coalesce(${s.failed ?? null}, failed),
      in_bytes = coalesce(${s.inBytes ?? null}, in_bytes),
      out_bytes = coalesce(${s.outBytes ?? null}, out_bytes),
      progress = coalesce(${s.progress ?? null}, progress),
      updated_at = ${now()}
    where id = ${id}
  `.execute(k.db);
}

async function finishTask(
  k: KernelApi,
  id: string,
  status: 'done' | 'failed' | 'stopped' | 'canceled',
  error: string | null,
): Promise<void> {
  const ts = now();
  await sql`
    update media_tool_tasks
       set status = ${status}, last_error = ${error}, end_at = ${ts},
           progress = case when ${status} = 'done' then 1 else progress end,
           updated_at = ${ts}
     where id = ${id}
  `.execute(k.db);
}

function taskConfig(r: MediaTaskRow): Record<string, unknown> {
  try {
    const v = JSON.parse(r.config_json || '{}') as Record<string, unknown>;
    return v && typeof v === 'object' ? v : {};
  } catch {
    return {};
  }
}

async function stopped(k: KernelApi, id: string): Promise<boolean> {
  const s = await statusOf(k, id);
  return s === 'stopped' || s === 'canceled';
}

async function runThumbnails(k: KernelApi, task: MediaTaskRow): Promise<void> {
  const root = filesRoot();
  const srcAbs = resolveInRoot(root, task.source);
  const dstAbs = resolveInRoot(root, task.target);
  const cfg = taskConfig(task);
  const size = Math.min(Math.max(Number(cfg.size) || 256, 32), 2048);

  const stat = await fsp.stat(srcAbs).catch(() => null);
  if (!stat || !stat.isDirectory()) throw new Error('source 必须是 files 根内的目录');

  const files = await walkFiles(srcAbs, MAX_FILES, (name) =>
    IMAGE_EXT.has(path.extname(name).slice(1).toLowerCase()),
  );
  await updateStats(k, task.id, { total: files.length, progress: 0 });

  let done = 0;
  let failed = 0;
  let inBytes = 0;
  let outBytes = 0;
  for (const rel of files) {
    if ((done + failed) % 10 === 0 && (await stopped(k, task.id))) {
      await updateStats(k, task.id, { done, processed: done, failed, inBytes, outBytes });
      return;
    }
    const src = path.join(srcAbs, rel);
    const outRel = `${rel.replace(/\.[^./\\]+$/, '')}.jpg`;
    const dst = path.join(dstAbs, outRel);
    try {
      const st = await fsp.stat(src);
      inBytes += st.size;
      await fsp.mkdir(path.dirname(dst), { recursive: true });
      await k.media.thumb(src, dst, size);
      done += 1;
      try {
        outBytes += (await fsp.stat(dst)).size;
      } catch {
        /* 输出大小拿不到不影响成功 */
      }
    } catch {
      failed += 1;
    }
    if ((done + failed) % 10 === 0) {
      await updateStats(k, task.id, {
        done,
        processed: done,
        failed,
        inBytes,
        outBytes,
        progress: files.length > 0 ? (done + failed) / files.length : 0,
      });
    }
  }
  await updateStats(k, task.id, {
    done,
    processed: done,
    failed,
    inBytes,
    outBytes,
    progress: files.length > 0 ? 1 : 0,
  });
}

function outputExt(config: Record<string, unknown>, fallback: string): string {
  const raw = String(config.format || '').trim().toLowerCase();
  if (!raw) return fallback;
  return raw === 'jpeg' ? 'jpg' : raw;
}

async function runSingleTranscode(
  k: KernelApi,
  task: MediaTaskRow,
  mode: 'video' | 'audio',
): Promise<void> {
  const root = filesRoot();
  const srcAbs = resolveInRoot(root, task.source);
  const dstDir = resolveInRoot(root, task.target);
  const stat = await fsp.stat(srcAbs).catch(() => null);
  if (!stat || stat.isDirectory()) throw new Error('source 必须是 files 根内的文件');

  const cfg = taskConfig(task);
  const ext = outputExt(cfg, mode === 'audio' ? 'mp3' : 'mp4');
  const base = path.basename(srcAbs).replace(/\.[^./\\]+$/, '');
  const dst = path.join(dstDir, `${base}.${ext}`);
  await fsp.mkdir(dstDir, { recursive: true });

  await updateStats(k, task.id, { total: 1, done: 0, progress: 0 });
  if (await stopped(k, task.id)) return;
  await k.media.transcode(srcAbs, dst, 'copy', { mode, ...cfg });
  let outBytes: number;
  try {
    outBytes = (await fsp.stat(dst)).size;
  } catch {
    outBytes = 0;
  }
  await updateStats(k, task.id, {
    done: 1,
    processed: 1,
    failed: 0,
    inBytes: stat.size,
    outBytes,
    progress: 1,
  });
}

/** 把本次输出打成 zip（相对路径保留子目录），返回 zip 字节数 */
async function zipOutputs(
  filesAbs: string[],
  baseDir: string,
  outFile: string,
): Promise<number> {
  await fsp.mkdir(path.dirname(outFile), { recursive: true });
  await new Promise<void>((resolve, reject) => {
    const output = fs.createWriteStream(outFile);
    const archive = new ZipArchive({ zlib: { level: 6 } });
    output.on('close', () => resolve());
    output.on('error', reject);
    archive.on('error', reject);
    archive.pipe(output);
    for (const abs of filesAbs) {
      archive.file(abs, { name: path.relative(baseDir, abs).replace(/\\/g, '/') });
    }
    void archive.finalize();
  });
  return (await fsp.stat(outFile)).size;
}

async function runImage(k: KernelApi, task: MediaTaskRow): Promise<void> {
  const root = filesRoot();
  const srcAbs = resolveInRoot(root, task.source);
  const dstDir = resolveInRoot(root, task.target);
  const cfg = taskConfig(task);
  const policy = cfg.policy === 'copy' ? 'copy' : 'skip';
  const ext = outputExt(cfg, 'jpg');
  const srcStat = await fsp.stat(srcAbs).catch(() => null);
  if (!srcStat) throw new Error('source 不存在');

  const files: string[] = [];
  if (srcStat.isDirectory()) {
    const rels = await walkFiles(srcAbs, MAX_FILES, () => true);
    for (const rel of rels) files.push(rel);
  } else {
    files.push('');
  }
  await updateStats(k, task.id, { total: files.length, progress: 0 });

  let done = 0;
  let skipped = 0;
  let nonMedia = 0;
  let failed = 0;
  let inBytes = 0;
  let outBytes = 0;
  const outputs: string[] = [];

  for (const rel of files) {
    if ((done + skipped + failed) % 10 === 0 && (await stopped(k, task.id))) {
      await updateStats(k, task.id, {
        done,
        processed: done,
        skipped,
        nonMedia,
        failed,
        inBytes,
        outBytes,
      });
      return;
    }
    const src = rel ? path.join(srcAbs, rel) : srcAbs;
    const relOut = rel
      ? `${rel.replace(/\.[^./\\]+$/, '')}.${ext}`
      : `${path.basename(srcAbs).replace(/\.[^./\\]+$/, '')}.${ext}`;
    const dst = path.join(dstDir, relOut);
    const isImage = IMAGE_EXT.has(path.extname(src).slice(1).toLowerCase());
    try {
      const st = await fsp.stat(src);
      inBytes += st.size;
      if (!isImage) {
        nonMedia += 1;
        if (policy === 'copy') {
          await fsp.mkdir(path.dirname(dst), { recursive: true });
          await fsp.copyFile(src, dst);
          outputs.push(dst);
          done += 1;
        } else {
          skipped += 1;
        }
        continue;
      }
      await fsp.mkdir(path.dirname(dst), { recursive: true });
      await k.media.transcode(src, dst, 'copy', { mode: 'image', ...cfg });
      outputs.push(dst);
      done += 1;
      try {
        outBytes += (await fsp.stat(dst)).size;
      } catch {
        /* ignore */
      }
    } catch {
      failed += 1;
    }
    if ((done + skipped + failed) % 10 === 0) {
      await updateStats(k, task.id, {
        done,
        processed: done,
        skipped,
        nonMedia,
        failed,
        inBytes,
        outBytes,
        progress: files.length > 0 ? (done + skipped + failed) / files.length : 0,
      });
    }
  }
  await updateStats(k, task.id, {
    done,
    processed: done,
    skipped,
    nonMedia,
    failed,
    inBytes,
    outBytes,
    progress: files.length > 0 ? 1 : 0,
  });

  // 可选：把本次输出打成 zip（target 目录的兄弟文件 `<target>.zip`）
  if (cfg.zip === true && outputs.length > 0 && task.target.trim() !== '') {
    try {
      const zipPath = `${dstDir}.zip`;
      outBytes += await zipOutputs(outputs, dstDir, zipPath);
      await updateStats(k, task.id, { outBytes });
    } catch {
      failed += 1;
      await updateStats(k, task.id, { failed });
    }
  }
}

function arrangeFolder(date: Date, by: string): string {
  const y = String(date.getFullYear());
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  if (by === 'day') return `${y}/${m}/${d}`;
  if (by === 'month') return `${y}/${m}`;
  return y;
}

async function runArrange(k: KernelApi, task: MediaTaskRow): Promise<void> {
  const root = filesRoot();
  const srcAbs = resolveInRoot(root, task.source);
  const dstAbs = resolveInRoot(root, task.target);
  const cfg = taskConfig(task);
  const by = cfg.by === 'month' || cfg.by === 'day' ? cfg.by : 'year';
  const policy =
    cfg.sameName === 'rename' || cfg.sameName === 'overwrite' ? cfg.sameName : 'skip';

  const stat = await fsp.stat(srcAbs).catch(() => null);
  if (!stat || !stat.isDirectory()) throw new Error('source 必须是目录');
  const dstStat = await fsp.stat(dstAbs).catch(() => null);
  if (!dstStat || !dstStat.isDirectory()) throw new Error('target 必须是已存在的目录');
  if ((await fsp.readdir(dstAbs)).length > 0) throw new Error('target 必须为空目录');
  const relSrc = path.relative(dstAbs, srcAbs);
  const relDst = path.relative(srcAbs, dstAbs);
  if (!relSrc.startsWith('..') || !relDst.startsWith('..')) {
    throw new Error('source 与 target 不能互相包含');
  }

  const files = await walkFiles(srcAbs, MAX_FILES, () => true);
  await updateStats(k, task.id, { total: files.length, progress: 0 });

  let done = 0;
  let skipped = 0;
  let failed = 0;
  let inBytes = 0;
  let outBytes = 0;
  for (const rel of files) {
    if ((done + skipped + failed) % 10 === 0 && (await stopped(k, task.id))) {
      await updateStats(k, task.id, { done, processed: done, skipped, failed, inBytes, outBytes });
      return;
    }
    const src = path.join(srcAbs, rel);
    try {
      const st = await fsp.stat(src);
      inBytes += st.size;
      const folder = arrangeFolder(new Date(st.mtimeMs), by);
      const name = path.basename(src);
      let dst = path.join(dstAbs, folder, name);
      if (fs.existsSync(dst)) {
        if (policy === 'skip') {
          skipped += 1;
          continue;
        }
        if (policy === 'rename') {
          const stem = name.replace(/\.[^./\\]+$/, '');
          const ext = path.extname(name);
          let i = 1;
          while (fs.existsSync(dst)) {
            dst = path.join(dstAbs, folder, `${stem} (${i})${ext}`);
            i += 1;
          }
        }
      }
      await fsp.mkdir(path.dirname(dst), { recursive: true });
      await fsp.rename(src, dst);
      done += 1;
      outBytes += st.size;
    } catch {
      failed += 1;
    }
    if ((done + skipped + failed) % 10 === 0) {
      await updateStats(k, task.id, {
        done,
        processed: done,
        skipped,
        failed,
        inBytes,
        outBytes,
        progress: files.length > 0 ? (done + skipped + failed) / files.length : 0,
      });
    }
  }
  await updateStats(k, task.id, {
    done,
    processed: done,
    skipped,
    failed,
    inBytes,
    outBytes,
    progress: files.length > 0 ? 1 : 0,
  });
}

let pumping = false;

/** 单泵：一次只跑一个任务；stop 后立即释放 */
export async function pumpTasks(k: KernelApi): Promise<void> {
  if (pumping) return;
  pumping = true;
  try {
    for (;;) {
      const rows = (
        await sql<MediaTaskRow>`
          select * from media_tool_tasks where status = 'pending'
          order by created_at asc limit 1
        `.execute(k.db)
      ).rows;
      const task = rows[0];
      if (!task) break;

      const ts = now();
      await sql`
        update media_tool_tasks
           set status = 'running', start_at = ${ts}, updated_at = ${ts}
         where id = ${task.id}
      `.execute(k.db);
      try {
        if (!k.media.available()) throw new Error('media sidecar / ffmpeg 不可用');
        if (task.kind === 'thumbnails') await runThumbnails(k, task);
        else if (task.kind === 'video') await runSingleTranscode(k, task, 'video');
        else if (task.kind === 'audio') await runSingleTranscode(k, task, 'audio');
        else if (task.kind === 'image') await runImage(k, task);
        else if (task.kind === 'arrange') await runArrange(k, task);
        else throw new Error(`unknown kind: ${task.kind}`);

        const current = await statusOf(k, task.id);
        if (current === 'stopped' || current === 'canceled') {
          await finishTask(k, task.id, current as 'stopped' | 'canceled', null);
        } else {
          await finishTask(k, task.id, 'done', null);
        }
      } catch (err) {
        const message = String((err as Error)?.message || err).slice(0, 500);
        k.log.warn({ task: task.id, err: message }, 'media-tool task failed');
        await finishTask(k, task.id, 'failed', message);
      }
    }
  } finally {
    pumping = false;
  }
}

// ---------------------------------------------------------------- 路由
async function loadTask(k: KernelApi, req: FastifyRequest, id: string): Promise<MediaTaskRow | null> {
  const rows = (
    await sql<MediaTaskRow>`
      select * from media_tool_tasks where id = ${id} and uid = ${uidOf(req)}
    `.execute(k.db)
  ).rows;
  if (rows[0]) return rows[0];
  if (!isAdmin(req)) return null;
  const legacy = (
    await sql<MediaTaskRow>`
      select * from media_tool_tasks where id = ${id} and uid = ''
    `.execute(k.db)
  ).rows;
  return legacy[0] ?? null;
}

export function registerMediaTaskRoutes(app: FastifyInstance, k: KernelApi): void {
  for (const schema of MEDIA_TASK_SCHEMAS) app.addSchema(schema);

  app.get(
    '/api/v1/media-tool/tasks',
    secured('mediatool:read', {
      schema: {
        operationId: 'mediaToolTaskList',
        tags: TAG,
        summary: '媒体工具任务列表（按账号隔离）',
        querystring: Type.Object({
          kind: Type.Optional(Type.String()),
          status: Type.Optional(Type.String()),
          limit: Type.Optional(Type.String()),
        }),
        response: { 200: ref('MediaToolTaskListResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { kind?: string; status?: string; limit?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 50, 200));
      const uid = uidOf(req);
      const admin = isAdmin(req);
      const rows = (
        await sql<MediaTaskRow>`
          select * from media_tool_tasks
           where ${admin ? sql`(uid = ${uid} or uid = '')` : sql`uid = ${uid}`}
             ${q.kind ? sql`and kind = ${q.kind}` : sql``}
             ${q.status ? sql`and status = ${q.status}` : sql``}
           order by created_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return { items: rows.map(toItem) };
    },
  );

  app.get(
    '/api/v1/media-tool/tasks/get',
    secured('mediatool:read', {
      schema: {
        operationId: 'mediaToolTaskGet',
        tags: TAG,
        summary: '读取单个媒体任务',
        querystring: Type.Object({ id: Type.String() }),
        response: {
          200: ref('MediaToolTaskItem'),
          404: ref('MediaToolErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const q = (req.query || {}) as { id?: string };
      const task = q.id ? await loadTask(k, req, q.id) : null;
      if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
      return toItem(task);
    },
  );

  app.post(
    '/api/v1/media-tool/tasks/upsert',
    secured('mediatool:write', {
      schema: {
        operationId: 'mediaToolTaskUpsert',
        tags: TAG,
        summary: '创建 / 编辑媒体任务（除单图压缩外需管理员）',
        body: ref('MediaToolTaskUpsertBody'),
        response: {
          200: ref('MediaToolTaskItem'),
          400: ref('MediaToolErrorResponse'),
          403: ref('MediaToolErrorResponse'),
          404: ref('MediaToolErrorResponse'),
          409: ref('MediaToolErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as {
        id?: string;
        kind?: string;
        source?: string;
        target?: string;
        config?: Record<string, unknown>;
      };
      const kind = String(body.kind || '');
      if (!['thumbnails', 'video', 'audio', 'image', 'arrange'].includes(kind)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'unknown kind' });
      }
      // 管理员门槛：只有单图压缩对所有登录用户开放
      if (kind !== 'image' && !isAdmin(req)) {
        return reply
          .code(403)
          .send({ error: Err.forbidden, message: 'this tool requires an administrator' });
      }
      const root = filesRoot();
      let srcAbs: string;
      let dstAbs: string;
      try {
        srcAbs = resolveInRoot(root, body.source || '');
        dstAbs = resolveInRoot(root, body.target || '');
      } catch {
        return reply
          .code(400)
          .send({ error: Err.badRequest, message: 'path escapes files root' });
      }
      if (srcAbs === dstAbs) {
        return reply.code(400).send({ error: Err.badRequest, message: 'target 不能与 source 相同' });
      }
      if (!fs.existsSync(srcAbs)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'source 不存在' });
      }
      if (kind === 'arrange') {
        const dstStat = await fsp.stat(dstAbs).catch(() => null);
        if (!dstStat || !dstStat.isDirectory()) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'target 必须是已存在的目录' });
        }
        if ((await fsp.readdir(dstAbs)).length > 0) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'target 必须为空目录' });
        }
        const relSrc = path.relative(dstAbs, srcAbs);
        const relDst = path.relative(srcAbs, dstAbs);
        if (!relSrc.startsWith('..') || !relDst.startsWith('..')) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'source 与 target 不能互相包含' });
        }
      }

      const cfg = (body.config || {}) as Record<string, unknown>;
      if (kind === 'image' && cfg.zip === true && dstAbs === root) {
        return reply
          .code(400)
          .send({ error: Err.badRequest, message: 'zip requires a non-root target folder' });
      }

      const uid = uidOf(req);
      const configJson = JSON.stringify(body.config ?? {});
      const ts = now();

      if (body.id) {
        const existing = await loadTask(k, req, body.id);
        if (!existing) {
          return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
        }
        if (existing.status === 'running') {
          return reply
            .code(409)
            .send({ error: Err.conflict, message: 'running task cannot be edited' });
        }
        await sql`
          update media_tool_tasks
             set kind = ${kind}, source = ${body.source}, target = ${body.target},
                 config_json = ${configJson}, status = 'stopped', progress = 0,
                 total = 0, done = 0, processed = 0, skipped = 0, non_media = 0,
                 failed = 0, in_bytes = 0, out_bytes = 0, last_error = null,
                 start_at = null, end_at = null, updated_at = ${ts}
           where id = ${body.id} and uid = ${uid}
        `.execute(k.db);
        const row = await loadTask(k, req, body.id);
        return toItem(row!);
      }

      const id = crypto.randomUUID();
      await sql`
        insert into media_tool_tasks
          (id, uid, kind, source, target, config_json, status,
           total, done, processed, skipped, non_media, failed, in_bytes, out_bytes,
           progress, last_error, start_at, end_at, created_at, updated_at)
        values (${id}, ${uid}, ${kind}, ${body.source}, ${body.target}, ${configJson}, 'pending',
                0, 0, 0, 0, 0, 0, 0, 0, 0, null, null, null, ${ts}, ${ts})
      `.execute(k.db);
      pumpTasks(k).catch((err) => k.log.warn({ err: String(err) }, 'media-tool pump stopped'));
      const row = await loadTask(k, req, id);
      return toItem(row!);
    },
  );

  app.post(
    '/api/v1/media-tool/tasks/delete',
    secured('mediatool:write', {
      schema: {
        operationId: 'mediaToolTaskDelete',
        tags: TAG,
        summary: '删除媒体任务（不动磁盘文件）',
        body: ref('MediaToolTaskIdBody'),
        response: {
          200: ref('MediaToolTaskOkResponse'),
          403: ref('MediaToolErrorResponse'),
          404: ref('MediaToolErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string };
      const task = body.id ? await loadTask(k, req, body.id) : null;
      if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
      if (task.kind !== 'image' && !isAdmin(req)) {
        return reply
          .code(403)
          .send({ error: Err.forbidden, message: 'this tool requires an administrator' });
      }
      await sql`delete from media_tool_tasks where id = ${task.id}`.execute(k.db);
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/media-tool/tasks/start',
    secured('mediatool:write', {
      schema: {
        operationId: 'mediaToolTaskStart',
        tags: TAG,
        summary: '开始 / 续跑任务',
        body: ref('MediaToolTaskIdBody'),
        response: {
          200: ref('MediaToolTaskOkResponse'),
          403: ref('MediaToolErrorResponse'),
          404: ref('MediaToolErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string };
      const task = body.id ? await loadTask(k, req, body.id) : null;
      if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
      if (task.kind !== 'image' && !isAdmin(req)) {
        return reply
          .code(403)
          .send({ error: Err.forbidden, message: 'this tool requires an administrator' });
      }
      await sql`
        update media_tool_tasks
           set status = 'pending', last_error = null, progress = 0,
               total = 0, done = 0, processed = 0, skipped = 0, non_media = 0,
               failed = 0, in_bytes = 0, out_bytes = 0, start_at = null, end_at = null,
               updated_at = ${now()}
         where id = ${task.id}
      `.execute(k.db);
      pumpTasks(k).catch((err) => k.log.warn({ err: String(err) }, 'media-tool pump stopped'));
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/media-tool/tasks/stop',
    secured('mediatool:write', {
      schema: {
        operationId: 'mediaToolTaskStop',
        tags: TAG,
        summary: '停止任务（运行中的在下一批检查点停）',
        body: ref('MediaToolTaskIdBody'),
        response: {
          200: ref('MediaToolTaskOkResponse'),
          403: ref('MediaToolErrorResponse'),
          404: ref('MediaToolErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string };
      const task = body.id ? await loadTask(k, req, body.id) : null;
      if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
      if (task.kind !== 'image' && !isAdmin(req)) {
        return reply
          .code(403)
          .send({ error: Err.forbidden, message: 'this tool requires an administrator' });
      }
      await sql`
        update media_tool_tasks set status = 'stopped', updated_at = ${now()}
         where id = ${task.id} and status in ('pending', 'running')
      `.execute(k.db);
      return { ok: true };
    },
  );
}

/** 迁移：新表 + 旧任务复制 */
export const MEDIA_TASK_MIGRATION = {
  id: '097_media_tool_tasks',
  async up(db: any) {
    await sql`
      create table if not exists media_tool_tasks (
        id text primary key,
        uid text not null default '',
        kind text not null,
        source text not null,
        target text not null,
        config_json text not null default '{}',
        status text not null default 'pending',
        total integer not null default 0,
        done integer not null default 0,
        processed integer not null default 0,
        skipped integer not null default 0,
        non_media integer not null default 0,
        failed integer not null default 0,
        in_bytes integer not null default 0,
        out_bytes integer not null default 0,
        progress real not null default 0,
        last_error text,
        start_at integer,
        end_at integer,
        created_at integer not null,
        updated_at integer not null
      )
    `.execute(db);
    await sql`
      create index if not exists idx_media_tool_tasks_uid
      on media_tool_tasks (uid, created_at desc)
    `.execute(db);
    await sql`
      create index if not exists idx_media_tool_tasks_status
      on media_tool_tasks (status, created_at)
    `.execute(db);
    // 历史任务迁移：uid=''（仅管理员可见）；状态做映射
    await sql`
      insert into media_tool_tasks
        (id, uid, kind, source, target, config_json, status, total, done, skipped, failed,
         progress, last_error, created_at, updated_at)
      select id, '', case when kind = 'transcode' then 'video' else 'thumbnails' end,
             source, target, params,
             case status when 'done' then 'done' when 'failed' then 'failed'
                         when 'canceled' then 'canceled' else 'pending' end,
             total, done, 0, failed, 0, error, created_at, updated_at
        from media_tool_jobs
       where id not in (select id from media_tool_tasks)
    `.execute(db);
  },
};