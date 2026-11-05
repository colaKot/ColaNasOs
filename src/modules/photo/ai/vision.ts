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

/**
 * 跑一批 AI 分析（人脸 / 场景 / embedding，可选 OCR 与活动）。
 *
 * HTTP 路由与内核队列任务（`photo.ai.scan`）共用这一段。队列任务在内核重启后
 * 会被 recover() 重新捡起来 —— 「识别没跑完 → 重启 → 接着跑」靠的就是它，
 * 循环不能留在客户端（客户端一关就断，2026-11-04）。
 */
export async function runAnalyzeBatch(
  k: KernelApi,
  opts: {
    libraryId?: string;
    limit?: number;
    force?: boolean;
    wantOcr?: boolean;
    wantActivity?: boolean;
  },
): Promise<{
  processed: number;
  skipped: number;
  faces: number;
  facesTooSmall: number;
  scenes: number;
  ocr: number;
  activities: number;
  remaining: number;
  sceneGates: { confident: number; ambiguous: number; unknown: number };
}> {
  const cfg = aiConfig(k);
  const limit = Math.min(Number(opts.limit || 10) || 10, 200);
  const force = opts.force === true;
  // 未显式指定时跟随开关：开关是用户意图，不该因为调用方没传参数就被跳过
  // （2026-11-04：手动入队只传了 limit，OCR / 活动就一直不跑）
  const wantOcr = (opts.wantOcr ?? cfg.ocrEnabled) === true && cfg.ocrEnabled;
  const wantActivity = (opts.wantActivity ?? cfg.activityEnabled) === true && cfg.activityEnabled;
  noteAiJob('face');
  noteAiJob('place');
  noteAiJob('clip');
  if (wantOcr) noteAiJob('ocr');
  if (wantActivity) noteAiJob('activity');
  // 失败过的不再重复挑：没有 embedding 就做，而坏图永远产不出 embedding，
  // 不排除就会在每轮批次里反复被选中（实测会打成 0.2s 一轮的热循环）。
  const pendingCond = force
    ? sql``
    : sql`and i.ai_skip_at = 0 and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)`;
  const rows = (
    opts.libraryId
      ? await sql<{ id: string; rel_path: string }>`
          select i.id, i.rel_path from photo_items i
          where i.library_id = ${opts.libraryId} and i.in_trash = 0
            ${pendingCond}
          order by i.taken_at desc limit ${limit}
        `.execute(k.db)
      : await sql<{ id: string; rel_path: string }>`
          select i.id, i.rel_path from photo_items i
          where i.in_trash = 0
            ${pendingCond}
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
      if (force) {
        // 重新识别成功了：清掉旧的失败记账，下次常规批次能正常纳入统计
        await sql`
          update photo_items set ai_skip_at = 0, ai_skip_reason = null where id = ${row.id}
        `.execute(k.db);
      }
    } catch (err) {
      const message = String((err as Error)?.message || err);
      // 记账：坏图不记账就会被每轮重新挑中（见 pendingCond）
      await sql`
        update photo_items
           set ai_skip_at = ${now()}, ai_skip_reason = ${message.slice(0, 200)}
         where id = ${row.id}
      `.execute(k.db);
      k.log.warn(
        { photo: row.id, err: message },
        'photo-ai analyze failed',
      );
      skipped += 1;
    }
  }

  const remainingRows = (
    await sql<{ n: number }>`
      select count(*) as n from photo_items i
       where i.in_trash = 0 and i.ai_skip_at = 0
         and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)
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
}

