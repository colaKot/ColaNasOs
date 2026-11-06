import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { now, ref } from './schemas';
import {
  aiConfig,
  saveAiConfig,
  AI_DONE_BASE,
  AI_DONE_OCR,
  AI_DONE_ACTIVITY,
  noteAiJob,
  aiJobRunning,
} from './config';
import { enqueueScanOnce } from './vision';
import { faceIndex, fromBuffer, toBuffer, mergeClusterPair } from './face';
import { paramsFromEnv } from './cluster-v2';
import { ensureSidecar, aiAvailable } from './sidecar';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';

interface McpStored {
  enabled: boolean;
  uid: string;
  token: string;
}

const MCP_KEY = 'mcp';

function mcpStored(k: KernelApi): McpStored {
  const raw = (k.config.get<Partial<McpStored>>(MCP_KEY) || {}) as Partial<McpStored>;
  return {
    enabled: raw.enabled === true,
    uid: String(raw.uid || ''),
    token: String(raw.token || ''),
  };
}

async function ensureMcpToken(k: KernelApi): Promise<McpStored> {
  const cur = mcpStored(k);
  if (cur.token) return cur;
  const token = crypto.randomBytes(24).toString('base64url');
  await k.config.set(MCP_KEY, { ...cur, token });
  return { ...cur, token };
}

export const MCP_TOOLS = [
  'photo_search',
  'photo_similar',
  'photo_recent',
  'photo_scenes',
  'photo_faces',
  'photo_stats',
];

