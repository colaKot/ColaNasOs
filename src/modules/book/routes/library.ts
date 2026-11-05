import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import {
  absoluteInput,
  filesRoot,
  isAbsoluteInput,
  registerExtraRoot,
  resolveInRoot,
} from '../../files/fs-root';
import { scanBookLibrary, type BookLibraryRow } from '../scan';
import { Err } from '../../../../kernel/errors';
import { TAG, newId } from '../util';
import { applyBookScanSchedule } from '../schedule';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 库 */
export async function registerBookLibrary(app: FastifyInstance, k: KernelApi, h: BookHelpers): Promise<void> {
    // ---------------------------------------------------------------- 库

    app.post(
      '/api/v1/book/libraries',
      secured('book:write', {
        schema: {
          operationId: 'bookLibraryCreate',
          tags: TAG,
          summary: '新建书库（目录须在 files 根内）',
          body: h.ref('BookLibraryCreateBody'),
          response: {
            200: h.ref('BookLibraryItem'),
            400: h.ref('BookErrorResponse'),
            409: h.ref('BookErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string; path?: string; type?: string };
        const name = (body.name || '').trim();
        const raw = (body.path || '').trim();
        const type = body.type === 'comic' ? 'comic' : 'book';
        if (!name || !raw) {
          return reply.code(400).send({ error: Err.badRequest, message: 'name and path required' });
        }

        let rel: string;
        let abs: string;
        try {
          // 绝对路径（D:/books、\\host\share\books）直接收：书库来源和音乐 / 影视一样，
          // 用户想加的是本机哪个目录，不是 files 根下的哪个子目录。
          if (isAbsoluteInput(raw)) {
            abs = path.resolve(absoluteInput(raw));
            rel = abs.split(path.sep).join('/');
          } else {
            abs = resolveInRoot(filesRoot(), raw);
            rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
          }
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path escapes root' });
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
          select id from book_libraries where root_path = ${rel}
        `.execute(k.db);
        if (existing.rows.length > 0) {
          return reply.code(409).send({ error: Err.conflict, message: 'library already exists' });
        }

        const id = newId();
        const now = Math.floor(Date.now() / 1000);
        if (isAbsoluteInput(raw)) registerExtraRoot(absoluteInput(raw));
        await sql`
          insert into book_libraries (id, name, root_path, type, created_at, last_scan_at, items)
          values (${id}, ${name}, ${rel}, ${type}, ${now}, null, 0)
        `.execute(k.db);

        void h.libWatch.refresh();
        void applyBookScanSchedule(k);
        return {
          id,
          name,
          path: rel,
          type,
          items: 0,
          scanWhenStart: 0,
          scanWhenChange: 0,
          scanIntervalHours: 0,
          createdAt: now,
          lastScanAt: null,
        };
      },
    );

    app.post(
      '/api/v1/book/libraries/update',
      secured('book:write', {
        schema: {
          operationId: 'bookLibraryUpdate',
          tags: TAG,
          summary: '改名 / 切换书籍或漫画类型',
          body: h.ref('BookLibraryUpdateBody'),
          response: { 200: h.ref('BookLibraryItem'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          id?: string;
          name?: string;
          type?: string;
          scanWhenStart?: boolean;
          scanWhenChange?: boolean;
          scanIntervalHours?: number;
        };
        const lib = body.id ? await h.loadLibrary(body.id) : null;
        if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

        const name = body.name !== undefined ? body.name.trim() || lib.name : lib.name;
        const type = body.type === 'comic' ? 'comic' : body.type === 'book' ? 'book' : (lib.type || 'book');
        const whenStart =
          body.scanWhenStart === undefined ? Number(lib.scan_when_start) || 0 : body.scanWhenStart ? 1 : 0;
        const whenChange =
          body.scanWhenChange === undefined ? Number(lib.scan_when_change) || 0 : body.scanWhenChange ? 1 : 0;
        const interval =
          body.scanIntervalHours === undefined
            ? Number(lib.scan_interval_hours) || 0
            : Math.min(24, Math.max(0, Number(body.scanIntervalHours) || 0));
        await k.db.transaction().execute(async (trx: any) => {
          await sql`
            update book_libraries
               set name = ${name},
                   type = ${type},
                   scan_when_start = ${whenStart},
                   scan_when_change = ${whenChange},
                   scan_interval_hours = ${interval}
             where id = ${lib.id}
          `.execute(trx);
          if (type !== lib.type) {
            // 类型是「来源级」的，改来源就同步它下面所有书（列表按 books.type 过滤）
            await sql`update books set type = ${type} where library_id = ${lib.id}`.execute(trx);
          }
        });
        void applyBookScanSchedule(k);
        void h.libWatch.refresh();
        return {
          id: lib.id,
          name,
          path: lib.root_path,
          type,
          items: Number(lib.items) || 0,
          scanWhenStart: whenStart,
          scanWhenChange: whenChange,
          scanIntervalHours: interval,
          createdAt: lib.created_at,
          lastScanAt: lib.last_scan_at,
        };
      },
    );

    app.get(
      '/api/v1/book/libraries',
      secured('book:read', {
        schema: {
          operationId: 'bookLibraryList',
          tags: TAG,
          summary: '书库列表',
          response: { 200: h.ref('BookLibraryListResponse') },
        },
      }),
      async () => {
        const res = await sql<BookLibraryRow>`
          select * from book_libraries order by created_at, name limit 500
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            name: r.name,
            path: r.root_path,
            type: r.type || 'book',
            items: Number(r.items) || 0,
            scanWhenStart: Number(r.scan_when_start) || 0,
            scanWhenChange: Number(r.scan_when_change) || 0,
            scanIntervalHours: Number(r.scan_interval_hours) || 0,
            createdAt: r.created_at,
            lastScanAt: r.last_scan_at,
          })),
        };
      },
    );

    app.post(
      '/api/v1/book/libraries/remove',
      secured('book:write', {
        schema: {
          operationId: 'bookLibraryRemove',
          tags: TAG,
          summary: '删除书库（级联清理收藏 / 进度 / 归档 / 列表条目）',
          body: h.ref('BookLibraryRemoveBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const lib = body.id ? await h.loadLibrary(body.id) : null;
        if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

        await k.db.transaction().execute(async (trx: any) => {
          const ids = sql`select id from books where library_id = ${lib.id}`;
          await sql`delete from book_favorites where book_id in (${ids})`.execute(trx);
          await sql`delete from book_progress where book_id in (${ids})`.execute(trx);
          await sql`delete from book_history where book_id in (${ids})`.execute(trx);
          await sql`delete from book_archived where book_id in (${ids})`.execute(trx);
          await sql`delete from book_list_items where book_id in (${ids})`.execute(trx);
          await sql`delete from books where library_id = ${lib.id}`.execute(trx);
          await sql`delete from book_libraries where id = ${lib.id}`.execute(trx);
        });

        void h.libWatch.refresh();
        void applyBookScanSchedule(k);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/book/scan',
      secured('book:write', {
        schema: {
          operationId: 'bookScan',
          tags: TAG,
          summary: '扫描索引（epub/cbz 解析元数据；未变文件跳过）',
          body: h.ref('BookScanBody'),
          response: { 200: h.ref('BookScanResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { libraryId?: string; limit?: number; prune?: boolean };
        let libs: BookLibraryRow[];
        if (body.libraryId) {
          const one = await h.loadLibrary(body.libraryId);
          if (!one) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
          libs = [one];
        } else {
          const res = await sql<BookLibraryRow>`select * from book_libraries`.execute(k.db);
          libs = res.rows;
        }

        const total = {
          libraries: libs.length,
          books: 0,
          added: 0,
          updated: 0,
          skipped: 0,
          parsed: 0,
          missing: 0,
          pruned: 0,
        };
        for (const lib of libs) {
          const r = await scanBookLibrary(k.db, lib, body.limit, undefined, { prune: body.prune === true });
          total.books += r.books;
          total.added += r.added;
          total.updated += r.updated;
          total.skipped += r.skipped;
          total.parsed += r.parsed;
          total.missing += r.missing;
          total.pruned += r.pruned;
        }
        k.log.info(total, 'book.scan');
        return total;
      },
    );

}
