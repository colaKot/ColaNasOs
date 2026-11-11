import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { loadSeriesDisplay } from '../series-title';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';

/**
 * 剧的展示信息（中文剧名 + TMDB 竖版海报）。
 *
 * 刻意不进契约：这是给自家客户端的展示层补充，前端用 transport 直接取；
 * `series` 列仍是分组 / 查询键，这里只给「显示名」和兜底海报，不改它。
 */
export async function registerVideoSeriesDisplay(
  app: FastifyInstance,
  k: KernelApi,
): Promise<void> {
  app.get(
    '/api/v1/video/series/display',
    secured('video:read', { schema: { hide: true } }),
    async () => {
      const rows = (
        await sql<{ name: string; path: string }>`
          select series as name, min(rel_path) as path
            from video_items
           where series is not null and series <> ''
           group by series
        `.execute(k.db)
      ).rows;
      return { items: await loadSeriesDisplay(k, rows) };
    },
  );
}
