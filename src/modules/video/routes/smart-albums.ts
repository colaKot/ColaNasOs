import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, toItem, type MediaRow } from '../util';
import { offlineCond, offlineSmbPrefixes } from '../sources';
import { pathWhere, visibilityOf } from '../../files/visibility';
import { seriesCoverIdSql, seriesPosterIdSql } from '../series-sql';
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
      const vis = visibilityOf(k.config, req.user);
      const cutoff = Math.floor(Date.now() / 1000) - 30 * 24 * 3600;
      // 离线 SMB 来源的条目列表里看不到，计数也不能算进去（否则「最近添加 20 部」点进去只有 3 部）
      const offline = await offlineSmbPrefixes(k.db);
      const offlineFilter = offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``;
      const items = [];
      for (const key of RULE_KEYS) {
        // 计数口径必须和条目一致：电视剧按剧算 1 条（整部剧一张卡），电影一文件 1 条。
        // 直接把所有集数加起来会出现「显示 240 条点进去 8 部剧」。
        const rows = (
          await sql<{ n: number }>`
            select
              (select count(*) from (
                 select 1
                   from video_items v
                  where v.media_type = 'video'
                    ${offlineFilter}
                    and ${pathWhere(vis, 'v.rel_path')}
                    and v.series is not null and v.series <> ''
                    and ${ruleWhere(key, uid, cutoff)}
                  group by v.library_id, v.series
              )) +
              (select count(*)
                 from video_items v
                where v.media_type = 'video'
                  ${offlineFilter}
                  and ${pathWhere(vis, 'v.rel_path')}
                  and (v.series is null or v.series = '')
                  and ${ruleWhere(key, uid, cutoff)}
              ) as n
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
      const offline = await offlineSmbPrefixes(k.db);
      const offlineFilter = offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``;
      const vis = visibilityOf(k.config, req.user);

      /**
       * 电视剧按剧聚合：整部剧只出一张卡。
       *
       * 不这么做的话「未看」合集里一部 40 集的剧会铺 40 张一模一样的封面
       * （用户 2026-11-12 反馈）。集数 / 季数 / 已看集数都按**整部剧**算，
       * 不是「命中了规则的集数」—— 卡片展示的是这部剧本身的体量。
       */
      const seriesRows = (
        await sql<{
          library_id: string;
          name: string;
          seasons: number;
          episodes: number;
          watched_episodes: number;
          cover_id: string | null;
          poster_id: string | null;
          at: number;
        }>`
          select v.library_id, v.series as name,
                 (select count(distinct coalesce(t.season, 0)) from video_items t
                   where t.library_id = v.library_id and t.series = v.series
                     and t.media_type = 'video') as seasons,
                 (select count(*) from video_items t
                   where t.library_id = v.library_id and t.series = v.series
                     and t.media_type = 'video') as episodes,
                 (select count(*) from video_items t
                    join video_watch w on w.item_id = t.id and w.owner_id = ${uid}
                   where t.library_id = v.library_id and t.series = v.series
                     and t.media_type = 'video') as watched_episodes,
                 ${seriesCoverIdSql('v')} as cover_id,
                 ${seriesPosterIdSql('v')} as poster_id,
                 max(v.mtime) as at
            from video_items v
           where v.media_type = 'video'
             ${libFilter}
             ${offlineFilter}
             and ${pathWhere(vis, 'v.rel_path')}
             and v.series is not null and v.series <> ''
             and ${ruleWhere(key, uid, cutoff)}
           group by v.library_id, v.series
           order by at desc
           limit ${limit}
        `.execute(k.db)
      ).rows;

      // 卡片上的年份 / 简介 / 评分用「封面那一集」的元数据（剧级字段本来就一样）
      const coverIds = [
        ...new Set(seriesRows.map((r) => r.cover_id).filter((x): x is string => !!x)),
      ];
      const coverRows = coverIds.length
        ? (
            await sql<MediaRow>`
              select v.*, exists(select 1 from video_watch w
                                  where w.item_id = v.id and w.owner_id = ${uid}) as watched
                from video_items v
               where v.id in (${sql.join(coverIds.map((id) => sql`${id}`), sql`, `)})
            `.execute(k.db)
          ).rows
        : [];
      const coverById = new Map(coverRows.map((r) => [r.id, r]));

      const movies = (
        await sql<MediaRow>`
          select v.*, exists(select 1 from video_watch w
                              where w.item_id = v.id and w.owner_id = ${uid}) as watched
            from video_items v
           where v.media_type = 'video'
             ${libFilter}
             ${offlineFilter}
             and ${pathWhere(vis, 'v.rel_path')}
             and (v.series is null or v.series = '')
             and ${ruleWhere(key, uid, cutoff)}
           order by v.mtime desc, v.id asc
           limit ${limit}
        `.execute(k.db)
      ).rows;

      const merged: Array<{ at: number; item: Record<string, unknown> }> = [
        ...movies.map((r) => ({ at: Number(r.mtime) || 0, item: toItem(r) as never })),
        ...seriesRows.flatMap((g) => {
          const row = g.cover_id ? coverById.get(g.cover_id) : undefined;
          if (!row) return [];
          return [
            {
              at: Number(g.at) || 0,
              item: {
                ...toItem(row),
                // 这张卡代表整部剧：标题用剧名，季 / 集号不外露
                title: g.name,
                season: null,
                episode: null,
                seriesInfo: {
                  name: g.name,
                  seasons: Number(g.seasons) || 1,
                  episodes: Number(g.episodes) || 0,
                  watchedEpisodes: Number(g.watched_episodes) || 0,
                  coverId: g.cover_id,
                  posterId: g.poster_id,
                },
              } as never,
            },
          ];
        }),
      ];
      merged.sort((a, b) => b.at - a.at);
      return { items: merged.slice(0, limit).map((x) => x.item), nextCursor: null };
    },
  );
}
