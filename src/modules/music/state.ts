import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import type { FastifyRequest } from 'fastify';
import { toTrack, type TrackRow } from './util';

/**
 * 音乐用户态：收藏 + 播放历史（按 JWT `sub` 隔离）。
 *
 * 历史只留最近 200 条/人（写入时裁剪），避免长期使用把表撑大；
 * 收藏是幂等集合，重复收藏不报错。
 */
const MAX_HISTORY = 200;

const FavoriteBody = Type.Object(
  { id: Type.String({ minLength: 1 }), favorite: Type.Boolean() },
  { $id: 'MusicFavoriteBody' },
);

const TrackRef = Type.Object({ id: Type.String({ minLength: 1 }) }, { $id: 'MusicTrackRefBody' });

/** 兼容旧客户端：收藏 / 历史的精简结构仍保留在契约里（接口已改为返回完整曲目）。 */
const StateItem = Type.Object(
  {
    id: Type.String(),
    title: Type.String(),
    artist: Type.Union([Type.String(), Type.Null()]),
    album: Type.Union([Type.String(), Type.Null()]),
    duration: Type.Union([Type.Integer(), Type.Null()]),
    favorite: Type.Boolean(),
  },
  { $id: 'MusicStateItem' },
);

const StateList = Type.Object(
  { items: Type.Array(Type.Ref(StateItem)) },
  { $id: 'MusicStateList' },
);

const HistoryItem = Type.Object(
  {
    id: Type.String(),
    title: Type.String(),
    artist: Type.Union([Type.String(), Type.Null()]),
    album: Type.Union([Type.String(), Type.Null()]),
    duration: Type.Union([Type.Integer(), Type.Null()]),
    playedAt: Type.Integer(),
  },
  { $id: 'MusicHistoryItem' },
);

const HistoryList = Type.Object(
  { items: Type.Array(Type.Ref(HistoryItem)) },
  { $id: 'MusicHistoryList' },
);

const HistoryQuery = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })) },
  { $id: 'MusicHistoryQuery' },
);

const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'MusicStateOk' });

export const MUSIC_STATE_SCHEMAS = [
  FavoriteBody,
  TrackRef,
  StateItem,
  StateList,
  HistoryItem,
  HistoryList,
  HistoryQuery,
  OkResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });
const now = () => Math.floor(Date.now() / 1000);

export async function registerMusicState(app: any, k: KernelApi): Promise<void> {
  for (const schema of MUSIC_STATE_SCHEMAS) app.addSchema(schema);

  app.post(
    '/api/v1/music/favorite',
    secured('music:write', {
      schema: {
        operationId: 'musicFavorite',
        tags: ['music'],
        summary: '收藏 / 取消收藏曲目（按用户隔离）',
        body: ref('MusicFavoriteBody'),
        response: { 200: ref('MusicStateOk') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { id?: string; favorite?: boolean };
      const owner = req.user?.sub ?? '';
      if (body.favorite) {
        await sql`
          insert into music_favorites (item_id, owner_id, created_at)
          values (${body.id}, ${owner}, ${now()})
          on conflict(owner_id, item_id) do nothing
        `.execute(k.db);
      } else {
        await sql`delete from music_favorites where item_id = ${body.id} and owner_id = ${owner}`.execute(
          k.db,
        );
      }
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/music/favorites/ids',
    secured('music:read', {
      schema: {
        operationId: 'musicFavoriteIds',
        tags: ['music'],
        summary: '我的收藏 id 列表（曲库页星标状态用，只回 id 不带曲目）',
        response: {
          200: Type.Object({ ids: Type.Array(Type.String()) }),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const owner = req.user?.sub ?? '';
      const rows = (
        await sql<{ item_id: string }>`
          select item_id from music_favorites where owner_id = ${owner}
        `.execute(k.db)
      ).rows;
      return { ids: rows.map((r) => String(r.item_id)) };
    },
  );

  app.get(
    '/api/v1/music/favorites',
    secured('music:read', {
      schema: {
        operationId: 'musicFavorites',
        tags: ['music'],
        summary: '我的收藏（按收藏时间倒序，返回完整曲目）',
        response: { 200: ref('MusicListResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const owner = req.user?.sub ?? '';
      // 返回完整曲目（而不是精简的 MusicStateItem）：收藏页与曲目页共用同一个
      // 封面网格 / 播放队列，少了 path / hasCover 就没法直接播、也没法取封面。
      const rows = (
        await sql<TrackRow>`
          select t.*
          from music_favorites f join music_tracks t on t.id = f.item_id
          where f.owner_id = ${owner}
          order by f.created_at desc limit 200
        `.execute(k.db)
      ).rows;
      return { items: rows.map(toTrack), nextCursor: null };
    },
  );

  app.post(
    '/api/v1/music/play',
    secured('music:write', {
      schema: {
        operationId: 'musicPlay',
        tags: ['music'],
        summary: '记录一次播放（写历史）',
        body: ref('MusicTrackRefBody'),
        response: { 200: ref('MusicStateOk') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { id?: string };
      const owner = req.user?.sub ?? '';
      await sql`
        insert into music_plays (id, item_id, owner_id, played_at)
        values (${cryptoId()}, ${body.id}, ${owner}, ${Date.now()})
      `.execute(k.db);
      // 每人只留最近 MAX_HISTORY 条
      await sql`
        delete from music_plays where owner_id = ${owner} and id not in (
          select id from music_plays where owner_id = ${owner} order by played_at desc limit ${MAX_HISTORY}
        )
      `.execute(k.db);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/music/history',
    secured('music:read', {
      schema: {
        operationId: 'musicHistory',
        tags: ['music'],
        summary: '播放历史（按时间倒序，返回完整曲目）',
        querystring: ref('MusicHistoryQuery'),
        response: { 200: ref('MusicListResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const owner = req.user?.sub ?? '';
      const limit = Math.min(
        Number(((req.query || {}) as { limit?: number }).limit || 50) || 50,
        200,
      );
      const rows = (
        await sql<TrackRow>`
          select t.*
          from music_plays p join music_tracks t on t.id = p.item_id
          where p.owner_id = ${owner}
          order by p.played_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return { items: rows.map(toTrack), nextCursor: null };
    },
  );
}

function cryptoId(): string {
  // 避免引入 crypto 只为 uuid：时间戳 + 随机后缀足够（历史记录不需要可猜测性）
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}
