import fs from 'node:fs';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { assignCluster, fromBuffer } from './face';
import { aiAvailable, ensureSidecar, ffmpegPath } from './sidecar';
import { aiConfig, noteAiJob, clearAiJob, FACE_MIN_WIDTH_RATIO } from './config';
import { EMB_DIM, now, ref } from './schemas';
import { Err } from '../../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/** 余弦（相似检索用；人脸自带归一化，这里通用实现） */
function cosine(a: Float32Array | number[], b: Float32Array | number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}

const toBuffer = (vec: number[]): Buffer => Buffer.from(new Float32Array(vec).buffer);

interface PendingRow {
  id: string;
  rel_path: string;
}

/** 挑出「还没做某一项」的照片（force = 全量重算） */
async function pickPending(
  k: KernelApi,
  body: { libraryId?: string; limit?: number; force?: boolean },
  doneSql: (force: boolean) => any,
): Promise<PendingRow[]> {
  const limit = Math.min(Number(body.limit || 10) || 10, 200);
  const force = body.force === true;
  if (body.libraryId) {
    return (
      await sql<PendingRow>`
        select i.id, i.rel_path from photo_items i
         where i.library_id = ${body.libraryId} and i.in_trash = 0
           ${doneSql(force)}
         order by i.taken_at desc limit ${limit}
      `.execute(k.db)
    ).rows;
  }
  return (
    await sql<PendingRow>`
      select i.id, i.rel_path from photo_items i
       where i.in_trash = 0
         ${doneSql(force)}
       order by i.taken_at desc limit ${limit}
    `.execute(k.db)
  ).rows;
}

