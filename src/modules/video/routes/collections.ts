import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { newId, TAG, toItem, type MediaRow } from '../util';
import { pathWhere, visibilityOf } from '../../files/visibility';
import { seriesCoverIdSql, seriesPosterIdSql } from '../series-sql';
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

/** 回读完整条目（封面用解析后的值，前端不必自己再算一次 fallback） */
async function readCollection(
  k: KernelApi,
  id: string,
  uid: string,
): Promise<CollectionRow | null> {
  return (
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
    ).rows[0] ?? null
  );
}

function collectionOut(r: CollectionRow) {
  return {
    id: r.id,
    name: r.name,
    kind: r.kind,
    items: Number(r.items) || 0,
    createdAt: Number(r.created_at),
    updatedAt: Number(r.updated_at),
    description: r.description ?? null,
    coverItemId: r.cover_resolved ?? null,
    sortOrder: Number(r.sort_order) || 0,
  };
}

/**
 * 合集条目卡片。
 *
 * 电视剧按剧聚合：一部剧只出一张卡（`seriesInfo` 交给前端走剧详情），
 * 与剧库列表 / 智能合集用同一套 `seriesCoverIdSql` 口径。GET 与「加入 / 移出」
 * 的返回都必须走这里，否则同一个合集两次请求返回的条目形态不一致。
 */
