import { sql } from 'kysely';
import path from 'node:path';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot } from '../../files/fs-root';
import { TAG, BookRow, newId, toBook } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

interface CollectionRow {
  id: string;
  owner_id: string;
  name: string;
  paths: string;
  created_at: number;
  updated_at: number;
}

/**
 * 用户自建图书合集：按目录整理（和音乐合集同一模型，按 owner 隔离）。
 *
 * 目录用「files 根内相对路径」匹配：books.rel_path 是相对路径，
 * 选择器给的是绝对路径，所以先把绝对路径转成相对（能落在 files 根内才有效）。
 */
export async function registerBookUserCollections(
  app: FastifyInstance,
  k: KernelApi,
  h: BookHelpers,
): Promise<void> {
  const parsePaths = (raw: string): string[] => {
    try {
      const v = JSON.parse(raw || '[]');
      return Array.isArray(v) ? v.map((x) => String(x)) : [];
    } catch {
      return [];
    }
  };

  const rootPosix = filesRoot().split(path.sep).join('/').replace(/\/$/, '').toLowerCase();

  const normalize = (p: string): string => {
    const posix = p.trim().replace(/\\/g, '/');
    const low = posix.toLowerCase();
    if (low.startsWith(`${rootPosix}/`)) return posix.slice(rootPosix.length + 1);
    return posix.replace(/^\/+/, '');
  };

  const likeOf = (p: string) => `${normalize(p).replace(/\/$/, '')}/%`;

  const anyLike = (col: 'rel_path' | 'b.rel_path', likes: string[]) =>
    likes.reduce(
      (acc: any, l: string) => sql`${acc} or ${sql.ref(col)} like ${l}`,
      sql`1 = 0` as any,
    );

  const decorate = async (rows: CollectionRow[]) => {
    const out = [];
    for (const r of rows) {
      const paths = parsePaths(r.paths);
      const likes = paths.map(likeOf);
      if (likes.length === 0) {
        out.push({ ...r, paths, books: 0, cover: null as string | null });
        continue;
      }
      const cond = anyLike('rel_path', likes);
      const inner = anyLike('rel_path', likes);
      const stat = await sql<{ n: number; cover: string | null }>`
        select count(*) as n,
               (select id from books b2
                 where (${inner}) and b2.has_cover = 1
                 order by b2.created_at desc limit 1) as cover
          from books b
         where ${cond}
      `.execute(k.db);
      out.push({
        ...r,
        paths,
        books: Number(stat.rows[0]?.n) || 0,
        cover: stat.rows[0]?.cover ?? null,
      });
    }
    return out.map((c) => ({
      id: c.id,
      name: c.name,
      paths: c.paths,
      books: c.books,
      coverId: c.cover,
      createdAt: c.created_at,
      updatedAt: c.updated_at,
    }));
  };

  app.get(
    '/api/v1/book/user-collections',
    secured('book:read', {
      schema: {
        operationId: 'bookUserCollectionList',
        tags: TAG,
        summary: '当前用户的图书合集（含书数与封面）',
        response: { 200: h.ref('BookUserCollectionListResponse') },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const rows = await sql<CollectionRow>`
        select * from book_user_collections
         where owner_id = ${owner}
         order by created_at desc, id
         limit 200
      `.execute(k.db);
      return { items: await decorate(rows.rows) };
    },
  );

  app.post(
    '/api/v1/book/user-collections',
    secured('book:write', {
      schema: {
        operationId: 'bookUserCollectionCreate',
        tags: TAG,
        summary: '新建图书合集',
        body: h.ref('BookUserCollectionBody'),
        response: { 200: h.ref('BookUserCollection'), 400: h.ref('BookErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { name?: string; paths?: string[] };
      const name = (body.name || '').trim();
      const paths = (body.paths || []).map((p) => p.trim()).filter(Boolean);
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      if (paths.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'paths required' });
      }

      const owner = req.user?.sub || '';
      const now = Math.floor(Date.now() / 1000);
      const id = newId();
      await sql`
        insert into book_user_collections (id, owner_id, name, paths, created_at, updated_at)
        values (${id}, ${owner}, ${name}, ${JSON.stringify(paths)}, ${now}, ${now})
      `.execute(k.db);
      return { id, name, paths, books: 0, coverId: null, createdAt: now, updatedAt: now };
    },
  );

  app.post(
    '/api/v1/book/user-collections/update',
    secured('book:write', {
      schema: {
        operationId: 'bookUserCollectionUpdate',
        tags: TAG,
        summary: '改名 / 换目录',
        body: h.ref('BookUserCollectionUpdateBody'),
        response: { 200: h.ref('BookUserCollection'), 404: h.ref('BookErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string; name?: string; paths?: string[] };
      const owner = req.user?.sub || '';
      const row = (
        await sql<CollectionRow>`
          select * from book_user_collections
           where id = ${body.id || ''} and owner_id = ${owner}
        `.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });

      const name = body.name !== undefined ? body.name.trim() || row.name : row.name;
      const paths =
        body.paths !== undefined
          ? body.paths.map((p) => p.trim()).filter(Boolean)
          : parsePaths(row.paths);
      if (paths.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'paths required' });
      }
      const now = Math.floor(Date.now() / 1000);
      await sql`
        update book_user_collections
           set name = ${name}, paths = ${JSON.stringify(paths)}, updated_at = ${now}
         where id = ${row.id}
      `.execute(k.db);
      const [item] = await decorate([{ ...row, name, paths: JSON.stringify(paths), updated_at: now }]);
      return item;
    },
  );

  app.post(
    '/api/v1/book/user-collections/remove',
    secured('book:write', {
      schema: {
        operationId: 'bookUserCollectionRemove',
        tags: TAG,
        summary: '删除合集（不动书与索引）',
        body: h.ref('BookLibraryRemoveBody'),
        response: { 200: h.ref('BookOkResponse') },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { id?: string };
      const owner = req.user?.sub || '';
      await sql`
        delete from book_user_collections where id = ${body.id || ''} and owner_id = ${owner}
      `.execute(k.db);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/book/user-collections/items',
    secured('book:read', {
      schema: {
        operationId: 'bookUserCollectionItems',
        tags: TAG,
        summary: '合集里的书',
        querystring: h.ref('BookUserCollectionItemsQuery'),
        response: { 200: h.ref('BookListResponse'), 404: h.ref('BookErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { id?: string; limit?: number };
      const owner = req.user?.sub || '';
      const row = (
        await sql<CollectionRow>`
          select * from book_user_collections
           where id = ${q.id || ''} and owner_id = ${owner}
        `.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });

      const likes = parsePaths(row.paths).map(likeOf);
      if (likes.length === 0) return { items: [], nextCursor: null };
      const limit = h.limitOf(q.limit, 200, 500);
      const cond = anyLike('b.rel_path', likes);
      const res = await sql<BookRow>`
        select b.*,
               case when f.book_id is null then 0 else 1 end as favorite,
               p.percent as progress_percent,
               case when a.book_id is null then 0 else 1 end as archived
          from books b
          left join book_favorites f on f.book_id = b.id and f.owner_id = ${owner}
          left join book_progress p on p.book_id = b.id and p.owner_id = ${owner}
          left join book_archived a on a.book_id = b.id and a.owner_id = ${owner}
         where ${cond}
         order by b.title asc, b.id asc
         limit ${limit}
      `.execute(k.db);
      return { items: res.rows.map(toBook), nextCursor: null };
    },
  );
}
