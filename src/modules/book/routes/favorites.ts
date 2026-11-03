import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 收藏 / 进度 */
export async function registerBookFavorites(app: FastifyInstance, k: KernelApi, h: BookHelpers): Promise<void> {
    // ---------------------------------------------------------------- 收藏 / 进度

    app.post(
      '/api/v1/book/favorites/add',
      secured('book:write', {
        schema: {
          operationId: 'bookFavoriteAdd',
          tags: TAG,
          summary: '收藏',
          body: h.ref('BookFavoriteBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const owner = req.user?.sub || '';
        const row = body.id ? await h.loadBook(body.id, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        await sql`
          insert or ignore into book_favorites (book_id, owner_id, created_at)
          values (${row.id}, ${owner}, ${Math.floor(Date.now() / 1000)})
        `.execute(k.db);

        return { ok: true };
      },
    );

    app.post(
      '/api/v1/book/favorites/remove',
      secured('book:write', {
        schema: {
          operationId: 'bookFavoriteRemove',
          tags: TAG,
          summary: '取消收藏',
          body: h.ref('BookFavoriteBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const owner = req.user?.sub || '';
        const row = body.id ? await h.loadBook(body.id, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        await sql`
          delete from book_favorites where book_id = ${row.id} and owner_id = ${owner}
        `.execute(k.db);

        return { ok: true };
      },
    );

    app.get(
      '/api/v1/book/progress',
      secured('book:read', {
        schema: {
          operationId: 'bookProgress',
          tags: TAG,
          summary: '当前用户阅读进度（无记录返回 0）',
          querystring: h.ref('BookIdQuery'),
          response: { 200: h.ref('BookProgress'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const owner = req.user?.sub || '';
        const row = q.id ? await h.loadBook(q.id, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        const res = await sql<{ position: string; percent: number; updated_at: number }>`
          select position, percent, updated_at
            from book_progress where book_id = ${row.id} and owner_id = ${owner}
        `.execute(k.db);
        const p = res.rows[0];
        return {
          bookId: row.id,
          position: p?.position ?? '',
          percent: Number(p?.percent) || 0,
          updatedAt: Number(p?.updated_at) || 0,
        };
      },
    );

    app.post(
      '/api/v1/book/progress/save',
      secured('book:write', {
        schema: {
          operationId: 'bookProgressSave',
          tags: TAG,
          summary: '保存阅读进度',
          body: h.ref('BookProgressBody'),
          response: { 200: h.ref('BookProgress'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; position?: string; percent?: number };
        const owner = req.user?.sub || '';
        const row = body.id ? await h.loadBook(body.id, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        const now = Math.floor(Date.now() / 1000);
        await sql`
          insert into book_progress (book_id, owner_id, position, percent, updated_at)
          values (${row.id}, ${owner}, ${body.position ?? ''}, ${Math.min(
            100,
            Math.max(0, Number(body.percent) || 0),
          )}, ${now})
          on conflict(book_id, owner_id) do update set
            position = excluded.position,
            percent = excluded.percent,
            updated_at = excluded.updated_at
        `.execute(k.db);

        return {
          bookId: row.id,
          position: body.position ?? '',
          percent: Math.min(100, Math.max(0, Number(body.percent) || 0)),
          updatedAt: now,
        };
      },
    );

}
