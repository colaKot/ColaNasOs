import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { newId, TAG, toItem, type MediaRow } from '../util';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

interface CollectionRow {
  id: string;
  uid: string;
  name: string;
  kind: string;
  created_at: number;
  updated_at: number;
  items?: number;
  description?: string | null;
  cover_item_id?: string | null;
  sort_order?: number | null;
  /** 解析后的封面：手选优先，否则最早加入的条目 */
  cover_resolved?: string | null;
}

const uidOf = (req: FastifyRequest) => String(req.user?.sub || '');
const now = () => Math.floor(Date.now() / 1000);

/** 影视自定义合集（每用户；条目按加入时间倒序） */
export async function registerVideoCollections(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/video/collections',
    secured('video:read', {
      schema: {
        operationId: 'videoCollectionList',
        tags: TAG,
        summary: '我的合集（按更新时间倒序，带条目数）',
        response: { 200: h.ref('VideoCollectionListResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const rows = (
        await sql<CollectionRow>`
          select c.*,
                 (select count(*) from video_collection_items i where i.collection_id = c.id) as items,
                 coalesce(
                   (select i.item_id from video_collection_items i
                     where i.collection_id = c.id and i.item_id = c.cover_item_id),
                   (select i.item_id from video_collection_items i
                     where i.collection_id = c.id order by i.added_at, i.item_id limit 1)
                 ) as cover_resolved
            from video_collections c
           where c.uid = ${uidOf(req)}
           order by c.sort_order asc, c.updated_at desc, c.id asc
           limit 200
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          name: r.name,
          kind: r.kind,
          items: Number(r.items) || 0,
          createdAt: Number(r.created_at),
          updatedAt: Number(r.updated_at),
          description: r.description ?? null,
          coverItemId: r.cover_resolved ?? null,
          sortOrder: Number(r.sort_order) || 0,
        })),
      };
    },
  );

  app.post(
    '/api/v1/video/collections/upsert',
    secured('video:write', {
      schema: {
        operationId: 'videoCollectionUpsert',
        tags: TAG,
        summary: '创建 / 编辑合集（名称 / 简介 / 封面 / 顺序）',
        body: h.ref('VideoCollectionUpsertBody'),
        response: { 200: h.ref('VideoCollection'), 400: h.ref('VideoErrorResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as {
        id?: string;
        name?: string;
        kind?: string;
        description?: string | null;
        coverItemId?: string | null;
        sortOrder?: number;
      };
      const name = String(body.name || '').trim();
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      const uid = uidOf(req);
      const ts = now();

      /** 回读完整条目（封面用解析后的值，前端不必自己再算一次 fallback） */
      const readBack = async (id: string): Promise<CollectionRow | null> =>
        (
          await sql<CollectionRow>`
            select c.*,
                   (select count(*) from video_collection_items i where i.collection_id = c.id) as items,
                   coalesce(
                     (select i.item_id from video_collection_items i
                       where i.collection_id = c.id and i.item_id = c.cover_item_id),
                     (select i.item_id from video_collection_items i
                       where i.collection_id = c.id order by i.added_at, i.item_id limit 1)
                   ) as cover_resolved
              from video_collections c
             where c.id = ${id} and c.uid = ${uid}
          `.execute(k.db)
        ).rows[0] ?? null;

      const out = (r: CollectionRow) => ({
        id: r.id,
        name: r.name,
        kind: r.kind,
        items: Number(r.items) || 0,
        createdAt: Number(r.created_at),
        updatedAt: Number(r.updated_at),
        description: r.description ?? null,
        coverItemId: r.cover_resolved ?? null,
        sortOrder: Number(r.sort_order) || 0,
      });

      if (body.id) {
        const existing = (
          await sql<CollectionRow>`
            select * from video_collections where id = ${body.id} and uid = ${uid}
          `.execute(k.db)
        ).rows[0];
        if (!existing) {
          return reply.code(400).send({ error: Err.badRequest, message: 'collection not found' });
        }
        await sql`
          update video_collections set name = ${name}, updated_at = ${ts}
           where id = ${existing.id} and uid = ${uid}
        `.execute(k.db);
        if (body.description !== undefined) {
          const desc = body.description == null ? null : String(body.description).trim() || null;
          await sql`update video_collections set description = ${desc} where id = ${existing.id}`.execute(
            k.db,
          );
        }
        if (body.coverItemId !== undefined) {
          const coverId = body.coverItemId == null ? null : String(body.coverItemId);
          if (coverId) {
            // 封面必须是合集成员，否则会出现「封面是别的合集里的片子」
            const member = (
              await sql<{ n: number }>`
                select count(*) as n from video_collection_items
                 where collection_id = ${existing.id} and item_id = ${coverId}
              `.execute(k.db)
            ).rows[0];
            if (Number(member?.n) === 0) {
              return reply
                .code(400)
                .send({ error: Err.badRequest, message: 'cover must be a member' });
            }
          }
          await sql`update video_collections set cover_item_id = ${coverId} where id = ${existing.id}`.execute(
            k.db,
          );
        }
        if (body.sortOrder !== undefined) {
          const order = Math.max(0, Math.min(Number(body.sortOrder) || 0, 99999));
          await sql`update video_collections set sort_order = ${order} where id = ${existing.id}`.execute(
            k.db,
          );
        }
        const updated = await readBack(existing.id);
        return updated ? out(updated) : out(existing);
      }

      const id = newId();
      const kind = String(body.kind || 'custom');
      const desc =
        body.description == null ? null : String(body.description).trim() || null;
      const sortOrder = Math.max(0, Math.min(Number(body.sortOrder) || 0, 99999));
      await sql`
        insert into video_collections
          (id, uid, name, kind, description, sort_order, created_at, updated_at)
        values (${id}, ${uid}, ${name}, ${kind}, ${desc}, ${sortOrder}, ${ts}, ${ts})
      `.execute(k.db);
      const created = await readBack(id);
      return created
        ? out(created)
        : {
            id,
            name,
            kind,
            items: 0,
            createdAt: ts,
            updatedAt: ts,
            description: desc,
            coverItemId: null,
            sortOrder,
          };
    },
  );

  app.post(
    '/api/v1/video/collections/delete',
    secured('video:write', {
      schema: {
        operationId: 'videoCollectionDelete',
        tags: TAG,
        summary: '删除合集（只删合集与其条目关系，不删影片）',
        body: h.ref('VideoCollectionIdBody'),
        response: { 200: h.ref('VideoOkResponse'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string };
      if (!body.id) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      const uid = uidOf(req);
      const existing = (
        await sql<CollectionRow>`
          select id from video_collections where id = ${body.id} and uid = ${uid}
        `.execute(k.db)
      ).rows[0];
      if (!existing) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      await k.db.transaction().execute(async (trx: any) => {
        await sql`delete from video_collection_items where collection_id = ${body.id}`.execute(trx);
        await sql`delete from video_collections where id = ${body.id} and uid = ${uid}`.execute(trx);
      });
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/video/collections/items',
    secured('video:read', {
      schema: {
        operationId: 'videoCollectionItems',
        tags: TAG,
        summary: '合集内影片（按加入时间倒序）',
        querystring: h.ref('VideoCollectionIdBody'),
        response: { 200: h.ref('VideoCollectionItemsResponse'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const q = (req.query || {}) as { id?: string };
      const uid = uidOf(req);
      const col = q.id
        ? (
            await sql<CollectionRow>`
              select * from video_collections where id = ${q.id} and uid = ${uid}
            `.execute(k.db)
          ).rows[0]
        : null;
      if (!col) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      const rows = (
        await sql<MediaRow>`
          select v.*
            from video_collection_items i
            join video_items v on v.id = i.item_id
           where i.collection_id = ${col.id}
           order by i.added_at desc, v.id asc
           limit 2000
        `.execute(k.db)
      ).rows;
      return { id: col.id, name: col.name, items: rows.map(toItem) };
    },
  );

  app.post(
    '/api/v1/video/collections/items',
    secured('video:write', {
      schema: {
        operationId: 'videoCollectionItemsSet',
        tags: TAG,
        summary: '批量加入 / 移出合集',
        body: h.ref('VideoCollectionItemsBody'),
        response: { 200: h.ref('VideoCollectionItemsResponse'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string; itemIds?: string[]; action?: string };
      const uid = uidOf(req);
      const col = body.id
        ? (
            await sql<CollectionRow>`
              select * from video_collections where id = ${body.id} and uid = ${uid}
            `.execute(k.db)
          ).rows[0]
        : null;
      if (!col) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      const ids = (body.itemIds ?? []).map((x) => String(x)).filter(Boolean);
      const ts = now();
      await k.db.transaction().execute(async (trx: any) => {
        for (const itemId of ids) {
          if (body.action === 'remove') {
            await sql`
              delete from video_collection_items
               where collection_id = ${col.id} and item_id = ${itemId}
            `.execute(trx);
          } else {
            await sql`
              insert into video_collection_items (collection_id, item_id, added_at)
              values (${col.id}, ${itemId}, ${ts})
              on conflict(collection_id, item_id) do nothing
            `.execute(trx);
          }
        }
        await sql`update video_collections set updated_at = ${ts} where id = ${col.id}`.execute(trx);
      });
      const rows = (
        await sql<MediaRow>`
          select v.*
            from video_collection_items i
            join video_items v on v.id = i.item_id
           where i.collection_id = ${col.id}
           order by i.added_at desc, v.id asc
           limit 2000
        `.execute(k.db)
      ).rows;
      return { id: col.id, name: col.name, items: rows.map(toItem) };
    },
  );
}
