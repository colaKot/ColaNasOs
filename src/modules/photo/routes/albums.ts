import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, PhotoItemRow, AlbumRow, newId, toItem, encodeCursor, decodeCursor, albumFrom } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';

/** 相册 */
export async function registerPhotoAlbums(app: FastifyInstance, k: KernelApi, h: PhotoHelpers): Promise<void> {
    // ---------------------------------------------------------------- 相册

    app.post(
      '/api/v1/photo/albums',
      secured('photo:write', {
        schema: {
          operationId: 'photoAlbumCreate',
          tags: TAG,
          summary: '新建相册（可按 id 批量加入）',
          body: h.ref('PhotoAlbumCreateBody'),
          response: { 200: h.ref('PhotoAlbum'), 400: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string; itemIds?: string[] };
        const name = (body.name || '').trim();
        if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });

        const owner = req.user?.sub || '';
        const now = Math.floor(Date.now() / 1000);
        const id = newId();

        await k.db.transaction().execute(async (trx: any) => {
          await sql`
            insert into photo_albums (id, name, owner_id, created_at, updated_at)
            values (${id}, ${name}, ${owner}, ${now}, ${now})
          `.execute(trx);

          for (const itemId of body.itemIds || []) {
            await sql`
              insert or ignore into photo_album_items (album_id, item_id, added_at)
              values (${id}, ${itemId}, ${now})
            `.execute(trx);
          }
        });

        const album = await h.loadAlbum(id, owner);
        return album ? albumFrom(album) : { id, name, items: 0, coverPath: null, createdAt: now };
      },
    );

    app.get(
      '/api/v1/photo/albums',
      secured('photo:read', {
        schema: {
          operationId: 'photoAlbumList',
          tags: TAG,
          summary: '当前用户的相册列表',
          response: { 200: h.ref('PhotoAlbumListResponse') },
        },
      }),
      async (req) => {
        const owner = req.user?.sub || '';
        const res = await sql<AlbumRow>`
          select a.id, a.name, a.owner_id, a.created_at,
            a.description, a.cover_item_id, a.sort_order,
            (select count(*) from photo_album_items m where m.album_id = a.id) as items,
            coalesce(
              (select i.rel_path from photo_album_items m
                 join photo_items i on i.id = m.item_id
                where m.album_id = a.id and i.id = a.cover_item_id),
              (select i.rel_path from photo_album_items m
                 join photo_items i on i.id = m.item_id
                where m.album_id = a.id order by m.added_at, i.id limit 1)
            ) as cover_path
            from photo_albums a
           where a.owner_id = ${owner}
           order by a.sort_order asc, a.created_at desc, a.id
           limit 200
        `.execute(k.db);
        return { items: res.rows.map(albumFrom) };
      },
    );

    // 相册元数据编辑：改名 / 写简介 / 挑封面 / 手排顺序。
    // 只更新传入的字段（undefined 与 null 语义不同：undefined = 不动，null = 清空）。
    app.post(
      '/api/v1/photo/albums/update',
      secured('photo:write', {
        schema: {
          operationId: 'photoAlbumUpdate',
          tags: TAG,
          summary: '编辑相册（名称 / 简介 / 封面 / 排序）',
          body: h.ref('PhotoAlbumUpdateBody'),
          response: { 200: h.ref('PhotoAlbum'), 400: h.ref('PhotoErrorResponse'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          albumId?: string;
          name?: string;
          description?: string | null;
          coverItemId?: string | null;
          sortOrder?: number;
        };
        const owner = req.user?.sub || '';
        const album = body.albumId ? await h.loadAlbum(body.albumId, owner) : null;
        if (!album) return reply.code(404).send({ error: Err.notFound, message: 'album not found' });

        const now = Math.floor(Date.now() / 1000);
        if (body.name !== undefined) {
          const name = String(body.name).trim();
          if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
          await sql`update photo_albums set name = ${name} where id = ${album.id}`.execute(k.db);
        }
        if (body.description !== undefined) {
          const desc = body.description == null ? null : String(body.description).trim() || null;
          await sql`update photo_albums set description = ${desc} where id = ${album.id}`.execute(
            k.db,
          );
        }
        if (body.coverItemId !== undefined) {
          // 只接受本相册已有的成员，避免出现"封面是别的相册的照片"
          let coverId: string | null = body.coverItemId == null ? null : String(body.coverItemId);
          if (coverId) {
            const member = (
              await sql<{ n: number }>`
                select count(*) as n from photo_album_items
                 where album_id = ${album.id} and item_id = ${coverId}
              `.execute(k.db)
            ).rows[0];
            if (Number(member?.n) === 0) {
              return reply
                .code(400)
                .send({ error: Err.badRequest, message: 'cover must be a member of the album' });
            }
          } else {
            coverId = null;
          }
          await sql`update photo_albums set cover_item_id = ${coverId} where id = ${album.id}`.execute(
            k.db,
          );
        }
        if (body.sortOrder !== undefined) {
          const order = Math.max(0, Math.min(Number(body.sortOrder) || 0, 99999));
          await sql`update photo_albums set sort_order = ${order} where id = ${album.id}`.execute(
            k.db,
          );
        }
        await sql`update photo_albums set updated_at = ${now} where id = ${album.id}`.execute(k.db);

        const updated = await h.loadAlbum(album.id, owner);
        return updated ? albumFrom(updated) : albumFrom(album);
      },
    );

    app.get(
      '/api/v1/photo/albums/items',
      secured('photo:read', {
        schema: {
          operationId: 'photoAlbumItems',
          tags: TAG,
          summary: '相册成员（时间轴序）',
          querystring: h.ref('PhotoAlbumItemsQuery'),
          response: {
            200: h.ref('PhotoTimelineResponse'),
            400: h.ref('PhotoErrorResponse'),
            404: h.ref('PhotoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { albumId?: string; cursor?: string; limit?: number };
        const owner = req.user?.sub || '';
        const album = q.albumId ? await h.loadAlbum(q.albumId, owner) : null;
        if (!album) return reply.code(404).send({ error: Err.notFound, message: 'album not found' });

        const cur = decodeCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);

        let where = sql`m.album_id = ${album.id} and i.in_trash = 0`;
        if (cur) {
          where = sql`${where} and (i.taken_at < ${cur.takenAt} or (i.taken_at = ${cur.takenAt} and i.id > ${cur.id}))`;
        }

        const res = await sql<PhotoItemRow>`
          select i.* from photo_album_items m
            join photo_items i on i.id = m.item_id
           where ${where}
           order by i.taken_at desc, i.id asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const next = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        return {
          items: rows.map(toItem),
          nextCursor: next ? encodeCursor(next.taken_at, next.id) : null,
        };
      },
    );

    app.post(
      '/api/v1/photo/albums/add',
      secured('photo:write', {
        schema: {
          operationId: 'photoAlbumAdd',
          tags: TAG,
          summary: '向相册加入照片',
          body: h.ref('PhotoAlbumMembersBody'),
          response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { albumId?: string; itemIds?: string[] };
        const owner = req.user?.sub || '';
        const album = body.albumId ? await h.loadAlbum(body.albumId, owner) : null;
        if (!album) return reply.code(404).send({ error: Err.notFound, message: 'album not found' });

        const now = Math.floor(Date.now() / 1000);
        const ids = (body.itemIds || []).slice(0, 500);
        await k.db.transaction().execute(async (trx: any) => {
          for (const itemId of ids) {
            await sql`
              insert or ignore into photo_album_items (album_id, item_id, added_at)
              values (${album.id}, ${itemId}, ${now})
            `.execute(trx);
          }
          await sql`update photo_albums set updated_at = ${now} where id = ${album.id}`.execute(trx);
        });

        return { ok: true };
      },
    );

    app.post(
      '/api/v1/photo/albums/remove',
      secured('photo:write', {
        schema: {
          operationId: 'photoAlbumRemove',
          tags: TAG,
          summary: '从相册移出照片',
          body: h.ref('PhotoAlbumMembersBody'),
          response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { albumId?: string; itemIds?: string[] };
        const owner = req.user?.sub || '';
        const album = body.albumId ? await h.loadAlbum(body.albumId, owner) : null;
        if (!album) return reply.code(404).send({ error: Err.notFound, message: 'album not found' });

        const now = Math.floor(Date.now() / 1000);
        for (const itemId of (body.itemIds || []).slice(0, 500)) {
          await sql`
            delete from photo_album_items where album_id = ${album.id} and item_id = ${itemId}
          `.execute(k.db);
        }
        await sql`update photo_albums set updated_at = ${now} where id = ${album.id}`.execute(k.db);

        return { ok: true };
      },
    );

    app.post(
      '/api/v1/photo/albums/delete',
      secured('photo:write', {
        schema: {
          operationId: 'photoAlbumDelete',
          tags: TAG,
          summary: '删除相册',
          body: h.ref('PhotoAlbumDeleteBody'),
          response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { albumId?: string };
        const owner = req.user?.sub || '';
        const album = body.albumId ? await h.loadAlbum(body.albumId, owner) : null;
        if (!album) return reply.code(404).send({ error: Err.notFound, message: 'album not found' });

        await k.db.transaction().execute(async (trx: any) => {
          await sql`delete from photo_album_items where album_id = ${album.id}`.execute(trx);
          await sql`delete from photo_albums where id = ${album.id}`.execute(trx);
        });

        return { ok: true };
      },
    );
}
