import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { TAG, BookRow, toBook } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 阅读历史（按用户隔离，每本书只保留最近一次） */
export async function registerBookHistory(
  app: FastifyInstance,
  k: KernelApi,
  h: BookHelpers,
): Promise<void> {
  app.get(
    '/api/v1/book/history',
    secured('book:read', {
      schema: {
        operationId: 'bookHistory',
        tags: TAG,
        summary: '阅读历史（最近读的在最前）',
        querystring: h.ref('BookHistoryQuery'),
        response: { 200: h.ref('BookListResponse') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { limit?: number };
      const owner = req.user?.sub || '';
      const limit = h.limitOf(q.limit, 60, 200);
      const res = await sql<BookRow>`
        select b.*,
               case when f.book_id is null then 0 else 1 end as favorite,
               p.percent as progress_percent,
               case when a.book_id is null then 0 else 1 end as archived,
               hist.read_at as read_at
          from book_history hist
          join books b on b.id = hist.book_id
          left join book_favorites f on f.book_id = b.id and f.owner_id = ${owner}
          left join book_progress p on p.book_id = b.id and p.owner_id = ${owner}
          left join book_archived a on a.book_id = b.id and a.owner_id = ${owner}
         where hist.owner_id = ${owner}
         order by hist.read_at desc
         limit ${limit}
      `.execute(k.db);
      return { items: res.rows.map(toBook), nextCursor: null };
    },
  );

  app.post(
    '/api/v1/book/history/clear',
    secured('book:write', {
      schema: {
        operationId: 'bookHistoryClear',
        tags: TAG,
        summary: '清空当前用户的阅读历史（不影响阅读进度）',
        response: { 200: h.ref('BookOkResponse') },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      await sql`delete from book_history where owner_id = ${owner}`.execute(k.db);
      return { ok: true };
    },
  );
}
