import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, newId, toTrack } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

interface CollectionRow {
  id: string;
  owner_id: string;
  name: string;
  paths: string;
  created_at: number;
  updated_at: number;
}

/**
 * 音乐合集：用户自建的一组音乐目录。
 *
 * 为什么不是「音乐库」：曲库（`music_libraries` / `music_tracks`）是**全局共享**的，
 * 管理员配一次所有人看同一批歌；而合集、歌单、收藏是**每个用户自己的整理方式**，
 * 按 `owner_id` 隔离。
 *
 * 合集收的是**目录**而不是曲目 id —— 目录里后来新放进去的歌自动进合集，
 * 适合「一张专辑一个文件夹」这种现成的整理方式。
 */
export async function registerMusicCollections(
  app: FastifyInstance,
  k: KernelApi,
  h: MusicHelpers,
): Promise<void> {
  /** paths JSON → 数组（坏数据不炸，直接当空） */
  const parsePaths = (raw: string): string[] => {
    try {
      const v = JSON.parse(raw || '[]');
      return Array.isArray(v) ? v.map((x) => String(x)) : [];
    } catch {
      return [];
    }
  };

  /** 目录前缀匹配：合集路径可能是 `国语怀旧`（库内相对）或 `G:/music/国语怀旧`（绝对） */
  const likeOf = (p: string) => `${p.replace(/[\\/]+$/, '').replace(/[\\/]/g, '/')}/%`;

  /** `a like x or b like y …`；空数组时给个恒假条件，避免拼出 `where ` 语法错 */
  const anyLike = (col: 'rel_path' | 't.rel_path' | 't2.rel_path', likes: string[]) =>
    likes.reduce(
      (acc: any, l: string) => sql`${acc} or ${sql.ref(col)} like ${l}`,
      sql`1 = 0` as any,
    );

  /**
   * 每个合集补「曲目数 + 封面」。
   *
   * 一条 SQL 一次算完：`exists` 里按「以某条合集路径开头」判定归属，
   * 避免 N 个合集发 N 次查询（列表 200 个合集就是 400 次）。
   */
  const decorate = async (rows: CollectionRow[], owner: string) => {
    const out = [];
    for (const r of rows) {
      const paths = parsePaths(r.paths);
      const likes = paths.map(likeOf);
      if (likes.length === 0) {
        out.push({ ...r, paths, tracks: 0, cover: null as string | null });
        continue;
      }
      const cond = anyLike('t.rel_path', likes);
      const inner = anyLike('t2.rel_path', likes);
      const stat = await sql<{ n: number; cover: string | null }>`
        select count(*) as n,
               (select t2.id from music_tracks t2
                 where (${inner})
                   and t2.has_cover = 1
                 order by t2.created_at desc limit 1) as cover
          from music_tracks t
         where ${cond}
      `.execute(k.db);
      out.push({
        ...r,
        paths,
        tracks: Number(stat.rows[0]?.n) || 0,
        cover: stat.rows[0]?.cover ?? null,
      });
    }
    return out.map((c) => ({
      id: c.id,
      name: c.name,
      paths: c.paths,
      tracks: c.tracks,
      coverTrackId: c.cover,
      createdAt: c.created_at,
      updatedAt: c.updated_at,
    }));
  };

  app.get(
    '/api/v1/music/collections',
    secured('music:read', {
      schema: {
        operationId: 'musicCollectionList',
        tags: TAG,
        summary: '当前用户的音乐合集（含曲目数与封面）',
        response: { 200: h.ref('MusicCollectionListResponse') },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const rows = await sql<CollectionRow>`
        select * from music_collections
         where owner_id = ${owner}
         order by created_at desc, id
         limit 200
      `.execute(k.db);
      return { items: await decorate(rows.rows, owner) };
    },
  );

  app.post(
    '/api/v1/music/collections',
    secured('music:write', {
      schema: {
        operationId: 'musicCollectionCreate',
        tags: TAG,
        summary: '新建音乐合集',
        body: h.ref('MusicCollectionBody'),
        response: { 200: h.ref('MusicCollection'), 400: h.ref('MusicErrorResponse') },
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
        insert into music_collections (id, owner_id, name, paths, created_at, updated_at)
        values (${id}, ${owner}, ${name}, ${JSON.stringify(paths)}, ${now}, ${now})
      `.execute(k.db);
      return {
        id,
        name,
        paths,
        tracks: 0,
        coverTrackId: null,
        createdAt: now,
        updatedAt: now,
      };
    },
  );

  app.post(
    '/api/v1/music/collections/update',
    secured('music:write', {
      schema: {
        operationId: 'musicCollectionUpdate',
        tags: TAG,
        summary: '改名 / 换目录',
        body: h.ref('MusicCollectionUpdateBody'),
        response: { 200: h.ref('MusicCollection'), 404: h.ref('MusicErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string; name?: string; paths?: string[] };
      const owner = req.user?.sub || '';
      const row = (
        await sql<CollectionRow>`
          select * from music_collections
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
        update music_collections
           set name = ${name}, paths = ${JSON.stringify(paths)}, updated_at = ${now}
         where id = ${row.id}
      `.execute(k.db);
      const [item] = await decorate([{ ...row, name, paths: JSON.stringify(paths), updated_at: now }], owner);
      return item;
    },
  );

  app.post(
    '/api/v1/music/collections/remove',
    secured('music:write', {
      schema: {
        operationId: 'musicCollectionRemove',
        tags: TAG,
        summary: '删除合集（不动磁盘文件与曲库索引）',
        body: h.ref('MusicLibraryRemoveBody'),
        response: { 200: h.ref('MusicOkResponse') },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { id?: string };
      const owner = req.user?.sub || '';
      await sql`
        delete from music_collections where id = ${body.id || ''} and owner_id = ${owner}
      `.execute(k.db);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/music/collections/items',
    secured('music:read', {
      schema: {
        operationId: 'musicCollectionItems',
        tags: TAG,
        summary: '合集里的曲目',
        querystring: h.ref('MusicCollectionItemsQuery'),
        response: { 200: h.ref('MusicListResponse'), 404: h.ref('MusicErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { id?: string; limit?: number };
      const owner = req.user?.sub || '';
      const row = (
        await sql<CollectionRow>`
          select * from music_collections
           where id = ${q.id || ''} and owner_id = ${owner}
        `.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });

      const likes = parsePaths(row.paths).map(likeOf);
      if (likes.length === 0) return { items: [], nextCursor: null };
      const limit = h.limitOf(q.limit, 200, 500);
      const cond = anyLike('rel_path', likes);
      const res = await sql`
        select * from music_tracks
         where ${cond}
         order by coalesce(album, ''), coalesce(track_no, 0), title
         limit ${limit}
      `.execute(k.db);
      return { items: (res.rows as any[]).map((r) => toTrack(r)), nextCursor: null };
    },
  );
}
