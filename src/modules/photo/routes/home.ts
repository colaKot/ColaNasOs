import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';
import { TAG, toItem, type PhotoItemRow } from '../util';

/** 相册首页看板：把统计 / 足迹 / 人物 / 那年今日聚合成一次请求 */
export async function registerPhotoHome(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/photo/home/summary',
    secured('photo:read', {
      schema: {
        operationId: 'photoHomeSummary',
        tags: TAG,
        summary: '相册首页看板（统计 / 足迹 / 人物 / 那年今日）',
        response: { 200: h.ref('PhotoHomeSummary') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      const owner = sql`library_id in (select id from photo_libraries where owner_id = ${uid})`;

      const agg = await sql<{
        n: number;
        bytes: number | null;
        videos: number | null;
        today_new: number;
        active_days: number;
      }>`
        select count(*) as n,
               sum(size) as bytes,
               sum(case when mime like 'video/%' then 1 else 0 end) as videos,
               sum(case when created_at >= ${Math.floor(new Date().setHours(0, 0, 0, 0) / 1000)}
                        then 1 else 0 end) as today_new,
               count(distinct date(taken_at, 'unixepoch', 'localtime')) as active_days
          from photo_items
         where in_trash = 0 and ${owner}
      `.execute(k.db);

      const years = await sql<{ year: number; count: number }>`
        select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as year,
               count(*) as count
          from photo_items
         where in_trash = 0 and ${owner}
         group by year order by year desc
      `.execute(k.db);

      const since = Math.floor(Date.now() / 1000) - 365 * 86400;
      const days = await sql<{ date: string; count: number }>`
        select date(taken_at, 'unixepoch', 'localtime') as date, count(*) as count
          from photo_items
         where in_trash = 0 and taken_at >= ${since} and ${owner}
         group by date order by date asc
      `.execute(k.db);

      const months = await sql<{ year: number; month: number; count: number }>`
        select cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as year,
               cast(strftime('%m', taken_at, 'unixepoch', 'localtime') as integer) as month,
               count(*) as count
          from photo_items
         where in_trash = 0 and taken_at >= ${since} and ${owner}
         group by year, month order by count desc limit 1
      `.execute(k.db);

      const footprint = await sql<{ cities: number; places: number; days: number }>`
        select count(distinct geohash4) as cities,
               count(distinct geohash5) as places,
               count(distinct date(taken_at, 'unixepoch', 'localtime')) as days
          from photo_items
         where in_trash = 0 and latitude is not null and longitude is not null and ${owner}
      `.execute(k.db);

      const people = await sql<{
        id: string;
        name: string | null;
        size: number;
        cover_photo_id: string | null;
        cover_path: string | null;
      }>`
        select c.id, c.name, c.size, c.cover_photo_id,
               (select i.rel_path from photo_items i where i.id = c.cover_photo_id) as cover_path
          from photo_face_clusters c
         where c.size >= ${Math.max(1, Number(k.config.get<any>('photo.ai')?.faceMinShowCount) || 10)}
           or (c.name is not null and c.name <> '')
         order by c.size desc limit 8
      `.execute(k.db);

      const pending = await sql<{ n: number }>`
        select count(*) as n from photo_face_clusters where name is null or name = ''
      `.execute(k.db);

      // 那年今日：最近 3 年同月同日，每年最多 3 张（照片级返回，用于卡片缩略图）
      //
      // 原实现是 `strftime('%m-%d', taken_at, ...) = 'MM-DD'`：函数包住了列，
      // 完全用不上 taken_at 索引 —— 每次进相册首页都要全表扫一遍。
      // 改成「每年一个 [当天 00:00, 次日 00:00) 的区间」，三个区间都能走索引，
      // 语义完全等价（都是本地时区的这一天，`new Date` 的月末/跨年进位由 JS 处理）。
      const now = new Date();
      const mm = String(now.getMonth() + 1).padStart(2, '0');
      const dd = String(now.getDate()).padStart(2, '0');
      const minYear = now.getFullYear() - 3;
      const ranges: Array<[number, number]> = [];
      for (let y = minYear; y <= now.getFullYear(); y += 1) {
        const start = new Date(y, now.getMonth(), now.getDate(), 0, 0, 0, 0);
        const end = new Date(y, now.getMonth(), now.getDate() + 1, 0, 0, 0, 0);
        ranges.push([Math.floor(start.getTime() / 1000), Math.floor(end.getTime() / 1000)]);
      }
      const sameDay = await sql<PhotoItemRow>`
        select * from photo_items
         where in_trash = 0 and ${owner}
           and (${sql.join(
             ranges.map(([a, b]) => sql`(taken_at >= ${a} and taken_at < ${b})`),
             sql` or `,
           )})
         order by taken_at desc limit 120
      `.execute(k.db);

      const byYear = new Map<number, PhotoItemRow[]>();
      for (const r of sameDay.rows) {
        const y = new Date(Number(r.taken_at) * 1000).getFullYear();
        if (!byYear.has(y)) byYear.set(y, []);
        byYear.get(y)!.push(r);
      }

      const row = agg.rows[0];
      return {
        library: {
          photos: Number(row?.n) || 0,
          videos: Number(row?.videos) || 0,
          todayNew: Number(row?.today_new) || 0,
          bytes: Number(row?.bytes) || 0,
        },
        heat: {
          total: Number(row?.n) || 0,
          activeDays: Number(row?.active_days) || 0,
          byYear: years.rows.map((r) => ({ year: Number(r.year), count: Number(r.count) })),
          byDay: days.rows.map((r) => ({ date: String(r.date), count: Number(r.count) })),
          peakMonth: months.rows[0]
            ? {
                year: Number(months.rows[0].year),
                month: Number(months.rows[0].month),
                count: Number(months.rows[0].count),
              }
            : null,
        },
        footprint: {
          cities: Number(footprint.rows[0]?.cities) || 0,
          places: Number(footprint.rows[0]?.places) || 0,
          days: Number(footprint.rows[0]?.days) || 0,
        },
        people: {
          items: people.rows.map((r) => ({
            id: r.id,
            name: r.name,
            size: Number(r.size) || 0,
            coverPath: r.cover_path,
          })),
          pending: Number(pending.rows[0]?.n) || 0,
        },
        onThisDay: [...byYear.entries()]
          .sort((a, b) => b[0] - a[0])
          .map(([year, list]) => ({
            date: `${year}-${mm}-${dd}`,
            year,
            photoCount: list.length,
            items: list.slice(0, 3).map(toItem),
          })),
      };
    },
  );

  app.get(
    '/api/v1/photo/on-this-day',
    secured('photo:read', {
      schema: {
        operationId: 'photoOnThisDay',
        tags: TAG,
        summary: '那年今日：所有年份同月同日的照片（按年分组）',
        querystring: h.ref('PhotoOnThisDayQuery'),
        response: { 200: h.ref('PhotoOnThisDayResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      const q = (req.query || {}) as {
        month?: number;
        day?: number;
        perYear?: number;
      };
      const now = new Date();
      const mm = String(q.month ?? now.getMonth() + 1).padStart(2, '0');
      const dd = String(q.day ?? now.getDate()).padStart(2, '0');
      const perYear = Math.min(Math.max(Number(q.perYear) || 60, 1), 200);
      const rows = await sql<PhotoItemRow & { y: number }>`
        select *, cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as y
          from photo_items
         where in_trash = 0
           and library_id in (select id from photo_libraries where owner_id = ${uid})
           and strftime('%m-%d', taken_at, 'unixepoch', 'localtime') = ${`${mm}-${dd}`}
         order by taken_at desc
         limit 4000
      `.execute(k.db);

      const byYear = new Map<number, PhotoItemRow[]>();
      for (const row of rows.rows) {
        const year = Number(row.y);
        if (!byYear.has(year)) byYear.set(year, []);
        byYear.get(year)!.push(row);
      }

      return {
        years: [...byYear.entries()]
          .sort((a, b) => b[0] - a[0])
          .map(([year, list]) => ({
            year,
            date: `${year}-${mm}-${dd}`,
            photoCount: list.length,
            items: list.slice(0, perYear).map(toItem),
          })),
      };
    },
  );
}