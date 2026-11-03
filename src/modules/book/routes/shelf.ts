import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, BookRow, toBook, encodeCursor, decodeCursor, likePattern } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 书架 / 详情 */
export async function registerBookShelf(app: FastifyInstance, k: KernelApi, h: BookHelpers): Promise<void> {
    // ---------------------------------------------------------------- 书架 / 详情

    app.get(
      '/api/v1/book/list',
      secured('book:read', {
        schema: {
          operationId: 'bookList',
          tags: TAG,
          summary: '书架（标题序 + 排序键 cursor；可按格式 / 收藏过滤）',
          querystring: h.ref('BookListQuery'),
          response: { 200: h.ref('BookListResponse'), 400: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as {
          libraryId?: string;
          q?: string;
          format?: string;
          favorite?: string;
          archived?: string;
          listId?: string;
          cursor?: string;
          limit?: number;
        };
        const cur = decodeCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);
        const owner = req.user?.sub || '';

        let where = sql`1 = 1`;
        if (q.libraryId) where = sql`${where} and b.library_id = ${q.libraryId}`;
        if (q.format) where = sql`${where} and b.format = ${q.format}`;
        if (q.favorite === '1' || q.favorite === 'true') where = sql`${where} and f.book_id is not null`;
        if (q.archived === '1' || q.archived === 'true') where = sql`${where} and a.book_id is not null`;
        else if (q.archived === '0' || q.archived === 'false') {
          where = sql`${where} and a.book_id is null`;
        }
        if (q.listId) {
          where = sql`${where} and b.id in (
            select li.book_id from book_list_items li
              join book_lists l on l.id = li.list_id
             where li.list_id = ${q.listId} and l.owner_id = ${owner}
          )`;
        }
        if (q.q && q.q.trim()) {
          const pat = likePattern(q.q.trim());
          where = sql`${where} and (b.title like ${pat} escape '\\' or b.author like ${pat} escape '\\')`;
        }
        if (cur) {
          where = sql`${where} and (b.title > ${cur.title} or (b.title = ${cur.title} and b.id > ${cur.id}))`;
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
           order by b.title asc, b.id asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const next = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        return {
          items: rows.map(toBook),
          nextCursor: next ? encodeCursor(next.title, next.id) : null,
        };
      },
    );

    app.get(
      '/api/v1/book/item',
      secured('book:read', {
        schema: {
          operationId: 'bookItem',
          tags: TAG,
          summary: '书籍详情（含当前用户收藏与进度）',
          querystring: h.ref('BookIdQuery'),
          response: { 200: h.ref('BookItem'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const owner = req.user?.sub || '';
        const row = q.id ? await h.loadBook(q.id, owner) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });
        return toBook(row);
      },
    );

    app.get(
      '/api/v1/book/stats',
      secured('book:read', {
        schema: {
          operationId: 'bookStats',
          tags: TAG,
          summary: '书库 / 藏书 / 当前用户收藏数',
          response: { 200: h.ref('BookStatsResponse') },
        },
      }),
      async (req) => {
        const owner = req.user?.sub || '';
        const libs = await sql<{ n: number }>`
          select count(*) as n from book_libraries
        `.execute(k.db);
        const books = await sql<{ n: number }>`select count(*) as n from books`.execute(k.db);
        const favs = await sql<{ n: number }>`
          select count(*) as n from book_favorites where owner_id = ${owner}
        `.execute(k.db);
        return {
          libraries: Number(libs.rows[0]?.n) || 0,
          books: Number(books.rows[0]?.n) || 0,
          favorites: Number(favs.rows[0]?.n) || 0,
        };
      },
    );

}
