import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, toItem, type MediaRow } from '../util';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/**
 * 智能合集（预设规则）。
 *
 * 本版不提供规则编辑器，只提供一组**预设货架**：
 * 最近添加 / 未看 / 继续观看 / 4K / HDR / 全景声 / 长片。
 * 规则在 SQL 里算（不做全表拉到内存），计数与条目走同一份条件，避免「显示 12 条点进去 3 条」。
 */
const RULE_KEYS = ['recent30', 'unwatched', 'continue', '4k', 'hdr', 'atmos', 'long'] as const;
type RuleKey = (typeof RULE_KEYS)[number];

function isRuleKey(v: string): v is RuleKey {
  return (RULE_KEYS as readonly string[]).includes(v);
}

function ruleWhere(key: RuleKey, uid: string, cutoff: number): any {
  switch (key) {
    case 'recent30':
      return sql`v.mtime >= ${cutoff}`;
    case 'unwatched':
      return sql`not exists (
        select 1 from video_progress p where p.item_id = v.id and p.owner_id = ${uid}
      )`;
    case 'continue':
      return sql`exists (
        select 1 from video_progress p
         where p.item_id = v.id and p.owner_id = ${uid} and p.percent > 0 and p.percent < 95
      )`;
    case '4k':
      return sql`v.is_4k = 1`;
    case 'hdr':
      return sql`(v.hdr10 = 1 or v.hdr10plus = 1 or v.hlg = 1 or v.dolby_vision = 1)`;
    case 'atmos':
      return sql`v.dolby_atmos = 1`;
    case 'long':
      return sql`coalesce(v.duration, 0) >= 7200000`;
    default:
      return sql`1 = 1`;
  }
}

export async function registerVideoSmartAlbums(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/video/smart-albums',
    secured('video:read', {
      schema: {
        operationId: 'videoSmartAlbums',
        tags: TAG,
        summary: '智能合集（预设规则）与各自条数',
        response: { 200: h.ref('VideoSmartAlbumListResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String(req.user?.sub || '');
      const cutoff = Math.floor(Date.now() / 1000) - 30 * 24 * 3600;
      const items = [];
      for (const key of RULE_KEYS) {
        const rows = (
          await sql<{ n: number }>`
            select count(*) as n
              from video_items v
             where v.media_type = 'video' and ${ruleWhere(key, uid, cutoff)}
          `.execute(k.db)
        ).rows;
        items.push({ key, count: Number(rows[0]?.n) || 0 });
      }
      return { items };
    },
  );

  app.get(
    '/api/v1/video/smart-albums/items',
    secured('video:read', {
      schema: {
        operationId: 'videoSmartAlbumItems',
        tags: TAG,
        summary: '智能合集条目（与计数同一份规则）',
        querystring: h.ref('VideoSmartAlbumItemsQuery'),
        response: {
          200: h.ref('VideoListResponse'),
          400: h.ref('VideoErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const q = (req.query || {}) as { key?: string; libraryId?: string; limit?: number };
      const key = String(q.key || '');
      if (!isRuleKey(key)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'unknown smart album' });
      }
      const uid = String(req.user?.sub || '');
      const cutoff = Math.floor(Date.now() / 1000) - 30 * 24 * 3600;
      const limit = Math.max(1, Math.min(Number(q.limit) || 60, 200));
      const libFilter = q.libraryId ? sql`and v.library_id = ${q.libraryId}` : sql``;

      const rows = (
        await sql<MediaRow>`
          select v.*
            from video_items v
           where v.media_type = 'video'
             ${libFilter}
             and ${ruleWhere(key, uid, cutoff)}
           order by v.mtime desc, v.id asc
           limit ${limit}
        `.execute(k.db)
      ).rows;
      return { items: rows.map(toItem), nextCursor: null };
    },
  );
}
