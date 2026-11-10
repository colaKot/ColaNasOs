import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, TrackRow, PlaylistRow, newId, toTrack, toPlaylist } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/** 播放列表 */
export async function registerMusicPlaylists(app: FastifyInstance, k: KernelApi, h: MusicHelpers): Promise<void> {
    // ---------------------------------------------------------------- 播放列表

    app.get(
      '/api/v1/music/playlists',
      secured('music:read', {
        schema: {
          operationId: 'musicPlaylistList',
          tags: TAG,
          summary: '当前用户的歌单',
          response: { 200: h.ref('MusicPlaylistListResponse') },
        },
      }),
      async (req) => {
        const owner = req.user?.sub || '';
        const res = await sql<PlaylistRow>`
          select p.id, p.name, p.owner_id, p.created_at,
            (select count(*) from music_playlist_items i where i.playlist_id = p.id) as tracks,
            (select t.id from music_playlist_items i
               join music_tracks t on t.id = i.track_id
              where i.playlist_id = p.id and t.has_cover = 1
              order by i.position limit 1) as cover_track_id
            from music_playlists p
           where p.owner_id = ${owner}
           order by p.created_at desc, p.id
           limit 200
        `.execute(k.db);
        return { items: res.rows.map(toPlaylist) };
      },
    );

    app.post(
      '/api/v1/music/playlists',
      secured('music:write', {
        schema: {
          operationId: 'musicPlaylistCreate',
          tags: TAG,
          summary: '新建歌单（可按 id 批量加入）',
          body: h.ref('MusicPlaylistCreateBody'),
          response: { 200: h.ref('MusicPlaylist'), 400: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string; trackIds?: string[] };
        const name = (body.name || '').trim();
        if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });

        const owner = req.user?.sub || '';
        const now = Math.floor(Date.now() / 1000);
        const id = newId();

        await k.db.transaction().execute(async (trx: any) => {
          await sql`
            insert into music_playlists (id, name, owner_id, created_at, updated_at)
            values (${id}, ${name}, ${owner}, ${now}, ${now})
          `.execute(trx);

          let position = 0;
          for (const trackId of body.trackIds || []) {
            position += 1;
            await sql`
              insert or ignore into music_playlist_items (playlist_id, track_id, position, added_at)
              values (${id}, ${trackId}, ${position}, ${now})
            `.execute(trx);
          }
        });

        const playlist = await h.loadPlaylist(id, owner);
        return playlist
          ? toPlaylist(playlist)
          : { id, name, tracks: 0, coverTrackId: null, createdAt: now };
      },
    );

    app.get(
      '/api/v1/music/playlists/items',
      secured('music:read', {
        schema: {
          operationId: 'musicPlaylistItems',
          tags: TAG,
          summary: '歌单曲目（按加入顺序）',
          querystring: h.ref('MusicPlaylistItemsQuery'),
          response: { 200: h.ref('MusicListResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { playlistId?: string; limit?: number };
        const owner = req.user?.sub || '';
        const playlist = q.playlistId ? await h.loadPlaylist(q.playlistId, owner) : null;
        if (!playlist) return reply.code(404).send({ error: Err.notFound, message: 'playlist not found' });

        const limit = h.limitOf(q.limit, 200, 500);
        const res = await sql<TrackRow>`
          select t.* from music_playlist_items i
            join music_tracks t on t.id = i.track_id
           where i.playlist_id = ${playlist.id}
           order by i.position, t.id
           limit ${limit}
        `.execute(k.db);

        return { items: res.rows.map(toTrack), nextCursor: null };
      },
    );

    app.post(
      '/api/v1/music/playlists/add',
      secured('music:write', {
        schema: {
          operationId: 'musicPlaylistAdd',
          tags: TAG,
          summary: '向歌单加入曲目',
          body: h.ref('MusicPlaylistMembersBody'),
          response: { 200: h.ref('MusicOkResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { playlistId?: string; trackIds?: string[] };
        const owner = req.user?.sub || '';
        const playlist = body.playlistId ? await h.loadPlaylist(body.playlistId, owner) : null;
        if (!playlist) return reply.code(404).send({ error: Err.notFound, message: 'playlist not found' });

        const now = Math.floor(Date.now() / 1000);
        // 去重后再批量写：原实现是「每首 1 次 SELECT + 1 次 INSERT」，
        // 加 500 首要 1000 次往返；现在固定 3 次（查已存在 / 查最大位次 / multi-VALUES 插入）。
        const wantIds = [...new Set((body.trackIds || []).slice(0, 500))];
        await k.db.transaction().execute(async (trx: any) => {
          const existing = new Set<string>();
          if (wantIds.length > 0) {
            const rows = await sql<{ track_id: string }>`
              select track_id from music_playlist_items
               where playlist_id = ${playlist.id}
                 and track_id in (${sql.join(
                   wantIds.map((id) => sql`${id}`),
                   sql`, `,
                 )})
            `.execute(trx);
            for (const r of rows.rows) existing.add(String(r.track_id));
          }
          const fresh = wantIds.filter((id) => !existing.has(id));
          if (fresh.length > 0) {
            const maxRow = await sql<{ max_pos: number | null }>`
              select coalesce(max(position), 0) as max_pos
                from music_playlist_items where playlist_id = ${playlist.id}
            `.execute(trx);
            let position = Number(maxRow.rows[0]?.max_pos) || 0;
            const values = fresh.map((trackId) => {
              position += 1;
              return sql`(${playlist.id}, ${trackId}, ${position}, ${now})`;
            });
            await sql`
              insert into music_playlist_items (playlist_id, track_id, position, added_at)
              values ${sql.join(values, sql`, `)}
            `.execute(trx);
          }
          await sql`update music_playlists set updated_at = ${now} where id = ${playlist.id}`.execute(
            trx,
          );
        });

        return { ok: true };
      },
    );

    app.post(
      '/api/v1/music/playlists/remove',
      secured('music:write', {
        schema: {
          operationId: 'musicPlaylistRemove',
          tags: TAG,
          summary: '从歌单移出曲目',
          body: h.ref('MusicPlaylistMembersBody'),
          response: { 200: h.ref('MusicOkResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { playlistId?: string; trackIds?: string[] };
        const owner = req.user?.sub || '';
        const playlist = body.playlistId ? await h.loadPlaylist(body.playlistId, owner) : null;
        if (!playlist) return reply.code(404).send({ error: Err.notFound, message: 'playlist not found' });

        const now = Math.floor(Date.now() / 1000);
        // 一条 `in (...)` 删完。原实现逐首 delete，而且是 500 次**独立隐式事务**
        // （没有包 transaction），WAL 要落 500 次盘。
        const ids = [...new Set((body.trackIds || []).slice(0, 500))];
        await k.db.transaction().execute(async (trx: any) => {
          if (ids.length > 0) {
            await sql`
              delete from music_playlist_items
               where playlist_id = ${playlist.id}
                 and track_id in (${sql.join(
                   ids.map((id) => sql`${id}`),
                   sql`, `,
                 )})
            `.execute(trx);
          }
          await sql`update music_playlists set updated_at = ${now} where id = ${playlist.id}`.execute(
            trx,
          );
        });

        return { ok: true };
      },
    );

    app.post(
      '/api/v1/music/playlists/rename',
      secured('music:write', {
        schema: {
          operationId: 'musicPlaylistRename',
          tags: TAG,
          summary: '重命名歌单',
          body: h.ref('MusicPlaylistRenameBody'),
          response: { 200: h.ref('MusicOkResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { playlistId?: string; name?: string };
        const name = (body.name || '').trim();
        if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
        const owner = req.user?.sub || '';
        const playlist = body.playlistId ? await h.loadPlaylist(body.playlistId, owner) : null;
        if (!playlist) return reply.code(404).send({ error: Err.notFound, message: 'playlist not found' });

        const now = Math.floor(Date.now() / 1000);
        await sql`
          update music_playlists set name = ${name}, updated_at = ${now} where id = ${playlist.id}
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/music/playlists/delete',
      secured('music:write', {
        schema: {
          operationId: 'musicPlaylistDelete',
          tags: TAG,
          summary: '删除歌单',
          body: h.ref('MusicPlaylistDeleteBody'),
          response: { 200: h.ref('MusicOkResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { playlistId?: string };
        const owner = req.user?.sub || '';
        const playlist = body.playlistId ? await h.loadPlaylist(body.playlistId, owner) : null;
        if (!playlist) return reply.code(404).send({ error: Err.notFound, message: 'playlist not found' });

        await k.db.transaction().execute(async (trx: any) => {
          await sql`delete from music_playlist_items where playlist_id = ${playlist.id}`.execute(trx);
          await sql`delete from music_playlists where id = ${playlist.id}`.execute(trx);
        });

        return { ok: true };
      },
    );
}
