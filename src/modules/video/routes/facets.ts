import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { effectiveSources, offlineCond, offlineSmbPrefixes, sourceRootCond } from '../sources';
import { GENRE_FACET_LIMIT, isSingleWorkGenre, jpTagCond, resolutionCond } from '../jp-filter';
import { TAG } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/**
 * 日本电影库筛选面板要用的「选项 + 数量」一次性拿全。
 *
 * 为什么单独做一个接口：面板上每一项都要带条数（不然用户点进去才发现是空的），
 * 客户端自己拉 200 条样本聚合会漏掉长尾来源 / 长尾题材；而逐个条件各拉一次 count
 * 又是好几遍全表扫描。这里用 2 条 SQL + 一次内存聚合解决：
 *   ① 来源 —— 一条 CASE 分组（来源数量是个位数）
 *   ② 标签 / 分辨率 —— 一条 SQL 里几个 SUM(CASE)，只扫一遍
 *   ③ 题材 —— 只读 `nfo_genres` 一列，在 JS 里累加计数后取前 30（**不信任 json1**，
 *      老库可能没编扩展），结果按「库 + 离线来源集合」缓存 5 分钟
 */

interface GenreFacetRow {
  name: string;
  count: number;
}

const genreCache = new Map<string, { at: number; rows: GenreFacetRow[] }>();
const GENRE_TTL_MS = 5 * 60 * 1000;

/** 兼容 NFO 早期「逗号分隔」写法（与 util.ts#jsonList 同口径） */
function parseGenreList(raw: unknown): string[] {
  const text = String(raw ?? '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    if (Array.isArray(parsed)) return parsed.map((v) => String(v ?? '').trim()).filter(Boolean);
  } catch {
    // 落到下面的分隔符拆分
  }
  return text
    .split(/[,，|]/)
    .map((v) => v.trim())
    .filter(Boolean);
}

/** 把「应该一定有值」的筛选条件收紧成非空（避免到处写 `!`） */
function must(cond: ReturnType<typeof sql> | null): ReturnType<typeof sql> {
  if (!cond) throw new Error('invalid facet key');
  return cond;
}

const sumIf = (cond: ReturnType<typeof sql>) => sql`sum(case when ${cond} then 1 else 0 end)`;

export async function registerVideoFacets(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/video/facets',
    secured('video:read', {
      schema: {
        operationId: 'videoFacets',
        tags: TAG,
        summary: '筛选面板选项：来源 / 标签 / 分辨率计数 + NFO 题材前 30（排除单体作品）',
        querystring: h.ref('VideoFacetsQuery'),
        response: { 200: h.ref('VideoFacetsResponse') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { libraryId?: string };
      const lib = q.libraryId ? await h.loadLibrary(q.libraryId) : null;
      const libId = lib?.id ?? '';

      // 与列表同源：离线 SMB 来源的条目列表里看不到，计数也不能算进去
      const offline = await offlineSmbPrefixes(k.db);
      const scoped = sql`1 = 1
        ${libId ? sql`and video_items.library_id = ${libId}` : sql``}
        ${offline.length > 0 ? sql`and ${offlineCond(offline)}` : sql``}`;

      // ---------------------------------------------------------------- ① 来源
      const sources = lib ? await effectiveSources(k.db, lib) : [];
      const sourceCounts = new Map<string, number>();
      if (sources.length > 0) {
        // 一条 SQL 分组：来源数量就是个位数，用 CASE 把它落到下标上，
        // 比「每个来源各扫一遍」便宜得多。
        const cases = sources.map((s, i) => sql`when ${sourceRootCond(s.root_path)} then ${i}`);
        const idxExpr = sql`case ${sql.join(cases, sql` `)} else -1 end`;
        const res = await sql<{ idx: number; n: number }>`
          select ${idxExpr} as idx, count(*) as n
            from video_items
           where ${scoped}
           group by idx
        `.execute(k.db);
        for (const row of res.rows) {
          const i = Number(row.idx);
          if (i >= 0 && i < sources.length) sourceCounts.set(sources[i].id, Number(row.n) || 0);
        }
      }

      // ---------------------------------------------------------------- ② 标签 / 分辨率
      // 「破解」= 无码 or ltx。两个集合可能有重叠，所以一条 SQL 里把
      // 「只看 ltx」「ltx 且没被判无码」都数出来，避免再多扫一遍表：
      //   cracked = uncensored + ltxOnly
      const res2 = (
        await sql<{
          uncensored: number | null;
          ltx: number | null;
          ltx_only: number | null;
          uhd: number | null;
          fhd: number | null;
        }>`
          select ${sumIf(must(jpTagCond('uncensored')))} as uncensored,
                 ${sumIf(must(jpTagCond('ltx')))} as ltx,
                 ${sumIf(sql`${must(jpTagCond('ltx'))} and not (${must(jpTagCond('uncensored'))})`)} as ltx_only,
                 ${sumIf(must(resolutionCond('4k')))} as uhd,
                 ${sumIf(must(resolutionCond('1080')))} as fhd
            from video_items
           where ${scoped}
        `.execute(k.db)
      ).rows[0];
      const uncensoredCount = Number(res2?.uncensored) || 0;
      const ltxCount = Number(res2?.ltx) || 0;
      const ltxOnly = Number(res2?.ltx_only) || 0;

      // ---------------------------------------------------------------- ③ 题材（top 30）
      const cacheKey = `${libId}\u0000${offline.join(',')}`;
      const hit = genreCache.get(cacheKey);
      let genres: GenreFacetRow[];
      if (hit && Date.now() - hit.at < GENRE_TTL_MS) {
        genres = hit.rows;
      } else {
        // 只读一列文本：2k 条约 25ms，10 万条约几百毫秒 —— 缓存 5 分钟内不会重复付。
        const res3 = await sql<{ nfo_genres: string | null }>`
          select nfo_genres from video_items
           where ${scoped} and coalesce(nfo_genres, '') <> ''
        `.execute(k.db);
        const counter = new Map<string, number>();
        for (const row of res3.rows) {
          for (const name of parseGenreList(row.nfo_genres)) {
            if (isSingleWorkGenre(name)) continue;
            counter.set(name, (counter.get(name) || 0) + 1);
          }
        }
        genres = [...counter.entries()]
          .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
          .slice(0, GENRE_FACET_LIMIT)
          .map(([name, count]) => ({ name, count }));
        genreCache.set(cacheKey, { at: Date.now(), rows: genres });
        // 库多起来之后别让缓存无限长（只按时间淘汰最旧的）
        if (genreCache.size > 32) {
          const oldest = [...genreCache.entries()].sort((a, b) => a[1].at - b[1].at)[0];
          if (oldest) genreCache.delete(oldest[0]);
        }
      }

      return {
        sources: sources.map((s) => ({ id: s.id, count: sourceCounts.get(s.id) ?? 0 })),
        genres,
        tags: [
          { key: 'uncensored', count: uncensoredCount },
          { key: 'cracked', count: uncensoredCount + ltxOnly },
          { key: 'ltx', count: ltxCount },
        ],
        resolutions: [
          { key: '4k', count: Number(res2?.uhd) || 0 },
          { key: '1080', count: Number(res2?.fhd) || 0 },
        ],
      };
    },
  );
}
