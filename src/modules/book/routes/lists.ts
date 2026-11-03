import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, BookRow, newId, toBook } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 自定义列表 */
export async function registerBookLists(app: FastifyInstance, k: KernelApi, h: BookHelpers): Promise<void> {
    // ---------------------------------------------------------------- 自定义列表

    app.get(
      '/api/v1/book/lists',
      secured('book:read', {
        schema: {
          operationId: 'bookLists',
          tags: TAG,
          summary: '当前用户的自定义列表（按名称排序）',
          response: { 200: h.ref('BookListsResponse') },
        },
      }),
      async (req) => {
        const owner = req.user?.sub || '';
        const res = await sql<{ id: string; name: string; created_at: number; books: number }>`
          select l.id, l.name, l.created_at,
                 (select count(*) from book_list_items i where i.list_id = l.id) as books
            from book_lists l
           where l.owner_id = ${owner}
           order by l.name asc, l.id asc
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            name: r.name,
            books: Number(r.books) || 0,
            createdAt: Number(r.created_at) || 0,
          })),
        };
      },
    );

    app.post(
      '/api/v1/book/lists',
      secured('book:write', {
        schema: {
          operationId: 'bookListCreate',
          tags: TAG,
          summary: '新建自定义列表（同用户重名 409）',
          body: h.ref('BookListCreateBody'),
          response: {
            200: h.ref('BookListItem'),
            400: h.ref('BookErrorResponse'),
            409: h.ref('BookErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string };
        const owner = req.user?.sub || '';
        const name = (body.name || '').trim();
        if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });

        const dup = await sql<{ n: number }>`
          select count(*) as n from book_lists where owner_id = ${owner} and name = ${name}
        `.execute(k.db);
        if ((Number(dup.rows[0]?.n) || 0) > 0) {
          return reply.code(409).send({ error: Err.conflict, message: 'list already exists' });
        }

        const id = newId();
        const now = Math.floor(Date.now() / 1000);
        await sql`
          insert into book_lists (id, name, owner_id, created_at)
          values (${id}, ${name}, ${owner}, ${now})
        `.execute(k.db);
        return { id, name, books: 0, createdAt: now };
      },
    );

    app.post(
      '/api/v1/book/lists/remove',
      secured('book:write', {
        schema: {
          operationId: 'bookListRemove',
          tags: TAG,
          summary: '删除自定义列表（级联清条目）',
          body: h.ref('BookListRemoveBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const owner = req.user?.sub || '';
        if (!body.id) {
          return reply.code(404).send({ error: Err.notFound, message: 'list not found' });
        }
        const del = await sql`
          delete from book_lists where id = ${body.id} and owner_id = ${owner}
        `.execute(k.db);
        if (Number(del.numAffectedRows) === 0) {
          return reply.code(404).send({ error: Err.notFound, message: 'list not found' });
        }
        await sql`delete from book_list_items where list_id = ${body.id}`.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/book/lists/add',
      secured('book:write', {
        schema: {
          operationId: 'bookListAdd',
          tags: TAG,
          summary: '把书加入自定义列表（重复加入跳过）',
          body: h.ref('BookListRefBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { listId?: string; bookId?: string };
        const owner = req.user?.sub || '';
        const list = body.listId
          ? await sql<{ id: string }>`
              select id from book_lists where id = ${body.listId} and owner_id = ${owner}
            `.execute(k.db)
          : null;
        if (!list || !list.rows[0]) {
          return reply.code(404).send({ error: Err.notFound, message: 'list not found' });
        }
        const row = body.bookId ? await h.loadBook(body.bookId, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        await sql`
          insert or ignore into book_list_items (list_id, book_id, position)
          values (
            ${list.rows[0].id}, ${row.id},
            (select coalesce(max(position), -1) + 1 from book_list_items where list_id = ${list.rows[0].id})
          )
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/book/lists/items/remove',
      secured('book:write', {
        schema: {
          operationId: 'bookListRemoveItem',
          tags: TAG,
          summary: '把书移出自定义列表',
          body: h.ref('BookListRefBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { listId?: string; bookId?: string };
        const owner = req.user?.sub || '';
        const list = body.listId
          ? await sql<{ id: string }>`
              select id from book_lists where id = ${body.listId} and owner_id = ${owner}
            `.execute(k.db)
          : null;
        if (!list || !list.rows[0]) {
          return reply.code(404).send({ error: Err.notFound, message: 'list not found' });
        }
        await sql`
          delete from book_list_items
           where list_id = ${list.rows[0].id} and book_id = ${body.bookId ?? ''}
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.get(
      '/api/v1/book/lists/items',
      secured('book:read', {
        schema: {
          operationId: 'bookListItems',
          tags: TAG,
          summary: '自定义列表内的书（按加入顺序）',
          querystring: h.ref('BookListItemsQuery'),
          response: { 200: h.ref('BookListItemsResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { listId?: string };
        const owner = req.user?.sub || '';
        const list = q.listId
          ? await sql<{ id: string }>`
              select id from book_lists where id = ${q.listId} and owner_id = ${owner}
            `.execute(k.db)
          : null;
        if (!list || !list.rows[0]) {
          return reply.code(404).send({ error: Err.notFound, message: 'list not found' });
        }

        const res = await sql<BookRow>`
          select b.*,
                 case when f.book_id is null then 0 else 1 end as favorite,
                 p.percent as progress_percent,
                 case when a.book_id is null then 0 else 1 end as archived
            from book_list_items i
            join books b on b.id = i.book_id
            left join book_favorites f on f.book_id = b.id and f.owner_id = ${owner}
            left join book_progress p on p.book_id = b.id and p.owner_id = ${owner}
            left join book_archived a on a.book_id = b.id and a.owner_id = ${owner}
           where i.list_id = ${list.rows[0].id}
           order by i.position asc, b.title asc, b.id asc
        `.execute(k.db);

        return { items: res.rows.map(toBook) };
      },
    );
}
