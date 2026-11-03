import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, BookRow, toBook, likePattern } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 合集 / 归档 */
export async function registerBookCollections(app: FastifyInstance, k: KernelApi, h: BookHelpers): Promise<void> {
    // ---------------------------------------------------------------- 合集 / 归档

    /** 合集名 cursor：`{n}`；合集条目 cursor：`{x(index),t(title),i(id)}` */
    /** 合集内排序用的哨兵：没有序号的书排在最后 */
    const NO_INDEX = 1_000_000;

    app.post(
      '/api/v1/book/collection',
      secured('book:write', {
        schema: {
          operationId: 'bookCollectionSet',
          tags: TAG,
          summary: '设置 / 清除书籍所属合集与序号',
          body: h.ref('BookCollectionBody'),
          response: {
            200: h.ref('BookOkResponse'),
            400: h.ref('BookErrorResponse'),
            404: h.ref('BookErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          id?: string;
          name?: string | null;
          index?: number | null;
        };
        const row = body.id ? await h.loadBook(body.id, req.user?.sub || '') : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        const name = typeof body.name === 'string' ? body.name.trim() : '';
        if (name.length > 100) {
          return reply.code(400).send({ error: Err.badRequest, message: 'collection too long' });
        }
        const index =
          typeof body.index === 'number' && Number.isFinite(body.index)
            ? Math.trunc(body.index)
            : null;

        await sql`
          update books
             set collection = ${name || null},
                 collection_index = ${name ? index : null}
           where id = ${row.id}
        `.execute(k.db);

        return { ok: true };
      },
    );

    app.get(
      '/api/v1/book/collections',
      secured('book:read', {
        schema: {
          operationId: 'bookCollections',
          tags: TAG,
          summary: '合集列表（按合集名聚合，带书数与封面书 id）',
          querystring: h.ref('BookCollectionsQuery'),
          response: { 200: h.ref('BookCollectionsResponse'), 400: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { q?: string; cursor?: string; limit?: number };
        const cur = h.decodeNameCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);

        let where = sql`b.collection is not null and b.collection <> ''`;
        if (q.q && q.q.trim()) {
          const pat = likePattern(q.q.trim());
          where = sql`${where} and b.collection like ${pat} escape '\\'`;
        }
        if (cur) where = sql`${where} and b.collection > ${cur.name}`;

        const res = await sql<{ name: string; books: number; cover_id: string | null }>`
          select b.collection as name,
                 count(*) as books,
                 (select x.id from books x
                   where x.collection = b.collection
                   order by coalesce(x.collection_index, ${NO_INDEX}), x.title, x.id
                   limit 1) as cover_id
            from books b
           where ${where}
           group by b.collection
           order by b.collection asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const next = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        return {
          items: rows.map((r) => ({
            name: r.name,
            books: Number(r.books) || 0,
            coverId: r.cover_id,
          })),
          nextCursor: next ? h.encodeNameCursor(next.name) : null,
        };
      },
    );

    app.get(
      '/api/v1/book/collections/items',
      secured('book:read', {
        schema: {
          operationId: 'bookCollectionItems',
          tags: TAG,
          summary: '合集内的书（按序号、标题排序）',
          querystring: h.ref('BookCollectionItemsQuery'),
          response: {
            200: h.ref('BookListResponse'),
            400: h.ref('BookErrorResponse'),
            404: h.ref('BookErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { name?: string; cursor?: string; limit?: number };
        const name = (q.name || '').trim();
        if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });

        const exists = await sql<{ n: number }>`
          select count(*) as n from books where collection = ${name}
        `.execute(k.db);
        if ((Number(exists.rows[0]?.n) || 0) === 0) {
          return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
        }

        const cur = h.decodeCollectionCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);
        const owner = req.user?.sub || '';

        let where = sql`b.collection = ${name}`;
        if (cur) {
          const at = cur.index ?? NO_INDEX;
          where = sql`${where} and (
            coalesce(b.collection_index, ${NO_INDEX}) > ${at}
            or (coalesce(b.collection_index, ${NO_INDEX}) = ${at} and (
              b.title > ${cur.title} or (b.title = ${cur.title} and b.id > ${cur.id})
            ))
          )`;
        }

        const res = await sql<BookRow>`
          select b.*,
                 case when f.book_id is null then 0 else 1 end as favorite,
                 p.percent as progress_percent,
                 case when a.book_id is null then 0 else 1 end as archived
            from books b
            left join book_favorites f on f.book_id = b.id and f.owner_id = ${owner}
            left join book_progress p on p.book_id = b.id and p.owner_id = ${owner}
            left join book_archived a on a.book_id = b.id and a.owner_id = ${owner}
           where ${where}
           order by coalesce(b.collection_index, ${NO_INDEX}) asc, b.title asc, b.id asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const last = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        return {
          items: rows.map(toBook),
          nextCursor: last
            ? h.encodeCollectionCursor(last.collection_index, last.title, last.id)
            : null,
        };
      },
    );

    app.post(
      '/api/v1/book/archive',
      secured('book:write', {
        schema: {
          operationId: 'bookArchive',
          tags: TAG,
          summary: '归档 / 取消归档（按当前用户隔离）',
          body: h.ref('BookArchiveBody'),
          response: { 200: h.ref('BookOkResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; archived?: boolean };
        const owner = req.user?.sub || '';
        const row = body.id ? await h.loadBook(body.id, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        if (body.archived === false) {
          await sql`
            delete from book_archived where book_id = ${row.id} and owner_id = ${owner}
          `.execute(k.db);
        } else {
          await sql`
            insert or ignore into book_archived (book_id, owner_id, created_at)
            values (${row.id}, ${owner}, ${Math.floor(Date.now() / 1000)})
          `.execute(k.db);
        }
        return { ok: true };
      },
    );

}
