import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';
import { aiConfig } from '../ai/config';
import { coverRanker } from '../cover';
import { phashSimilarity } from '../phash';
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

      // 首页人物同样跟随「AI 设置 → 人脸显示下限」：1~2 张的碎片组不占卡片位。
      // 旧实现写死兜底 10，用户把下限设成 0/3 时首页与列表口径不一致。
      const minShowCount = Math.max(1, aiConfig(k).faceMinShowCount);
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
         where c.size >= ${minShowCount}
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

      // 卡片封面：按 6 级优先序（横屏+前5人脸 → … → 竖屏），见 cover.ts。
      // items 只回 3 张，所以这里按封面分重排，让客户端直接取 items.first 当封面。
      const coverOf = await coverRanker(
        k,
        sameDay.rows.map((r) => r.id),
      );

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
            items: [...list]
              .sort((a, b) => coverOf(b.id) - coverOf(a.id))
              .slice(0, 3)
              .map(toItem),
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

      // 只**重排**、不过滤：按封面 6 级优先序排（横屏+前5人脸 … 竖屏），
      // 同档再按拍摄时间倒序。这样那年今日点进来第一眼就能看见人、且优先横着放。
      const coverOf = await coverRanker(k, rows.rows.map((r) => r.id));

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
            items: [...list]
              .sort(
                (a, b) =>
                  coverOf(b.id) - coverOf(a.id) ||
                  Number(b.taken_at) - Number(a.taken_at),
              )
              .slice(0, perYear)
              .map(toItem),
          })),
      };
    },
  );

  /**
   * 时光对照的「这两张为什么放一起」。
   *
   * 配对优先级：
   *   1. 同一人脸簇（`photo_faces.cluster_id`）在≥2个年份都出现 —— 就是同一个人，
   *      取最早 / 最晚年份里该人脸最清晰的一张；有人工命名的人物优先。
   *   2. 找不到同人时降级：最早 / 最晚年份里优先「同一相册」，其次 phash 画面相似，
   *      最后只看时间跨度。降级原因会原样返回，界面必须写清。
   *
   * 人脸、人物名、头像全部复用现有表与 `/photo/face/image`，不另建数据结构。
   */
  app.get(
    '/api/v1/photo/time-contrast',
    secured('photo:read', {
      schema: {
        operationId: 'photoTimeContrast',
        tags: TAG,
        summary: '时光对照：同一天最早的年份 vs 最近的年份（优先锁定同一人物）',
        querystring: h.ref('PhotoOnThisDayQuery'),
        response: { 200: h.ref('PhotoTimeContrastResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      const q = (req.query || {}) as { month?: number; day?: number };
      const now = new Date();
      const month = Math.min(Math.max(Number(q.month) || now.getMonth() + 1, 1), 12);
      const day = Math.min(Math.max(Number(q.day) || now.getDate(), 1), 31);
      const mm = String(month).padStart(2, '0');
      const dd = String(day).padStart(2, '0');
      const dayKey = `${mm}-${dd}`;

      const rows = await sql<PhotoItemRow & { y: number; phash: string | null }>`
        select *, cast(strftime('%Y', taken_at, 'unixepoch', 'localtime') as integer) as y
          from photo_items
         where in_trash = 0
           and media_kind = 'image'
           and library_id in (select id from photo_libraries where owner_id = ${uid})
           and strftime('%m-%d', taken_at, 'unixepoch', 'localtime') = ${dayKey}
         order by taken_at desc
         limit 4000
      `.execute(k.db);

      const byYear = new Map<number, (PhotoItemRow & { y: number; phash: string | null })[]>();
      for (const r of rows.rows) {
        const y = Number(r.y);
        if (!byYear.has(y)) byYear.set(y, []);
        byYear.get(y)!.push(r);
      }

      const empty = {
        month,
        day,
        mode: 'fallback' as const,
        person: null,
        album: null,
        reason: 'time_span' as const,
        similarity: null,
        gapYears: 0,
        left: null,
        right: null,
      };
      if (byYear.size < 2) return empty;

      const faceRows = (
        await sql<{
          id: string;
          photo_id: string;
          cluster_id: string | null;
          name: string | null;
          score: number;
          quality: number | null;
          box_width: number | null;
          box_height: number | null;
          img_width: number | null;
          img_height: number | null;
        }>`
          select f.id, f.photo_id, f.cluster_id, c.name, f.score, f.quality,
                 f.box_width, f.box_height, f.img_width, f.img_height
            from photo_faces f
            join photo_items i on i.id = f.photo_id
            left join photo_face_clusters c on c.id = f.cluster_id
           where i.in_trash = 0
             and i.library_id in (select id from photo_libraries where owner_id = ${uid})
             and strftime('%m-%d', i.taken_at, 'unixepoch', 'localtime') = ${dayKey}
        `.execute(k.db)
      ).rows;

      type FaceInfo = (typeof faceRows)[number] & { area: number; weight: number };
      const facesByPhoto = new Map<string, FaceInfo[]>();
      for (const f of faceRows) {
        const gw = Number(f.box_width) || 0;
        const gh = Number(f.box_height) || 0;
        const iw = Number(f.img_width) || 0;
        const ih = Number(f.img_height) || 0;
        const area = iw > 0 && ih > 0 ? (gw * gh) / (iw * ih) : 0;
        // 质量优先、检测分兜底；老数据没有 bbox 时仍按检测分排个序
        const q = f.quality == null ? Number(f.score) || 0 : Number(f.quality);
        const weight = area * (0.25 + 0.75 * Math.max(0, Math.min(1, q))) + (Number(f.score) || 0) * 0.001;
        const list = facesByPhoto.get(f.photo_id) ?? [];
        list.push({ ...f, area, weight });
        facesByPhoto.set(f.photo_id, list);
      }

      const photoById = new Map<string, { row: PhotoItemRow; year: number }>();
      for (const r of rows.rows) photoById.set(r.id, { row: r, year: Number(r.y) });

      const topFaces = (photoId: string) =>
        [...(facesByPhoto.get(photoId) ?? [])]
          .sort((a, b) => b.weight - a.weight)
          .slice(0, 3)
          .map((f) => ({
            id: f.id,
            clusterId: f.cluster_id,
            name: f.name,
            score: Number(f.score) || 0,
            quality: f.quality == null ? null : Number(f.quality),
            area: Number(f.area.toFixed(4)),
          }));

      const sideOf = (photoId: string) => {
        const info = photoById.get(photoId)!;
        const faces = facesByPhoto.get(photoId) ?? [];
        return {
          year: info.year,
          item: toItem(info.row),
          faces: topFaces(photoId),
          faceCount: faces.length,
        };
      };

      // ---------- 1) 同一人物：统计每个 cluster 出现在哪些年份 ----------
      const clusterYears = new Map<
        string,
        { name: string | null; byYear: Map<number, { photoId: string; weight: number }[]> }
      >();
      for (const [photoId, faces] of facesByPhoto) {
        const info = photoById.get(photoId);
        if (!info) continue;
        for (const f of faces) {
          if (!f.cluster_id) continue;
          let c = clusterYears.get(f.cluster_id);
          if (!c) {
            c = { name: null, byYear: new Map() };
            clusterYears.set(f.cluster_id, c);
          }
          if (f.name) c.name = f.name;
          const list = c.byYear.get(info.year) ?? [];
          list.push({ photoId, weight: f.weight });
          c.byYear.set(info.year, list);
        }
      }

      let best: {
        id: string;
        name: string | null;
        firstYear: number;
        lastYear: number;
        leftPhotoId: string;
        rightPhotoId: string;
      } | null = null;
      let bestScore = -Infinity;
      for (const [id, c] of clusterYears) {
        const years = [...c.byYear.keys()].sort((a, b) => a - b);
        if (years.length < 2) continue;
        const firstYear = years[0];
        const lastYear = years[years.length - 1];
        const pick = (year: number) =>
          [...(c.byYear.get(year) ?? [])].sort((a, b) => b.weight - a.weight)[0];
        const left = pick(firstYear);
        const right = pick(lastYear);
        if (!left || !right) continue;
        // 人工命名过的人物更可信；同名前提下跨度越大越值得对照
        const score = (c.name ? 1_000_000 : 0) + (lastYear - firstYear) * 1000;
        if (score > bestScore) {
          bestScore = score;
          best = {
            id,
            name: c.name,
            firstYear,
            lastYear,
            leftPhotoId: left.photoId,
            rightPhotoId: right.photoId,
          };
        }
      }

      if (best) {
        const b = best;
        return {
          month,
          day,
          mode: 'person' as const,
          person: { id: b.id, name: b.name },
          album: null,
          reason: 'person' as const,
          similarity: null,
          gapYears: b.lastYear - b.firstYear,
          left: sideOf(b.leftPhotoId),
          right: sideOf(b.rightPhotoId),
        };
      }

      // ---------- 2) 降级：最早 / 最晚年份，优先同相册，其次 phash 相似 ----------
      const years = [...byYear.keys()].sort((a, b) => a - b);
      const firstYear = years[0];
      const lastYear = years[years.length - 1];
      const leftCandidates = (byYear.get(firstYear) ?? []).slice(0, 60);
      const rightCandidates = (byYear.get(lastYear) ?? []).slice(0, 60);

      const albumRows = await sql<{ item_id: string; album_id: string; album_name: string }>`
        select m.item_id, a.id as album_id, a.name as album_name
          from photo_album_items m
          join photo_albums a on a.id = m.album_id
         where a.owner_id = ${uid}
           and m.item_id in (${sql.join(
             [...leftCandidates, ...rightCandidates].map((r) => sql`${r.id}`),
             sql`, `,
           )})
      `.execute(k.db);
      const albumsByItem = new Map<string, { id: string; name: string }[]>();
      for (const a of albumRows.rows) {
        const list = albumsByItem.get(a.item_id) ?? [];
        list.push({ id: a.album_id, name: a.album_name });
        albumsByItem.set(a.item_id, list);
      }
      const sharedAlbum = (a: string, b: string) => {
        const set = new Set((albumsByItem.get(a) ?? []).map((x) => x.id));
        return (albumsByItem.get(b) ?? []).find((x) => set.has(x.id)) ?? null;
      };

      let fallback: {
        left: (typeof leftCandidates)[number];
        right: (typeof rightCandidates)[number];
        album: { id: string; name: string } | null;
        similarity: number | null;
      } | null = null;
      let fallbackScore = -Infinity;
      for (const l of leftCandidates) {
        for (const r of rightCandidates) {
          if (l.id === r.id) continue;
          const album = sharedAlbum(l.id, r.id);
          const sim = phashSimilarity(l.phash, r.phash);
          const score =
            (album ? 2 : 0) +
            (sim ?? 0) +
            (l.library_id === r.library_id ? 0.3 : 0);
          if (score > fallbackScore) {
            fallbackScore = score;
            fallback = { left: l, right: r, album, similarity: sim };
          }
        }
      }
      if (!fallback) {
        // 理论上只有两边为空才会走到这里（byYear.size>=2 已保证非空）
        return empty;
      }

      const sim = fallback.similarity;
      const reason = fallback.album
        ? ('same_album' as const)
        : sim != null && sim >= 0.8
          ? ('similar' as const)
          : ('time_span' as const);

      return {
        month,
        day,
        mode: 'fallback' as const,
        person: null,
        album: fallback.album,
        reason,
        similarity: sim == null ? null : Number(sim.toFixed(3)),
        gapYears: Number(fallback.right.y) - Number(fallback.left.y),
        left: sideOf(fallback.left.id),
        right: sideOf(fallback.right.id),
      };
    },
  );
}