import fs from 'node:fs';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { extractFrames } from '../media-frames';
import { applyAlbumRulesForItems } from '../album-rules';
import { assignCluster, fromBuffer } from './face';
import { invalidatePhotoVectorIndex, searchPhotoVectors } from './vector-index';
import { aiAvailable, ensureSidecar, ffmpegPath } from './sidecar';
import {
  aiConfig,
  aiNeededMask,
  AI_DONE_BASE,
  AI_DONE_OCR,
  AI_DONE_ACTIVITY,
  noteAiJob,
  clearAiJob,
  FACE_MIN_WIDTH_RATIO,
} from './config';
import { EMB_DIM, now, ref } from './schemas';
import { Err } from '../../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

const toBuffer = (vec: number[]): Buffer => Buffer.from(new Float32Array(vec).buffer);

/** sidecar `analyze` 的返回结构 */
interface AnalyzeOut {
  faces: Array<{
    score: number;
    quality?: number;
    pose?: { yaw: number | null; roll: number | null; iod?: number } | null;
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
}

interface PendingRow {
  id: string;
  rel_path: string;
  media_kind?: string | null;
  duration_ms?: number | null;
}

/** 分析一批时需要的媒体信息（视频要抽帧、动态照片要切尾部视频） */
interface AnalyzeRow extends PendingRow {
  ai_done_mask: number;
  media_kind: string | null;
  live_kind: string | null;
  live_size: number | null;
  duration_ms: number | null;
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
        select i.id, i.rel_path, i.media_kind, i.duration_ms from photo_items i
         where i.library_id = ${body.libraryId} and i.in_trash = 0
           ${doneSql(force)}
         order by i.taken_at desc limit ${limit}
      `.execute(k.db)
    ).rows;
  }
  return (
    await sql<PendingRow>`
      select i.id, i.rel_path, i.media_kind, i.duration_ms from photo_items i
       where i.in_trash = 0
         ${doneSql(force)}
       order by i.taken_at desc limit ${limit}
    `.execute(k.db)
  ).rows;
}

/** 视频要先抽一帧才能给 sidecar：返回可分析的临时路径 + 清理函数 */
async function analyzeSource(
  k: KernelApi,
  abs: string,
  row: PendingRow,
): Promise<{ src: string; cleanup: () => Promise<void> }> {
  if (row.media_kind !== 'video') return { src: abs, cleanup: async () => undefined };
  const fr = await extractFrames(k, abs, { durationMs: Number(row.duration_ms) || null, count: 1 });
  if (fr.files.length === 0) {
    await fr.cleanup();
    return { src: abs, cleanup: async () => undefined };
  }
  return { src: fr.files[0], cleanup: fr.cleanup };
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
  const wantActivity =
    (opts.wantActivity ?? cfg.activityEnabled) === true && cfg.activityEnabled;
  // 「本次要集齐哪些位」必须和本次实际请求一致。按当前开关硬算会让
  // 手动 analyze（body 默认不带 ocr/activity）永远挑到同一批照片：
  // 它要求的位这次根本没做，remaining 不降、热循环（冒烟实测 2026-11-06）。
  // 长期待办仍由 enqueueScanOnce 按开关算（aiNeededMask），两者分工明确。
  const needMask =
    AI_DONE_BASE | (wantOcr ? AI_DONE_OCR : 0) | (wantActivity ? AI_DONE_ACTIVITY : 0);
  noteAiJob('face');
  noteAiJob('place');
  noteAiJob('clip');
  if (wantOcr) noteAiJob('ocr');
  if (wantActivity) noteAiJob('activity');
  // 按「做过哪些项」挑片，而不是「有没有 embedding」：
  // 以前只认 embedding，导致开关后来才打开的照片（OCR / 活动）永远不会被补做，
  // 系统误判「全部识别完」→ 重启不入队 → 面板一直显示空闲（2026-11-06）。
  // 失败过的不再重复挑：坏图永远产不出 embedding，不排除就会打成 0.2s 一轮的热循环。
  const pendingCond = force
    ? sql``
    : sql`and i.ai_skip_at = 0 and (i.ai_done_mask & ${needMask}) <> ${needMask}`;
  const rows = (
    opts.libraryId
      ? await sql<AnalyzeRow>`
          select i.id, i.rel_path, i.ai_done_mask, i.media_kind, i.live_kind, i.live_size,
                 i.duration_ms
          from photo_items i
          where i.library_id = ${opts.libraryId} and i.in_trash = 0
            ${pendingCond}
          order by i.taken_at desc limit ${limit}
        `.execute(k.db)
      : await sql<AnalyzeRow>`
          select i.id, i.rel_path, i.ai_done_mask, i.media_kind, i.live_kind, i.live_size,
                 i.duration_ms
          from photo_items i
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
    const doneMask = Number(row.ai_done_mask) || 0;
    // 已经做过的基础结果不重算：老照片只补 OCR / 活动，sidecar 会跳过
    // 人脸检测和 CLIP 推理，1.9 万张补做不用再付一遍全量推理的代价。
    const needBase = force || (doneMask & AI_DONE_BASE) === 0;
    const doOcr = wantOcr && (force || (doneMask & AI_DONE_OCR) === 0);
    const doActivity = wantActivity && (force || (doneMask & AI_DONE_ACTIVITY) === 0);
    const isVideo = row.media_kind === 'video';
    const liveSize = Number(row.live_size) || 0;
    const isMotion = row.live_kind === 'motion' && liveSize > 0;

