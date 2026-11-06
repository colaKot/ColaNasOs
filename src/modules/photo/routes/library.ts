import { enqueueScanOnce } from '../ai/vision';
import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import {
  absoluteInput,
  filesRoot,
  httpError,
  isAbsoluteInput,
  registerExtraRoot,
  resolveInRoot,
} from '../../files/fs-root';
import { scanLibrary, type LibraryRow } from '../scan';
import { Err } from '../../../../kernel/errors';
import type { FastifyRequest } from 'fastify';
import { TAG, newId } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';

export interface PhotoScanInput {
  libraryId?: string;
  limit?: number;
  prune?: boolean;
  force?: boolean;
}

/**
 * 扫描的**唯一实现**：HTTP 路由（同步，给小库 / CLI）与任务队列（异步，给界面）共用。
 *
 * 抽出来是因为「同步扫描」这条路走不通：一次全库扫描几分钟起，而客户端统一 30 s
 * 超时 —— 用户看到的是「扫描失败」，服务端其实还在跑，于是他会再点一次。
 */
export async function runPhotoScan(k: KernelApi, body: PhotoScanInput, uid: string) {
  let libs: LibraryRow[];
  if (body.libraryId) {
    const one = (
      await sql<LibraryRow>`select * from photo_libraries where id = ${body.libraryId}`.execute(k.db)
    ).rows[0];
    if (!one) throw httpError(404, 'library not found');
    libs = [one];
  } else {
    const res = await sql<LibraryRow>`
      select * from photo_libraries where owner_id = ${uid}
    `.execute(k.db);
    // 未指定来源目录的默认库不参与扫描（root_path 为空时会把整个 files 根当成相册）
    libs = res.rows.filter((l) => (l.root_path || '').trim() !== '');
  }

  const total = {
    libraries: libs.length,
    images: 0,
    added: 0,
    updated: 0,
    skipped: 0,
    missing: 0,
    pruned: 0,
  };
  for (const lib of libs) {
    const r = await scanLibrary(k.db, lib, body.limit, undefined, {
      prune: body.prune === true,
      force: body.force === true,
    });
    total.images += r.images;
    total.added += r.added;
    total.updated += r.updated;
    total.skipped += r.skipped;
    total.missing += r.missing;
    total.pruned += r.pruned;
  }
  k.log.info(total, 'photo.scan');
  // 扫完就把新照片送去识别：开关开着就自动跑，不用人再点一次
  void enqueueScanOnce(k)
    .then((r) => k.log.info({ ...r }, 'photo.ai scan autostart'))
    .catch((err) => k.log.warn({ err: String(err) }, 'photo.ai scan autostart failed'));
  return total;
}

