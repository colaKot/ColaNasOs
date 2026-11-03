import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, PhotoItemRow, toItem, encodeCursor, decodeCursor, newId } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';

/** 集合：把照片聚成一组（按用户隔离），比相册更轻，不要求命名冲突校验 */
export async function registerPhotoCollections(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  const uidOf = (req: { user?: { sub?: string } }) => String(req.user?.sub || '');

  app.get(
    '/api/v1/photo/collections',
    secured('photo:read', {
      schema: {
        operationId: 'photoCollectionList',
        tags: TAG,
        summary: '集合列表',
        response: { 200: h.ref('PhotoCollectionListResponse') },
      },
    }),
    async (req) => {
      const rows = (
        await sql<{
          id: string;
          name: string;
          created_at: number;
          items: number;
          cover_path: string | null;
        }>`
          select c.id, c.name, c.created_at,
                 (select count(*) from photo_collection_items ci where ci.collection_id = c.id) as items,
                 (select i.rel_path from photo_collection_items ci
                    join photo_items i on i.id = ci.item_id
                   where ci.collection_id = c.id
                   order by ci.added_at desc limit 1) as cover_path
            from photo_collections c
           where c.owner_id = ${uidOf(req as any)}
           order by c.created_at desc, c.id
           limit 500
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          name: r.name,
          items: Number(r.items) || 0,
          coverPath: r.cover_path,
          createdAt: Number(r.created_at),
        })),
      };
    },
  );

  app.post(
    '/api/v1/photo/collections',
    secured('photo:write', {
      schema: {
        operationId: 'photoCollectionCreate',
        tags: TAG,
        summary: '新建集合',
        body: h.ref('PhotoCollectionCreateBody'),
        response: { 200: h.ref('PhotoCollection'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { name?: string };
      const name = (body.name || '').trim();
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      const id = newId();
      const now = Math.floor(Date.now() / 1000);
      await sql`
        insert into photo_collections (id, name, owner_id, created_at, updated_at)
        values (${id}, ${name}, ${uidOf(req as any)}, ${now}, ${now})
      `.execute(k.db);
      return { id, name, items: 0, coverPath: null, createdAt: now };
    },
  );

  app.post(
    '/api/v1/photo/collections/delete',
    secured('photo:write', {
      schema: {
        operationId: 'photoCollectionDelete',
        tags: TAG,
        summary: '删除集合（只删集合关系，不动照片）',
        body: h.ref('PhotoCollectionDeleteBody'),
        response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string };
      const found = await sql<{ id: string }>`
        select id from photo_collections where id = ${body.id || ''} and owner_id = ${uidOf(req as any)}
      `.execute(k.db);
      if (found.rows.length === 0) {
        return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      }
      await k.db.transaction().execute(async (trx: any) => {
        await sql`delete from photo_collection_items where collection_id = ${body.id}`.execute(trx);
        await sql`delete from photo_collections where id = ${body.id}`.execute(trx);
      });
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/photo/collections/add',
    secured('photo:write', {
      schema: {
        operationId: 'photoCollectionAdd',
        tags: TAG,
        summary: '把照片加入集合',
        body: h.ref('PhotoCollectionMembersBody'),
        response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { collectionId?: string; itemIds?: string[] };
      const owner = uidOf(req as any);
      const found = await sql<{ id: string }>`
        select id from photo_collections where id = ${body.collectionId || ''} and owner_id = ${owner}
      `.execute(k.db);
      if (found.rows.length === 0) {
        return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      }
      const now = Math.floor(Date.now() / 1000);
      for (const itemId of (body.itemIds || []).slice(0, 500)) {
        // 只允许加入自己库里的照片
        const ok = await sql<{ id: string }>`
          select id from photo_items
           where id = ${itemId}
             and library_id in (select id from photo_libraries where owner_id = ${owner})
        `.execute(k.db);
        if (ok.rows.length === 0) continue;
        await sql`
          insert into photo_collection_items (collection_id, item_id, added_at)
          values (${body.collectionId}, ${itemId}, ${now})
          on conflict (collection_id, item_id) do nothing
        `.execute(k.db);
      }
      await sql`update photo_collections set updated_at = ${now} where id = ${body.collectionId}`.execute(
        k.db,
      );
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/photo/collections/remove',
    secured('photo:write', {
      schema: {
        operationId: 'photoCollectionRemove',
        tags: TAG,
        summary: '把照片移出集合',
        body: h.ref('PhotoCollectionMembersBody'),
        response: { 200: h.ref('PhotoOkResponse') },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { collectionId?: string; itemIds?: string[] };
      const owner = uidOf(req as any);
      const ids = (body.itemIds || []).slice(0, 500);
      if (ids.length > 0) {
        await sql`
          delete from photo_collection_items
           where collection_id = ${body.collectionId || ''}
             and item_id in (${sql.join(
               ids.map((id) => sql`${id}`),
               sql`, `,
             )})
             and collection_id in (select id from photo_collections where owner_id = ${owner})
        `.execute(k.db);
      }
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/photo/collections/items',
    secured('photo:read', {
      schema: {
        operationId: 'photoCollectionItems',
        tags: TAG,
        summary: '集合里的照片（按加入时间倒序）',
        querystring: h.ref('PhotoCollectionItemsQuery'),
        response: { 200: h.ref('PhotoTimelineResponse') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { collectionId?: string; cursor?: string; limit?: number };
      const limit = h.limitOf(q.limit, 60, 200);
      const offset = Math.max(0, Number(q.cursor) || 0);
      const rows = (
        await sql<PhotoItemRow & { added_at: number }>`
          select i.*, ci.added_at
            from photo_collection_items ci
            join photo_items i on i.id = ci.item_id
           where ci.collection_id = ${q.collectionId || ''}
             and ci.collection_id in (select id from photo_collections where owner_id = ${uidOf(req as any)})
           order by ci.added_at desc, i.id
           limit ${limit + 1} offset ${offset}
        `.execute(k.db)
      ).rows;
      const page = rows.slice(0, limit);
      return {
        items: page.map(toItem),
        nextCursor: rows.length > limit ? String(offset + limit) : null,
      };
    },
  );
}