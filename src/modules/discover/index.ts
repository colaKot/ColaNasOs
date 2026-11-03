import fsp from 'node:fs/promises';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { registerDiscoverApi } from './api';
import { registerDoubanRoutes } from './douban-routes';
import type { FastifyRequest } from 'fastify';

/**
 * SP3-11 的 discover（旧工程 `discover`）：
 *   POST /api/v1/discover/scrape   扫描同目录 NFO，补全简介 / 年份 / 类型 / 评分
 *   GET  /api/v1/discover/meta     已刮削的条目
 *
 * 取舍：
 * - **只做离线 NFO**（Kodi 命名：`<文件名>.nfo`、`movie.nfo`、`tvshow.nfo`）。TMDB 需要 API key 与外网，
 *   没有 key 时宁可明确不提供，也不做「静默失败」；
 * - 结果落在独立表 `video_meta`，不往 `video_items` 里塞列 —— 扫描重扫不会覆盖刮削结果。
 */
const TAG = ['discover'];
const MAX_NFO = 512 * 1024;

const ScrapeBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String({ description: '只刮某个影视库' })),
  },
  { $id: 'DiscoverScrapeBody' },
);

const ScrapeResponse = Type.Object(
  { scanned: Type.Integer(), scraped: Type.Integer(), skipped: Type.Integer() },
  { $id: 'DiscoverScrapeResponse' },
);

const MetaItem = Type.Object(
  {
    itemId: Type.String(),
    title: Type.String(),
    plot: Type.Union([Type.String(), Type.Null()]),
    year: Type.Union([Type.Integer(), Type.Null()]),
    genre: Type.Union([Type.String(), Type.Null()]),
    rating: Type.Union([Type.Number(), Type.Null()]),
    updatedAt: Type.Integer(),
  },
  { $id: 'DiscoverMetaItem' },
);

const MetaList = Type.Object(
  { items: Type.Array(Type.Ref(MetaItem)) },
  { $id: 'DiscoverMetaList' },
);

const MetaQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 100 })),
  },
  { $id: 'DiscoverMetaQuery' },
);

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'DiscoverError' },
);

const DISCOVER_SCHEMAS = [ScrapeBody, ScrapeResponse, MetaItem, MetaList, MetaQuery, ErrorResponse];
const ref = (id: string) => ({ $ref: `${id}#` });

/** 从 NFO 里取几个常用字段（NFO 是 XML，但字段都是扁平的，正则足够且零依赖） */
export function parseNfo(xml: string): {
  title?: string;
  plot?: string;
  year?: number;
  genre?: string;
  rating?: number;
} {
  const tag = (name: string): string | undefined => {
    const m = new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, 'i').exec(xml);
    if (!m) return undefined;
    return m[1]
      .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
      .replace(/<[^>]+>/g, '')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .trim();
  };
  const yearRaw = tag('year') || tag('premiered')?.slice(0, 4);
  const ratingRaw = tag('rating');
  return {
    title: tag('title'),
    plot: tag('plot') || tag('outline'),
    year: yearRaw ? Number(yearRaw.slice(0, 4)) || undefined : undefined,
    genre: tag('genre'),
    rating: ratingRaw ? Number(ratingRaw) || undefined : undefined,
  };
}

async function readNfo(rel: string): Promise<string | null> {
  const root = filesRoot();
  const dir = path.dirname(rel);
  const base = path.basename(rel, path.extname(rel));
  const candidates = [
    path.join(dir, `${base}.nfo`),
    path.join(dir, 'movie.nfo'),
    path.join(dir, 'tvshow.nfo'),
  ];
  for (const c of candidates) {
    try {
      const abs = resolveInRoot(root, c);
      const stat = await fsp.stat(abs);
      if (stat.size > MAX_NFO) continue;
      return await fsp.readFile(abs, 'utf8');
    } catch {
      /* 试下一个 */
    }
  }
  return null;
}

