import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import {
    TAG,
    TrackRow,
    toTrack,
    decodeCursor,
    encodeSortCursor,
    decodeSortCursor,
} from '../util';
import { musicSearchWhere } from '../search';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/**
 * 可排序的列（白名单）。
 *
 * 空值统一 coalesce 成「最小值」，否则 NULL 在 asc 时排最前、cursor 比较又永远为 NULL，
 * 翻页会在有 null 的艺人和正常艺人之间来回跳。
 */
const SORT_EXPR: Record<string, { expr: string; numeric: boolean }> = {
    title: { expr: 'title', numeric: false },
    artist: { expr: "coalesce(artist, '')", numeric: false },
    album: { expr: "coalesce(album, '')", numeric: false },
    created: { expr: 'created_at', numeric: true },
    duration: { expr: 'coalesce(duration, 0)', numeric: true },
    year: { expr: 'coalesce(year, 0)', numeric: true },
};

/** 列表 / 详情 */
export async function registerMusicItems(app: FastifyInstance, k: KernelApi, h: MusicHelpers): Promise<void> {
    // ---------------------------------------------------------------- 列表 / 详情

    app.get(
      '/api/v1/music/list',
      secured('music:read', {
        schema: {
          operationId: 'musicList',
          tags: TAG,
          summary: '曲目列表（可排序 + 排序键 cursor）',
          querystring: h.ref('MusicListQuery'),
          response: { 200: h.ref('MusicListResponse'), 400: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as {
          libraryId?: string;
          q?: string;
          artist?: string;
          album?: string;
          albumArtist?: string;
          genre?: string;
          year?: number;
          sort?: string;
          order?: string;
          cursor?: string;
          limit?: number;
        };
        // 新旧两种 cursor 都认：老格式是 {t,i}（标题序），新格式是 {k,i}（任意排序列）
        const cur =
          decodeSortCursor(q.cursor) ??
          (() => {
            const legacy = decodeCursor(q.cursor);
            return legacy ? { key: legacy.title as string | number, id: legacy.id } : null;
          })();
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);
        const sortKey = SORT_EXPR[String(q.sort || 'title')] ? String(q.sort || 'title') : 'title';
        const sort = SORT_EXPR[sortKey];
        const desc = q.order === 'desc';
        const dir = sql.raw(desc ? 'desc' : 'asc');
        const cmp = sql.raw(desc ? '<' : '>');

        let where = sql`1 = 1`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.artist) where = sql`${where} and artist = ${q.artist}`;
        if (q.album) where = sql`${where} and album = ${q.album}`;
        if (q.albumArtist) where = sql`${where} and album_artist = ${q.albumArtist}`;
        if (q.genre) where = sql`${where} and genre = ${q.genre}`;
        if (q.year != null && Number.isFinite(Number(q.year))) {
          where = sql`${where} and year = ${Number(q.year)}`;
        }
        if (q.q && q.q.trim()) {
          // 标题 / 艺人 / 专辑 / 文件名：简繁互通 + 跳字模糊
          const sw = musicSearchWhere(['title', 'artist', 'album', 'rel_path'], q.q.trim());
          if (sw) where = sql`${where} and ${sw}`;
        }
        if (cur) {
          const key = sort.numeric ? Number(cur.key) : String(cur.key);
          where = sql`${where} and (${sql.raw(sort.expr)} ${cmp} ${key}
            or (${sql.raw(sort.expr)} = ${key} and id > ${cur.id}))`;
        }

        const res = await sql<TrackRow>`
          select * from music_tracks
           where ${where}
           order by ${sql.raw(sort.expr)} ${dir}, id asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const next = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        const keyOf = (r: TrackRow): string | number => {
          switch (sortKey) {
            case 'artist':
              return r.artist ?? '';
            case 'album':
              return r.album ?? '';
            case 'created':
              return Number(r.created_at || 0);
            case 'duration':
              return r.duration ?? 0;
            case 'year':
              return r.year ?? 0;
            default:
              return r.title;
          }
        };
        return {
          items: rows.map(toTrack),
          nextCursor: next ? encodeSortCursor(keyOf(next), next.id) : null,
        };
      },
    );

    // ---------------------------------------------------------------- 专辑 / 艺人聚合
    // 客户端此前拉前 200 首在本地 groupBy：库一超过 200 首，专辑/艺人列表就不完整
    // （而且是静默缺失，用户只会觉得"有些专辑不见了"）。

    app.get(
      '/api/v1/music/albums',
      secured('music:read', {
        schema: {
          operationId: 'musicAlbums',
          tags: TAG,
          summary: '专辑聚合（张数 / 总时长 / 代表封面）',
          querystring: h.ref('MusicAlbumsQuery'),
          response: { 200: h.ref('MusicAlbumListResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { libraryId?: string; q?: string; sort?: string; limit?: number };
        const limit = h.limitOf(q.limit, 200, 1000);
        let where = sql`album is not null and album != ''`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.q && q.q.trim()) {
          const sw = musicSearchWhere(['album'], q.q.trim());
          if (sw) where = sql`${where} and ${sw}`;
        }
        const order =
          q.sort === 'tracks'
            ? sql`count(*) desc, album asc`
            : q.sort === 'year'
              ? sql`coalesce(max(year), 0) desc, album asc`
              : sql`album asc`;
        const rows = await sql<{
          name: string;
          artist: string | null;
          album_artist: string | null;
          year: number | null;
          tracks: number;
          duration: number | null;
          cover_id: string | null;
        }>`
          select t.album as name,
                 min(t.artist) as artist,
                 min(t.album_artist) as album_artist,
                 max(t.year) as year,
                 count(*) as tracks,
                 sum(t.duration) as duration,
                 (select t2.id from music_tracks t2
                   where t2.album = t.album and t2.has_cover = 1
                   order by coalesce(t2.track_no, 0), t2.id limit 1) as cover_id
            from music_tracks t
           where ${where}
           group by t.album
           order by ${order}
           limit ${limit}
        `.execute(k.db);
        return {
          items: rows.rows.map((r) => ({
            name: r.name,
            artist: r.album_artist || r.artist || null,
            year: r.year == null ? null : Number(r.year),
            tracks: Number(r.tracks) || 0,
            durationMs: Number(r.duration) || 0,
            coverTrackId: r.cover_id ?? null,
          })),
        };
      },
    );

    app.get(
      '/api/v1/music/artists',
      secured('music:read', {
        schema: {
          operationId: 'musicArtists',
          tags: TAG,
          summary: '艺人聚合（曲目数 / 专辑数 / 代表封面）',
          querystring: h.ref('MusicArtistsQuery'),
          response: { 200: h.ref('MusicArtistListResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { libraryId?: string; q?: string; sort?: string; limit?: number };
        const limit = h.limitOf(q.limit, 200, 1000);
        let where = sql`artist is not null and artist != ''`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.q && q.q.trim()) {
          const sw = musicSearchWhere(['artist'], q.q.trim());
          if (sw) where = sql`${where} and ${sw}`;
        }
        const order =
          q.sort === 'tracks' ? sql`count(*) desc, artist asc` : sql`artist asc`;
        const rows = await sql<{
          name: string;
          tracks: number;
          albums: number;
          duration: number | null;
          cover_id: string | null;
        }>`
          select t.artist as name,
                 count(*) as tracks,
                 count(distinct t.album) as albums,
                 sum(t.duration) as duration,
                 (select t2.id from music_tracks t2
                   where t2.artist = t.artist and t2.has_cover = 1
                   order by t2.id limit 1) as cover_id
            from music_tracks t
           where ${where}
           group by t.artist
           order by ${order}
           limit ${limit}
        `.execute(k.db);
        return {
          items: rows.rows.map((r) => ({
            name: r.name,
            tracks: Number(r.tracks) || 0,
            albums: Number(r.albums) || 0,
            durationMs: Number(r.duration) || 0,
            coverTrackId: r.cover_id ?? null,
          })),
        };
      },
    );

    app.get(
      '/api/v1/music/item',
      secured('music:read', {
        schema: {
          operationId: 'musicItem',
          tags: TAG,
          summary: '曲目详情',
          querystring: h.ref('MusicIdQuery'),
          response: { 200: h.ref('MusicTrack'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadTrack(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'track not found' });
        return toTrack(row);
      },
    );

    app.get(
      '/api/v1/music/stats',
      secured('music:read', {
        schema: {
          operationId: 'musicStats',
          tags: TAG,
          summary: '曲目 / 专辑 / 艺术家 / 总时长',
          response: { 200: h.ref('MusicStatsResponse') },
        },
      }),
      async () => {
        const libs = await sql<{ n: number }>`
          select count(*) as n from music_libraries
        `.execute(k.db);
        const agg = await sql<{
          n: number;
          total: number | null;
          albums: number;
          artists: number;
        }>`
          select count(*) as n,
                 sum(duration) as total,
                 count(distinct album) as albums,
                 count(distinct artist) as artists
            from music_tracks
        `.execute(k.db);
        const row = agg.rows[0];
        return {
          libraries: Number(libs.rows[0]?.n) || 0,
          tracks: Number(row?.n) || 0,
          albums: Number(row?.albums) || 0,
          artists: Number(row?.artists) || 0,
          durationMs: Number(row?.total) || 0,
        };
      },
    );

}
