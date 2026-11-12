import { sql } from 'kysely';
import { pathWhere, visibilityOf } from '../../files/visibility';
import { Type } from '@sinclair/typebox';
import { ftsPhrase } from '../../files/fts';
import { actorKey } from '../jp-actor';
import { secured } from '../../../../kernel/route';
import { libTypeOf, normalizeLibType } from '../media-type';
import { missingEpisodes } from '../series';
import { rankMarksOf } from '../jp-rank';
import { effectiveSources, offlineCond, offlineSmbPrefixes, sourceRootCond } from '../sources';
import { jpTagCond, resolutionCond } from '../jp-filter';
import {
  bindVideoListCacheInvalidation,
  videoListCacheGet,
  videoListCacheKey,
  videoListCacheSet,
} from '../list-cache';
import { ONLINE_NO, normalizeConnType } from '../smb';
import {
  FolderMode,
  folderPathOf,
  hideSameNameImageCond,
  imageSortExpr,
  letterCond,
  requireRoot,
  rootsOf,
  scopeCond,
  videoMediaSortExpr,
} from '../image-scope';
import { Err } from '../../../../kernel/errors';
import {
  TAG,
  MediaRow,
  VideoItemRow,
  toItem,
  imageToMediaRow,
  dropSharedArtwork,
  decodeCursor,
  encodeCursor,
  encodeSortCursor,
  decodeSortCursor,
  isSortKey,
  likePattern,
  encodeTimeCursor,
  decodeTimeCursor,
  type SortKey,
} from '../util';
import { localizeHomeTitles } from '../series-title';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/** 「看完」的统一门（进度百分比）：服务端一处定义，列表筛选与历史清空共用 */
const FINISHED_PERCENT = 95;

/**
 * 给列表打「日榜第 N」角标。
 *
 * 只在页内真的存在番号（`code`）时才去读榜单快照，普通影视库一点开销都不产生；
 * 快照是本地表，不联网。没有快照就原样返回 —— 卡片自然不显示角标。
 */
async function withRank(k: KernelApi, items: Array<Record<string, unknown>>): Promise<any[]> {
  if (!items.some((i) => i && i.code)) return items;
  const [daily, weekly, monthly] = await Promise.all([
    rankMarksOf(k.db, 'daily').catch(() => new Map<string, number>()),
    rankMarksOf(k.db, 'weekly').catch(() => new Map<string, number>()),
    rankMarksOf(k.db, 'monthly').catch(() => new Map<string, number>()),
  ]);
  if (daily.size === 0 && weekly.size === 0 && monthly.size === 0) return items;
  return items.map((i) => {
    const code = i?.code ? String(i.code).toUpperCase() : '';
    if (!code) return { ...i, rankDaily: null, rankWeekly: null, rankMonthly: null };
    return {
      ...i,
      rankDaily: daily.get(code) ?? null,
      rankWeekly: weekly.get(code) ?? null,
      rankMonthly: monthly.get(code) ?? null,
    };
  });
}

/**
 * 剧封面的统一口径（`/video/series`、`recentSeriesOf`、首页推荐共用）：
 * 优先取本剧里「有海报的那一集」，都没有才退回最小 id。
 * 否则 `/video/art` 会 404，剧集卡片整排灰块。
 */
function seriesCoverIdSql(alias?: string) {
  const col = (name: string) => sql.ref(alias ? `${alias}.${name}` : name);
  // 竖版海报优先：nfo_thumb 是横版剧照 / 缩略图，拿它当封面会出现
  // 「一部剧整排都是剧照」。先挑真正有 poster 的那一集，整部剧都没有才退 thumb。
  return sql<string | null>`coalesce(
    min(case when nullif(${col('nfo_poster')}, '') is not null then ${col('id')} end),
    min(case when nullif(${col('nfo_thumb')}, '') is not null then ${col('id')} end),
    min(${col('id')})
  )`;
}

/** 逗号分隔的多选参数 → 数组（去空、去重、限长） */
function csvList(raw: unknown, max = 40): string[] {
  return [...new Set(String(raw ?? '')
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean))].slice(0, max);
}

/**
 * 列表筛选条件统一在这里拼，`/video/list` 与 `/video/list/count` 共用同一份，
 * 避免「显示 12 条、点进去 3 条」这类经典不一致。
 */
function applyFilters(
  where: ReturnType<typeof sql>,
  q: {
    years?: string;
    genres?: string;
    regions?: string;
    actor?: string;
    director?: string;
    watched?: string;
    scraped?: string;
    flag?: string;
    resolution?: string;
    jpTag?: string;
  },
  uid: string,
  /** 来源筛选：已解析好的来源根（`rel_path` 前缀），null = 不限 */
  sourceRoot?: string | null,
): ReturnType<typeof sql> {
  let w = where;

  if (sourceRoot) w = sql`${w} and ${sourceRootCond(sourceRoot)}`;

  const years = csvList(q.years).filter((v) => /^\d{1,4}$/.test(v));
  if (years.length > 0) {
    const nums = years.filter((v) => v !== '0').map((v) => Number(v));
    const wantEmpty = years.includes('0');
    const parts: ReturnType<typeof sql>[] = [];
    if (nums.length > 0) parts.push(sql`nfo_year in (${sql.join(nums.map((n) => sql`${n}`), sql`, `)})`);
    if (wantEmpty) parts.push(sql`(nfo_year is null or nfo_year = 0)`);
    if (parts.length > 0) w = sql`${w} and (${sql.join(parts, sql` or `)})`;
  }

  // 类型 / 地区 / 人物都是 JSON 数组文本，用「带引号的精确包含」匹配，
  // 不用 json_each 是为了兼容没编 json1 扩展的老库；带引号能避免「科幻」命中「科幻片」。
  const likeJson = (
    column: 'nfo_genres' | 'nfo_regions' | 'nfo_actors' | 'nfo_directors',
    values: string[],
    /**
     * 人名容错：库里少数记录的演员/导演被写成了「名字 头像地址 TMDB-id」一整串
     * （2026-11-09 实测 5 条，`nfo_directors` 形如 `["周星驰 https://... 57607"]`），
     * 带引号的精确匹配会把它们漏掉 —— 点进导演页看到「暂无内容」。
     * 这里额外放一条「名字 + 空格」的宽松匹配，只对人物启用，题材/地区不需要。
     */
    opts: { dirtyNames?: boolean } = {},
  ) => {
    if (values.length === 0) return;
    const parts = values.map((v) => {
      const escaped = v.replace(/[%_\\]/g, (c) => `\\${c}`);
      const exact = sql`coalesce(${sql.raw(column)}, '') like ${`%"${escaped}"%`} escape '\\'`;
      if (!opts.dirtyNames) return exact;
      const loose = sql`coalesce(${sql.raw(column)}, '') like ${`%"${escaped} %`} escape '\\'`;
      return sql`(${exact} or ${loose})`;
    });
    w = sql`${w} and (${sql.join(parts, sql` or `)})`;
  };
  likeJson('nfo_genres', csvList(q.genres));
  likeJson('nfo_regions', csvList(q.regions));
  likeJson('nfo_actors', csvList(q.actor), { dirtyNames: true });
  likeJson('nfo_directors', csvList(q.director), { dirtyNames: true });

  const watched = String(q.watched ?? '').trim().toLowerCase();
  if (watched === 'true' || watched === '1') {
    w = sql`${w} and exists(select 1 from video_watch w2 where w2.item_id = video_items.id and w2.owner_id = ${uid})`;
  } else if (watched === 'false' || watched === '0') {
    w = sql`${w} and not exists(select 1 from video_watch w3 where w3.item_id = video_items.id and w3.owner_id = ${uid})`;
  }

  const scraped = String(q.scraped ?? '').trim().toLowerCase();
  if (scraped === 'true' || scraped === '1') {
    w = sql`${w} and coalesce(nfo_name, '') <> ''`;
  } else if (scraped === 'false' || scraped === '0') {
    w = sql`${w} and coalesce(nfo_name, '') = ''`;
  }

  const flag = String(q.flag ?? '').trim().toLowerCase();
  if (flag === '4k') w = sql`${w} and is_4k = 1`;
  else if (flag === 'hdr') w = sql`${w} and (hdr10 = 1 or hdr10plus = 1 or hlg = 1 or dolby_vision = 1)`;
  else if (flag === 'atmos') w = sql`${w} and dolby_atmos = 1`;
  else if (flag === 'long') w = sql`${w} and coalesce(duration, 0) >= 7200000`;

  // 日本库的分辨率 / 标签：口径与 facets 面板共用 jp-filter 里的同一份判断
  const resolution = resolutionCond(q.resolution);
  if (resolution) w = sql`${w} and ${resolution}`;
  const jpTag = jpTagCond(q.jpTag);
  if (jpTag) w = sql`${w} and ${jpTag}`;

  return w;
}

