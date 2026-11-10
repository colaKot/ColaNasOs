import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { readImageMeta } from '../exif';
import { TAG, PhotoItemRow, toItem, encodeCursor, decodeCursor, likePattern } from '../util';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';
import { scoreSemantic } from '../ai/semantic';

/** 时间轴 / 搜索 */
export async function registerPhotoTimeline(app: FastifyInstance, k: KernelApi, h: PhotoHelpers): Promise<void> {
    // ---------------------------------------------------------------- 时间轴 / 搜索

    app.get(
      '/api/v1/photo/timeline',
      secured('photo:read', {
        schema: {
          operationId: 'photoTimeline',
          tags: TAG,
          summary: '时间轴（taken_at 倒序，排序键 cursor）',
          querystring: h.ref('PhotoTimelineQuery'),
          response: { 200: h.ref('PhotoTimelineResponse'), 400: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as {
          libraryId?: string;
          favorite?: boolean;
          folder?: string;
          order?: string;
          cursor?: string;
          limit?: number;
        };
        const cur = decodeCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);
        const asc = q.order === 'asc';

        let where = sql`in_trash = 0 and library_id in (select id from photo_libraries where owner_id = ${String((req as any).user?.sub || '')})`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.favorite === true) where = sql`${where} and favorite = 1`;
        if (q.folder) {
          const prefix = `${q.folder.replace(/^\/+|\/+$/g, '')}/`;
          where = sql`${where} and rel_path like ${prefix + '%'}`;
        }
        if (cur) {
          // 游标方向必须与 ORDER BY 的次键同向：排序是 `taken_at <dir>, id asc`，
          // 所以两个方向在同秒内都是「取 id 更大的那些」。
          // 这里原先把 asc 分支写成 `id <`，同一秒的照片跨页会重复 + 漏图。
          where = asc
            ? sql`${where} and (taken_at > ${cur.takenAt} or (taken_at = ${cur.takenAt} and id > ${cur.id}))`
            : sql`${where} and (taken_at < ${cur.takenAt} or (taken_at = ${cur.takenAt} and id > ${cur.id}))`;
        }

        const res = await sql<PhotoItemRow>`
          select * from photo_items
           where ${where}
           order by taken_at ${sql.raw(asc ? 'asc' : 'desc')}, id asc
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

    // 批量收藏 / 取消收藏（只作用于当前用户库内的照片）
    app.post(
      '/api/v1/photo/favorite',
      secured('photo:write', {
        schema: {
          operationId: 'photoFavoriteSet',
          tags: TAG,
          summary: '批量收藏 / 取消收藏',
          body: h.ref('PhotoFavoriteBody'),
          response: { 200: h.ref('PhotoFavoriteResponse') },
        },
      }),
      async (req) => {
        const uid = String((req as any).user?.sub || '');
        const body = (req.body || {}) as { ids?: string[]; favorite?: boolean };
        const ids = (body.ids || []).slice(0, 500);
        if (ids.length === 0) return { updated: 0 };
        const favorite = body.favorite === true ? 1 : 0;
        const res = await sql`
          update photo_items set favorite = ${favorite}
           where id in (${sql.join(
             ids.map((id) => sql`${id}`),
             sql`, `,
           )})
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db);
        return { updated: Number(res.numAffectedRows || 0) };
      },
    );

    app.get(
      '/api/v1/photo/item',
      secured('photo:read', {
        schema: {
          operationId: 'photoItem',
          tags: TAG,
          summary: '单张照片详情',
          querystring: h.ref('PhotoItemQuery'),
          response: { 200: h.ref('PhotoItem'), 404: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const uid = String((req as any).user?.sub || '');
        // 必须带所属库归属：此前只按 id 查，任意登录用户拿到 id 就能读别人照片的元数据。
        // 同文件其它接口（收藏 / 时间轴）都带这段 owner 条件，这里补齐。
        const res = await sql<PhotoItemRow>`
          select * from photo_items
           where id = ${q.id || ''}
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'photo not found' });
        return toItem(row);
      },
    );

    // 属性 / EXIF 面板：按需读文件头，不落库（避免为几个展示字段做迁移与回填）
    app.get(
      '/api/v1/photo/exif',
      secured('photo:read', {
        schema: {
          operationId: 'photoExif',
          tags: TAG,
          summary: '照片属性与 EXIF（按需解析文件头；无 EXIF 字段返回 null）',
          querystring: h.ref('PhotoItemQuery'),
          response: {
            200: Type.Object({
              id: Type.String(),
              path: Type.String(),
              size: Type.Integer(),
              width: Type.Union([Type.Integer(), Type.Null()]),
              height: Type.Union([Type.Integer(), Type.Null()]),
              mime: Type.String(),
              takenAt: Type.Union([Type.Integer(), Type.Null()]),
              camera: Type.Union([Type.String(), Type.Null()]),
              make: Type.Union([Type.String(), Type.Null()]),
              lens: Type.Union([Type.String(), Type.Null()]),
              software: Type.Union([Type.String(), Type.Null()]),
              orientation: Type.Union([Type.Integer(), Type.Null()]),
              iso: Type.Union([Type.Integer(), Type.Null()]),
              fNumber: Type.Union([Type.Number(), Type.Null()]),
              exposureTimeSec: Type.Union([Type.Number(), Type.Null()]),
              focalLengthMm: Type.Union([Type.Number(), Type.Null()]),
              latitude: Type.Union([Type.Number(), Type.Null()]),
              longitude: Type.Union([Type.Number(), Type.Null()]),
            }),
            404: h.ref('PhotoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const uid = String((req as any).user?.sub || '');
        const res = await sql<PhotoItemRow & { mtime?: number }>`
          select * from photo_items
           where id = ${q.id || ''}
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'photo not found' });

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        let meta;
        try {
          meta = await readImageMeta(abs);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'unreadable image' });
        }

        return {
          id: row.id,
          path: row.rel_path,
          size: Number(row.size) || 0,
          width: meta.width ?? row.width ?? null,
          height: meta.height ?? row.height ?? null,
          mime: meta.mime || row.mime || '',
          takenAt: meta.takenAt ?? (Number(row.taken_at) || null),
          camera: meta.camera,
          make: meta.make,
          lens: meta.lens,
          software: meta.software,
          orientation: meta.orientation,
          iso: meta.iso == null ? null : Math.round(meta.iso),
          fNumber: meta.fNumber,
          exposureTimeSec: meta.exposureTime,
          focalLengthMm: meta.focalLength,
          latitude: meta.latitude,
          longitude: meta.longitude,
        };
      },
    );

    app.get(
      '/api/v1/photo/search',
      secured('photo:read', {
        schema: {
          operationId: 'photoSearch',
          tags: TAG,
          summary: '按路径关键词与时间范围搜索',
          querystring: h.ref('PhotoSearchQuery'),
          response: { 200: h.ref('PhotoTimelineResponse'), 400: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as {
          q?: string;
          from?: number;
          to?: number;
          libraryId?: string;
          folder?: string;
          order?: string;
          cursor?: string;
          limit?: number;
        };
        const cur = decodeCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);

        let where = sql`in_trash = 0 and library_id in (select id from photo_libraries where owner_id = ${String((req as any).user?.sub || '')})`;
        if (q.q && q.q.trim()) {
          where = sql`${where} and rel_path like ${likePattern(q.q.trim())} escape '\\'`;
        }
        if (Number.isFinite(q.from)) where = sql`${where} and taken_at >= ${Number(q.from)}`;
        if (Number.isFinite(q.to)) where = sql`${where} and taken_at <= ${Number(q.to)}`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.folder) {
          const prefix = `${q.folder.replace(/^\/+|\/+$/g, '')}/`;
          where = sql`${where} and rel_path like ${prefix + '%'}`;
        }
        const asc = q.order === 'asc';
        if (cur) {
          // 游标方向必须与 ORDER BY 的次键同向：排序是 `taken_at <dir>, id asc`，
          // 所以两个方向在同秒内都是「取 id 更大的那些」。
          // 这里原先把 asc 分支写成 `id <`，同一秒的照片跨页会重复 + 漏图。
          where = asc
            ? sql`${where} and (taken_at > ${cur.takenAt} or (taken_at = ${cur.takenAt} and id > ${cur.id}))`
            : sql`${where} and (taken_at < ${cur.takenAt} or (taken_at = ${cur.takenAt} and id > ${cur.id}))`;
        }

        const res = await sql<PhotoItemRow>`
          select * from photo_items
           where ${where}
           order by taken_at ${sql.raw(asc ? 'asc' : 'desc')}, id asc
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

    /**
     * 搜索框混合检索。
     *
     * 为什么单独一个接口而不是改 `/photo/search`：那个接口的语义是「路径关键词 + 时间范围」，
     * 被时间轴分页、年份过滤共用；混进语义排序会破坏它的游标语义。
     * 这里用 offset 分页（语义集合上限 300，翻到底就停），排序即相关度。
     */
    app.get(
      '/api/v1/photo/search/hybrid',
      secured('photo:read', {
        schema: {
          operationId: 'photoSearchHybrid',
          tags: TAG,
          summary: '混合检索：场景/活动标签 + OCR + 路径，按相关度排序（offset 分页）',
          querystring: h.ref('PhotoHybridSearchQuery'),
          response: { 200: h.ref('PhotoHybridSearchResponse'), 400: h.ref('PhotoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { q?: string; offset?: number; limit?: number };
        const query = String(q.q || '').trim();
        if (!query) {
          return reply.code(400).send({ error: Err.badRequest, message: 'q required' });
        }
        const offset = Math.max(0, Number(q.offset) || 0);
        const limit = h.limitOf(q.limit, 60, 200);
        const uid = String((req as any).user?.sub || '');

        const scored = await scoreSemantic(k, query, { uid, limit: 300 });
        const pageIds = scored.hits.slice(offset, offset + limit).map((x) => x.id);
        if (pageIds.length === 0) {
          return {
            items: [],
            nextOffset: null,
            total: scored.hits.length,
            tags: scored.tags,
            unmatched: scored.unmatched,
            degraded: scored.degraded,
            reason: scored.reason,
          };
        }

        const rows = (
          await sql<PhotoItemRow>`
            select * from photo_items
             where id in (${sql.join(pageIds.map((id) => sql`${id}`), sql`, `)})
               and in_trash = 0
               and library_id in (select id from photo_libraries where owner_id = ${uid})
          `.execute(k.db)
        ).rows;
        // 保持相关度顺序（SQL 的 in 不保证顺序）
        const byId = new Map(rows.map((r) => [r.id, r]));
        const items = pageIds
          .map((id) => byId.get(id))
          .filter(Boolean)
          .map((r) => toItem(r as PhotoItemRow));

        const nextOffset = offset + pageIds.length < scored.hits.length ? offset + pageIds.length : null;
        return {
          items,
          nextOffset,
          total: scored.hits.length,
          tags: scored.tags,
          unmatched: scored.unmatched,
          degraded: scored.degraded,
          reason: scored.reason,
        };
      },
    );

    app.get(
      '/api/v1/photo/stats',
      secured('photo:read', {
        schema: {
          operationId: 'photoStats',
          tags: TAG,
          summary: '总量与时间跨度',
          response: { 200: h.ref('PhotoStatsResponse') },
        },
      }),
      async (req: FastifyRequest) => {
        const uid = String((req as any).user?.sub || '');
        const libs = await sql<{ n: number }>`
          select count(*) as n from photo_libraries where owner_id = ${uid}
        `.execute(k.db);
        const agg = await sql<{
          n: number;
          earliest: number | null;
          latest: number | null;
          bytes: number | null;
          videos: number | null;
        }>`
          select count(*) as n, min(taken_at) as earliest, max(taken_at) as latest,
                 sum(size) as bytes,
                 sum(case when mime like 'video/%' then 1 else 0 end) as videos
            from photo_items
           where in_trash = 0
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db);
        const years = await sql<{ year: number; count: number }>`
          select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as year,
                 count(*) as count
            from photo_items
           where in_trash = 0
             and library_id in (select id from photo_libraries where owner_id = ${uid})
           group by year
           order by year desc
        `.execute(k.db);
        const todayStart = Math.floor(new Date().setHours(0, 0, 0, 0) / 1000);
        const today = await sql<{ n: number }>`
          select count(*) as n from photo_items
           where in_trash = 0 and created_at >= ${todayStart}
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db);
        const active = await sql<{ n: number }>`
          select count(distinct date(taken_at, 'unixepoch', 'localtime')) as n
            from photo_items
           where in_trash = 0
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db);
        const since = Math.floor(Date.now() / 1000) - 365 * 86400;
        const days = await sql<{ date: string; count: number }>`
          select date(taken_at, 'unixepoch', 'localtime') as date, count(*) as count
            from photo_items
           where in_trash = 0 and taken_at >= ${since}
             and library_id in (select id from photo_libraries where owner_id = ${uid})
           group by date
           order by date asc
        `.execute(k.db);
        const row = agg.rows[0];
        return {
          libraries: Number(libs.rows[0]?.n) || 0,
          items: Number(row?.n) || 0,
          earliest: row?.earliest ?? null,
          latest: row?.latest ?? null,
          byYear: years.rows.map((r) => ({
            year: Number(r.year),
            count: Number(r.count),
          })),
          videos: Number(row?.videos) || 0,
          bytes: Number(row?.bytes) || 0,
          todayNew: Number(today.rows[0]?.n) || 0,
          activeDays: Number(active.rows[0]?.n) || 0,
          byDay: days.rows.map((r) => ({ date: String(r.date), count: Number(r.count) })),
        };
      },
    );

    // 年视图下钻：某年 12 个月的张数与封面。
    // 客户端此前要"拉全年再分组"，一年几千张要翻十几页；这里一次给齐。
    app.get(
      '/api/v1/photo/calendar',
      secured('photo:read', {
        schema: {
          operationId: 'photoCalendar',
          tags: TAG,
          summary: '某年各月的张数与封面（年视图下钻）',
          querystring: h.ref('PhotoCalendarQuery'),
          response: { 200: h.ref('PhotoCalendarResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { year?: number };
        const year = Number(q.year) || new Date().getFullYear();
        const owner = req.user?.sub || '';
        const rows = await sql<{ m: number; n: number; path: string | null }>`
          select m, n, path from (
            select cast(strftime('%m', taken_at, 'unixepoch', 'localtime') as integer) as m,
                   count(*) over (
                     partition by cast(strftime('%m', taken_at, 'unixepoch', 'localtime') as integer)
                   ) as n,
                   rel_path as path,
                   row_number() over (
                     partition by cast(strftime('%m', taken_at, 'unixepoch', 'localtime') as integer)
                     order by taken_at desc, id desc
                   ) as rn
              from photo_items
             where in_trash = 0
               and cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) = ${year}
               and library_id in (select id from photo_libraries where owner_id = ${owner})
          )
          where rn = 1
          order by m
        `.execute(k.db);
        const byMonth = new Map(rows.rows.map((r) => [Number(r.m), r]));
        const months = Array.from({ length: 12 }, (_, i) => {
          const r = byMonth.get(i + 1);
          return {
            month: i + 1,
            count: r ? Number(r.n) : 0,
            coverPath: r?.path ?? null,
          };
        });
        return {
          year,
          total: months.reduce((sum, m) => sum + m.count, 0),
          months,
        };
      },
    );

    // 年视图卡片封面：每年一张「有人像」的代表图。
    //
    // 为什么不复用 calendar 的「每月最新一张」：那几乎总是风景/截图/文档，
    // 年份卡上排一排蓝天白云根本认不出是哪一年。这里三级优先：
    //   ① 含「常出现的 3 个人」（簇 size 最大 = 本人/家人，而不是合影里的路人）
    //   ② 含任意人脸
    //   ③ 该年最新一张（AI 还没跑完时的兜底 —— 有图总比空白强）
    // 三个查询都按「同一年里 rank=1」取，后写的覆盖先写的，正好是优先级从低到高。
    app.get(
      '/api/v1/photo/year-covers',
      secured('photo:read', {
        schema: {
          operationId: 'photoYearCovers',
          tags: TAG,
          summary: '每年一张「有人像」的代表图（年视图卡片封面）',
          response: { 200: h.ref('PhotoYearCoversResponse') },
        },
      }),
      async (req: FastifyRequest) => {
        const uid = String((req as any).user?.sub || '');
        const own = sql`library_id in (select id from photo_libraries where owner_id = ${uid})`;

        const years = await sql<{ year: number; count: number }>`
          select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as year,
                 count(*) as count
            from photo_items
           where in_trash = 0 and ${own}
           group by year
           order by year desc
        `.execute(k.db);

        // 「最符合」的排序键：人脸**相对面积和** > 脸数 > 时间。
        // 只按脸数排会挑中截图/合影缩略图（一堆几十像素的小头像，脸数还更多）；
        // 按面积排就落到「大脸的人像照」上，这正是年份卡想要的那张。
        // 同时过滤掉占图不到 1% 的极小脸（背景路人、截图角落的头像）。
        const faceArea = sql`sum(
          case when f.img_width > 0 and f.img_height > 0
               then (f.box_width * f.box_height) * 1.0 / (f.img_width * f.img_height)
               else 0 end
        )`;

        const topPeople = await sql<{ year: number; path: string }>`
          select y as year, path from (
            select cast(strftime('%Y', p.taken_at, 'unixepoch', 'localtime') as integer) as y,
                   p.rel_path as path,
                   row_number() over (
                     partition by strftime('%Y', p.taken_at, 'unixepoch', 'localtime')
                     order by p.area desc, p.cnt desc, p.taken_at desc
                   ) as rn
              from (
                select ph.id as id, ph.taken_at as taken_at, ph.rel_path as rel_path,
                       count(*) as cnt, ${faceArea} as area
                  from photo_items ph
                  join photo_faces f on f.photo_id = ph.id
                 where ph.in_trash = 0
                   and ph.library_id in (select id from photo_libraries where owner_id = ${uid})
                   and lower(ph.rel_path) not like '%screenshot%'
                   and f.cluster_id in (
                     select id from photo_face_clusters where size > 0 order by size desc limit 5
                   )
                   and (f.img_width is null or f.img_width = 0
                        or (f.box_width * f.box_height) * 100 >= f.img_width * f.img_height)
                 group by ph.id
              ) p
          ) where rn = 1
        `.execute(k.db);

        const anyFace = await sql<{ year: number; path: string }>`
          select y as year, path from (
            select cast(strftime('%Y', p.taken_at, 'unixepoch', 'localtime') as integer) as y,
                   p.rel_path as path,
                   row_number() over (
                     partition by strftime('%Y', p.taken_at, 'unixepoch', 'localtime')
                     order by p.area desc, p.cnt desc, p.taken_at desc
                   ) as rn
              from (
                select ph.id as id, ph.taken_at as taken_at, ph.rel_path as rel_path,
                       count(*) as cnt, ${faceArea} as area
                  from photo_items ph
                  join photo_faces f on f.photo_id = ph.id
                 where ph.in_trash = 0
                   and ph.library_id in (select id from photo_libraries where owner_id = ${uid})
                   and lower(ph.rel_path) not like '%screenshot%'
                   and f.cluster_id is not null
                   and (f.img_width is null or f.img_width = 0
                        or (f.box_width * f.box_height) * 100 >= f.img_width * f.img_height)
                 group by ph.id
              ) p
          ) where rn = 1
        `.execute(k.db);

        const latest = await sql<{ year: number; path: string }>`
          select y as year, path from (
            select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as y,
                   rel_path as path,
                   row_number() over (
                     partition by strftime('%Y', taken_at, 'unixepoch', 'localtime')
                     order by taken_at desc, id desc
                   ) as rn
              from photo_items
             where in_trash = 0 and ${own}
               and lower(rel_path) not like '%screenshot%'
          ) where rn = 1
        `.execute(k.db);

        const cover = new Map<number, string>();
        for (const r of latest.rows) cover.set(Number(r.year), r.path);
        for (const r of anyFace.rows) cover.set(Number(r.year), r.path);
        for (const r of topPeople.rows) cover.set(Number(r.year), r.path);

        return {
          years: years.rows.map((r) => ({
            year: Number(r.year),
            count: Number(r.count),
            coverPath: cover.get(Number(r.year)) ?? null,
          })),
        };
      },
    );

    app.get(
      '/api/v1/photo/folders',
    secured('photo:read', {
      schema: {
        operationId: 'photoFolders',
        tags: TAG,
        summary: '文件视图：按目录聚合照片',
        querystring: h.ref('PhotoFolderQuery'),
        response: { 200: h.ref('PhotoFolderList') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { path?: string };
      const base = (q.path || '').replace(/^\/+|\/+$/g, '');
      const prefix = base ? `${base}/` : '';
      const uid = String((req as any).user?.sub || '');
      const off = prefix.length;

      // 目录聚合下沉到 SQL。
      // 原实现是 `select * ... limit 20000` 再在 JS 里切路径分组：进一个大目录就要
      // 把整棵子树（含 30 多列）读进内存，十万张的库上是几十 MB 的分配 + 全量 GC 压力。
      // 现在三条聚合查询搞定，且只读 rel_path / taken_at 两列。
      const ownerPart = sql`i.in_trash = 0
        and i.library_id in (select id from photo_libraries where owner_id = ${uid})
        and i.rel_path like ${prefix + '%'}`;

      // 子目录：名字 + 张数 + 封面（该目录最新一张）
      const dirRows = (
        await sql<{ name: string; n: number; cover: string }>`
          with grouped as (
            select substr(i.rel_path, ${off + 1}, instr(substr(i.rel_path, ${off + 1}), '/') - 1) as name,
                   i.rel_path,
                   i.taken_at
              from photo_items i
             where ${ownerPart}
               and instr(substr(i.rel_path, ${off + 1}), '/') > 0
          ),
          ranked as (
            select name, rel_path,
                   row_number() over (partition by name order by taken_at desc, rel_path) as rn,
                   count(*) over (partition by name) as n
              from grouped
          )
          select name, n, rel_path as cover from ranked where rn = 1 order by name
        `.execute(k.db)
      ).rows;

      // 当前目录下的直接文件：计数 + 最多 200 张（要完整行给 toItem）
      const fileCount = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items i
           where ${ownerPart}
             and instr(substr(i.rel_path, ${off + 1}), '/') = 0
        `.execute(k.db)
      ).rows[0];
      const direct = (
        await sql<PhotoItemRow>`
          select * from photo_items i
           where ${ownerPart}
             and instr(substr(i.rel_path, ${off + 1}), '/') = 0
           order by taken_at desc, id asc
           limit 200
        `.execute(k.db)
      ).rows;

      return {
        path: base,
        files: Number(fileCount?.n) || 0,
        fileItems: direct.map(toItem),
        dirs: dirRows.map((r) => ({
          name: r.name,
          path: base ? `${base}/${r.name}` : r.name,
          items: Number(r.n) || 0,
          coverPath: r.cover,
        })),
      };
    },
  );

  app.get(
    '/api/v1/photo/folders/roots',
    secured('photo:read', {
      schema: {
        operationId: 'photoFolderRoots',
        tags: TAG,
        summary: '文件视图根：当前用户的相册来源目录',
        response: { 200: h.ref('PhotoFolderRoots') },
      },
    }),
    async (req) => {
      const uid = String((req as any).user?.sub || '');
      const rows = (
        await sql<{
          id: string;
          name: string;
          root_path: string;
          items: number;
          cover_path: string | null;
        }>`
          select l.id, l.name, l.root_path,
                 (select count(*) from photo_items i
                   where i.library_id = l.id and i.in_trash = 0) as items,
                 (select i.rel_path from photo_items i
                   where i.library_id = l.id and i.in_trash = 0
                   order by i.taken_at desc, i.id asc limit 1) as cover_path
            from photo_libraries l
           where l.owner_id = ${uid}
           order by l.created_at asc
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          name: r.name,
          path: r.root_path,
          items: Number(r.items) || 0,
          coverPath: r.cover_path,
        })),
      };
    },
  );

  app.get(
    '/api/v1/photo/ai/models',
    secured('photo:read', {
      schema: {
        operationId: 'photoModels',
        tags: TAG,
        summary: '模型目录（只读）',
        response: { 200: h.ref('PhotoModelList') },
      },
    }),
    async () => {
      const dir =
        process.env.COLANAS_MODEL_DIR || path.join(process.cwd(), 'vendor', 'models');
      if (!fs.existsSync(dir)) return { dir, exists: false, items: [] };
      const items = fs
        .readdirSync(dir, { withFileTypes: true })
        .filter((e) => e.isFile())
        .map((e) => {
          const st = fs.statSync(path.join(dir, e.name));
          return {
            name: e.name,
            size: st.size,
            modified: Math.floor(st.mtimeMs / 1000),
          };
        })
        .sort((a, b) => a.name.localeCompare(b.name));
      return { dir, exists: true, items };
    },
  );
}