    // 视频不能直接喂 analyze（它只解一帧静态图，而且首帧多半是黑场，
    // 抽出来是「一片黑」照样会被判成场景）。先抽中段一帧成临时 JPEG 再分析。
    let analyzeSrc = abs;
    let frameCleanup: (() => Promise<void>) | null = null;
    if (isVideo) {
      const fr = await extractFrames(k, abs, {
        durationMs: Number(row.duration_ms) || null,
        count: 1,
      });
      frameCleanup = fr.cleanup;
      if (fr.files.length === 0) {
        // 抽不出帧（损坏 / 不支持的编码）：记账跳过，别每轮重新挑中打热循环
        await sql`
          update photo_items
             set ai_skip_at = ${now()}, ai_skip_reason = 'video frame extract failed'
           where id = ${row.id}
        `.execute(k.db);
        skipped += 1;
        continue;
      }
      analyzeSrc = fr.files[0];
    }

    try {
      let out: AnalyzeOut;
      try {
        out = await s.request<AnalyzeOut>(
          'analyze',
          {
            src: analyzeSrc,
            faces: needBase && cfg.faceEnabled,
            scenes: needBase && cfg.placeEnabled,
            embed: needBase,
            ocr: doOcr,
            activity: doActivity,
          },
          600_000,
        );
      } finally {
        if (frameCleanup) await frameCleanup();
      }

      if (force && needBase) {
        await sql`delete from photo_faces where photo_id = ${row.id}`.execute(k.db);
      }
      if (needBase && cfg.faceEnabled) {
        // 同一张照片共用一份「已用过的组」：合照里两张脸绝不能并进同一个人。
        const usedClusterIds = new Set<string>();
        for (const face of out.faces) {
          // 小脸门：面积占比过小的脸多半是背景路人，进了库只会把簇搅浑。
          // 阈值按既有实现的口径（box_width / photo_width），可用环境变量覆盖。
          const iw = face.imgWidth ?? 0;
          if (face.box && iw > 0 && face.box.width / iw < FACE_MIN_WIDTH_RATIO) {
            smallFacesSkipped += 1;
            continue;
          }
          const res = await assignCluster(k, Float32Array.from(face.emb), row.id, {
            quality: face.quality ?? Math.round((Number(face.score) || 0) * 100),
            score: Number(face.score) || 0,
            poseYaw: face.pose?.yaw ?? null,
            poseRoll: face.pose?.roll ?? null,
            poseIod: face.pose?.iod ?? null,
            usedClusterIds,
            box: face.box
              ? {
                  left: face.box.left,
                  top: face.box.top,
                  width: face.box.width,
                  height: face.box.height,
                  imgWidth: face.imgWidth,
                  imgHeight: face.imgHeight,
                }
              : null,
          });
          if (res) faceCount += 1;
        }
      }
      if (needBase && cfg.placeEnabled && out.scenes.length > 0) {
        await sql`
          insert into photo_scenes (photo_id, label, score, updated_at)
          values (${row.id}, ${out.scenes[0].label}, ${out.scenes[0].score}, ${now()})
          on conflict(photo_id) do update set
            label = excluded.label, score = excluded.score, updated_at = excluded.updated_at
        `.execute(k.db);
        sceneCount += 1;
      }
      // v2：保留多标签与门控出口（top-1 仍在 photo_scenes，兼容既有查询）
      if (needBase && out.sceneGate) {
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
      if (needBase && out.embedding.length === EMB_DIM) {
        await sql`
          insert into photo_embeddings (photo_id, dim, vec, updated_at)
          values (${row.id}, ${EMB_DIM}, ${toBuffer(out.embedding)}, ${now()})
          on conflict(photo_id) do update set
            dim = excluded.dim, vec = excluded.vec, updated_at = excluded.updated_at
        `.execute(k.db);
        // 新向量立刻可被以图搜图命中（否则要等索引 30 秒的行数检查）。
        // 只是一句 `state = null`，批量识别时不会拖慢写入；真正的重建发生在下一次查询。
        invalidatePhotoVectorIndex(k.db);
      }

      if (doOcr && out.ocr) {
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

      if (doActivity && out.activity) {
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
      // 只要这次 analyze 成功返回就记账「做过」，与有没有检出文字 / 活动无关：
      // 没有文字的照片本来就不会写 photo_ocr，用结果表当完成标记会永远循环。
      const gained =
        (needBase ? AI_DONE_BASE : 0) |
        (doOcr ? AI_DONE_OCR : 0) |
        (doActivity ? AI_DONE_ACTIVITY : 0);
      if (force) {
        // 重新识别成功了：清掉旧的失败记账，下次常规批次能正常纳入统计
        await sql`
          update photo_items
             set ai_done_mask = ${gained}, ai_skip_at = 0, ai_skip_reason = null
           where id = ${row.id}
        `.execute(k.db);
      } else if (gained) {
        await sql`
          update photo_items set ai_done_mask = ai_done_mask | ${gained} where id = ${row.id}
        `.execute(k.db);
      }
    } catch (err) {
      const message = String((err as Error)?.message || err);
      if (needBase) {
        // 坏图 / 基础分析失败：记账，避免每轮重新挑中形成热循环（见 pendingCond）
        await sql`
          update photo_items
             set ai_skip_at = ${now()}, ai_skip_reason = ${message.slice(0, 200)}
           where id = ${row.id}
        `.execute(k.db);
      } else {
        // 只补做 OCR / 活动失败（多为模型缺失）：照片本身是好的，别把它永久
        // 踢出待办队列。置位本轮请求的项防止热循环，日志留原因，用户点「重置」可重跑。
        const gained = (doOcr ? AI_DONE_OCR : 0) | (doActivity ? AI_DONE_ACTIVITY : 0);
        if (gained) {
          await sql`
            update photo_items set ai_done_mask = ai_done_mask | ${gained} where id = ${row.id}
          `.execute(k.db);
        }
      }
      k.log.warn(
        { photo: row.id, err: message },
        'photo-ai analyze failed',
      );
      skipped += 1;
    }
  }

  // 规则相册：本批打了场景 / 人脸的片子，命中的自动收进相册。
  // 放在批结束后统一做一次（不是每张一次），避免 N 次查 albums 表。
  try {
    await applyAlbumRulesForItems(
      k.db,
      rows.map((r: any) => String(r.id)),
    );
  } catch (err) {
    k.log.warn({ err: String((err as Error)?.message || err) }, 'album rules apply failed');
  }

  const remainingRows = (
    await sql<{ n: number }>`
      select count(*) as n from photo_items i
       where i.in_trash = 0 and i.ai_skip_at = 0
         and (i.ai_done_mask & ${needMask}) <> ${needMask}
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
        const src = await analyzeSource(k, abs, row);
        try {
          const out = await s.request<{ text: string; lines: unknown[] }>(
            'ocr',
            { src: src.src },
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
        const src = await analyzeSource(k, abs, row);
        try {
          const out = await s.request<{
            labels: Array<{ key: string; label: string; score: number }>;
            topScore: number;
            hasActivity: boolean;
          }>('activity', { src: src.src }, 600_000);

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
      const uid = String((req as any).user?.sub || '');

      // 可见库：先取一次库 id（通常 1~5 个），后面回表过滤直接内联，
      // 比 `library_id in (select ...)` 让 SQLite 每次重算子查询更稳。
      const libIds = (
        await sql<{ id: string }>`
          select id from photo_libraries where owner_id = ${uid}
        `.execute(k.db)
      ).rows.map((r) => String(r.id));
      if (libIds.length === 0) return { items: [] };
      const libIn = sql.join(
        libIds.map((id) => sql`${id}`),
        sql`, `,
      );

      // 打分走内存常驻索引（全库 100% 覆盖，14ms 量级），不再有 scanLimit 的召回缺口。
      //
      // 索引只负责打分，权限过滤放在回表：先多取一些候选（limit × 20，最少 200），
      // 过滤回收站 / 非本人库之后如果不够 limit，就扩大候选重试。这样多用户场景下
      // 「别人库里的高分照片」不会占掉名额。
      const excluded = String(q.id ?? '');
      let want = Math.min(Math.max(limit * 20, 200), 20_000);
      let scored: Array<{ photoId: string; score: number }> = [];
      let scanned!: number;
      for (let attempt = 0; attempt < 4; attempt++) {
        const res = await searchPhotoVectors(k.db, baseVec, want, excluded);
        scanned = res.scanned;
        const cand = res.hits.filter((h) => minScore == null || h.score >= minScore);
        if (cand.length === 0) return { items: [] };
        const okIds = (
          await sql<{ id: string }>`
            select id from photo_items
             where id in (${sql.join(
               cand.map((c) => sql`${c.photoId}`),
               sql`, `,
             )})
               and in_trash = 0
               and library_id in (${libIn})
          `.execute(k.db)
        ).rows;
        const ok = new Set(okIds.map((r) => String(r.id)));
        scored = cand.filter((c) => ok.has(c.photoId)).slice(0, limit);
        if (scored.length >= limit || want >= scanned) break;
        want = Math.min(scanned, want * 4);
      }
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
 * 四个调用点：① 保存 AI 设置 ② 内核启动（重启续跑）③ 照片扫描结束
 * ④ 队列恢复（暂停时任务会 break 成 done，恢复必须重新入队，2026-11-06）。
 */
export async function enqueueScanOnce(
  k: KernelApi,
  opts: { force?: boolean; limit?: number } = {},
): Promise<{ queued: boolean; reason?: string }> {
  const cfg = aiConfig(k);
  if (cfg.paused) return { queued: false, reason: 'paused' };
  // 人脸 / 场景都关时不主动跑全库（用户已经明确不想做基础识别）
  if (!cfg.faceEnabled && !cfg.placeEnabled) return { queued: false, reason: 'disabled' };
  const needMask = aiNeededMask(cfg);

  const busy = (
    await sql<{ n: number }>`
      select count(*) as n from tasks
       where type = 'photo.ai.scan' and state in ('pending','running')
    `.execute(k.db)
  ).rows;
  if (Number(busy[0]?.n) > 0) return { queued: false, reason: 'running' };

  // 与 runAnalyzeBatch 完全同一把尺：缺哪一项就算待办，不再只看 embedding。
  // 否则「已有 embedding 但 OCR/活动是后来才开开关的」照片会被判定全部完成，
  // 重启不续跑、暂停恢复也不动，面板一直空闲（2026-11-06）。
  const pending = (
    await sql<{ n: number }>`
      select count(*) as n from photo_items i
       where i.in_trash = 0 and i.ai_skip_at = 0
         and (i.ai_done_mask & ${needMask}) <> ${needMask}
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
