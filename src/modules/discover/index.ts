import fsp from 'node:fs/promises';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { pathVisible, visibilityOf } from '../files/visibility';
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
    {
      // 收藏三态（watching / downloading / downloaded / owned）+ 下载任务号：
      // 只给已有 discover_favorites 补列，不动主键 (uid, media_type, tmdb_id)。
      id: '154_discover_favorite_state',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(discover_favorites)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('state')) {
          await sql`alter table discover_favorites add column state text not null default 'watching'`.execute(db);
        }
        if (!cols.includes('download_task_id')) {
          await sql`alter table discover_favorites add column download_task_id text`.execute(db);
        }
        if (!cols.includes('updated_at')) {
          await sql`alter table discover_favorites add column updated_at integer`.execute(db);
        }
      },
    },
    {
      // 收藏条目的展示元数据（标题 / 海报 / 上映日期）。
      //
      // 为什么要有：收藏只存 tmdb_id，列表要靠 media_catalog 快照反查；但用户在
      // 「搜索」里收藏的条目不在榜单快照里，卡片就退化成「TMDB #1423191」+ 没海报，
      // 看着像没收藏成功（2026-11-10 反馈）。现在抓到一次就写在这里，之后秒回。
      id: '171_discover_favorite_meta',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(discover_favorites)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!cols.includes('meta')) {
          await sql`alter table discover_favorites add column meta text`.execute(db);
        }
      },
    },
    {
      // 评分体系 = 豆瓣 时的两级缓存：
      //  - douban_ratings：TMDB 媒体 id ↔ 豆瓣条目/评分的映射（补齐一次，之后秒回）
      //  - douban_chart：豆瓣榜单条目（含反查到的 TMDB 卡片），供 fast 首屏占位
      id: '156_douban_rating_cache',
      async up(db) {
        await sql`
          create table if not exists douban_ratings (
            media_id integer not null,
            media_type text not null default 'movie',
            douban_id text,
            title text,
            year text,
            rating real,
            vote_count integer,
            url text,
            updated_at integer not null,
            primary key (media_id, media_type)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_douban_ratings_updated
          on douban_ratings (updated_at desc)
        `.execute(db);
        await sql`
          create table if not exists douban_chart (
            kind text not null,
            code text not null,
            douban_id text not null,
            rank integer not null default 0,
            title text not null,
            rating real,
            payload text,
            updated_at integer not null,
            primary key (kind, code, douban_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_douban_chart_order
          on douban_chart (kind, code, rank)
        `.execute(db);
      },
    },
  ],

  async register(app, k) {
    await registerDoubanRoutes(app, k);
    for (const schema of DISCOVER_SCHEMAS) app.addSchema(schema);
    await registerDiscoverApi(app, k);

    /**
     * 影视库源目录（既有实现 的 `/api/video/source/list`）。
     *
     * 发现页设置里「电影 / 剧集下载目录」下拉要它：`path` 会被存进 pt.download
     * 当 transmission 的 download-dir。参考页按 `media_type` 过滤（movie/tv，mixed 两边都列），
     * 所以 lib_type 必须归一成这三种；一库多源就展开成多条。
     */
    app.post(
      '/api/v1/video/source/list',
      secured('discover:read', {
        schema: {
          operationId: 'videoSourceList',
          tags: ['video'],
          summary: '影视库源目录（发现页下载目录下拉用）',
          body: Type.Object({}, { additionalProperties: true }),
          response: {
            // 包一层 items：数组直返在生成客户端里拿不到（只能拿到 Map）
            200: Type.Object({
              items: Type.Array(
                Type.Object({
                  id: Type.String(),
                  libraryId: Type.String(),
                  libraryName: Type.String(),
                  path: Type.String(),
                  mediaType: Type.String({ description: 'movie / tv / mixed' }),
                }),
              ),
            }),
          },
        },
      }),
      async (req) => {
        const vis = visibilityOf(k.config, req.user);
        const rows = (
          await sql<any>`
            select l.id as library_id, l.name as library_name, l.lib_type,
                   coalesce(s.root_path, l.root_path) as path
              from video_libraries l
              left join video_library_sources s on s.library_id = l.id
             order by l.name asc
          `.execute(k.db)
        ).rows;
        const seen = new Set<string>();
        const items: Array<Record<string, string>> = [];
        for (const r of rows) {
          const path = String(r.path || '');
          const key = `${r.library_id}:${path}`;
          if (!path || !pathVisible(vis, path) || seen.has(key)) continue;
          seen.add(key);
          const libType = String(r.lib_type || 'movie');
          const mediaType =
            libType === 'tv' ? 'tv' : libType === 'mixed' ? 'mixed' : 'movie';
          items.push({
            id: key,
            libraryId: String(r.library_id),
            libraryName: String(r.library_name || ''),
            path,
            mediaType,
          });
        }
        return { items };
      },
    );

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