export async function registerPhotoVision(app: any, k: KernelApi): Promise<void> {
  // ---------------------------------------------------------------- 综合分析

  app.post(
    '/api/v1/photo/ai/analyze',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiAnalyze',
        tags: ['photo'],
        summary: '分批分析照片（人脸 / 场景 / embedding，可选 OCR 与活动）',
        body: ref('PhotoAiAnalyzeBody'),
        response: { 200: ref('PhotoAiAnalyzeResponse'), 503: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      if (!aiAvailable()) {
        return reply
          .code(503)
          .send({ error: Err.aiUnavailable, message: '缺少模型 / ffmpeg / sidecar' });
      }
      if (!k.media.available() && !ffmpegPath()) {
        return reply.code(503).send({ error: Err.aiUnavailable, message: 'ffmpeg 不可用' });
      }

      const body = (req.body || {}) as {
        libraryId?: string;
        limit?: number;
        force?: boolean;
        ocr?: boolean;
        activity?: boolean;
      };
      const cfg = aiConfig(k);
      if (cfg.paused) {
        return reply.code(503).send({ error: Err.aiUnavailable, message: 'AI 任务已暂停' });
      }
      const limit = Math.min(Number(body.limit || 10) || 10, 200);
      const force = body.force === true;
      const wantOcr = body.ocr === true && cfg.ocrEnabled;
      const wantActivity = body.activity === true && cfg.activityEnabled;
      noteAiJob('face');
      noteAiJob('place');
      noteAiJob('clip');
      if (wantOcr) noteAiJob('ocr');
      if (wantActivity) noteAiJob('activity');

      const rows = (
        body.libraryId
          ? await sql<{ id: string; rel_path: string }>`
              select i.id, i.rel_path from photo_items i
              where i.library_id = ${body.libraryId} and i.in_trash = 0
                ${force ? sql`` : sql`and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)`}
              order by i.taken_at desc limit ${limit}
            `.execute(k.db)
          : await sql<{ id: string; rel_path: string }>`
              select i.id, i.rel_path from photo_items i
              where i.in_trash = 0
                ${force ? sql`` : sql`and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)`}
              order by i.taken_at desc limit ${limit}
            `.execute(k.db)
      ).rows;

      const s = await ensureSidecar(k);
      const root = filesRoot();
      let processed = 0;
      let skipped = 0;
      let faceCount = 0;
      let sceneCount = 0;
      const sceneGateCounts = { confident: 0, ambiguous: 0, unknown: 0 };
      let ocrCount = 0;
      let activityCount = 0;
      let smallFacesSkipped = 0;

      for (const row of rows) {
        const abs = resolveAnyPath(root, row.rel_path);
        if (!fs.existsSync(abs)) {
          skipped += 1;
          continue;
        }
        try {
          const out = await s.request<{
            faces: Array<{
              score: number;
              emb: number[];
              box?: { left: number; top: number; width: number; height: number } | null;
              imgWidth?: number;
              imgHeight?: number;
            }>;
            scenes: Array<{ label: string; score: number }>;
            sceneGate?: {
              exit: 'confident' | 'ambiguous' | 'unknown';
              reason: string;
              score: number;
              margin: number;
              scorable: boolean | null;
            } | null;
            embedding: number[];
            ocr?: { text: string; lines: unknown[] } | null;
            activity?: {
              labels: Array<{ key: string; label: string; score: number }>;
              topScore: number;
              hasActivity: boolean;
            } | null;
          }>(
            'analyze',
            {
              src: abs,
              faces: cfg.faceEnabled,
              scenes: cfg.placeEnabled,
              embed: true,
              ocr: wantOcr,
              activity: wantActivity,
            },
            600_000,
          );

          if (force) {
            await sql`delete from photo_faces where photo_id = ${row.id}`.execute(k.db);
          }
          if (cfg.faceEnabled) {
            for (const face of out.faces) {
              // 小脸门：面积占比过小的脸多半是背景路人，进了库只会把簇搅浑。
              // 阈值按参考实现的口径（box_width / photo_width），可用环境变量覆盖。
              const iw = face.imgWidth ?? 0;
              if (face.box && iw > 0 && face.box.width / iw < FACE_MIN_WIDTH_RATIO) {
                smallFacesSkipped += 1;
                continue;
              }
              await assignCluster(
                k,
                Float32Array.from(face.emb),
                row.id,
                face.box
                  ? {
                      left: face.box.left,
                      top: face.box.top,
                      width: face.box.width,
                      height: face.box.height,
                      imgWidth: face.imgWidth,
                      imgHeight: face.imgHeight,
                    }
                  : null,
                Number(face.score) || 1,
              );
              faceCount += 1;
            }
          }
          if (cfg.placeEnabled && out.scenes.length > 0) {
            await sql`
              insert into photo_scenes (photo_id, label, score, updated_at)
              values (${row.id}, ${out.scenes[0].label}, ${out.scenes[0].score}, ${now()})
              on conflict(photo_id) do update set
                label = excluded.label, score = excluded.score, updated_at = excluded.updated_at
            `.execute(k.db);
            sceneCount += 1;
          }
          // v2：保留多标签与门控出口（top-1 仍在 photo_scenes，兼容既有查询）
          if (out.sceneGate) {
            const exit = out.sceneGate.exit;
            await sql`delete from photo_scene_tags where photo_id = ${row.id}`.execute(k.db);
            for (const s of out.scenes) {
              await sql`
                insert into photo_scene_tags (photo_id, label, score, gate, updated_at)
                values (${row.id}, ${s.label}, ${Number(s.score) || 0}, ${exit}, ${now()})
                on conflict(photo_id, label) do update set
                  score = excluded.score, gate = excluded.gate, updated_at = excluded.updated_at
              `.execute(k.db);
            }
            sceneGateCounts[exit] += 1;
            k.log.debug({ photo: row.id, gate: out.sceneGate }, 'scene gate');
          }
          if (out.embedding.length === EMB_DIM) {
            await sql`
              insert into photo_embeddings (photo_id, dim, vec, updated_at)
              values (${row.id}, ${EMB_DIM}, ${toBuffer(out.embedding)}, ${now()})
              on conflict(photo_id) do update set
                dim = excluded.dim, vec = excluded.vec, updated_at = excluded.updated_at
            `.execute(k.db);
          }

          if (wantOcr && out.ocr) {
            const text = String(out.ocr.text || '').trim();
            if (text) {
              await sql`
                insert into photo_ocr (photo_id, text, updated_at)
                values (${row.id}, ${text}, ${now()})
                on conflict(photo_id) do update set
                  text = excluded.text, updated_at = excluded.updated_at
              `.execute(k.db);
              ocrCount += 1;
            }
          }

          if (wantActivity && out.activity) {
            if (force) {
              await sql`delete from photo_activities where photo_id = ${row.id}`.execute(k.db);
            }
            if (out.activity.hasActivity && out.activity.labels.length > 0) {
              for (const label of out.activity.labels) {
                await sql`
                  insert into photo_activities (photo_id, label, score, updated_at)
                  values (${row.id}, ${label.label}, ${Number(label.score) || 0}, ${now()})
                  on conflict(photo_id, label) do update set
                    score = excluded.score, updated_at = excluded.updated_at
                `.execute(k.db);
              }
              activityCount += out.activity.labels.length;
            }
          }
          processed += 1;
        } catch (err) {
          k.log.warn(
            { photo: row.id, err: String((err as Error)?.message || err) },
            'photo-ai analyze failed',
          );
          skipped += 1;
        }
      }

      const remainingRows = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items i
           where i.in_trash = 0 and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)
        `.execute(k.db)
      ).rows;

      clearAiJob('face');
      clearAiJob('place');
      clearAiJob('clip');
      if (wantOcr) clearAiJob('ocr');
      if (wantActivity) clearAiJob('activity');

      return {
        processed,
        skipped,
        faces: faceCount,
        facesTooSmall: smallFacesSkipped,
        scenes: sceneCount,
        ocr: ocrCount,
        activities: activityCount,
        remaining: Number(remainingRows[0]?.n ?? 0),
        sceneGates: sceneGateCounts,
      };
    },
  );

  // ---------------------------------------------------------------- OCR

  app.post(
    '/api/v1/photo/ai/ocr',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiOcr',
        tags: ['photo'],
        summary: '分批做文字识别（票夹与语义搜索的原料）',
        body: ref('PhotoAiBatchBody'),
        response: { 200: ref('PhotoAiAnalyzeResponse'), 503: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      if (!aiAvailable()) {
        return reply
          .code(503)
          .send({ error: Err.aiUnavailable, message: '缺少模型 / ffmpeg / sidecar' });
      }
      const body = (req.body || {}) as { libraryId?: string; limit?: number; force?: boolean };
      if (aiConfig(k).paused) {
        return reply.code(503).send({ error: Err.aiUnavailable, message: 'AI 任务已暂停' });
      }
      if (!aiConfig(k).ocrEnabled) {
        return reply
          .code(503)
          .send({ error: Err.aiUnavailable, message: 'OCR 已在 AI 设置中关闭' });
      }
      noteAiJob('ocr');
      const rows = await pickPending(k, body, (force) =>
        force ? sql`` : sql`and not exists (select 1 from photo_ocr o where o.photo_id = i.id)`,
      );

      const s = await ensureSidecar(k);
      const root = filesRoot();
      let processed = 0;
      let skipped = 0;
      let ocrCount = 0;

      for (const row of rows) {
        const abs = resolveAnyPath(root, row.rel_path);
        if (!fs.existsSync(abs)) {
          skipped += 1;
          continue;
        }
        try {
          const out = await s.request<{ text: string; lines: unknown[] }>(
            'ocr',
            { src: abs },
            600_000,
          );
          const text = String(out.text || '').trim();
          if (text) {
            await sql`
              insert into photo_ocr (photo_id, text, updated_at)
              values (${row.id}, ${text}, ${now()})
              on conflict(photo_id) do update set text = excluded.text, updated_at = excluded.updated_at
            `.execute(k.db);
            ocrCount += 1;
          }
          processed += 1;
        } catch (err) {
          k.log.warn(
            { photo: row.id, err: String((err as Error)?.message || err) },
            'photo-ai ocr failed',
          );
          skipped += 1;
        }
      }

      const remaining = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items i
           where i.in_trash = 0 and not exists (select 1 from photo_ocr o where o.photo_id = i.id)
        `.execute(k.db)
      ).rows[0];

      clearAiJob('ocr');

      return {
        processed,
        skipped,
        faces: 0,
        scenes: 0,
        ocr: ocrCount,
        activities: 0,
        remaining: Number(remaining?.n ?? 0),
      };
    },
  );

  // ---------------------------------------------------------------- 活动

  app.post(
    '/api/v1/photo/ai/activities',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiActivities',
        tags: ['photo'],
        summary: '分批做活动识别（SigLIP2 零样本，τ=0.078）',
        body: ref('PhotoAiBatchBody'),
        response: { 200: ref('PhotoAiAnalyzeResponse'), 503: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      if (!aiAvailable()) {
        return reply
          .code(503)
          .send({ error: Err.aiUnavailable, message: '缺少模型 / ffmpeg / sidecar' });
      }
      const body = (req.body || {}) as { libraryId?: string; limit?: number; force?: boolean };
      if (aiConfig(k).paused) {
        return reply.code(503).send({ error: Err.aiUnavailable, message: 'AI 任务已暂停' });
      }
      if (!aiConfig(k).activityEnabled) {
        return reply
          .code(503)
          .send({ error: Err.aiUnavailable, message: '活动识别已在 AI 设置中关闭' });
      }
      noteAiJob('activity');
      const rows = await pickPending(k, body, (force) =>
        force
          ? sql``
          : sql`and not exists (select 1 from photo_activities a where a.photo_id = i.id)`,
      );

      const s = await ensureSidecar(k);
      const root = filesRoot();
      let processed = 0;
      let skipped = 0;
      let activityCount = 0;

      for (const row of rows) {
        const abs = resolveAnyPath(root, row.rel_path);
        if (!fs.existsSync(abs)) {
          skipped += 1;
          continue;
        }
        try {
          const out = await s.request<{
            labels: Array<{ key: string; label: string; score: number }>;
            topScore: number;
            hasActivity: boolean;
          }>('activity', { src: abs }, 600_000);

          if (body.force === true) {
            await sql`delete from photo_activities where photo_id = ${row.id}`.execute(k.db);
          }
          if (out.hasActivity && out.labels.length > 0) {
            for (const label of out.labels) {
              await sql`
                insert into photo_activities (photo_id, label, score, updated_at)
                values (${row.id}, ${label.label}, ${Number(label.score) || 0}, ${now()})
                on conflict(photo_id, label) do update set
                  score = excluded.score, updated_at = excluded.updated_at
              `.execute(k.db);
            }
            activityCount += out.labels.length;
          }
          processed += 1;
        } catch (err) {
          k.log.warn(
            { photo: row.id, err: String((err as Error)?.message || err) },
            'photo-ai activity failed',
          );
          skipped += 1;
        }
      }

      const remaining = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items i
           where i.in_trash = 0 and not exists (select 1 from photo_activities a where a.photo_id = i.id)
        `.execute(k.db)
      ).rows[0];

      clearAiJob('activity');

      return {
        processed,
        skipped,
        faces: 0,
        scenes: 0,
        ocr: 0,
        activities: activityCount,
        remaining: Number(remaining?.n ?? 0),
      };
    },
  );

  app.get(
    '/api/v1/photo/activities',
    secured('photo:read', {
      schema: {
        operationId: 'photoActivities',
        tags: ['photo'],
        summary: '某个活动下的照片',
        querystring: ref('PhotoActivityQuery'),
        response: { 200: ref('PhotoAiPhotoRefList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { label?: string; limit?: number };
      const limit = Math.min(Number(q.limit || 60) || 60, 200);
      const rows = (
        await sql<{ id: string; rel_path: string; taken_at: number; score: number }>`
          select i.id, i.rel_path, i.taken_at, a.score
            from photo_activities a
            join photo_items i on i.id = a.photo_id
           where a.label = ${q.label ?? ''} and a.score >= 0.078 and i.in_trash = 0
           order by i.taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          score: Number(r.score),
        })),
      };
    },
  );

  app.get(
    '/api/v1/photo/activities/summary',
    secured('photo:read', {
      schema: {
        operationId: 'photoActivitySummary',
        tags: ['photo'],
        summary: '活动分布（按张数倒序）',
        response: { 200: ref('PhotoSceneSummary') },
      },
    }),
    async () => {
      const rows = (
        await sql<{ label: string; n: number }>`
          select a.label, count(*) as n
            from photo_activities a
            join photo_items i on i.id = a.photo_id
           where a.score >= 0.078 and i.in_trash = 0
           group by a.label order by n desc limit 100
        `.execute(k.db)
      ).rows;
      return { items: rows.map((r) => ({ label: r.label, count: Number(r.n) })) };
    },
  );

  // ---------------------------------------------------------------- 场景

  app.get(
    '/api/v1/photo/scenes/summary',
    secured('photo:read', {
      schema: {
        operationId: 'photoSceneSummary',
        tags: ['photo'],
        summary: '场景分布（按照片数倒序）',
        response: { 200: ref('PhotoSceneSummary') },
      },
    }),
    async () => {
      const rows = (
        await sql<{ label: string; n: number }>`
          select s.label, count(*) as n
            from photo_scenes s
            join photo_items i on i.id = s.photo_id
           where i.in_trash = 0
           group by s.label order by n desc limit 100
        `.execute(k.db)
      ).rows;
      return { items: rows.map((r) => ({ label: r.label, count: Number(r.n) })) };
    },
  );

  // ---------------------------------------------------------------- 场景多标签（含置信度）

  app.get(
    '/api/v1/photo/scene-tags/summary',
    secured('photo:read', {
      schema: {
        operationId: 'photoSceneTagSummary',
        tags: ['photo'],
        summary: '场景多标签分布：张数 + confident/ambiguous 分层 + 封面',
        response: { 200: ref('PhotoSceneTagSummary') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      const rows = (
        await sql<{
          label: string;
          n: number;
          confident: number | null;
          cover_id: string | null;
          cover_path: string | null;
        }>`
          select t.label,
                 count(*) as n,
                 sum(case when t.gate = 'confident' then 1 else 0 end) as confident,
                 (select t2.photo_id
                    from photo_scene_tags t2
                    join photo_items i2 on i2.id = t2.photo_id
                   where t2.label = t.label and i2.in_trash = 0
                     and i2.library_id in (select id from photo_libraries where owner_id = ${uid})
                   order by t2.score desc limit 1) as cover_id,
                 (select i3.rel_path
                    from photo_scene_tags t3
                    join photo_items i3 on i3.id = t3.photo_id
                   where t3.label = t.label and i3.in_trash = 0
                     and i3.library_id in (select id from photo_libraries where owner_id = ${uid})
                   order by t3.score desc limit 1) as cover_path
            from photo_scene_tags t
            join photo_items i on i.id = t.photo_id
           where i.in_trash = 0
             and i.library_id in (select id from photo_libraries where owner_id = ${uid})
           group by t.label
           order by n desc
           limit 120
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          label: r.label,
          count: Number(r.n) || 0,
          confident: Number(r.confident) || 0,
          ambiguous: Math.max(0, (Number(r.n) || 0) - (Number(r.confident) || 0)),
          coverId: r.cover_id ?? null,
          coverPath: r.cover_path ?? null,
        })),
      };
    },
  );

  app.get(
    '/api/v1/photo/scene-tags',
    secured('photo:read', {
      schema: {
        operationId: 'photoSceneTags',
        tags: ['photo'],
        summary: '某个场景标签下的照片（带 gate，可按高置信过滤）',
        querystring: ref('PhotoSceneTagQuery'),
        response: { 200: ref('PhotoSceneTagList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { label?: string; limit?: number; onlyConfident?: boolean };
      const uid = String((req as any).user?.sub || '');
      const label = String(q.label || '').trim();
      const limit = Math.max(1, Math.min(Number(q.limit) || 120, 500));
      if (!label) return { label: '', items: [] };
      const rows = (
        await sql<{ id: string; rel_path: string; taken_at: number; score: number; gate: string | null }>`
          select i.id, i.rel_path, i.taken_at, t.score, t.gate
            from photo_scene_tags t
            join photo_items i on i.id = t.photo_id
           where t.label = ${label}
             and i.in_trash = 0
             and i.library_id in (select id from photo_libraries where owner_id = ${uid})
             ${q.onlyConfident === true ? sql`and t.gate = 'confident'` : sql``}
           order by t.score desc
           limit ${limit}
        `.execute(k.db)
      ).rows;
      return {
        label,
        items: rows.map((r) => ({
          id: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          score: Number(r.score) || 0,
          gate: r.gate ?? null,
        })),
      };
    },
  );

  app.get(
    '/api/v1/photo/scene-tags/photo',
    secured('photo:read', {
      schema: {
        operationId: 'photoSceneTagsOfPhoto',
        tags: ['photo'],
        summary: '单张照片的全部场景标签（含 gate），详情页「这张像什么」用',
        querystring: ref('PhotoSceneTagsQuery'),
        response: { 200: ref('PhotoSceneTagList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { id?: string };
      const uid = String((req as any).user?.sub || '');
      const id = String(q.id || '').trim();
      if (!id) return { label: '', items: [] };
      const rows = (
        await sql<{ label: string; score: number; gate: string | null; rel_path: string; taken_at: number }>`
          select t.label, t.score, t.gate, i.rel_path, i.taken_at
            from photo_scene_tags t
            join photo_items i on i.id = t.photo_id
           where t.photo_id = ${id}
             and i.in_trash = 0
             and i.library_id in (select id from photo_libraries where owner_id = ${uid})
           order by t.score desc
           limit 20
        `.execute(k.db)
      ).rows;
      return {
        label: '',
        items: rows.map((r) => ({
          id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          score: Number(r.score) || 0,
          gate: r.gate ?? null,
          label: r.label,
        })),
      };
    },
  );

  app.get(
    '/api/v1/photo/scenes',
    secured('photo:read', {
      schema: {
        operationId: 'photoScenes',
        tags: ['photo'],
        summary: '某个场景下的照片',
        querystring: ref('PhotoSceneQuery'),
        response: { 200: ref('PhotoAiPhotoRefList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { label?: string; limit?: number };
      const limit = Math.min(Number(q.limit || 60) || 60, 200);
      const rows = (
        await sql<{ id: string; rel_path: string; taken_at: number; score: number }>`
          select i.id, i.rel_path, i.taken_at, s.score
          from photo_scenes s join photo_items i on i.id = s.photo_id
          where s.label = ${q.label ?? ''} and i.in_trash = 0
          order by i.taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          score: Number(r.score),
        })),
      };
    },
  );

  // ---------------------------------------------------------------- 以图搜图

  app.get(
    '/api/v1/photo/similar',
    secured('photo:read', {
      schema: {
        operationId: 'photoSimilar',
        tags: ['photo'],
        summary: '以图搜图（CLIP 余弦，内存内 top-k）',
        querystring: ref('PhotoSimilarQuery'),
        response: { 200: ref('PhotoAiPhotoRefList'), 404: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as { id?: string; limit?: number; minScore?: number };
      const limit = Math.min(Number(q.limit || 12) || 12, 100);
      const minScore = q.minScore == null ? null : Math.max(0, Math.min(Number(q.minScore), 1));

      const base = (
        await sql<{
          vec: Buffer;
        }>`select vec from photo_embeddings where photo_id = ${q.id ?? ''}`.execute(k.db)
      ).rows[0];
      if (!base)
        return reply.code(404).send({ error: Err.notFound, message: 'embedding not found' });

      const baseVec = fromBuffer(base.vec);
      // 相似检索是内存线性扫描：默认只看最近 5000 条，可用 COLANAS_VECTOR_SCAN_LIMIT 调大。
      // 超过上限时召回会受限（不是全库最近邻），因此命中上限要留一条告警，别让用户以为已是全库结果。
      const scanLimit = Math.max(
        100,
        Math.min(Number(process.env.COLANAS_VECTOR_SCAN_LIMIT) || 5000, 50_000),
      );
      const rows = (
        await sql<{ photo_id: string; vec: Buffer }>`
          select e.photo_id, e.vec from photo_embeddings e
            join photo_items i on i.id = e.photo_id
           where e.photo_id != ${q.id ?? ''} and i.in_trash = 0
           limit ${scanLimit}
        `.execute(k.db)
      ).rows;
      if (rows.length >= scanLimit) {
        k.log.warn(
          { scanLimit, photo: q.id },
          'photo.similar: scan limit reached, recall may be incomplete',
        );
      }

      const scored = rows
        .map((r) => ({ photoId: r.photo_id, score: cosine(baseVec, fromBuffer(r.vec)) }))
        .filter((s) => minScore == null || s.score >= minScore)
        .sort((a, b) => b.score - a.score)
        .slice(0, limit);
      if (scored.length === 0) return { items: [] };

      const ids = scored.map((s) => s.photoId);
      const photos = (
        await sql<{ id: string; rel_path: string; taken_at: number }>`
          select id, rel_path, taken_at from photo_items
          where id in (${sql.join(
            ids.map((id) => sql`${id}`),
            sql`, `,
          )})
        `.execute(k.db)
      ).rows;
      const byId = new Map(photos.map((p) => [p.id, p]));

      return {
        items: scored
          .map((s) => {
            const p = byId.get(s.photoId);
            if (!p) return null;
            return { id: p.id, path: p.rel_path, takenAt: Number(p.taken_at), score: s.score };
          })
          .filter(Boolean),
      };
    },
  );
}
