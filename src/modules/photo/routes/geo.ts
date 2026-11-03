import crypto from 'node:crypto';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, PhotoItemRow, toItem } from '../util';
import { encode as geohashEncode } from '../geo/geohash';
import { nearestPlaceName } from '../geo/places';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';

/**
 * GPS 补全：列出没有经纬度的照片，手动打点后写回索引。
 *
 * 写入时同时物化 geohash..geohash7（地图按精度等值匹配，见 050_photo_geo）。
 */
export async function registerPhotoGeo(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  const uidOf = (req: { user?: { sub?: string } }) => String(req.user?.sub || '');

  app.get(
    '/api/v1/photo/geo/missing',
    secured('photo:read', {
      schema: {
        operationId: 'photoGeoMissing',
        tags: TAG,
        summary: '缺 GPS 的照片',
        querystring: h.ref('PhotoGeoMissingQuery'),
        response: { 200: h.ref('PhotoTimelineResponse') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { limit?: number; cursor?: string };
      const limit = h.limitOf(q.limit, 60, 200);
      const offset = Math.max(0, Number(q.cursor) || 0);
      const rows = (
        await sql<PhotoItemRow>`
          select * from photo_items
           where in_trash = 0
             and (latitude is null or longitude is null)
             and library_id in (select id from photo_libraries where owner_id = ${uidOf(req as any)})
           order by taken_at desc, id
           limit ${limit + 1} offset ${offset}
        `.execute(k.db)
      ).rows;
      const page = rows.slice(0, limit);
      return {
        items: page.map(toItem),
        nextCursor: rows.length > limit ? String(offset + limit) : null,
      };
    },
  );

  app.post(
    '/api/v1/photo/geo/set',
    secured('photo:write', {
      schema: {
        operationId: 'photoGeoSet',
        tags: TAG,
        summary: '给照片补经纬度（同时物化 geohash）',
        body: h.ref('PhotoGeoSetBody'),
        response: { 200: h.ref('PhotoGeoSetResponse'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { ids?: string[]; latitude?: number; longitude?: number };
      const ids = (body.ids || []).slice(0, 500);
      const lat = Number(body.latitude);
      const lng = Number(body.longitude);
      if (ids.length === 0) return reply.code(400).send({ error: Err.badRequest, message: 'ids required' });
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid coordinates' });
      }
      const gh = (p: number) => geohashEncode(lat, lng, p);
      const res = await sql`
        update photo_items
           set latitude = ${lat}, longitude = ${lng},
               geohash = ${gh(8)}, geohash2 = ${gh(2)}, geohash3 = ${gh(3)},
               geohash4 = ${gh(4)}, geohash5 = ${gh(5)}, geohash6 = ${gh(6)}, geohash7 = ${gh(7)}
         where id in (${sql.join(
           ids.map((id) => sql`${id}`),
           sql`, `,
         )})
           and library_id in (select id from photo_libraries where owner_id = ${uidOf(req as any)})
      `.execute(k.db);
      return { updated: Number(res.numAffectedRows || 0) };
    },
  );

  // ---------------------------------------------------------------- 参考照片

  app.get(
    '/api/v1/photo/geo/references',
    secured('photo:read', {
      schema: {
        operationId: 'photoGeoReferences',
        tags: TAG,
        summary: '最近带 GPS 的照片（GPS 补全的参考图）',
        querystring: h.ref('PhotoGeoMissingQuery'),
        response: { 200: h.ref('PhotoGeoReferenceList') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(Number(q.limit) || 20, 100));
      const rows = (
        await sql<{
          id: string;
          rel_path: string;
          taken_at: number;
          latitude: number;
          longitude: number;
          geohash5: string | null;
        }>`
          select id, rel_path, taken_at, latitude, longitude, geohash5
            from photo_items
           where in_trash = 0 and latitude is not null and longitude is not null
             and library_id in (select id from photo_libraries where owner_id = ${uidOf(req as any)})
           order by taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          latitude: Number(r.latitude),
          longitude: Number(r.longitude),
          place: nearestPlaceName(
            String(r.geohash5 || ''),
            Number(r.latitude),
            Number(r.longitude),
            'zh-CN',
          ),
        })),
      };
    },
  );

  // ---------------------------------------------------------------- 视觉候选

  app.get(
    '/api/v1/photo/geo/vision/status',
    secured('photo:read', {
      schema: {
        operationId: 'photoGeoVisionStatus',
        tags: TAG,
        summary: 'GPS 视觉候选生成进度',
        response: { 200: h.ref('PhotoGeoVisionStatus') },
      },
    }),
    async () => ({
      running: visionState.running,
      done: visionState.done,
      total: visionState.total,
      generated: visionState.generated,
    }),
  );

  app.get(
    '/api/v1/photo/geo/vision/candidates',
    secured('photo:read', {
      schema: {
        operationId: 'photoGeoVisionCandidates',
        tags: TAG,
        summary: 'GPS 视觉候选（相似照片的坐标作为锚点）',
        querystring: h.ref('PhotoGeoMissingQuery'),
        response: { 200: h.ref('PhotoGeoVisionList') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(Number(q.limit) || 30, 100));
      const uid = uidOf(req as any);
      const rows = (
        await sql<{
          id: string;
          photo_id: string;
          anchor_id: string;
          latitude: number;
          longitude: number;
          similarity: number;
          status: string;
          path: string;
          anchor_path: string;
        }>`
          select c.id, c.photo_id, c.anchor_id, c.latitude, c.longitude, c.similarity, c.status,
                 i.rel_path as path, a.rel_path as anchor_path
            from photo_gps_candidates c
            join photo_items i on i.id = c.photo_id
            join photo_items a on a.id = c.anchor_id
           where c.owner_id = ${uid} and c.status = 'pending'
           order by c.similarity desc limit ${limit}
        `.execute(k.db)
      ).rows;
      const total = (
        await sql<{ n: number }>`
          select count(*) as n from photo_gps_candidates
           where owner_id = ${uid} and status = 'pending'
        `.execute(k.db)
      ).rows[0];
      return {
        items: rows.map((r) => ({
          id: r.id,
          photoId: r.photo_id,
          path: r.path,
          anchorId: r.anchor_id,
          anchorPath: r.anchor_path,
          latitude: Number(r.latitude),
          longitude: Number(r.longitude),
          similarity: Number(r.similarity),
          status: r.status,
        })),
        total: Number(total?.n) || 0,
      };
    },
  );

  app.post(
    '/api/v1/photo/geo/vision/scan',
    secured('photo:write', {
      schema: {
        operationId: 'photoGeoVisionScan',
        tags: TAG,
        summary: '开始生成 GPS 视觉候选（CLIP 最近邻）',
        response: { 200: h.ref('PhotoGeoVisionStatus') },
      },
    }),
    async (req) => {
      const uid = uidOf(req as any);
      if (!visionState.running) {
        visionState.running = true;
        visionState.done = 0;
        visionState.total = 0;
        visionState.generated = 0;
        void runVisionCandidates(k, uid);
      }
      return {
        running: visionState.running,
        done: visionState.done,
        total: visionState.total,
        generated: visionState.generated,
      };
    },
  );

  app.post(
    '/api/v1/photo/geo/vision/apply',
    secured('photo:write', {
      schema: {
        operationId: 'photoGeoVisionApply',
        tags: TAG,
        summary: '确认视觉候选：写入坐标（可微调）',
        body: h.ref('PhotoGeoVisionApplyBody'),
        response: { 200: h.ref('PhotoGeoSetResponse'), 404: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string; latitude?: number; longitude?: number };
      const uid = uidOf(req as any);
      const row = (
        await sql<{ photo_id: string; latitude: number; longitude: number }>`
          select photo_id, latitude, longitude from photo_gps_candidates
           where id = ${String(body.id || '')} and owner_id = ${uid}
        `.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'candidate not found' });
      const lat = Number.isFinite(Number(body.latitude)) ? Number(body.latitude) : Number(row.latitude);
      const lng = Number.isFinite(Number(body.longitude))
        ? Number(body.longitude)
        : Number(row.longitude);
      const gh = (p: number) => geohashEncode(lat, lng, p);
      await sql`
        update photo_items
           set latitude = ${lat}, longitude = ${lng},
               geohash = ${gh(8)}, geohash2 = ${gh(2)}, geohash3 = ${gh(3)},
               geohash4 = ${gh(4)}, geohash5 = ${gh(5)}, geohash6 = ${gh(6)}, geohash7 = ${gh(7)}
         where id = ${row.photo_id}
           and library_id in (select id from photo_libraries where owner_id = ${uid})
      `.execute(k.db);
      await sql`
        update photo_gps_candidates set status = 'accepted', latitude = ${lat}, longitude = ${lng}
         where id = ${String(body.id || '')} and owner_id = ${uid}
      `.execute(k.db);
      return { updated: 1 };
    },
  );

  app.post(
    '/api/v1/photo/geo/vision/reject',
    secured('photo:write', {
      schema: {
        operationId: 'photoGeoVisionReject',
        tags: TAG,
        summary: '忽略一个 GPS 视觉候选',
        body: h.ref('PhotoGeoVisionRejectBody'),
        response: { 200: h.ref('PhotoGeoSetResponse') },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { id?: string };
      await sql`
        update photo_gps_candidates set status = 'rejected'
         where id = ${String(body.id || '')} and owner_id = ${uidOf(req as any)}
      `.execute(k.db);
      return { updated: 1 };
    },
  );
}

/** 视觉候选生成进度（单进程内存态） */
const visionState = { running: false, done: 0, total: 0, generated: 0 };

async function runVisionCandidates(k: KernelApi, uid: string): Promise<void> {
  try {
    const missing = (
      await sql<{ id: string; vec: Buffer }>`
        select i.id, e.vec
          from photo_items i join photo_embeddings e on e.photo_id = i.id
         where i.in_trash = 0 and e.dim = 512
           and (i.latitude is null or i.longitude is null)
           and i.library_id in (select id from photo_libraries where owner_id = ${uid})
         order by i.taken_at desc limit 400
      `.execute(k.db)
    ).rows;
    visionState.total = missing.length;
    if (missing.length === 0) {
      visionState.running = false;
      return;
    }

    const anchors = (
      await sql<{ id: string; vec: Buffer; latitude: number; longitude: number }>`
        select i.id, e.vec, i.latitude, i.longitude
          from photo_items i join photo_embeddings e on e.photo_id = i.id
         where i.in_trash = 0 and e.dim = 512
           and i.latitude is not null and i.longitude is not null
           and i.library_id in (select id from photo_libraries where owner_id = ${uid})
         order by i.taken_at desc limit 3000
      `.execute(k.db)
    ).rows;
    if (anchors.length === 0) {
      visionState.running = false;
      return;
    }

    const toVec = (buf: Buffer) =>
      new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.byteLength / 4));
    const anchorVecs = anchors.map((a) => ({ ...a, vec: toVec(a.vec) }));
    const dot = (a: Float32Array, b: Float32Array) => {
      let s = 0;
      for (let i = 0; i < a.length; i += 1) s += a[i] * b[i];
      return s;
    };

    for (const row of missing) {
      const vec = toVec(row.vec);
      let best: { anchor: (typeof anchorVecs)[number]; sim: number } | null = null;
      for (const anchor of anchorVecs) {
        const sim = dot(vec, anchor.vec);
        if (!best || sim > best.sim) best = { anchor, sim };
      }
      if (best && best.sim >= 0.92) {
        await sql`
          insert into photo_gps_candidates
            (id, owner_id, photo_id, anchor_id, latitude, longitude, similarity, status, created_at)
          values (${`gc_${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`}, ${uid},
                  ${row.id}, ${best.anchor.id}, ${Number(best.anchor.latitude)},
                  ${Number(best.anchor.longitude)}, ${best.sim}, 'pending',
                  ${Math.floor(Date.now() / 1000)})
          on conflict(owner_id, photo_id) do update set
            anchor_id = excluded.anchor_id,
            latitude = excluded.latitude,
            longitude = excluded.longitude,
            similarity = excluded.similarity,
            status = 'pending'
        `.execute(k.db);
        visionState.generated += 1;
      }
      visionState.done += 1;
    }
  } catch (err) {
    k.log.warn({ err: String((err as Error)?.message || err) }, 'gps vision candidates failed');
  } finally {
    visionState.running = false;
  }
}