/** 库 */
export async function registerPhotoLibrary(app: FastifyInstance, k: KernelApi, h: PhotoHelpers): Promise<void> {    // ---------------------------------------------------------------- 库

    app.post(
      '/api/v1/photo/libraries',
      secured('photo:write', {
        schema: {
          operationId: 'photoLibraryCreate',
          tags: TAG,
          summary: '新建相册库（目录须在 files 根内）',
          body: h.ref('PhotoLibraryCreateBody'),
          response: {
            200: h.ref('PhotoLibraryItem'),
            400: h.ref('PhotoErrorResponse'),
            409: h.ref('PhotoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string; path?: string };
        const name = (body.name || '').trim();
        const raw = (body.path || '').trim();
        if (!name || !raw) {
          return reply.code(400).send({ error: Err.badRequest, message: 'name and path required' });
        }

        let rel: string;
        let abs: string;
        if (isAbsoluteInput(raw)) {
          // 来源允许是本机任意目录（如 D:/Photos），登记为媒体白名单根
          abs = path.resolve(absoluteInput(raw));
          rel = abs.split(path.sep).join('/');
          registerExtraRoot(abs);
        } else {
          try {
            abs = resolveInRoot(filesRoot(), raw);
            rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'path escapes root' });
          }
        }
        if (!rel) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path must be a subdirectory' });
        }
        let st;
        try {
          st = fs.statSync(abs);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path not found' });
        }
        if (!st.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path is not a directory' });
        }

        const existing = await sql<{ id: string }>`
          select id from photo_libraries where root_path = ${rel}
        `.execute(k.db);
        if (existing.rows.length > 0) {
          return reply.code(409).send({ error: Err.conflict, message: 'library already exists' });
        }

        const id = newId();
        const now = Math.floor(Date.now() / 1000);
        await sql`
          insert into photo_libraries (id, name, root_path, owner_id, created_at, last_scan_at, items)
          values (${id}, ${name}, ${rel}, ${String((req as any).user?.sub || '')}, ${now}, null, 0)
        `.execute(k.db);

        void h.libWatch.refresh();
        return { id, name, path: rel, items: 0, createdAt: now, lastScanAt: null };
      },
    );

    // 每用户只有一个库：这个接口只改「我的相册」的根目录，不再新建库
    app.post(
      '/api/v1/photo/libraries/update',
      secured('photo:write', {
        schema: {
          operationId: 'photoLibraryUpdate',
          tags: TAG,
          summary: '设置当前用户相册库的来源目录',
          body: h.ref('PhotoLibraryUpdateBody'),
          response: {
            200: h.ref('PhotoLibraryItem'),
            400: h.ref('PhotoErrorResponse'),
            404: h.ref('PhotoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const owner = String((req as any).user?.sub || '');
        const body = (req.body || {}) as { path?: string };
        const raw = (body.path || '').trim();
        if (!raw) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path required' });
        }
        let rel: string;
        let abs: string;
        if (isAbsoluteInput(raw)) {
          // 来源允许是本机任意目录（如 D:/Photos），登记为媒体白名单根
          abs = path.resolve(absoluteInput(raw));
          rel = abs.split(path.sep).join('/');
          registerExtraRoot(abs);
        } else {
          try {
            abs = resolveInRoot(filesRoot(), raw);
            rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'path escapes root' });
          }
        }
        let st;
        try {
          st = fs.statSync(abs);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path not found' });
        }
        if (!st.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path is not a directory' });
        }
        const found = await sql<LibraryRow>`
          select * from photo_libraries where owner_id = ${owner} order by created_at limit 1
        `.execute(k.db);
        const lib = found.rows[0];
        if (!lib) {
          return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
        }
        await sql`update photo_libraries set root_path = ${rel} where id = ${lib.id}`.execute(k.db);
        void h.libWatch.refresh();
        return {
          id: lib.id,
          name: lib.name,
          path: rel,
          items: Number(lib.items) || 0,
          createdAt: lib.created_at,
          lastScanAt: lib.last_scan_at,
        };
      },
    );

    app.get(
      '/api/v1/photo/libraries',
      secured('photo:read', {
        schema: {
          operationId: 'photoLibraryList',
          tags: TAG,
          summary: '相册库列表',
          response: { 200: h.ref('PhotoLibraryListResponse') },
        },
      }),
      async (req: FastifyRequest) => {
        const owner = String(req.user?.sub || '');
        // 每用户一个相册库：历史遗留的公共库（owner_id = ''）认领给第一个访问的用户，
        // 之后不再有「公共库」概念，也不再要求用户自己创建库。
        if (owner) {
          await sql`update photo_libraries set owner_id = ${owner} where owner_id = ''`.execute(k.db);
        }
        const res = await sql<LibraryRow>`
          select * from photo_libraries where owner_id = ${owner} order by created_at, name limit 500
        `.execute(k.db);
        for (const row of res.rows) {
          if (isAbsoluteInput(row.root_path)) registerExtraRoot(row.root_path);
        }
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            name: r.name,
            path: r.root_path,
            items: Number(r.items) || 0,
            createdAt: r.created_at,
            lastScanAt: r.last_scan_at,
          })),
        };
      },
    );

    app.post(
      '/api/v1/photo/libraries/remove',
      secured('photo:write', {
        schema: {
          operationId: 'photoLibraryRemove',
          tags: TAG,
          summary: '删除相册库（级联清理索引与相册成员）',
          body: h.ref('PhotoLibraryRemoveBody'),
          response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const lib = body.id ? await h.loadLibrary(body.id) : null;
        if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

        await k.db.transaction().execute(async (trx: any) => {
          await sql`
            delete from photo_album_items
             where item_id in (select id from photo_items where library_id = ${lib.id})
          `.execute(trx);
          await sql`delete from photo_items where library_id = ${lib.id}`.execute(trx);
          await sql`delete from photo_libraries where id = ${lib.id}`.execute(trx);
        });

        void h.libWatch.refresh();
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/photo/scan',
      secured('photo:write', {
        schema: {
          operationId: 'photoScan',
          tags: TAG,
          summary: '扫描索引（缺省扫描全部库；已索引且未变的文件跳过）',
          body: h.ref('PhotoScanBody'),
          response: { 200: h.ref('PhotoScanResponse'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req) =>
        runPhotoScan(k, (req.body || {}) as PhotoScanInput, String((req as any).user?.sub || '')),
    );

    // 异步扫描：入队后立即返回任务 id。
    // 为什么需要它：全库扫描几分钟起，而这个客户端统一 30 s 超时 —— 同步接口
    // 表现成「扫描失败」，服务端其实还在跑，用户于是再点一次。界面走这条，
    // 进度用 GET /api/v1/tasks/{id}，取消用 POST /api/v1/tasks/cancel。
    app.post(
      '/api/v1/photo/scan/task',
      secured('photo:write', {
        schema: {
          operationId: 'photoScanTask',
          tags: TAG,
          summary: '扫描索引（入队，立即返回任务 id；同一时刻只跑一轮）',
          body: h.ref('PhotoScanBody'),
          response: { 200: h.ref('PhotoScanTask'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as PhotoScanInput;
        const uid = String((req as any).user?.sub || '');
        // uid 必须进 payload：任务执行时没有请求上下文，而库是按 owner 过滤的
        const { id, reused } = await k.tasks.enqueueIfIdle(
          'photo.scan',
          { ...body, uid },
          { maxAttempts: 1 },
        );
        return { taskId: id, reused };
      },
    );

    // 扫描任务：重启不丢、失败可重试；payload 里带 uid 是因为任务执行时没有请求上下文
    k.tasks.register('photo.scan', async (payload) => {
      const p = (payload || {}) as PhotoScanInput & { uid?: string };
      const r = await runPhotoScan(k, p, String(p.uid || ''));
      return r.added + r.updated;
    });

    // ---------------------------------------------------------------- 本机目录浏览（选择来源）
    app.get(
      '/api/v1/photo/fs/roots',
      secured('photo:write', {
        schema: {
          operationId: 'photoFsRoots',
          tags: TAG,
          summary: '本机盘符 / 根目录',
          response: { 200: h.ref('PhotoFsRoots') },
        },
      }),
      async () => {
        const roots: string[] = [];
        if (process.platform === 'win32') {
          for (const d of 'CDEFGHIJKLMNOPQRSTUVWXYZ') {
            const p = `${d}:/`;
            try {
              if (fs.statSync(p).isDirectory()) roots.push(p);
            } catch {
              /* 不存在 / 未挂载 */
            }
          }
        } else {
          roots.push('/');
        }
        return { items: roots };
      },
    );

    app.get(
      '/api/v1/photo/fs/list',
      secured('photo:write', {
        schema: {
          operationId: 'photoFsList',
          tags: TAG,
          summary: '列出本机目录（选择来源目录）',
          querystring: h.ref('PhotoFsListQuery'),
          response: { 200: h.ref('PhotoFsList'), 400: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { path?: string };
        const raw = (q.path || '').trim();
        const slash = (v: string) => v.split(path.sep).join('/');

        if (!raw) {
          const roots: { name: string; path: string }[] = [];
          if (process.platform === 'win32') {
            for (const d of 'CDEFGHIJKLMNOPQRSTUVWXYZ') {
              const p = `${d}:/`;
              try {
                if (fs.statSync(p).isDirectory()) roots.push({ name: `${d}:`, path: p });
              } catch {
                /* 不存在 */
              }
            }
          } else {
            roots.push({ name: '/', path: '/' });
          }
          return { path: '', parent: null, dirs: roots };
        }

        const abs = path.resolve(absoluteInput(raw));
        let st;
        try {
          st = fs.statSync(abs);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path not found' });
        }
        if (!st.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path is not a directory' });
        }
        const dirs = fs
          .readdirSync(abs, { withFileTypes: true })
          .filter((e) => e.isDirectory())
          .map((e) => ({ name: e.name, path: slash(path.join(abs, e.name)) }))
          .sort((a, b) => a.name.localeCompare(b.name));
        const parentAbs = path.dirname(abs);
        return {
          path: slash(abs),
          parent: parentAbs === abs ? null : slash(parentAbs),
          dirs,
        };
      },
    );
  }