async function collectionItemCards(
  k: KernelApi,
  col: CollectionRow,
  user: unknown,
): Promise<Record<string, unknown>[]> {
  const uid = String((user as { sub?: string } | null)?.sub || '');
  const vis = visibilityOf(k.config, user);
  const cardCond = sql`i.collection_id = ${col.id} and ${pathWhere(vis, 'v.rel_path')}`;
  const seriesRows = (
    await sql<{
      library_id: string;
      name: string;
      seasons: number;
      episodes: number;
      watched_episodes: number;
      cover_id: string | null;
      poster_id: string | null;
      at: number;
    }>`
      select v.library_id, v.series as name,
             (select count(distinct coalesce(t.season, 0)) from video_items t
               where t.library_id = v.library_id and t.series = v.series
                 and t.media_type = 'video') as seasons,
             (select count(*) from video_items t
               where t.library_id = v.library_id and t.series = v.series
                 and t.media_type = 'video') as episodes,
             (select count(*) from video_items t
                join video_watch w on w.item_id = t.id and w.owner_id = ${uid}
               where t.library_id = v.library_id and t.series = v.series
                 and t.media_type = 'video') as watched_episodes,
             ${seriesCoverIdSql('v')} as cover_id,
             ${seriesPosterIdSql('v')} as poster_id,
             max(i.added_at) as at
        from video_collection_items i
        join video_items v on v.id = i.item_id
       where ${cardCond}
         and v.series is not null and v.series <> ''
       group by v.library_id, v.series
       order by at desc
       limit 2000
    `.execute(k.db)
  ).rows;

  // 卡片上的年份 / 简介 / 评分用「封面那一集」的元数据（剧级字段本来就一样）
  const coverIds = [
    ...new Set(seriesRows.map((r) => r.cover_id).filter((x): x is string => !!x)),
  ];
  const coverRows = coverIds.length
    ? (
        await sql<MediaRow>`
          select v.*, exists(select 1 from video_watch w
                              where w.item_id = v.id and w.owner_id = ${uid}) as watched
            from video_items v
           where v.id in (${sql.join(coverIds.map((id) => sql`${id}`), sql`, `)})
        `.execute(k.db)
      ).rows
    : [];
  const coverById = new Map(coverRows.map((r) => [r.id, r]));

  const movies = (
    await sql<MediaRow>`
      select v.*, exists(select 1 from video_watch w
                          where w.item_id = v.id and w.owner_id = ${uid}) as watched,
             i.added_at as collection_added_at
        from video_collection_items i
        join video_items v on v.id = i.item_id
       where ${cardCond}
         and (v.series is null or v.series = '')
       order by i.added_at desc, v.id asc
       limit 2000
    `.execute(k.db)
  ).rows;

  const merged: Array<{ at: number; item: Record<string, unknown> }> = [
    ...movies.map((r) => ({
      at: Number((r as MediaRow & { collection_added_at?: number }).collection_added_at) || 0,
      item: toItem(r) as never,
    })),
    ...seriesRows.flatMap((g) => {
      const row = g.cover_id ? coverById.get(g.cover_id) : undefined;
      if (!row) return [];
      return [
        {
          at: Number(g.at) || 0,
          item: {
            ...toItem(row),
            // 这张卡代表整部剧：标题用剧名，季 / 集号不外露
            title: g.name,
            season: null,
            episode: null,
            seriesInfo: {
              name: g.name,
              seasons: Number(g.seasons) || 1,
              episodes: Number(g.episodes) || 0,
              watchedEpisodes: Number(g.watched_episodes) || 0,
              coverId: g.cover_id,
              posterId: g.poster_id,
            },
          } as never,
        },
      ];
    }),
  ];
  merged.sort((a, b) => b.at - a.at);
  return merged.slice(0, 2000).map((x) => x.item);
}

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
      // 条目数 / 封面也要按授权目录算：否则列表显示「12 部」，点进去只剩 3 部。
      const cond = pathWhere(visibilityOf(k.config, req.user), 'v.rel_path');
      const rows = (
        await sql<CollectionRow>`
          select c.*,
                 -- 条目数按「剧聚合」口径：一部剧只算 1 条，否则集合卡显示 40 条、
                 -- 点进去只有 1 张封面（与智能合集 / 剧库列表保持一致）。
                 (
                   (select count(*) from (
                      select 1
                        from video_collection_items i
                        join video_items v on v.id = i.item_id
                       where i.collection_id = c.id and ${cond}
                         and v.series is not null and v.series <> ''
                       group by v.library_id, v.series
                   )) +
                   (select count(*)
                      from video_collection_items i
                      join video_items v on v.id = i.item_id
                     where i.collection_id = c.id and ${cond}
                       and (v.series is null or v.series = ''))
                 ) as items,
                 coalesce(
                   (select i.item_id from video_collection_items i
                      join video_items v on v.id = i.item_id
                     where i.collection_id = c.id and i.item_id = c.cover_item_id and ${cond}),
                   (select i.item_id from video_collection_items i
                      join video_items v on v.id = i.item_id
                     where i.collection_id = c.id and ${cond}
                     order by i.added_at, i.item_id limit 1)
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
        const updated = await readCollection(k, existing.id, uid);
        return updated ? collectionOut(updated) : collectionOut(existing);
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
      const created = await readCollection(k, id, uid);
      return created
        ? collectionOut(created)
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

  app.post(
    '/api/v1/video/collections/merge',
    secured('video:write', {
      schema: {
        operationId: 'videoCollectionMerge',
        tags: TAG,
        summary: '合并两个合集（来源的影片并入目标，来源合集被删除）',
        body: Type.Object({
          sourceId: Type.String({ minLength: 1, description: '被合并（将被删除）的合集' }),
          targetId: Type.String({ minLength: 1, description: '接收影片并保留的合集' }),
        }),
        response: {
          200: h.ref('VideoCollection'),
          400: h.ref('VideoErrorResponse'),
          404: h.ref('VideoErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { sourceId?: string; targetId?: string };
      const sourceId = String(body.sourceId || '');
      const targetId = String(body.targetId || '');
      if (!sourceId || !targetId) {
        return reply.code(400).send({ error: Err.badRequest, message: 'sourceId/targetId required' });
      }
      if (sourceId === targetId) {
        return reply.code(400).send({ error: Err.badRequest, message: 'cannot merge into itself' });
      }
      const uid = uidOf(req);
      const found = (
        await sql<CollectionRow>`
          select * from video_collections
           where id in (${sourceId}, ${targetId}) and uid = ${uid}
        `.execute(k.db)
      ).rows;
      const source = found.find((r) => r.id === sourceId);
      const target = found.find((r) => r.id === targetId);
      if (!source || !target) {
        return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
      }

      const ts = now();
      await k.db.transaction().execute(async (trx: any) => {
        // insert or ignore：两边都有的影片不会重复；保留目标合集原有的加入时间
        await sql`
          insert or ignore into video_collection_items (collection_id, item_id, added_at)
          select ${targetId}, item_id, added_at
            from video_collection_items where collection_id = ${sourceId}
        `.execute(trx);
        await sql`delete from video_collection_items where collection_id = ${sourceId}`.execute(trx);
        await sql`delete from video_collections where id = ${sourceId} and uid = ${uid}`.execute(trx);
        await sql`
          update video_collections set updated_at = ${ts} where id = ${targetId} and uid = ${uid}
        `.execute(trx);
      });

      const updated = await readCollection(k, targetId, uid);
      return updated
        ? collectionOut(updated)
        : reply.code(404).send({ error: Err.notFound, message: 'collection not found' });
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
      return {
        id: col.id,
        name: col.name,
        items: await collectionItemCards(k, col, req.user),
      };
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
      return {
        id: col.id,
        name: col.name,
        items: await collectionItemCards(k, col, req.user),
      };
    },
  );
}