export async function registerPhotoVision(app: any, k: KernelApi): Promise<void> {
  // 后台识别任务：一次点击把整库跑完，内核重启后由队列 recover() 接着跑。
  //
  // 为什么不能像以前那样在客户端循环：客户端一关 / 服务端一重启就断，
  // 用户看到的就是「识别没跑完，再打开也没有继续」（2026-11-04）。
  k.tasks.register('photo.ai.scan', async (payload, ctx) => {
    const opts = (payload || {}) as {
      limit?: number;
      force?: boolean;
      ocr?: boolean;
      activity?: boolean;
    };
    let processed = 0;
    // 第一次拿到的 processed+remaining 作为「本任务总量」：remaining 是还没做
    // embedding 的照片数，随着跑会减少。
    let total = -1;
    for (let round = 0; round < 100000; round += 1) {
      if (await ctx.isCanceled()) break;
      if (aiConfig(k).paused) {
        ctx.log('info', 'AI 任务已暂停，停止本轮');
        break;
      }
      const res = await runAnalyzeBatch(k, {
        limit: opts.limit ?? 50,
        force: opts.force,
        wantOcr: opts.ocr,
        wantActivity: opts.activity,
      });
      processed += res.processed;
      if (total < 0) total = res.processed + res.remaining;
      const done = Math.max(0, total - res.remaining);
      await ctx.progress(
        total > 0 ? Math.min(100, Math.floor((done / total) * 100)) : 0,
        done,
        total,
      );
      ctx.log('info', `AI 批次完成 processed=${res.processed} remaining=${res.remaining}`);
      // 这一批一张都没动（文件丢失 / 全跳过）就收工，避免死循环
      if (res.processed <= 0 || res.remaining <= 0) break;
    }
    return { processed };
  });
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
      // 真正的批处理在 runAnalyzeBatch：队列任务（photo.ai.scan）用的是同一个函数
      return await runAnalyzeBatch(k, {
        libraryId: body.libraryId,
        limit: body.limit,
        force: body.force,
        wantOcr: body.ocr,
        wantActivity: body.activity,
      });
    },
  );

  // 整库后台识别：入队一次，内核重启后由队列 recover() 接着跑
  app.post(
    '/api/v1/photo/ai/scan',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiScan',
        tags: ['photo'],
        summary: '整库后台识别（入队，重启后可续跑）',
        body: ref('PhotoAiScanBody'),
        response: { 200: ref('PhotoAiScanResponse'), 503: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      if (!aiAvailable()) {
        return reply
          .code(503)
          .send({ error: Err.aiUnavailable, message: '缺少模型 / ffmpeg / sidecar' });
      }
      if (aiConfig(k).paused) {
        return reply.code(503).send({ error: Err.aiUnavailable, message: 'AI 任务已暂停' });
      }
      const body = (req.body || {}) as {
        force?: boolean;
        ocr?: boolean;
        activity?: boolean;
        limit?: number;
      };
      const limit = Math.min(Math.max(Number(body.limit) || 50, 1), 200);
      const cfg = aiConfig(k);
      const { id, reused } = await k.tasks.enqueueIfIdle('photo.ai.scan', {
        force: body.force === true,
        // 不传就跟开关走：开着 OCR 就应该做 OCR，不该因为参数缺省被关掉
        ocr: body.ocr ?? cfg.ocrEnabled,
        activity: body.activity ?? cfg.activityEnabled,
        limit,
      });
      return { jobId: id, reused };
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
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      const rows = (
        await sql<{
          label: string;
          n: number;
          cover_id: string | null;
          cover_path: string | null;
        }>`
          select a.label, count(*) as n,
                 (select a2.photo_id
                    from photo_activities a2
                    join photo_items i2 on i2.id = a2.photo_id
                   where a2.label = a.label and a2.score >= 0.078
                     and i2.in_trash = 0
                     and i2.library_id in (select id from photo_libraries where owner_id = ${uid})
                   order by i2.taken_at desc limit 1) as cover_id,
                 (select i3.rel_path
                    from photo_activities a3
                    join photo_items i3 on i3.id = a3.photo_id
                   where a3.label = a.label and a3.score >= 0.078
                     and i3.in_trash = 0
                     and i3.library_id in (select id from photo_libraries where owner_id = ${uid})
                   order by i3.taken_at desc limit 1) as cover_path
            from photo_activities a
            join photo_items i on i.id = a.photo_id
           where a.score >= 0.078 and i.in_trash = 0
             and i.library_id in (select id from photo_libraries where owner_id = ${uid})
           group by a.label order by n desc limit 100
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          label: r.label,
          count: Number(r.n),
          coverId: r.cover_id ?? null,
          coverPath: r.cover_path ?? null,
        })),
      };
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
                   order by i2.taken_at desc, t2.score desc limit 1) as cover_id,
                 (select i3.rel_path
                    from photo_scene_tags t3
                    join photo_items i3 on i3.id = t3.photo_id
                   where t3.label = t.label and i3.in_trash = 0
                     and i3.library_id in (select id from photo_libraries where owner_id = ${uid})
                   order by i3.taken_at desc, t3.score desc limit 1) as cover_path
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

/**
 * 还有没识别的照片就自动入队一次（已经在跑就不重复入队）。
 *
 * 这是「打开开关就自己跑」的实现：以前要靠用户去点「开始识别」，
 * 开关开了也只是个配置，不点就永远不动（2026-11-04 反馈）。
 * 三个调用点：① 保存 AI 设置 ② 内核启动（重启续跑）③ 照片扫描结束。
 */
export async function enqueueScanOnce(
  k: KernelApi,
  opts: { force?: boolean; limit?: number } = {},
): Promise<{ queued: boolean; reason?: string }> {
  const cfg = aiConfig(k);
  if (cfg.paused) return { queued: false, reason: 'paused' };
  // analyze 只产 人脸 / 场景 / embedding，两个开关都关就没活可干
  if (!cfg.faceEnabled && !cfg.placeEnabled) return { queued: false, reason: 'disabled' };

  const busy = (
    await sql<{ n: number }>`
      select count(*) as n from tasks
       where type = 'photo.ai.scan' and state in ('pending','running')
    `.execute(k.db)
  ).rows;
  if (Number(busy[0]?.n) > 0) return { queued: false, reason: 'running' };

  const pending = (
    await sql<{ n: number }>`
      select count(*) as n from photo_items i
       where i.in_trash = 0 and i.ai_skip_at = 0
         and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)
    `.execute(k.db)
  ).rows;
  if (Number(pending[0]?.n) <= 0) return { queued: false, reason: 'done' };

  await k.tasks.enqueueIfIdle('photo.ai.scan', {
    force: opts.force === true,
    ocr: cfg.ocrEnabled,
    activity: cfg.activityEnabled,
    limit: opts.limit ?? 30,
  });
  return { queued: true };
}