export const discover: ServerModule = {
  id: 'discover',
  prefix: '/api/v1/discover',
  permissions: ['discover:read', 'discover:write'],

  migrations: [
    {
      id: '044_video_meta',
      async up(db) {
        await sql`
          create table if not exists video_meta (
            item_id text primary key,
            plot text,
            year integer,
            genre text,
            rating real,
            updated_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '101_discover_favorites',
      async up(db) {
        // 发现页收藏（每用户独立；卡片 favorited 角标与收藏列表）
        await sql`
          create table if not exists discover_favorites (
            uid text not null,
            media_type text not null,
            tmdb_id integer not null,
            created_at integer not null,
            primary key (uid, media_type, tmdb_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_discover_favorites_uid
          on discover_favorites (uid, created_at desc)
        `.execute(db);
      },
    },
    {
      // 榜单快照（TMDB 发现页 / 日系榜单共用）。
      // 此前两处都只有进程内缓存：重启即失效，上游失败时直接空列表。
      id: '086_media_catalog',
      async up(db) {
        await sql`
          create table if not exists media_catalog (
            catalog_type text not null,
            key text not null,
            payload text not null,
            item_count integer not null default 0,
            snapshot_at integer not null,
            primary key (catalog_type, key)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_media_catalog_snapshot
            on media_catalog (catalog_type, snapshot_at desc)
        `.execute(db);
      },
    },
  ],

  async register(app, k) {
    await registerDoubanRoutes(app, k);
    for (const schema of DISCOVER_SCHEMAS) app.addSchema(schema);
    await registerDiscoverApi(app, k);

    app.post(
      '/api/v1/discover/scrape',
      secured('discover:write', {
        schema: {
          operationId: 'discoverScrape',
          tags: TAG,
          summary: '扫描同目录 NFO（离线刮削）',
          body: ref('DiscoverScrapeBody'),
          response: { 200: ref('DiscoverScrapeResponse') },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as { libraryId?: string };
        const rows = (
          body.libraryId
            ? await sql<{ id: string; rel_path: string }>`
                select id, rel_path from video_items where library_id = ${body.libraryId}
              `.execute(k.db)
            : await sql<{
                id: string;
                rel_path: string;
              }>`select id, rel_path from video_items`.execute(k.db)
        ).rows;

        let scraped = 0;
        let skipped = 0;
        for (const item of rows) {
          const nfo = await readNfo(item.rel_path);
          if (!nfo) {
            skipped += 1;
            continue;
          }
          const meta = parseNfo(nfo);
          await sql`
            insert into video_meta (item_id, plot, year, genre, rating, updated_at)
            values (${item.id}, ${meta.plot ?? null}, ${meta.year ?? null}, ${meta.genre ?? null},
                    ${meta.rating ?? null}, ${Math.floor(Date.now() / 1000)})
            on conflict(item_id) do update set
              plot = excluded.plot, year = excluded.year, genre = excluded.genre,
              rating = excluded.rating, updated_at = excluded.updated_at
          `.execute(k.db);
          scraped += 1;
        }
        return { scanned: rows.length, scraped, skipped };
      },
    );

    app.get(
      '/api/v1/discover/meta',
      secured('discover:read', {
        schema: {
          operationId: 'discoverMeta',
          tags: TAG,
          summary: '已刮削的条目（简介 / 年份 / 类型 / 评分）',
          querystring: ref('DiscoverMetaQuery'),
          response: { 200: ref('DiscoverMetaList') },
        },
      }),
      async (req: FastifyRequest) => {
        const q = (req.query || {}) as { libraryId?: string; limit?: number };
        const limit = Math.min(Number(q.limit || 100) || 100, 500);
        const rows = (
          q.libraryId
            ? await sql<{
                item_id: string;
                title: string;
                plot: string | null;
                year: number | null;
                genre: string | null;
                rating: number | null;
                updated_at: number;
              }>`
                select m.item_id, i.title, m.plot, m.year, m.genre, m.rating, m.updated_at
                from video_meta m join video_items i on i.id = m.item_id
                where i.library_id = ${q.libraryId}
                order by m.updated_at desc limit ${limit}
              `.execute(k.db)
            : await sql<{
                item_id: string;
                title: string;
                plot: string | null;
                year: number | null;
                genre: string | null;
                rating: number | null;
                updated_at: number;
              }>`
                select m.item_id, i.title, m.plot, m.year, m.genre, m.rating, m.updated_at
                from video_meta m join video_items i on i.id = m.item_id
                order by m.updated_at desc limit ${limit}
              `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            itemId: r.item_id,
            title: r.title,
            plot: r.plot,
            year: r.year === null ? null : Number(r.year),
            genre: r.genre,
            rating: r.rating === null ? null : Number(r.rating),
            updatedAt: Number(r.updated_at),
          })),
        };
      },
    );
  },
};