export async function registerPhotoAiSettings(app: FastifyInstance, k: KernelApi): Promise<void> {
  // ---------------------------------------------------------------- 配置读写

  app.get(
    '/api/v1/photo/ai/config',
    secured('photo:read', {
      schema: {
        operationId: 'photoAiConfig',
        tags: ['photo'],
        summary: 'AI 设置（配置 / 进度 / 任务队列）',
        response: { 200: ref('PhotoAiSettings') },
      },
    }),
    async (req: FastifyRequest) => {
      const cfg = aiConfig(k);
      const uid = String((req as any).user?.sub || '');
      const owner = sql`i.in_trash = 0 and i.library_id in (select id from photo_libraries where owner_id = ${uid})`;
      // 进度 = 「做过这项分析的照片数」，不是「检出结果的照片数」。
      // 以前按结果表 count：没有文字的照片永远不写 photo_ocr、没活动的永远不写
      // photo_activities，OCR / 活动的进度条就永远停在 45% / 24%，看着像没跑完，
      // 但队列其实已经没有待办任务了（2026-11-06 反馈「一直显示空闲」）。
      // 分母排除「已记账失败」的坏图：它们永远产不出结果，算进总数会让
      // 进度条永远差几张、看起来又像没跑完（可用「重新识别」force 重试）。
      const row = (
        await sql<{
          total: number;
          base: number;
          activity: number;
          ocr: number;
        }>`
          select
            (select count(*) from photo_items i where ${owner} and i.ai_skip_at = 0) as total,
            (select count(*) from photo_items i where ${owner} and (i.ai_done_mask & ${AI_DONE_BASE}) <> 0) as base,
            (select count(*) from photo_items i where ${owner} and (i.ai_done_mask & ${AI_DONE_ACTIVITY}) <> 0) as activity,
            (select count(*) from photo_items i where ${owner} and (i.ai_done_mask & ${AI_DONE_OCR}) <> 0) as ocr
        `.execute(k.db)
      ).rows[0];
      const total = Number(row?.total) || 0;
      const pct = (done: number) =>
        total <= 0 ? 0 : Math.min(100, Math.round((done / total) * 100));
      // 同时保留真实「已识别条数」：19113 张时识别 20 张，百分比会被四舍五入成 0%，
      // 只看百分比会误以为任务没动，所以 pending 用真实剩余数（不再按百分比反推）。
      const base = Number(row?.base) || 0;
      const doneOf = {
        face: base,
        place: base,
        activity: Number(row?.activity) || 0,
        ocr: Number(row?.ocr) || 0,
        clip: base,
      };
      // 队列里真有任务才算「识别中」。以前只看内存里的 aiJobRunning()，
      // 批次间隙或任务排队时一律回落 idle，面板就永远显示「空闲」。
      const active = (
        await sql<{ n: number }>`
          select count(*) as n from tasks
           where type = 'photo.ai.scan' and state in ('pending','running')
        `.execute(k.db)
      ).rows[0];
      const queueActive = Number(active?.n) > 0;
      const progress = {
        face: pct(doneOf.face),
        place: pct(doneOf.place),
        activity: pct(doneOf.activity),
        ocr: pct(doneOf.ocr),
        clip: pct(doneOf.clip),
        similarScan: 0,
        similarCompare: 0,
      };
      const job = (
        key: string,
        label: string,
        enabled: boolean,
        percent: number,
        done: number,
        totalCount = total,
      ) => ({
        key,
        label,
        status: !enabled ? 'disabled' : queueActive || aiJobRunning(key) ? 'running' : 'idle',
        pending: Math.max(0, totalCount - done),
        // 面板显示「已完成/总数」：几万张里识别 20 张，百分比会被四舍五入成 0%，
        // 只有条数才能让人看出任务真的在推进
        done,
        total: totalCount,
        percent,
      });
      return {
        config: cfg,
        progress,
        queue: {
          paused: cfg.paused,
          jobs: [
            job('face', '人脸识别', cfg.faceEnabled, progress.face, doneOf.face),
            job('ocr', 'OCR 文字', cfg.ocrEnabled, progress.ocr, doneOf.ocr),
            job('place', '场景识别', cfg.placeEnabled, progress.place, doneOf.place),
            job('activity', '活动识别', cfg.activityEnabled, progress.activity, doneOf.activity),
            job('clip', '图像搜索', true, progress.clip, doneOf.clip),
            job('similar', '重复照片', cfg.similarEnabled, 0, 0, 0),
          ],
        },
      };
    },
  );

  app.post(
    '/api/v1/photo/ai/config',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiConfigSet',
        tags: ['photo'],
        summary: '保存 AI 设置（部分字段）',
        body: ref('PhotoAiConfigBody'),
        response: { 200: ref('PhotoAiConfig') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const patch: Record<string, unknown> = {};
      for (const key of [
        'faceEnabled',
        'placeEnabled',
        'activityEnabled',
        'ocrEnabled',
        'similarEnabled',
        'gpuPrefer',
        'paused',
      ] as const) {
        if (typeof body[key] === 'boolean') patch[key] = body[key];
      }
      if (typeof body.faceMinShowCount === 'number') {
        patch.faceMinShowCount = Math.max(0, Math.min(1000, body.faceMinShowCount));
      }
      if (
        typeof body.matchSim === 'number' ||
        typeof body.minVotes === 'number' ||
        typeof body.threads === 'number'
      ) {
        const cur = aiConfig(k).tuning;
        patch.tuning = {
          matchSim:
            typeof body.matchSim === 'number'
              ? Math.max(0.3, Math.min(0.75, body.matchSim))
              : cur.matchSim,
          minVotes:
            typeof body.minVotes === 'number'
              ? Math.max(1, Math.min(8, Math.round(body.minVotes)))
              : cur.minVotes,
          threads:
            typeof body.threads === 'number'
              ? Math.max(1, Math.min(8, Math.round(body.threads)))
              : cur.threads,
        };
      }
      const before = aiConfig(k);
      const cfg = await saveAiConfig(k, patch as any);
      if (before.gpuPrefer !== cfg.gpuPrefer) {
        const { stopSidecar } = await import('./sidecar');
        await stopSidecar();
      }
      // 开关一打开就自己开始识别，不需要用户再去找「开始识别」按钮。
      // await 而不是 void：接口返回时任务已入队，前端紧接着刷新就能看到「识别中」。
      await enqueueScanOnce(k).catch(() => null);
      return cfg;
    },
  );

  app.post(
    '/api/v1/photo/ai/queue/pause',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiQueuePause',
        tags: ['photo'],
        summary: '暂停 / 恢复 AI 任务队列',
        body: ref('PhotoAiQueuePauseBody'),
        response: { 200: ref('PhotoAiConfig') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { paused?: boolean };
      const cfg = await saveAiConfig(k, { paused: body.paused === true });
      if (!cfg.paused) {
        // 暂停时 photo.ai.scan 的循环检测到 paused 就 break、任务变成 done，
        // 队列里再没有任何待跑任务。恢复只改配置是不够的 —— 必须重新入队，
        // 否则「恢复」点完毫无反应、任务栏一直空闲（2026-11-06）。
        const r = await enqueueScanOnce(k).catch(() => null);
        k.log.info({ ...(r || {}) }, 'photo.ai queue resumed');
      }
      return cfg;
    },
  );

  // ---------------------------------------------------------------- 识别结果重置

  app.post(
    '/api/v1/photo/ai/reset',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiReset',
        tags: ['photo'],
        summary: '清空某一类识别结果（OCR / 场景 / 活动 / 去重）',
        body: ref('PhotoAiResetBody'),
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { kind?: string };
      const uid = String((req as any).user?.sub || '');
      const owner = sql`photo_id in (
        select id from photo_items
         where library_id in (select id from photo_libraries where owner_id = ${uid})
      )`;
      const itemOwner = sql`id in (
        select id from photo_items
         where library_id in (select id from photo_libraries where owner_id = ${uid})
      )`;
      const kind = String(body.kind || '');
      let count = 0;
      if (kind === 'ocr') {
        const before = (
          await sql<{ n: number }>`select count(*) as n from photo_ocr where ${owner}`.execute(k.db)
        ).rows[0];
        await sql`delete from photo_ocr where ${owner}`.execute(k.db);
        // 清完成位：不清的话 scan 认为这项已经做过，重置完也不会重新识别
        await sql`
          update photo_items set ai_done_mask = ai_done_mask & ~${AI_DONE_OCR} where ${itemOwner}
        `.execute(k.db);
        count = Number(before?.n) || 0;
      } else if (kind === 'place') {
        const before = (
          await sql<{ n: number }>`select count(*) as n from photo_scenes where ${owner}`.execute(
            k.db,
          )
        ).rows[0];
        await sql`delete from photo_scene_tags where ${owner}`.execute(k.db);
        await sql`delete from photo_scenes where ${owner}`.execute(k.db);
        await sql`
          update photo_items set ai_done_mask = ai_done_mask & ~${AI_DONE_BASE} where ${itemOwner}
        `.execute(k.db);
        count = Number(before?.n) || 0;
      } else if (kind === 'activity') {
        const before = (
          await sql<{
            n: number;
          }>`select count(*) as n from photo_activities where ${owner}`.execute(k.db)
        ).rows[0];
        await sql`delete from photo_activities where ${owner}`.execute(k.db);
        await sql`
          update photo_items set ai_done_mask = ai_done_mask & ~${AI_DONE_ACTIVITY} where ${itemOwner}
        `.execute(k.db);
        count = Number(before?.n) || 0;
      }
      // 清位后立刻重新入队，别让用户再去找「开始识别」
      await enqueueScanOnce(k).catch(() => null);
      return {
        ok: true,
        count,
        message: kind === 'similar' ? '相似去重请在「相似清理」页处理' : `已清空 ${count} 条`,
      };
    },
  );

  // ---------------------------------------------------------------- 人脸聚类参数

  app.post(
    '/api/v1/photo/faces/tuning',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceTuning',
        tags: ['photo'],
        summary: '保存人脸聚类参数（认人严格度 / 参考数 / 线程数）',
        body: ref('PhotoAiTuningBody'),
        response: { 200: ref('PhotoAiTuningResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { matchSim: number; minVotes: number; threads: number };
      await saveAiConfig(k, {
        tuning: {
          matchSim: Math.max(0.3, Math.min(0.75, Number(body.matchSim) || 0.45)),
          minVotes: Math.max(1, Math.min(8, Math.round(Number(body.minVotes) || 2))),
          threads: Math.max(1, Math.min(8, Math.round(Number(body.threads) || 3))),
        },
      });
      return { ok: true, restarted: true };
    },
  );

  // ---------------------------------------------------------------- 人脸运维

  app.post(
    '/api/v1/photo/faces/rescan-missing',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceRescanMissing',
        tags: ['photo'],
        summary: '补齐漏检：对已分析但没有检出人脸的照片重新检测',
        body: ref('PhotoFaceRescanBody'),
        response: { 200: ref('PhotoAiOpResponse'), 503: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      if (!aiAvailable()) {
        return reply
          .code(503)
          .send({ error: 'ai_unavailable', message: '缺少模型 / ffmpeg / sidecar' });
      }
      const body = (req.body || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(Number(body.limit) || 200, 2000));
      const uid = String((req as any).user?.sub || '');
      const rows = (
        await sql<{ id: string; rel_path: string }>`
          select i.id, i.rel_path from photo_items i
           where i.in_trash = 0
             and i.library_id in (select id from photo_libraries where owner_id = ${uid})
             and exists (select 1 from photo_embeddings e where e.photo_id = i.id)
             and not exists (select 1 from photo_faces f where f.photo_id = i.id)
           order by i.taken_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      noteAiJob('face');
      const s = await ensureSidecar(k);
      const root = filesRoot();
      let count = 0;
      for (const row of rows) {
        try {
          const abs = resolveAnyPath(root, row.rel_path);
          if (!fs.existsSync(abs)) continue;
          const out = await s.request<{
            faces: Array<{
              score: number;
              quality?: number;
              pose?: { yaw: number | null; roll: number | null; iod?: number } | null;
              emb: number[];
            }>;
          }>(
            'analyze',
            { src: abs, faces: true, scenes: false, embed: false, ocr: false, activity: false },
            600_000,
          );
          const { assignCluster } = await import('./face');
          const usedClusterIds = new Set<string>();
          for (const face of out.faces) {
            const res = await assignCluster(k, Float32Array.from(face.emb), row.id, {
              quality: face.quality ?? Math.round((Number(face.score) || 0) * 100),
              score: Number(face.score) || 0,
              poseYaw: face.pose?.yaw ?? null,
              poseRoll: face.pose?.roll ?? null,
              poseIod: face.pose?.iod ?? null,
              usedClusterIds,
            });
            if (res) count += 1;
          }
        } catch (err) {
          k.log.warn(
            { photo: row.id, err: String((err as Error)?.message || err) },
            'face rescan failed',
          );
        }
      }
      return { ok: true, count, message: `已重新检测 ${rows.length} 张，写入 ${count} 张人脸` };
    },
  );

  app.post(
    '/api/v1/photo/faces/merge-similar',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceMergeSimilar',
        tags: ['photo'],
        summary: '自动合并相似人物（同框冲突跳过）',
        body: ref('PhotoFaceMergeSimilarBody'),
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { dryRun?: boolean; rounds?: number };
      const dryRun = body.dryRun === true;
      // 簇级合并阈值必须和 rebuild 用同一把尺（mergeClusterSim，默认 0.76）。
      // 此前这里借用增量投票的 matchSim（0.45）——那是"两张脸是否同一人"的单张门，
      // 拿它当簇级门会把不同的人整簇并掉。
      const clusterSim = paramsFromEnv().mergeClusterSim;
      await faceIndex.load(k.db);
      const rows = (
        await sql<{ id: string; size: number; centroid: Buffer }>`
          select id, size, centroid from photo_face_clusters order by size desc limit 500
        `.execute(k.db)
      ).rows;
      const clusters = rows.map((r) => ({
        id: r.id,
        size: Number(r.size) || 0,
        vec: fromBuffer(r.centroid),
      }));
      const merged = new Set<string>();
      const pairs: Array<{ from: string; to: string }> = [];
      for (let i = 0; i < clusters.length; i += 1) {
        if (merged.has(clusters[i].id)) continue;
        for (let j = i + 1; j < clusters.length; j += 1) {
          if (merged.has(clusters[j].id)) continue;
          const a = clusters[i];
          const b = clusters[j];
          let dot = 0;
          for (let d = 0; d < a.vec.length; d += 1) dot += a.vec[d] * b.vec[d];
          if (dot < clusterSim) continue;
          const samePhoto = (
            await sql<{ n: number }>`
              select count(*) as n from photo_faces fa
                join photo_faces fb on fb.photo_id = fa.photo_id
               where fa.cluster_id = ${a.id} and fb.cluster_id = ${b.id}
            `.execute(k.db)
          ).rows[0];
          if (Number(samePhoto?.n) > 0) continue;
          const from = a.size >= b.size ? b.id : a.id;
          const to = a.size >= b.size ? a.id : b.id;
          pairs.push({ from, to });
          merged.add(from);
          break;
        }
      }
      if (dryRun) {
        return { ok: true, count: pairs.length, message: `可合并 ${pairs.length} 对` };
      }
      const doMerge = async (fromId: string, toId: string) => {
        // 统一走 face.ts 的实现：审计可回滚、size 口径一致
        await mergeClusterPair(k, fromId, toId, String((req as any).user?.sub || ''));
      };
      const rounds = Math.max(1, Math.min(Number(body.rounds) || 1, 5));
      for (let r = 0; r < rounds; r += 1) {
        for (const p of pairs) {
          const alive = (
            await sql<{ n: number }>`
              select count(*) as n from photo_face_clusters where id in (${p.from}, ${p.to})
            `.execute(k.db)
          ).rows[0];
          if (Number(alive?.n) < 2) continue;
          await doMerge(p.from, p.to);
        }
      }
      return { ok: true, count: pairs.length, message: `已合并 ${pairs.length} 对` };
    },
  );

  app.post(
    '/api/v1/photo/faces/reset',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceResetAll',
        tags: ['photo'],
        summary: '全部重新识别人脸（清空现有聚类与人脸记录）',
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async () => {
      const faces = (await sql<{ n: number }>`select count(*) as n from photo_faces`.execute(k.db))
        .rows[0];
      await k.db.transaction().execute(async (trx: any) => {
        await sql`delete from photo_faces`.execute(trx);
        await sql`delete from photo_face_clusters`.execute(trx);
      });
      // 人脸属于基础分析，清掉基础位后 scan 才会重新跑一遍
      await sql`
        update photo_items set ai_done_mask = ai_done_mask & ~${AI_DONE_BASE}
      `.execute(k.db);
      faceIndex.reset();
      await enqueueScanOnce(k).catch(() => null);
      return { ok: true, count: Number(faces?.n) || 0, message: '已清空，可重新开始识别' };
    },
  );

  app.post(
    '/api/v1/photo/faces/purge',
    secured('photo:write', {
      schema: {
        operationId: 'photoFacePurge',
        tags: ['photo'],
        summary: '清理误检人脸（低分 / 无归属）',
        response: { 200: ref('PhotoAiOpResponse') },
      },
    }),
    async () => {
      const before = (await sql<{ n: number }>`select count(*) as n from photo_faces`.execute(k.db))
        .rows[0];
      await sql`delete from photo_faces where cluster_id is null or score < 0.35`.execute(k.db);
      const after = (await sql<{ n: number }>`select count(*) as n from photo_faces`.execute(k.db))
        .rows[0];
      await sql`
        delete from photo_face_clusters
         where not exists (select 1 from photo_faces f where f.cluster_id = photo_face_clusters.id)
      `.execute(k.db);
      await sql`
        update photo_face_clusters
           set size = (select count(distinct photo_id) from photo_faces f where f.cluster_id = photo_face_clusters.id)
      `.execute(k.db);
      faceIndex.reset();
      const removed = (Number(before?.n) || 0) - (Number(after?.n) || 0);
      return { ok: true, count: removed, message: `已清理 ${removed} 张误检人脸` };
    },
  );

  // ---------------------------------------------------------------- MCP 开放平台

  app.get(
    '/api/v1/photo/ai/mcp/status',
    secured('photo:read', {
      schema: {
        operationId: 'photoMcpStatus',
        tags: ['photo'],
        summary: 'MCP 开放平台状态',
        response: { 200: ref('PhotoMcpStatus') },
      },
    }),
    async (req: FastifyRequest) => {
      const stored = await ensureMcpToken(k);
      const host = String(req.headers.host || '127.0.0.1:7788');
      const token = stored.token;
      return {
        enabled: stored.enabled,
        tokenMasked: token ? `****${token.slice(-4)}` : '',
        uid: stored.uid,
        tools: MCP_TOOLS,
        baseUrl: `http://${host}/api/mcp`,
      };
    },
  );

  app.post(
    '/api/v1/photo/ai/mcp/config',
    secured('photo:write', {
      schema: {
        operationId: 'photoMcpConfigSet',
        tags: ['photo'],
        summary: '保存 MCP 配置（开关 / 挂载用户）',
        body: ref('PhotoMcpConfigBody'),
        response: { 200: ref('PhotoMcpStatus') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { enabled?: boolean; uid?: string };
      const cur = await ensureMcpToken(k);
      const next: McpStored = {
        enabled: typeof body.enabled === 'boolean' ? body.enabled : cur.enabled,
        uid: typeof body.uid === 'string' ? body.uid : cur.uid,
        token: cur.token,
      };
      await k.config.set(MCP_KEY, next);
      const host = String(req.headers.host || '127.0.0.1:7788');
      return {
        enabled: next.enabled,
        tokenMasked: next.token ? `****${next.token.slice(-4)}` : '',
        uid: next.uid,
        tools: MCP_TOOLS,
        baseUrl: `http://${host}/api/mcp`,
      };
    },
  );

  app.post(
    '/api/v1/photo/ai/mcp/token/rotate',
    secured('photo:write', {
      schema: {
        operationId: 'photoMcpTokenRotate',
        tags: ['photo'],
        summary: '轮换 MCP 访问令牌（明文只返回一次）',
        response: { 200: ref('PhotoMcpTokenResponse') },
      },
    }),
    async () => {
      const cur = mcpStored(k);
      const token = crypto.randomBytes(24).toString('base64url');
      await k.config.set(MCP_KEY, { ...cur, token });
      return { token };
    },
  );
}

export function mcpAccess(k: KernelApi, token: string): { ok: boolean; uid: string } {
  const cur = mcpStored(k);
  if (!cur.enabled || !cur.token || !token) return { ok: false, uid: '' };
  const a = Buffer.from(cur.token);
  const b = Buffer.from(token);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return { ok: false, uid: '' };
  return { ok: true, uid: cur.uid };
}
