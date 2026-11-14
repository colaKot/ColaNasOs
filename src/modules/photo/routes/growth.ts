import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, decodeCursor } from '../util';
import {
  ensureBuilt,
  growthStageJson,
  listPersons,
  listStages,
  loadStage,
  normalizeGranularity,
  rebuildTrack,
  repinStage,
  stageCandidates,
  stagePhotos,
  stagePhotosBatch,
} from '../growth';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';

/**
 * 成长轨迹的四个（+2）接口。
 *
 * 设计文档给的最小版是 persons / items / stage photos / repin；这里额外补
 * 「换封面候选」与「手动重建」两个，因为人工纠错闭环和 AI 补识别之后的刷新
 * 都属于 MVP 能长期用下去的必要入口。列表只读预计算落库的 Stage，
 * 20 万张照片也不在端上算分段。
 */
export async function registerPhotoGrowth(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  const uidOf = (req: { user?: { sub?: string } }) => String(req.user?.sub || '');

  app.get(
    '/api/v1/photo/growth/persons',
    secured('photo:read', {
      schema: {
        operationId: 'photoGrowthPersons',
        tags: TAG,
        summary: '成长轨迹：可选的人脸条（已命名优先，其次照片数最多）',
        querystring: h.ref('PhotoGrowthPersonQuery'),
        response: { 200: h.ref('PhotoGrowthPersonList') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { limit?: number };
      return { items: await listPersons(k, uidOf(req as any), h.limitOf(q.limit, 8, 50)) };
    },
  );

  app.get(
    '/api/v1/photo/growth/items',
    secured('photo:read', {
      schema: {
        operationId: 'photoGrowthItems',
        tags: TAG,
        summary: '成长轨迹：阶段列表（服务端预计算，排序键游标分页）',
        querystring: h.ref('PhotoGrowthItemsQuery'),
        response: { 200: h.ref('PhotoGrowthStageList'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as {
        person?: string;
        order?: string;
        granularity?: string;
        cursor?: string;
        limit?: number;
      };
      const person = String(q.person || '').trim();
      if (!person) {
        return reply.code(400).send({ error: Err.badRequest, message: 'person required' });
      }
      // 复用 util 的 decodeCursor 校验：非法游标直接 400，不静默从头翻
      if (q.cursor && !decodeCursor(q.cursor)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
      }
      const granularity = normalizeGranularity(q.granularity);
      const rebuilt = await ensureBuilt(k, uidOf(req as any), person, granularity);
      return listStages(
        k,
        uidOf(req as any),
        person,
        granularity,
        String(q.order || 'desc'),
        q.cursor,
        h.limitOf(q.limit, 20, 100),
        rebuilt,
      );
    },
  );

  app.get(
    '/api/v1/photo/growth/stage/photos',
    secured('photo:read', {
      schema: {
        operationId: 'photoGrowthStagePhotos',
        tags: TAG,
        summary: '成长轨迹：某阶段的全量照片（真分页）',
        querystring: h.ref('PhotoGrowthStagePhotosQuery'),
        response: { 200: h.ref('PhotoGrowthStagePhotos'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { stageId?: string; cursor?: string; limit?: number };
      const stage = await loadStage(k, uidOf(req as any), String(q.stageId || ''));
      if (!stage) {
        return reply.code(400).send({ error: Err.badRequest, message: 'stage not found' });
      }
      if (q.cursor && !decodeCursor(q.cursor)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
      }
      return stagePhotos(k, uidOf(req as any), stage, q.cursor, h.limitOf(q.limit, 60, 200));
    },
  );

  app.get(
    '/api/v1/photo/growth/stage/photos/batch',
    secured('photo:read', {
      schema: {
        operationId: 'photoGrowthStagePhotosBatch',
        tags: TAG,
        summary: '成长轨迹：批量取多段的拼贴照片（每段多张，选片口径同单段）',
        querystring: h.ref('PhotoGrowthStagePhotosBatchQuery'),
        response: { 200: h.ref('PhotoGrowthStagePhotosBatch'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { stageIds?: string; limit?: number };
      const ids = String(q.stageIds || '')
        .split(',')
        .map((id) => id.trim())
        .filter(Boolean);
      if (ids.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'stageIds required' });
      }
      // 一屏最多 20 段，客户端按 10 段一批；超过 10 段直接拒绝，避免单请求放大 SQL
      if (ids.length > 10) {
        return reply.code(400).send({ error: Err.badRequest, message: 'at most 10 stages per batch' });
      }
      const limit = Math.max(1, Math.min(12, Number(q.limit) || 8));
      return { items: await stagePhotosBatch(k, uidOf(req as any), ids, limit) };
    },
  );

  app.get(
    '/api/v1/photo/growth/stage/candidates',
    secured('photo:read', {
      schema: {
        operationId: 'photoGrowthStageCandidates',
        tags: TAG,
        summary: '成长轨迹：换封面的候选照片（可解释分数）',
        querystring: h.ref('PhotoGrowthCandidatesQuery'),
        response: { 200: h.ref('PhotoGrowthCandidateList'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { stageId?: string };
      const stage = await loadStage(k, uidOf(req as any), String(q.stageId || ''));
      if (!stage) {
        return reply.code(400).send({ error: Err.badRequest, message: 'stage not found' });
      }
      return { items: await stageCandidates(k, stage) };
    },
  );

  app.post(
    '/api/v1/photo/growth/stage/repin',
    secured('photo:write', {
      schema: {
        operationId: 'photoGrowthStageRepin',
        tags: TAG,
        summary: '成长轨迹：人工指定阶段封面（写 locked，重算不再覆盖）',
        body: h.ref('PhotoGrowthRepinBody'),
        response: { 200: h.ref('PhotoGrowthRepinResponse'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { stageId?: string; assetId?: string };
      const stage = await loadStage(k, uidOf(req as any), String(body.stageId || ''));
      if (!stage) {
        return reply.code(400).send({ error: Err.badRequest, message: 'stage not found' });
      }
      const updated = await repinStage(k, uidOf(req as any), stage, String(body.assetId || ''));
      if (!updated) {
        return reply.code(400).send({ error: Err.badRequest, message: 'asset not in stage' });
      }
      return { stage: growthStageJson(updated) };
    },
  );

  app.post(
    '/api/v1/photo/growth/rebuild',
    secured('photo:write', {
      schema: {
        operationId: 'photoGrowthRebuild',
        tags: TAG,
        summary: '成长轨迹：手动重算某人的阶段（AI 补识别 / 导入照片之后）',
        body: h.ref('PhotoGrowthRebuildBody'),
        response: { 200: h.ref('PhotoGrowthRebuildResponse'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { person?: string; granularity?: string };
      const person = String(body.person || '').trim();
      if (!person) {
        return reply.code(400).send({ error: Err.badRequest, message: 'person required' });
      }
      return rebuildTrack(k, uidOf(req as any), person, normalizeGranularity(body.granularity));
    },
  );
}