/** 列表 / 详情 */
export async function registerVideoItems(app: FastifyInstance, k: KernelApi, h: VideoHelpers): Promise<void> {
    bindVideoListCacheInvalidation(k);
    // ---------------------------------------------------------------- 列表 / 详情

    app.get(
      '/api/v1/video/list',
      secured('video:read', {
        schema: {
          operationId: 'videoList',
          tags: TAG,
          summary: '影片列表（标题序 + 排序键 cursor）',
          querystring: h.ref('VideoListQuery'),
          response: { 200: h.ref('VideoListResponse'), 400: h.ref('VideoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as {
          libraryId?: string;
          q?: string;
          series?: string;
          cursor?: string;
          limit?: number;
          mediaType?: string;
          sortBy?: string;
          sortOrder?: string;
          years?: string;
          genres?: string;
          regions?: string;
          actor?: string;
          director?: string;
          watched?: string;
          scraped?: string;
          flag?: string;
          folderPath?: string;
          folderMode?: string;
          letter?: string;
          resolution?: string;
          jpTag?: string;
          sourceId?: string;
        };
        const cur = decodeCursor(q.cursor);
        const timeCursor = decodeTimeCursor(q.cursor);
        const sortCurEarly = decodeSortCursor(q.cursor);
        // 三种游标都认（标题游标 / 时间游标 / 排序游标），都解析不了才 400
        if (q.cursor && !cur && !timeCursor && !sortCurEarly) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);

        const lib = q.libraryId ? await h.loadLibrary(q.libraryId) : null;
        const libType = lib ? libTypeOf(lib) : 'movie';
        const onlyImages =
          q.mediaType === 'image' || (q.mediaType !== 'video' && libType === 'image');
        const wantImage =
          q.mediaType === 'image' ||
          (q.mediaType !== 'video' && (libType === 'image' || libType === 'mixed'));
        const wantVideo = q.mediaType !== 'image' && libType !== 'image';

        const kwRaw = q.q && q.q.trim() ? q.q.trim() : '';
        const keyword = kwRaw ? likePattern(kwRaw) : '';
        // ≥3 字走 FTS5（trigram），1-2 字（中文两字词）仍用 LIKE，结果不变
        const fts = ftsPhrase(kwRaw);
        const uid = String(req.user?.sub || '');
        // 离线 SMB 来源：索引还在，但文件取不到。列表 / 搜索 / 首页统统不显示，
        // 免得用户看到一排裂图、点进去又失败。
        const offline = await offlineSmbPrefixes(k.db);

        // 图片 / 混合库的文件夹范围。folderPath 是带来源根的完整 rel_path，
        // 必须落在某个来源根内，否则是拿库路径探测其它目录。
        const sources = lib ? await effectiveSources(k.db, lib) : [];
        const roots = rootsOf(sources);
        let folderPath = '';
        let folderMode: FolderMode = '';
        try {
          folderPath = folderPathOf(q.folderPath);
          if (folderPath) requireRoot(folderPath, roots);
          folderMode =
            q.folderMode === 'exact' || q.folderMode === 'subtree'
              ? (q.folderMode as FolderMode)
              : '';
        } catch (e) {
          if ((e as { statusCode?: number }).statusCode === 403) {
            return reply.code(403).send({ error: Err.forbidden, message: 'folder outside library' });
          }
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid folder path' });
        }

        // 图片 / 混合库的列表：整库扫描 + 同名排除很重，按「用户 + 完整查询」
        // 缓存 20s；扫描完成 / SMB 上线会让缓存整体失效。
        const cacheKey = wantImage && lib ? videoListCacheKey('list', q, uid) : null;
        const cached = cacheKey ? videoListCacheGet(cacheKey) : null;
        if (cached) return cached as any;
        const put = <T>(value: T): T => {
          if (cacheKey) videoListCacheSet(cacheKey, value);
          return value;
        };

        // 图片 / 混合库排序：名字 / 拍摄 / 入库 / 查看时间；默认名字升序。
        const mediaSortRaw = String(q.sortBy || '').trim();
        const mediaSortBy = ['name', 'createTime', 'takenTime', 'viewTime'].includes(mediaSortRaw)
          ? mediaSortRaw
          : 'name';
        const mediaOrder: 'asc' | 'desc' =
          q.sortOrder === 'asc' || q.sortOrder === 'desc'
            ? q.sortOrder
            : mediaSortBy === 'name'
              ? 'asc'
              : 'desc';
        const mediaCur = decodeSortCursor(q.cursor);

        type MediaSortRow = MediaRow & { sort_key: string | number | null; watched?: number | null };

        // ---------------------------------------------------------- 图片（image / mixed）
        const imageRows = async (extra: number): Promise<MediaSortRow[]> => {
          if (!wantImage) return [];
          const expr = imageSortExpr('i', mediaSortBy);
          let where = sql`1 = 1`;
          where = sql`${where} and (${pathWhere(visibilityOf(k.config, req.user), 'i.rel_path')})`;
          if (q.libraryId) where = sql`${where} and i.library_id = ${q.libraryId}`;
          if (folderMode) where = sql`${where} and ${scopeCond('i', folderPath, folderMode, roots)}`;
          if (keyword) {
            where = sql`${where} and (i.title like ${keyword} escape '\\' or i.rel_path like ${keyword} escape '\\')`;
          }
          if (offline.length > 0) where = sql`${where} and ${offlineCond(offline, 'i.rel_path')}`;
          if (q.letter) where = sql`${where} and ${letterCond('i', q.letter)}`;
          // 混合库里与影片同名的图片不再单独出现（它已经是影片封面）
          if (libType === 'mixed') where = sql`${where} and ${hideSameNameImageCond('i')}`;
          if (mediaCur) {
            const cmp = mediaOrder === 'asc' ? sql`>` : sql`<`;
            where = sql`${where} and (${expr} ${cmp} ${mediaCur.value}
                        or (${expr} = ${mediaCur.value} and i.id > ${mediaCur.id}))`;
          }
          return (
            await sql<MediaSortRow>`
              select i.id, i.library_id, i.rel_path, i.title,
                     null as duration, i.width, i.height,
                     null as video_codec, null as audio_codec,
                     '' as container, 0 as has_subtitle, i.size, i.mtime,
                     null as series, null as season, null as episode,
                     'image' as media_type, i.taken_at,
                     null as code, 0 as uncensored, 0 as chinese_sub,
                     0 as is_4k, 0 as hdr10, 0 as hdr10plus, 0 as hlg,
                     0 as dolby_vision, 0 as dolby_atmos,
                     ${expr} as sort_key
                from image_items i
               where ${where}
               order by ${expr} ${sql.raw(mediaOrder)}, i.id asc
               limit ${extra}
            `.execute(k.db)
          ).rows;
        };

        // ---------------------------------------------------------- 视频（混合库，与图片统一时间口径）
        const videoRows = async (extra: number): Promise<MediaSortRow[]> => {
          if (!wantVideo) return [];
          const expr = videoMediaSortExpr('v', mediaSortBy, uid);
          let where = sql`1 = 1`;
          where = sql`${where} and (${pathWhere(visibilityOf(k.config, req.user), 'v.rel_path')})`;
          if (q.libraryId) where = sql`${where} and v.library_id = ${q.libraryId}`;
          if (folderMode) where = sql`${where} and ${scopeCond('v', folderPath, folderMode, roots)}`;
          if (q.series === 'none') where = sql`${where} and v.series is null`;
          else if (q.series && q.series.trim())
            where = sql`${where} and v.series = ${q.series.trim()}`;
          if (keyword) {
            // 搜索只查本地索引（nfo 在扫描时已落库）：名字 / 原名 / 番号 / 演员，
            // 都不需要再去 SMB 上读一遍。
            where = fts
              ? sql`${where} and v.rowid in (select rowid from video_items_fts where video_items_fts match ${fts})`
              : sql`${where} and (coalesce(v.nfo_name, '') like ${keyword} escape '\\'
                         or coalesce(v.nfo_original_name, '') like ${keyword} escape '\\'
                         or v.title like ${keyword} escape '\\'
                         or v.rel_path like ${keyword} escape '\\'
                         or coalesce(v.code, '') like ${keyword} escape '\\'
                         or coalesce(v.nfo_actors, '') like ${keyword} escape '\\'
                         or coalesce(v.nfo_directors, '') like ${keyword} escape '\\')`;
          }
          if (offline.length > 0) where = sql`${where} and ${offlineCond(offline, 'v.rel_path')}`;
          if (mediaCur) {
            const cmp = mediaOrder === 'asc' ? sql`>` : sql`<`;
            where = sql`${where} and (${expr} ${cmp} ${mediaCur.value}
                        or (${expr} = ${mediaCur.value} and v.id > ${mediaCur.id}))`;
          }
          return (
            await sql<MediaSortRow>`
              select v.*, cast(v.mtime / 1000 as integer) as taken_at,
                     ${expr} as sort_key,
                     exists(select 1 from video_watch w
                             where w.item_id = v.id and w.owner_id = ${uid}) as watched
                from video_items v
               where ${where}
               order by ${expr} ${sql.raw(mediaOrder)}, v.id asc
               limit ${extra}
            `.execute(k.db)
          ).rows;
        };

        const sortPage = (rows: MediaSortRow[], extra: number) => {
          const page = rows.slice(0, limit);
          const last = rows.length > extra && page.length > 0 ? page[page.length - 1] : null;
          return { page, last };
        };

        const mergeRows = (a: MediaSortRow[], b: MediaSortRow[]) => {
          const out = [...a, ...b];
          out.sort((x, y) => {
            const vx = x.sort_key;
            const vy = y.sort_key;
            if (vx !== vy) {
              if (vx == null) return 1;
              if (vy == null) return -1;
              if (typeof vx === 'number' && typeof vy === 'number') {
                return mediaOrder === 'asc' ? vx - vy : vy - vx;
              }
              const sx = String(vx);
              const sy = String(vy);
              if (sx !== sy) {
                return mediaOrder === 'asc'
                  ? (sx < sy ? -1 : 1)
                  : (sx < sy ? 1 : -1);
              }
            }
            return x.id < y.id ? -1 : x.id > y.id ? 1 : 0;
          });
          return out;
        };

        if (onlyImages) {
          const rows = await imageRows(limit + 1);
          const { page, last } = sortPage(rows, limit);
          return put({
            items: await withRank(k, dropSharedArtwork(page).map(toItem)),
            nextCursor: last ? encodeSortCursor(last.sort_key ?? '', last.id) : null,
          });
        }

        if (wantImage && wantVideo) {
          const [vs, is] = await Promise.all([videoRows(limit + 1), imageRows(limit + 1)]);
          const merged = mergeRows(vs, is);
          const { page, last } = sortPage(merged, limit);
          return put({
            items: await withRank(k, dropSharedArtwork(page).map(toItem)),
            nextCursor: last ? encodeSortCursor(last.sort_key ?? '', last.id) : null,
          });
        }

        // ---------------------------------------------------------- 纯视频库：排序 / 筛选
        const sortBy: SortKey = isSortKey(q.sortBy) ? q.sortBy : 'name';
        const order: 'asc' | 'desc' =
          q.sortOrder === 'asc' || q.sortOrder === 'desc'
            ? q.sortOrder
            : sortBy === 'name'
              ? 'asc'
              : 'desc';

        let where = sql`1 = 1`;
        where = sql`${where} and (${pathWhere(visibilityOf(k.config, req.user), 'rel_path')})`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.series === 'none') where = sql`${where} and series is null`;
        else if (q.series && q.series.trim()) where = sql`${where} and series = ${q.series.trim()}`;
        if (keyword) {
          // 搜索只查本地索引（nfo 已在扫描时缓存进库），覆盖名字 / 原名 / 番号 / 演员，
          // 不依赖 SMB 在线，也不用每次去网络盘找一遍。
          where = fts
            ? sql`${where} and rowid in (select rowid from video_items_fts where video_items_fts match ${fts})`
            : sql`${where} and (coalesce(nfo_name, '') like ${keyword} escape '\\'
                       or coalesce(nfo_original_name, '') like ${keyword} escape '\\'
                       or title like ${keyword} escape '\\'
                       or rel_path like ${keyword} escape '\\'
                       or coalesce(code, '') like ${keyword} escape '\\'
                       or coalesce(nfo_actors, '') like ${keyword} escape '\\'
                       or coalesce(nfo_directors, '') like ${keyword} escape '\\')`;
        }
        if (offline.length > 0) where = sql`${where} and ${offlineCond(offline, 'rel_path')}`;
        // 来源筛选：只认本库自己的来源。id 是客户端从 facets 拿的，正常不会越库，
        // 但 id 可复制 —— 不校验就能拿它探测任意路径。无效 id 直接给空页，
        // 不静默退化成「全部」（否则用户以为筛选生效了，其实看到的是整库）。
        let sourceRoot: string | null = null;
        if (q.sourceId) {
          const src = sources.find((s) => s.id === q.sourceId);
          if (!src) return put({ items: [], nextCursor: null });
          sourceRoot = src.root_path;
        }
        where = applyFilters(where, q, uid, sourceRoot);

        // 排序表达式（与 SET 里列出的 SORT_KEYS 一一对应）
        const exprOf: Record<SortKey, ReturnType<typeof sql>> = {
          name: sql`coalesce(nullif(nfo_name, ''), title)`,
          createTime: sql`created_at`,
          viewTime: sql`coalesce((select max(p.updated_at) from video_progress p
                                    where p.item_id = video_items.id and p.owner_id = ${uid}), 0)`,
          year: sql`coalesce(nfo_year, 0)`,
          score: sql`coalesce(nfo_score, 0)`,
          // 用裸 mtime 而不是 cast(mtime/1000 as integer)：除以 1000 不改变排序，
          // 但会让表达式索引 idx_video_items_mtime 匹配不上（见 088 迁移）。
          takenTime: sql`mtime`,
          duration: sql`coalesce(duration, 0)`,
        };
        const expr = exprOf[sortBy];

        const sortCur = decodeSortCursor(q.cursor);
        if (q.cursor && !sortCur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        if (sortCur) {
          const cmp = order === 'asc' ? sql`>` : sql`<`;
          where = sql`${where} and (${expr} ${cmp} ${sortCur.value}
                      or (${expr} = ${sortCur.value} and id > ${sortCur.id}))`;
        }

        const dir = sql.raw(order === 'asc' ? 'asc' : 'desc');
        const res = await sql<VideoItemRow & { sort_key: string | number | null; watched: number | null }>`
          select video_items.*,
                 ${expr} as sort_key,
                 exists(select 1 from video_watch w
                         where w.item_id = video_items.id and w.owner_id = ${uid}) as watched
            from video_items
           where ${where}
           order by ${expr} ${dir}, id asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const next = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        return put({
          items: await withRank(k, dropSharedArtwork(rows).map(toItem)),
          nextCursor: next ? encodeSortCursor(next.sort_key ?? '', next.id) : null,
        });
      },
    );

    app.get(
      '/api/v1/video/series',
      secured('video:read', {
        schema: {
          operationId: 'videoSeriesList',
          tags: TAG,
          summary: '剧集列表（剧名序 + 排序键 cursor；只含能解析出季 / 集号的文件）',
          querystring: h.ref('VideoSeriesListQuery'),
          response: { 200: h.ref('VideoSeriesListResponse'), 400: h.ref('VideoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as {
          libraryId?: string;
          q?: string;
          cursor?: string;
          limit?: number;
        };
        const cur = decodeCursor(q.cursor);
        if (q.cursor && !cur) {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
        }
        const limit = h.limitOf(q.limit, 60, 200);

        let where = sql`series is not null`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (q.q && q.q.trim()) {
          where = sql`${where} and series like ${likePattern(q.q.trim())} escape '\\'`;
        }
        if (cur) where = sql`${where} and series > ${cur.title}`;

        const res = await sql<{
          name: string;
          seasons: number;
          episodes: number;
          cover_id: string | null;
        }>`
          select series as name,
                 count(distinct coalesce(season, 0)) as seasons,
                 count(*) as episodes,
                 ${seriesCoverIdSql()} as cover_id
            from video_items
           where ${where}
           group by series
           order by series asc
           limit ${limit + 1}
        `.execute(k.db);

        const rows = res.rows.slice(0, limit);
        const next = res.rows.length > limit && rows.length > 0 ? rows[rows.length - 1] : null;
        return {
          items: rows.map((r) => ({
            name: r.name,
            seasons: Number(r.seasons) || 0,
            episodes: Number(r.episodes) || 0,
            coverId: r.cover_id,
          })),
          nextCursor: next ? encodeCursor(next.name, '') : null,
        };
      },
    );

    app.get(
      '/api/v1/video/series/items',
      secured('video:read', {
        schema: {
          operationId: 'videoSeriesItems',
          tags: TAG,
          summary: '某部剧的全部季 / 集（按季号、集号、标题排序）',
          querystring: h.ref('VideoSeriesItemsQuery'),
          response: {
            200: h.ref('VideoSeriesItemsResponse'),
            400: h.ref('VideoErrorResponse'),
            404: h.ref('VideoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { name?: string; libraryId?: string; limit?: number };
        const name = (q.name || '').trim();
        if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
        const limit = h.limitOf(q.limit, 500, 2000);

        // 剧集集数也要排掉离线来源：否则点进一部剧，SMB 没挂载时
        // 整屏都是点不开的灰块，还以为是文件坏了。
        const offline = await offlineSmbPrefixes(k.db);
        let where = sql`series = ${name}`;
        if (q.libraryId) where = sql`${where} and library_id = ${q.libraryId}`;
        if (offline.length > 0) where = sql`${where} and ${offlineCond(offline, 'rel_path')}`;

        const res = await sql<VideoItemRow>`
          select * from video_items
           where ${where}
           order by coalesce(season, 0) asc, coalesce(episode, 0) asc, title asc, id asc
           limit ${limit}
        `.execute(k.db);

        if (res.rows.length === 0) {
          return reply.code(404).send({ error: Err.notFound, message: 'series not found' });
        }
        // 整季缺集：只含真有缺口的季（算法与边界见 series.ts 的 missingEpisodes）
        const missing = missingEpisodes(
          res.rows.map((row) => ({ season: row.season, episode: row.episode })),
        );
        return { name, items: await withRank(k, res.rows.map(toItem)), missing };
      },
    );

    app.get(
      '/api/v1/video/item',
      secured('video:read', {
        schema: {
          operationId: 'videoItem',
          tags: TAG,
          summary: '影片详情',
          querystring: h.ref('VideoIdQuery'),
          response: { 200: h.ref('VideoItem'), 404: h.ref('VideoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadAnyItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'item not found' });
        return toItem(row);
      },
    );

    app.get(
      '/api/v1/video/progress',
      secured('video:read', {
        schema: {
          operationId: 'videoProgress',
          tags: TAG,
          summary: '当前用户在某条影片 / 剧集上的观看进度',
          querystring: h.ref('VideoProgressQuery'),
          response: {
            200: h.ref('VideoProgress'),
            404: h.ref('VideoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });

        const owner = req.user?.sub ?? '';
        const res = await sql<{ position: string; percent: number; updated_at: number }>`
          select position, percent, updated_at
            from video_progress
           where item_id = ${row.id} and owner_id = ${owner}
        `.execute(k.db);
        const p = res.rows[0];
        // 没看过不是错误：返回 0%，前端直接显示「未开始」
        return {
          itemId: row.id,
          position: p?.position ?? '',
          percent: Number(p?.percent) || 0,
          updatedAt: Number(p?.updated_at) || 0,
        };
      },
    );

    app.post(
      '/api/v1/video/progress/save',
      secured('video:write', {
        schema: {
          operationId: 'videoProgressSave',
          tags: TAG,
          summary: '保存观看进度（0-100，按用户隔离）',
          body: h.ref('VideoProgressBody'),
          response: {
            200: h.ref('VideoProgress'),
            400: h.ref('VideoErrorResponse'),
            404: h.ref('VideoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; position?: string; percent?: number };
        const row = body.id ? await h.loadItem(body.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });

        const percent = Math.max(0, Math.min(100, Math.round(Number(body.percent) || 0)));
        const position = String(body.position ?? '').slice(0, 200);
        const owner = req.user?.sub ?? '';
        // 毫秒时间戳 + 单调递增：同一毫秒内连续保存两条（连看两集）也要有确定顺序，
        // 否则「最近在看」会按标题次键抖动。取该用户当前最大值 +1 兜底。
        const prev = await sql<{ m: number | null }>`
          select max(updated_at) as m from video_progress where owner_id = ${owner}
        `.execute(k.db);
        const now = Math.max(Date.now(), Number(prev.rows[0]?.m ?? 0) + 1);
        await sql`
          insert into video_progress (item_id, owner_id, position, percent, updated_at)
          values (${row.id}, ${owner}, ${position}, ${percent}, ${now})
          on conflict(item_id, owner_id) do update set
            position = excluded.position,
            percent = excluded.percent,
            updated_at = excluded.updated_at
        `.execute(k.db);

        return { itemId: row.id, position, percent, updatedAt: now };
      },
    );

    app.get(
      '/api/v1/video/progress/list',
      secured('video:read', {
        schema: {
          operationId: 'videoProgressList',
          tags: TAG,
          summary: '本用户的观看进度（按更新时间倒序；可按剧名 / 库过滤）',
          querystring: h.ref('VideoProgressListQuery'),
          response: { 200: h.ref('VideoProgressListResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as {
          series?: string;
          libraryId?: string;
          state?: string;
          limit?: number;
        };
        const limit = h.limitOf(q.limit, 100, 500);
        const owner = req.user?.sub ?? '';

        let where = sql`p.owner_id = ${owner}`;
        if (q.series && q.series.trim()) where = sql`${where} and i.series = ${q.series.trim()}`;
        if (q.libraryId) where = sql`${where} and i.library_id = ${q.libraryId}`;
        // 看完的门统一放服务端：客户端各自写 >=95 迟早有一个写成 >=100
        if (q.state === 'finished') where = sql`${where} and p.percent >= ${FINISHED_PERCENT}`;
        if (q.state === 'unfinished') where = sql`${where} and p.percent < ${FINISHED_PERCENT}`;

        const res = await sql<
          VideoItemRow & { position: string; percent: number; updated_at: number }
        >`
          select i.*, p.position, p.percent, p.updated_at
            from video_progress p
            join video_items i on i.id = p.item_id
           where ${where}
           order by p.updated_at desc, i.title asc
           limit ${limit}
        `.execute(k.db);

        return {
          items: res.rows.map((r) => ({
            itemId: r.id,
            title: r.title,
            series: r.series,
            season: r.season,
            episode: r.episode,
            position: r.position,
            percent: Number(r.percent) || 0,
            updatedAt: Number(r.updated_at) || 0,
          })),
        };
      },
    );

    app.post(
      '/api/v1/video/progress/clear',
      secured('video:write', {
        schema: {
          operationId: 'videoProgressClear',
          tags: TAG,
          summary: '清空观看历史（可只清"已看完"，可按剧）',
          body: h.ref('VideoProgressClearBody'),
          response: { 200: h.ref('VideoProgressClearResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { onlyFinished?: boolean; series?: string };
        const owner = req.user?.sub ?? '';
        let where = sql`owner_id = ${owner}`;
        if (body.onlyFinished === true) where = sql`${where} and percent >= ${FINISHED_PERCENT}`;
        if (body.series && body.series.trim()) {
          where = sql`${where} and item_id in (select id from video_items where series = ${body.series.trim()})`;
        }
        const res = await sql`delete from video_progress where ${where}`.execute(k.db);
        return { cleared: Number(res.numAffectedRows || 0) };
      },
    );

    app.get(
      '/api/v1/video/stats',
      secured('video:read', {
        schema: {
          operationId: 'videoStats',
          tags: TAG,
          summary: '片数与总时长（可按库过滤，缺省为全部库合计）',
          querystring: h.ref('VideoStatsQuery'),
          response: { 200: h.ref('VideoStatsResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { libraryId?: string };
        // 首页统计也只统计「首页显示」的库；显式点进某个库时仍按该库统计。
        // 离线 SMB 来源的条目不计入，保证统计数字和列表里看得到的条数一致。
        const offline = await offlineSmbPrefixes(k.db);
        const offlineStatCond =
          offline.length > 0 ? sql`and ${offlineCond(offline, 'rel_path')}` : sql``;
        const libs = q.libraryId
          ? await sql<{ n: number }>`
              select count(*) as n from video_libraries where id = ${q.libraryId}
            `.execute(k.db)
          : await sql<{ n: number }>`
              select count(*) as n from video_libraries
               where coalesce(show_in_home, 1) <> 0
                 and not (conn_type = 'smb' and coalesce(online_state, 0) = ${ONLINE_NO})
            `.execute(k.db);
        const agg = q.libraryId
          ? await sql<{ n: number; total: number | null }>`
              select count(*) as n, sum(duration) as total from video_items
               where library_id = ${q.libraryId}
                 ${offlineStatCond}
            `.execute(k.db)
          : await sql<{ n: number; total: number | null }>`
              select count(*) as n, sum(duration) as total
                from video_items
               where library_id in (
                 select id from video_libraries where coalesce(show_in_home, 1) <> 0
               )
                 ${offlineStatCond}
            `.execute(k.db);
        const row = agg.rows[0];
        return {
          libraries: Number(libs.rows[0]?.n) || 0,
          items: Number(row?.n) || 0,
          durationMs: Number(row?.total) || 0,
        };
      },
    );

    // ---------------------------------------------------------------- 计数（与筛选同源）

    app.get(
      '/api/v1/video/list/count',
      secured('video:read', {
        schema: {
          operationId: 'videoListCount',
          tags: TAG,
          summary: '条目数（总数 / 已刮削数），筛选口径与 /video/list 一致',
          querystring: h.ref('VideoListCountQuery'),
          response: { 200: h.ref('VideoListCountResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as {
          libraryId?: string;
          series?: string;
          mediaType?: string;
          q?: string;
          folderPath?: string;
          folderMode?: string;
          letter?: string;
        };
        const lib = q.libraryId ? await h.loadLibrary(q.libraryId) : null;
        const libType = lib ? libTypeOf(lib) : 'movie';
        const sources = lib ? await effectiveSources(k.db, lib) : [];
        const roots = rootsOf(sources);
        let folderPath: string;
        let folderMode: FolderMode;
        try {
          folderPath = folderPathOf(q.folderPath);
          if (folderPath) requireRoot(folderPath, roots);
          folderMode =
            q.folderMode === 'exact' || q.folderMode === 'subtree'
              ? (q.folderMode as FolderMode)
              : '';
        } catch {
          return { total: 0, scraped: 0 };
        }
        const kwRaw = q.q && q.q.trim() ? q.q.trim() : '';
        const keyword = kwRaw ? likePattern(kwRaw) : '';
        // ≥3 字走 FTS5（trigram），1-2 字（中文两字词）仍用 LIKE，结果不变
        const fts = ftsPhrase(kwRaw);
        const offline = await offlineSmbPrefixes(k.db);
        const wantImages =
          q.mediaType !== 'video' && (libType === 'image' || libType === 'mixed');
        const wantVideos = q.mediaType !== 'image' && libType !== 'image';

        let total = 0;
        let scraped = 0;

        if (wantImages) {
          let where = sql`1 = 1`;
          where = sql`${where} and (${pathWhere(visibilityOf(k.config, req.user), 'i.rel_path')})`;
          if (q.libraryId) where = sql`${where} and i.library_id = ${q.libraryId}`;
          if (folderMode) where = sql`${where} and ${scopeCond('i', folderPath, folderMode, roots)}`;
          if (keyword) {
            where = sql`${where} and (i.title like ${keyword} escape '\\' or i.rel_path like ${keyword} escape '\\')`;
          }
          if (libType === 'mixed') where = sql`${where} and ${hideSameNameImageCond('i')}`;
          if (offline.length > 0) where = sql`${where} and ${offlineCond(offline, 'i.rel_path')}`;
          if (q.letter) where = sql`${where} and ${letterCond('i', q.letter)}`;
          const row = (
            await sql<{ n: number }>`select count(*) as n from image_items i where ${where}`.execute(
              k.db,
            )
          ).rows[0];
          total += Number(row?.n) || 0;
        }

        if (wantVideos) {
          let where = sql`1 = 1`;
          where = sql`${where} and (${pathWhere(visibilityOf(k.config, req.user), 'v.rel_path')})`;
          if (q.libraryId) where = sql`${where} and v.library_id = ${q.libraryId}`;
          if (folderMode) where = sql`${where} and ${scopeCond('v', folderPath, folderMode, roots)}`;
          if (q.series === 'none') where = sql`${where} and v.series is null`;
          else if (q.series && q.series.trim())
            where = sql`${where} and v.series = ${q.series.trim()}`;
          if (keyword) {
            where = fts
              ? sql`${where} and v.rowid in (select rowid from video_items_fts where video_items_fts match ${fts})`
              : sql`${where} and (coalesce(v.nfo_name, '') like ${keyword} escape '\\'
                           or coalesce(v.nfo_original_name, '') like ${keyword} escape '\\'
                           or v.title like ${keyword} escape '\\'
                           or v.rel_path like ${keyword} escape '\\'
                           or coalesce(v.code, '') like ${keyword} escape '\\'
                           or coalesce(v.nfo_actors, '') like ${keyword} escape '\\'
                           or coalesce(v.nfo_directors, '') like ${keyword} escape '\\')`;
          }
          if (offline.length > 0) where = sql`${where} and ${offlineCond(offline, 'v.rel_path')}`;
          const row = (
            await sql<{ n: number; scraped: number }>`
              select count(*) as n,
                     sum(case when coalesce(v.nfo_name, '') <> '' then 1 else 0 end) as scraped
                from video_items v
               where ${where}
            `.execute(k.db)
          ).rows[0];
          total += Number(row?.n) || 0;
          scraped += Number(row?.scraped) || 0;
        }

        return { total, scraped };
      },
    );

    // ---------------------------------------------------------------- 已观看（每用户）

    app.post(
      '/api/v1/video/watch',
      secured('video:write', {
        schema: {
          operationId: 'videoWatchMark',
          tags: TAG,
          summary: '标记已观看 / 未观看（电视剧可一次展开到全部集）',
          body: h.ref('VideoWatchBody'),
          response: { 200: h.ref('VideoWatchResponse') },
        },
      }),
      async (req: any, reply) => {
        const body = (req.body || {}) as {
          ids?: string[];
          watched?: boolean;
          expandSeries?: boolean;
        };
        const uid = String(req.user?.sub || '');
        const ids = (body.ids || []).filter((v) => typeof v === 'string' && v.trim() !== '');
        if (ids.length === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'ids required' });
        }
        const watched = body.watched !== false;
        const nowSec = Math.floor(Date.now() / 1000);

        // 电视剧：把整部剧所有集一起处理（用户点的是「这部剧」，不是「这一集」）
        let targets = ids;
        if (body.expandSeries) {
          const rows = (
            await sql<{ series: string; library_id: string }>`
              select distinct series, library_id from video_items
               where id in (${sql.join(ids.map((v) => sql`${v}`), sql`, `)})
                 and series is not null
            `.execute(k.db)
          ).rows;
          if (rows.length > 0) {
            const expanded = (
              await sql<{ id: string }>`
                select id from video_items
                 where ${sql.join(
                   rows.map((r) => sql`(series = ${r.series} and library_id = ${r.library_id})`),
                   sql` or `,
                 )}
              `.execute(k.db)
            ).rows;
            targets = [...new Set([...expanded.map((r) => r.id), ...ids])];
          }
        }

        // 批量写：整部剧展开后 targets 可能上千条。此前是「一条一次 insert」，
        // 每条各自一个写事务（WAL 一次 fsync），2000 集就是 2000 次落盘；
        // 中途失败还会留下「前 700 集已标记、后面没标」的脏数据。
        // 现在按 500 一批多值插入，且整批包在一个事务里 —— 要么全成，要么全不成。
        const CHUNK = 500;
        const chunks: string[][] = [];
        for (let i = 0; i < targets.length; i += CHUNK) chunks.push(targets.slice(i, i + CHUNK));

        await k.db.transaction().execute(async (trx: any) => {
          for (const chunk of chunks) {
            if (watched) {
              await sql`
                insert into video_watch (owner_id, item_id, watched_at)
                values ${sql.join(
                  chunk.map((id) => sql`(${uid}, ${id}, ${nowSec})`),
                  sql`, `,
                )}
                on conflict(owner_id, item_id) do update set watched_at = excluded.watched_at
              `.execute(trx);
            } else {
              await sql`
                delete from video_watch
                 where owner_id = ${uid}
                   and item_id in (${sql.join(
                     chunk.map((id) => sql`${id}`),
                     sql`, `,
                   )})
              `.execute(trx);
            }
          }
        });
        return { updated: targets.length, items: targets.length };
      },
    );

    // ---------------------------------------------------------------- 首页聚合（四段式）

    app.get(
      '/api/v1/video/home',
      secured('video:read', {
        schema: {
          operationId: 'videoHome',
          tags: TAG,
          summary: '影视首页：来源 / 推荐 / 继续观看 / 每库最近添加',
          querystring: h.ref('VideoHomeQuery'),
          response: { 200: h.ref('VideoHomeResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as {
          recommendLimit?: number;
          recentPlayLimit?: number;
          recentAddLimit?: number;
        };
        const uid = String(req.user?.sub || '');
        const recLimit = Math.max(1, Math.min(Number(q.recommendLimit) || 11, 30));
        const playLimit = Math.max(1, Math.min(Number(q.recentPlayLimit) || 20, 50));
        const addLimit = Math.max(1, Math.min(Number(q.recentAddLimit) || 20, 50));
        const offline = await offlineSmbPrefixes(k.db);

        const libs = (
          await sql<{
            id: string;
            name: string;
            lib_type: string | null;
            jp_movie: number | null;
            items: number;
            conn_type: string | null;
            online_state: number | null;
            show_in_home: number | null;
            sort_order: number | null;
            cover_id: string | null;
            image_cover_path: string | null;
          }>`
            select l.id, l.name, l.lib_type, l.jp_movie, l.items, l.conn_type, l.online_state,
                   l.show_in_home, l.sort_order,
                   (select i.id from video_items i
                     where i.library_id = l.id
                       ${offline.length > 0 ? sql`and ${offlineCond(offline, 'i.rel_path')}` : sql``}
                     -- 优先挑「有海报的」那条当封面：原来一律取最新一条，
                     -- 遇到没刮削的片子就是一次 /video/art 404（前端表现为裂图重试）。
                     order by (case when coalesce(nullif(i.nfo_poster, ''), nullif(i.nfo_thumb, '')) is not null
                                    then 0 else 1 end),
                              i.mtime desc
                     limit 1) as cover_id,
                   (select i.rel_path from image_items i
                     where i.library_id = l.id
                       ${offline.length > 0 ? sql`and ${offlineCond(offline, 'i.rel_path')}` : sql``}
                     order by coalesce(i.taken_at, 0) desc, i.id desc
                     limit 1) as image_cover_path
              from video_libraries l
             order by coalesce(l.sort_order, 0) asc, l.created_at asc
          `.execute(k.db)
        ).rows;

        // 「首页显示」关闭的库，在首页任何区块（来源 / 推荐 / 继续观看 / 最近添加）都不能出现；
        // 整库来源都离线的 SMB 库也直接不显示，避免点进去是一片空/裂图。
        const visibleLibs = libs.filter(
          (l) =>
            Number(l.show_in_home) !== 0 &&
            !(normalizeConnType(l.conn_type) === 'smb' && Number(l.online_state) === ONLINE_NO),
        );
        const visibleIds = visibleLibs.map((l) => l.id);
        const sources = visibleLibs.map((l) => ({
          id: l.id,
          name: l.name,
          libType: libTypeOf(l as never),
          items: Number(l.items) || 0,
          onlineState: Number(l.online_state) || 0,
          coverId: l.cover_id ?? null,
          // 图片库没有视频封面时，用第一张图当来源封面
          coverPath: l.cover_id ? null : l.image_cover_path ?? null,
          coverKind: l.cover_id ? 'video' : l.image_cover_path ? 'image' : null,
        }));
        const libFilter = visibleIds.length
          ? sql`and v.library_id in (${sql.join(visibleIds.map((id) => sql`${id}`), sql`, `)})`
          : sql`and 1 = 0`;

        const withWatched = sql<VideoItemRow>`
          select v.*, exists(select 1 from video_watch w
                              where w.item_id = v.id and w.owner_id = ${uid}) as watched
            from video_items v`;

        // 推荐：有评分优先 / 新片其次 / 未看优先。没有评分时退化成「最近添加」，
        // 不用随机，保证刷新两次结果一致（可复现才可排查）。
        //
        // 电影一部一张；电视剧按剧聚合（用户 2026-11-11 反馈：同一部剧每一集都被铺成
        // 独立卡片）。一部剧只出一张卡，排序取「未看集里评分最高、最新」的那一集；
        // 标题 / 海报 / 集数用剧级信息（seriesInfo），与 `/video/series` 同一套口径。
        const movieRows = (
          await sql<VideoItemRow>`
            select * from (${withWatched}) v
             where media_type = 'video'
               ${libFilter}
               ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
               and (series is null or series = '')
               and not exists(select 1 from video_watch w2
                               where w2.item_id = v.id and w2.owner_id = ${uid})
             order by coalesce(nfo_score, 0) desc, mtime desc
             limit ${recLimit}
          `.execute(k.db)
        ).rows;

        const seriesGroups = (
          await sql<{
            library_id: string;
            name: string;
            seasons: number;
            episodes: number;
            cover_id: string | null;
            rank_score: number;
            rank_at: number;
          }>`
            select library_id, series as name,
                   count(distinct coalesce(season, 0)) as seasons,
                   count(*) as episodes,
                   ${seriesCoverIdSql()} as cover_id,
                   max(case when not watched then coalesce(nfo_score, 0) else -1 end) as rank_score,
                   max(case when not watched then mtime else 0 end) as rank_at
              from (${withWatched}) v
             where media_type = 'video'
               ${libFilter}
               ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
               and series is not null and series <> ''
             group by library_id, series
            having max(case when not watched then 1 else 0 end) = 1
             order by rank_score desc, rank_at desc
             limit ${recLimit}
          `.execute(k.db)
        ).rows;

        // 卡片展示用「封面那一集」的元数据（简介 / 年份等是剧级的，任取一集都一样）
        const coverIds = [
          ...new Set(seriesGroups.map((g) => g.cover_id).filter((x): x is string => !!x)),
        ];
        const coverRows = coverIds.length
          ? (
              await sql<VideoItemRow>`
                select * from (${withWatched}) v
                 where v.id in (${sql.join(coverIds.map((id) => sql`${id}`), sql`, `)})
              `.execute(k.db)
            ).rows
          : [];
        const coverById = new Map(coverRows.map((r) => [r.id, r]));

        const ranked: Array<{ score: number; at: number; item: Record<string, unknown> }> = [];
        for (const r of dropSharedArtwork(movieRows)) {
          ranked.push({
            score: Number(r.nfo_score) || 0,
            at: Number(r.mtime) || 0,
            item: toItem(r),
          });
        }
        for (const g of seriesGroups) {
          const row = g.cover_id ? coverById.get(g.cover_id) : undefined;
          if (!row) continue;
          ranked.push({
            score: Number(g.rank_score) || 0,
            at: Number(g.rank_at) || 0,
            item: {
              ...toItem(row),
              // 首页上这张卡代表「整部剧」：标题用剧名，季 / 集号不外露，
              // 集数信息走 seriesInfo，点击由客户端打开剧详情。
              title: g.name,
              season: null,
              episode: null,
              seriesInfo: {
                name: g.name,
                seasons: Number(g.seasons) || 1,
                episodes: Number(g.episodes) || 0,
                coverId: g.cover_id,
              },
            },
          });
        }
        ranked.sort((a, b) => b.score - a.score || b.at - a.at);
        const recommend = ranked.slice(0, recLimit).map((x) => x.item);

        // 继续观看：有进度、未看完（<95%）
        const playRows = (
          await sql<VideoItemRow & { p_position: string; p_percent: number; p_updated: number }>`
            select v.*, p.position as p_position, p.percent as p_percent, p.updated_at as p_updated,
                   exists(select 1 from video_watch w
                           where w.item_id = v.id and w.owner_id = ${uid}) as watched
              from video_progress p
              join video_items v on v.id = p.item_id
             where p.owner_id = ${uid} and p.percent > 0 and p.percent < 95
               ${libFilter}
               ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
             order by p.updated_at desc
             limit ${playLimit}
          `.execute(k.db)
        ).rows;

        // 每库「最近添加」：只取首页可见的库（show_in_home）；图片库 / 混合库把图片也算进来
        const perLib: Array<{
          libraryId: string;
          libraryName: string;
          libType: string;
          items: unknown[];
          series?: unknown[];
        }> = [];
        for (const l of visibleLibs) {
          if (Number(l.items) === 0) continue;
          const lt = libTypeOf(l as never);
          const items: Array<{ at: number; item: unknown }> = [];
          if (lt !== 'image') {
            const rows = (
              await sql<VideoItemRow>`
                select * from (${withWatched}) v
                 where library_id = ${l.id} and media_type = 'video'
                   ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
                 order by mtime desc
                 limit ${addLimit}
              `.execute(k.db)
            ).rows;
            for (const r of dropSharedArtwork(rows)) {
              items.push({ at: Number(r.mtime) || 0, item: toItem(r) });
            }
          }
          if (lt === 'image' || lt === 'mixed') {
            const imgRows = (
              await sql<{
                id: string;
                library_id: string;
                rel_path: string;
                title: string;
                size: number;
                mtime: number;
                width: number | null;
                height: number | null;
                taken_at: number | null;
                mime: string | null;
              }>`
                select * from image_items
                 where library_id = ${l.id}
                   ${offline.length > 0 ? sql`and ${offlineCond(offline, 'rel_path')}` : sql``}
                 order by coalesce(taken_at, 0) desc, id desc
                 limit ${addLimit}
              `.execute(k.db)
            ).rows;
            for (const r of imgRows) {
              const at = Number(r.taken_at) || Number(r.mtime) || 0;
              items.push({ at, item: toItem(imageToMediaRow(r)) });
            }
          }
          if (items.length === 0) continue;
          items.sort((a, b) => b.at - a.at);
          const row: {
            libraryId: string;
            libraryName: string;
            libType: string;
            items: unknown[];
            series?: unknown[];
          } = {
            libraryId: l.id,
            libraryName: l.name,
            libType: lt,
            items: items.slice(0, addLimit).map((x) => x.item),
          };
          // 电视剧库：另给一份「按剧聚合」的卡片（一部剧一条）。
          // `items` 里是逐集数据，前端碰到 tv 库优先用这份，否则首页一排全是
          // 同一部剧的不同集（用户 2026-11-11 反馈）。
          if (lt === 'tv' || lt === 'short_tv') {
            row.series = await recentSeriesOf(k.db, l.id, addLimit, offline);
          }
          perLib.push(row);
        }

        // 推荐区剧卡的标题来自 series 列（英文发布名），按默认语言补中文显示名；
        // seriesInfo.name 仍是剧的分组 / 查询键，不能动。
        await localizeHomeTitles(k, recommend);

        return {
          sources,
          recommend,
          recentPlay: playRows.map(toItem),
          recentAdd: perLib,
          progress: playRows.map((r) => ({
            itemId: r.id,
            position: r.p_position || '',
            percent: Number(r.p_percent) || 0,
            updatedAt: Number(r.p_updated) || 0,
          })),
        };
      },
    );

    // ---------------------------------------------------------------- 收藏（按用户）
    // 收藏关系存在 video_favorites(owner_id, media_type, item_id)，不同用户互不影响。
    app.post(
      '/api/v1/video/favorites/set',
      secured('video:write', {
        schema: {
          operationId: 'videoFavoriteSet',
          tags: TAG,
          summary: '批量收藏 / 取消收藏',
          body: h.ref('VideoFavoriteBody'),
          response: { 200: h.ref('VideoFavoriteResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { ids?: string[]; favorite?: boolean };
        const uid = String((req as any).user?.sub || '');
        const ids = (body.ids || []).slice(0, 500);
        if (ids.length === 0) return { updated: 0 };
        if (body.favorite === true) {
          const rows = (
            await sql<{ id: string; media_type: string }>`
              select id, media_type from video_items
               where id in (${sql.join(
                 ids.map((id) => sql`${id}`),
                 sql`, `,
               )})
            `.execute(k.db)
          ).rows;
          const now = Math.floor(Date.now() / 1000);
          for (const row of rows) {
            await sql`
              insert into video_favorites (owner_id, media_type, item_id, created_at)
              values (${uid}, ${String(row.media_type || 'video')}, ${row.id}, ${now})
              -- 必须与主键 (owner_id, media_type, item_id) 完全一致：
              -- 写成 (owner_id, item_id) 时 SQLite 找不到匹配约束，收藏会直接失败
              on conflict (owner_id, media_type, item_id) do nothing
            `.execute(k.db);
          }
          return { updated: rows.length };
        }
        const res = await sql`
          delete from video_favorites
           where owner_id = ${uid}
             and item_id in (${sql.join(
               ids.map((id) => sql`${id}`),
               sql`, `,
             )})
        `.execute(k.db);
        return { updated: Number(res.numAffectedRows || 0) };
      },
    );

    app.get(
      '/api/v1/video/favorites',
      secured('video:read', {
        schema: {
          operationId: 'videoFavorites',
          tags: TAG,
          summary: '我收藏的影片',
          querystring: h.ref('VideoListQuery'),
          response: { 200: h.ref('VideoListResponse') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { libraryId?: string; limit?: number };
        const uid = String((req as any).user?.sub || '');
        const limit = h.limitOf(q.limit, 60, 200);
        let where = sql`f.owner_id = ${uid}`;
        if (q.libraryId) where = sql`${where} and i.library_id = ${q.libraryId}`;
        const rows = (
          await sql<MediaRow>`
            select i.* from video_favorites f
              join video_items i on i.id = f.item_id
             where ${where}
             order by f.created_at desc, i.id
             limit ${limit}
          `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({ ...toItem(r), favorite: true })),
          nextCursor: null,
        };
      },
    );

    // ------------------------------------------------------ 剧集级收藏（按用户）
    // 收藏关系存 video_series_favorites(owner_id, library_id, series)，与影片收藏互不影响。
    app.post(
      '/api/v1/video/series/favorites/set',
      secured('video:write', {
        schema: {
          operationId: 'videoSeriesFavoriteSet',
          tags: TAG,
          summary: '收藏 / 取消收藏一部剧',
          body: h.ref('VideoSeriesFavoriteBody'),
          response: {
            200: h.ref('VideoSeriesFavoriteResponse'),
            400: h.ref('VideoErrorResponse'),
            404: h.ref('VideoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          series?: string;
          libraryId?: string;
          favorite?: boolean;
        };
        const uid = String((req as any).user?.sub || '');
        const series = String(body.series || '').trim();
        if (!series) {
          return reply.code(400).send({ error: Err.badRequest, message: 'series required' });
        }

        if (body.favorite !== true) {
          await sql`
            delete from video_series_favorites
             where owner_id = ${uid} and series = ${series}
               ${body.libraryId ? sql`and library_id = ${body.libraryId}` : sql``}
          `.execute(k.db);
          return { favorite: false };
        }

        const exists = (
          await sql<{ library_id: string }>`
            select library_id from video_items
             where series = ${series}
               ${body.libraryId ? sql`and library_id = ${body.libraryId}` : sql``}
             limit 1
          `.execute(k.db)
        ).rows[0];
        if (!exists) {
          return reply.code(404).send({ error: Err.notFound, message: 'series not found' });
        }
        await sql`
          insert into video_series_favorites (owner_id, library_id, series, created_at)
          values (${uid}, ${exists.library_id}, ${series}, ${Math.floor(Date.now() / 1000)})
          on conflict (owner_id, library_id, series) do nothing
        `.execute(k.db);
        return { favorite: true };
      },
    );

    app.get(
      '/api/v1/video/series/favorites',
      secured('video:read', {
        schema: {
          operationId: 'videoSeriesFavorites',
          tags: TAG,
          summary: '我收藏的剧集（按最近收藏倒序）',
          response: { 200: h.ref('VideoSeriesFavoriteListResponse') },
        },
      }),
      async (req) => {
        const uid = String((req as any).user?.sub || '');
        const rows = (
          await sql<{
            series: string;
            library_id: string;
            seasons: number;
            episodes: number;
            cover_id: string | null;
            created_at: number;
          }>`
            select f.series, f.library_id, f.created_at,
                   count(distinct i.season) as seasons,
                   count(i.id) as episodes,
                   ${seriesCoverIdSql('i')} as cover_id
              from video_series_favorites f
              left join video_items i
                     on i.library_id = f.library_id and i.series = f.series
             where f.owner_id = ${uid}
             group by f.series, f.library_id, f.created_at
             order by f.created_at desc, f.series
             limit 200
          `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            series: r.series,
            libraryId: r.library_id,
            seasons: Number(r.seasons || 0),
            episodes: Number(r.episodes || 0),
            coverId: r.cover_id || undefined,
            createdAt: Number(r.created_at || 0),
          })),
        };
      },
    );

    // 详情页「演职人员」区用的演员资料：一条影片只带几个名字，
    // 前端拿到名字后一次问头像 / 身高 / 生日，避免为每个演员发一次请求。
    // 头像是 NFO 里的 `<thumb>`（jdbstatic 等 CDN），档案来自维基（可能为空）。
    app.post(
      '/api/v1/video/actor/avatars',
      secured('video:read', {
        schema: {
          operationId: 'videoActorAvatars',
          tags: TAG,
          summary: '按演员名批量取头像与档案（详情页演职人员区用）',
          body: Type.Object({
            names: Type.Array(Type.String(), { maxItems: 64 }),
            libraryId: Type.Optional(Type.String()),
          }),
          response: {
            200: Type.Object({
              items: Type.Array(
                Type.Object({
                  name: Type.String(),
                  key: Type.String(),
                  avatarUrl: Type.String(),
                  heightCm: Type.Integer(),
                  birthday: Type.String(),
                  birthplace: Type.String(),
                  itemCount: Type.Integer(),
                }),
              ),
            }),
          },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { names?: string[]; libraryId?: string };
        const names = (body.names || []).map((n) => String(n || '').trim()).filter(Boolean);
        if (names.length === 0) return { items: [] };
        const keys = [...new Set(names.map((n) => actorKey(n)).filter(Boolean))] as string[];
        if (keys.length === 0) return { items: [] };

        const rows = (
          await sql<{
            id: string;
            name: string;
            thumb_path: string | null;
            profile: string | null;
            n: number;
          }>`
            select a.id, a.name, a.thumb_path, a.profile,
                   (select count(*) from jp_actor_items ai
                     where ai.actor_id = a.id) as n
              from jp_actors a
             where a.id in (${sql.join(
               keys.map((k) => sql`${k}`),
               sql`, `,
             )})
          `.execute(k.db)
        ).rows;

        const byKey = new Map(rows.map((r) => [r.id, r]));
        return {
          items: names.map((name) => {
            const key = actorKey(name);
            const row = byKey.get(key);
            let profile: Record<string, unknown> = {};
            if (row?.profile) {
              try {
                profile = JSON.parse(row.profile) as Record<string, unknown>;
              } catch {
                profile = {};
              }
            }
            const num = (v: unknown) => {
              const n = Number(v);
              return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
            };
            return {
              name,
              key,
              avatarUrl: String(row?.thumb_path || profile.avatarUrl || ''),
              heightCm: num(profile.heightCm),
              birthday: String(profile.birthday ?? ''),
              birthplace: String(profile.birthplace ?? ''),
              itemCount: Number(row?.n || 0),
            };
          }),
        };
      },
    );
  }

/**
 * 电视剧库的「最近更新」卡片：一部剧一条。
 *
 * 排序用该剧最新的文件时间（`max(mtime)`）—— 用户刚下完一集，这部剧就该往前排。
 * 封面照 `/video/series` 的口径：优先取本剧里「有海报的那一集」，都没有才退回最小 id，
 * 否则前端拿 `/video/art` 会整排 404（表现为灰块）。
 *
 * `series` 为空的条目（识别不出季 / 集号的视频混在剧库里）单独算「1 季 1 集」，
 * 保证它们不会从首页凭空消失。
 */
async function recentSeriesOf(
  db: Parameters<typeof offlineSmbPrefixes>[0],
  libraryId: string,
  limit: number,
  offline: string[],
): Promise<Array<{ name: string; seasons: number; episodes: number; coverId: string | null }>> {
  const off = offline.length > 0 ? sql`and ${offlineCond(offline, 'rel_path')}` : sql``;
  const grouped = (
    await sql<{
      name: string;
      seasons: number;
      episodes: number;
      cover_id: string | null;
      at: number;
    }>`
      select series as name,
             count(distinct coalesce(season, 0)) as seasons,
             count(*) as episodes,
             ${seriesCoverIdSql()} as cover_id,
             max(mtime) as at
        from video_items
       where library_id = ${libraryId}
         and media_type = 'video'
         and series is not null
         and series <> ''
         ${off}
       group by series
       order by at desc
       limit ${limit}
    `.execute(db)
  ).rows;

  const solos = (
    await sql<{ id: string; name: string; at: number }>`
      select id,
             coalesce(nullif(nfo_name, ''), title) as name,
             mtime as at
        from video_items
       where library_id = ${libraryId}
         and media_type = 'video'
         and (series is null or series = '')
         ${off}
       order by mtime desc
       limit ${limit}
    `.execute(db)
  ).rows;

  const merged: Array<{ at: number; out: unknown }> = [
    ...grouped.map((r) => ({
      at: Number(r.at) || 0,
      out: {
        name: r.name,
        seasons: Number(r.seasons) || 1,
        episodes: Number(r.episodes) || 0,
        coverId: r.cover_id,
      },
    })),
    ...solos.map((r) => ({
      at: Number(r.at) || 0,
      out: { name: r.name, seasons: 1, episodes: 1, coverId: r.id },
    })),
  ];
  merged.sort((a, b) => b.at - a.at);
  return merged.slice(0, limit).map((x) => x.out as never);
}
