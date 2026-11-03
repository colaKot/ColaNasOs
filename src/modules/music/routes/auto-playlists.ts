import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, TrackRow, toTrack } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/**
 * 自动歌单：不改动用户数据，按索引时间 / 播放记录实时算出 4 个列表。
 *
 * - `recent_added`     最近入库（按 created_at 倒序）
 * - `recently_played`  最近播放（按 max(played_at) 倒序，去重）
 * - `most_played`      最常播放（按播放次数倒序，同次数看最近一次）
 * - `never_played`     从未播放（当前用户没有播放记录）
 *
 * 播放记录按 JWT `sub` 隔离；`recent_added` 是库级数据，与用户无关。
 */
const KINDS = ['recent_added', 'recently_played', 'most_played', 'never_played'] as const;
type Kind = (typeof KINDS)[number];

function isKind(v: string): v is Kind {
  return (KINDS as readonly string[]).includes(v);
}

async function tracksFor(
  k: KernelApi,
  kind: Kind,
  owner: string,
  limit: number,
): Promise<TrackRow[]> {
  if (kind === 'recent_added') {
    const res = await sql<TrackRow>`
      select * from music_tracks
       order by created_at desc, id desc
       limit ${limit}
    `.execute(k.db);
    return res.rows;
  }
  if (kind === 'recently_played') {
    const res = await sql<TrackRow>`
      select t.* from music_tracks t
        join (
          select item_id, max(played_at) as last
            from music_plays where owner_id = ${owner}
           group by item_id
        ) p on p.item_id = t.id
       order by p.last desc, t.id desc
       limit ${limit}
    `.execute(k.db);
    return res.rows;
  }
  if (kind === 'most_played') {
    const res = await sql<TrackRow>`
      select t.* from music_tracks t
        join music_plays p on p.item_id = t.id
       where p.owner_id = ${owner}
       group by t.id
       order by count(*) desc, max(p.played_at) desc, t.id asc
       limit ${limit}
    `.execute(k.db);
    return res.rows;
  }
  const res = await sql<TrackRow>`
    select t.* from music_tracks t
     where not exists (
       select 1 from music_plays p
        where p.owner_id = ${owner} and p.item_id = t.id
     )
     order by t.created_at desc, t.id desc
     limit ${limit}
  `.execute(k.db);
  return res.rows;
}

async function countFor(k: KernelApi, kind: Kind, owner: string): Promise<number> {
  if (kind === 'recent_added') {
    const res = await sql<{ n: number }>`select count(*) as n from music_tracks`.execute(k.db);
    return Number(res.rows[0]?.n) || 0;
  }
  if (kind === 'recently_played' || kind === 'most_played') {
    const res = await sql<{ n: number }>`
      select count(distinct item_id) as n from music_plays where owner_id = ${owner}
    `.execute(k.db);
    return Number(res.rows[0]?.n) || 0;
  }
  const res = await sql<{ n: number }>`
    select count(*) as n from music_tracks t
     where not exists (
       select 1 from music_plays p
        where p.owner_id = ${owner} and p.item_id = t.id
     )
  `.execute(k.db);
  return Number(res.rows[0]?.n) || 0;
}

/** 自动歌单列表 / 曲目 */
export async function registerMusicAutoPlaylists(
  app: FastifyInstance,
  k: KernelApi,
  h: MusicHelpers,
): Promise<void> {
  app.get(
    '/api/v1/music/auto-playlists',
    secured('music:read', {
      schema: {
        operationId: 'musicAutoPlaylists',
        tags: TAG,
        summary: '自动歌单概览（最近添加 / 最近播放 / 最常播放 / 从未播放）',
        response: { 200: h.ref('MusicAutoPlaylistListResponse') },
      },
    }),
    async (req) => {
      const owner = req.user?.sub ?? '';
      const items = await Promise.all(
        KINDS.map(async (kind) => {
          const rows = await tracksFor(k, kind, owner, 4);
          return {
            kind,
            count: await countFor(k, kind, owner),
            coverTrackId: rows.find((r) => r.has_cover === 1)?.id ?? null,
          };
        }),
      );
      return { items };
    },
  );

  app.get(
    '/api/v1/music/auto-playlist',
    secured('music:read', {
      schema: {
        operationId: 'musicAutoPlaylist',
        tags: TAG,
        summary: '自动歌单曲目（kind = recent_added / recently_played / most_played / never_played）',
        querystring: h.ref('MusicAutoPlaylistQuery'),
        response: {
          200: h.ref('MusicAutoPlaylistTracksResponse'),
          400: h.ref('MusicErrorResponse'),
        },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { kind?: string; limit?: number };
      const kind = q.kind ?? '';
      if (!isKind(kind)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'unknown kind' });
      }
      const owner = req.user?.sub ?? '';
      const rows = await tracksFor(k, kind, owner, h.limitOf(q.limit, 50, 200));
      return { items: rows.map(toTrack) };
    },
  );
}
