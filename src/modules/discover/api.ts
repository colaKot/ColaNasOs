import { sql } from 'kysely';
import fs from 'node:fs';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import { activeProxy } from '../../../kernel/proxy-fetch';
import {
  isFresh,
  listSnapshots,
  pruneSnapshots,
  readSnapshot,
  writeSnapshot,
} from '../../../kernel/catalog-store';
import type { FastifyRequest, FastifyReply } from 'fastify';
import {
  DiscoverUnavailable,
  fetchImageTo,
  imageUrl,
  isConfigured,
  normalizeConfig,
  tmdbGet,
  type TmdbConfig,
} from './tmdb';
import {
  attachCachedRatings,
  cachedRatings,
  doubanCacheStats,
  doubanCatalog,
  enrichDouban,
  ratingProviderOf,
  setRatingProvider,
} from './rating';

/**
 * 影视发现：目录（正在热映 / 热门 / 高分 / 即将上映）→ 详情 → 搜索。
 *
 * 三条硬约束：
 *   - 没有 API Key / 外网不通 ⇒ `degraded + reason`，绝不返回 500；
 *   - 目录结果**落库成快照**（`media_catalog`），进程内再挡一层 1 分钟缓存：
 *     重启后榜单还在，上游失败时回退到最近一次快照（此前只有内存缓存，重启即空）；
 *   - 图片走服务端代理 + 磁盘缓存，客户端不需要拿到 key，也不受图片域连通性影响。
 */
const TAG = ['discover'];

/** 收藏状态合法值（其它值一律回落到 watching） */
const FAVORITE_STATES = new Set(['watching', 'downloading', 'downloaded', 'owned']);

/** TMDB 官方风格 id → 中文名（静态表，不联网；与前端 compat 的静态表一致） */
const MOVIE_GENRES: Array<{ id: number; name: string }> = [
  { id: 28, name: '动作' },
  { id: 12, name: '冒险' },
  { id: 16, name: '动画' },
  { id: 35, name: '喜剧' },
  { id: 80, name: '犯罪' },
  { id: 99, name: '纪录片' },
  { id: 18, name: '剧情' },
  { id: 10751, name: '家庭' },
  { id: 14, name: '奇幻' },
  { id: 27, name: '恐怖' },
  { id: 9648, name: '悬疑' },
  { id: 10749, name: '爱情' },
  { id: 878, name: '科幻' },
  { id: 53, name: '惊悚' },
  { id: 10752, name: '战争' },
  { id: 37, name: '西部' },
];

const TV_GENRES: Array<{ id: number; name: string }> = [
  { id: 10759, name: '动作冒险' },
  { id: 16, name: '动画' },
  { id: 35, name: '喜剧' },
  { id: 80, name: '犯罪' },
  { id: 99, name: '纪录片' },
  { id: 18, name: '剧情' },
  { id: 10751, name: '家庭' },
  { id: 9648, name: '悬疑' },
  { id: 10764, name: '真人秀' },
  { id: 10765, name: '科幻奇幻' },
];

/** 进程内一层：同一页面连续翻页 / 反复切 tab，不必每次摸库 */
const L1_TTL_MS = 60 * 1000;
/** 快照新鲜期：6 小时内直接当数据源，完全不联网 */
const FRESH_SEC = 6 * 60 * 60;
/** 保留期：过期快照留 7 天，用来在上游抽风时兜底 */
const RETAIN_SEC = 7 * 24 * 60 * 60;

const SettingsItem = Type.Object(
  {
    apiKeyConfigured: Type.Boolean(),
    // 明文回传：用户要能看见自己配的是哪个 Key（自用 NAS，不做多租户隔离）
    apiKey: Type.String({ description: 'TMDB API Key 明文' }),
    baseUrl: Type.String(),
    language: Type.String(),
    imageBase: Type.String(),
    /** 评分体系：tmdb（默认）或 douban；决定列表里展示 vote_average 还是 ratingDouban */
    ratingProvider: Type.String({ description: 'tmdb / douban' }),
    /** 系统设置 → 网络代理实际生效的地址（只读回显，不可配） */
    proxyUrl: Type.String(),
  },
  { $id: 'DiscoverSettings' },
);

const SettingsBody = Type.Object(
  {
    apiKey: Type.Optional(Type.String({ maxLength: 200 })),
    baseUrl: Type.Optional(Type.String({ maxLength: 200 })),
    language: Type.Optional(Type.String({ maxLength: 20 })),
    imageBase: Type.Optional(Type.String({ maxLength: 200 })),
    ratingProvider: Type.Optional(Type.String({ maxLength: 16 })),
  },
  { $id: 'DiscoverSettingsBody' },
);

const MediaCard = Type.Object(
  {
    id: Type.Integer(),
    mediaType: Type.String({ description: 'movie / tv' }),
    title: Type.String(),
    originalTitle: Type.String(),
    overview: Type.String(),
    posterPath: Type.Union([Type.String(), Type.Null()]),
    backdropPath: Type.Union([Type.String(), Type.Null()]),
    year: Type.Union([Type.Integer(), Type.Null()]),
    rating: Type.Union([Type.Number(), Type.Null()]),
    /** 豆瓣分（评分体系=豆瓣时前端展示这个；未补齐为 null） */
    ratingDouban: Type.Optional(Type.Union([Type.Number(), Type.Null()])),
    doubanVoteCount: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
    doubanId: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    doubanUrl: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    /** 非 TMDB 来源（豆瓣榜单占位卡）的绝对海报地址 */
    posterUrl: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    /** 本库里已经有这部片（按 nfo_tmdb_id 精确匹配），客户端打「已拥有」角标 */
    owned: Type.Optional(Type.Boolean()),
    /** 当前账号已收藏（discover_favorites） */
    favorited: Type.Optional(Type.Boolean()),
    /**
     * 下载状态（客户端左上角角标用）：空 = 没下过，
     * downloading = 已在下载器里排队 / 下载中，downloaded = 下载完成（删了也保留）。
     */
    downloadState: Type.Optional(Type.String({ description: "'' / downloading / downloaded" })),
  },
  { $id: 'DiscoverMediaCard' },
);

const CatalogQuery = Type.Object(
  {
    kind: Type.Optional(
      Type.String({
        description:
          'trending / trending_day / trending_week / popular / top_rated / upcoming / now_playing / on_air',
        default: 'trending',
      }),
    ),
    media: Type.Optional(Type.String({ description: 'movie / tv', default: 'movie' })),
    page: Type.Optional(Type.Integer({ minimum: 1, maximum: 50, default: 1 })),
    genre: Type.Optional(
      Type.String({
        maxLength: 128,
        description: 'TMDB 类型 id；多个用 | 或逗号分隔（如 28|12）',
      }),
    ),
    year: Type.Optional(Type.Integer({ minimum: 1900, maximum: 2100 })),
    yearFrom: Type.Optional(Type.Integer({ minimum: 1900, maximum: 2100 })),
    yearTo: Type.Optional(Type.Integer({ minimum: 1900, maximum: 2100 })),
    /** 原始语言（with_original_language，如 zh / ja / en）；多个用逗号分隔，服务端逐语言取第一页合并 */
    language: Type.Optional(Type.String({ maxLength: 64 })),
    sort: Type.Optional(
      Type.String({
        maxLength: 40,
        description: 'popularity.desc / vote_average.desc / primary_release_date.desc',
      }),
    ),
    /** 出品国家 / 地区（ISO 3166-1，如 CN / US / JP） */
    country: Type.Optional(Type.String({ maxLength: 8, description: 'with_origin_country' })),
    /** 最低评分（0-10，TMDB vote_average.gte） */
    minVote: Type.Optional(Type.Number({ minimum: 0, maximum: 10 })),
  },
  { $id: 'DiscoverCatalogQuery' },
);

const CatalogResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(MediaCard)),
    page: Type.Integer(),
    totalPages: Type.Integer(),
    degraded: Type.Boolean(),
    reason: Type.String(),
    /** 当前评分体系（tmdb / douban）：客户端据此决定卡片显示哪个分 */
    ratingProvider: Type.Optional(Type.String()),
    /** true = 本次是"上游失败，回退到最近一次快照"，客户端应提示内容可能偏旧 */
    stale: Type.Optional(Type.Boolean()),
    /** 这份数据的抓取时间（Unix 秒）；stale 时用于显示"X 小时前" */
    snapshotAt: Type.Optional(Type.Integer()),
  },
  { $id: 'DiscoverCatalogResponse' },
);

const CatalogSnapshotItem = Type.Object(
  {
    catalogType: Type.String({ description: 'tmdb / jp_rank' }),
    key: Type.String(),
    itemCount: Type.Integer(),
    snapshotAt: Type.Integer(),
    ageSec: Type.Integer(),
    fresh: Type.Boolean({ description: '是否在新鲜期内（新鲜则不联网）' }),
  },
  { $id: 'DiscoverCatalogSnapshotItem' },
);

const CatalogSnapshotList = Type.Object(
  { items: Type.Array(Type.Ref(CatalogSnapshotItem)) },
  { $id: 'DiscoverCatalogSnapshotList' },
);

const PruneResponse = Type.Object(
  { pruned: Type.Integer() },
  { $id: 'DiscoverCatalogPruneResponse' },
);

const SearchQuery = Type.Object(
  {
    q: Type.String({ minLength: 1, maxLength: 100 }),
    media: Type.Optional(Type.String({ description: 'movie / tv', default: 'movie' })),
    page: Type.Optional(Type.Integer({ minimum: 1, maximum: 50, default: 1 })),
  },
  { $id: 'DiscoverSearchQuery' },
);

const DetailQuery = Type.Object(
  {
    id: Type.Integer({ minimum: 1 }),
    media: Type.Optional(Type.String({ description: 'movie / tv', default: 'movie' })),
  },
  { $id: 'DiscoverDetailQuery' },
);

const DetailResponse = Type.Object(
  {
    id: Type.Integer(),
    mediaType: Type.String(),
    title: Type.String(),
    originalTitle: Type.String(),
    overview: Type.String(),
    posterPath: Type.Union([Type.String(), Type.Null()]),
    backdropPath: Type.Union([Type.String(), Type.Null()]),
    year: Type.Union([Type.Integer(), Type.Null()]),
    runtime: Type.Union([Type.Integer(), Type.Null()]),
    rating: Type.Union([Type.Number(), Type.Null()]),
    genres: Type.Array(Type.String()),
    cast: Type.Array(Type.String()),
    /** 演员卡（带头像相对路径 + 角色名）：既有实现 详情页按这个渲染头像横滑列表 */
    castMembers: Type.Optional(
      Type.Array(
        Type.Object({
          name: Type.String(),
          character: Type.String(),
          profilePath: Type.Union([Type.String(), Type.Null()]),
        }),
        { maxItems: 20 },
      ),
    ),
    /** IMDb id（TMDB external_ids）；没配 Key 或取不到为 null */
    imdbId: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    /** 豆瓣条目 id / 链接 / 评分（来自本地豆瓣缓存，不额外联网） */
    doubanId: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    doubanUrl: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    ratingDouban: Type.Optional(Type.Union([Type.Number(), Type.Null()])),
    ratingProvider: Type.Optional(Type.String()),
    /** TV 的季集（电影为空数组）；season 0 = 特别篇，已过滤 */
    seasons: Type.Array(
      Type.Object({
        season: Type.Integer(),
        name: Type.String(),
        episodes: Type.Integer(),
      }),
    ),
    /** 详情页「信息」区：既有实现 参考页逐项渲染这些字段 */
    status: Type.String({ description: 'Released / Returning Series 等' }),
    tagline: Type.String(),
    /** ISO 639-1，参考页会 toUpperCase 展示 */
    originalLanguage: Type.String(),
    voteCount: Type.Integer(),
    numberOfSeasons: Type.Integer(),
    numberOfEpisodes: Type.Integer(),
    countries: Type.Array(Type.String()),
    networks: Type.Array(Type.String()),
    companies: Type.Array(Type.String()),
    createdBy: Type.Array(Type.String()),
    degraded: Type.Boolean(),
    reason: Type.String(),
  },
  { $id: 'DiscoverDetailResponse' },
);

const ImageQuery = Type.Object(
  {
    path: Type.String({ minLength: 2, maxLength: 200 }),
    size: Type.Optional(Type.String({ default: 'w342' })),
  },
  { $id: 'DiscoverImageQuery' },
);

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'DiscoverApiError' },
);

const FavoriteBody = Type.Object(
  {
    id: Type.Integer({ minimum: 1 }),
    mediaType: Type.String({ maxLength: 8 }),
    favorite: Type.Boolean(),
    /** 收藏状态；不传或非法值一律回落 watching */
    state: Type.Optional(
      Type.String({ description: 'watching / downloading / downloaded / owned' }),
    ),
  },
  { $id: 'DiscoverFavoriteBody' },
);
const FavoriteResponse = Type.Object(
  { favorite: Type.Boolean(), state: Type.String() },
  { $id: 'DiscoverFavoriteResponse' },
);
const FavoriteListQuery = Type.Object(
  { state: Type.Optional(Type.String()) },
  { $id: 'DiscoverFavoriteListQuery' },
);
const FavoriteListResponse = Type.Object(
  {
    items: Type.Array(
      Type.Object({
        id: Type.Integer(),
        mediaType: Type.String(),
        state: Type.String(),
        downloadTaskId: Type.Union([Type.String(), Type.Null()]),
      }),
    ),
  },
  { $id: 'DiscoverFavoriteListResponse' },
);

const SCHEMAS = [
  SettingsItem,
  SettingsBody,
  MediaCard,
  CatalogQuery,
  CatalogResponse,
  CatalogSnapshotItem,
  CatalogSnapshotList,
  PruneResponse,
  SearchQuery,
  DetailQuery,
  DetailResponse,
  ImageQuery,
  FavoriteBody,
  FavoriteResponse,
  FavoriteListQuery,
  FavoriteListResponse,
  ErrorResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });

function toCard(raw: any, mediaType: string) {
  const date = String(raw?.release_date || raw?.first_air_date || '');
  return {
    id: Number(raw?.id) || 0,
    mediaType,
    title: String(raw?.title || raw?.name || ''),
    originalTitle: String(raw?.original_title || raw?.original_name || ''),
    overview: String(raw?.overview || ''),
    posterPath: raw?.poster_path ? String(raw.poster_path) : null,
    backdropPath: raw?.backdrop_path ? String(raw.backdrop_path) : null,
    year: /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null,
    rating: Number.isFinite(Number(raw?.vote_average)) ? Number(raw.vote_average) : null,
  };
}

/**
 * 给发现页卡片打「已拥有 / 已收藏 / 下载状态」。
 * - owned：`video_items.nfo_tmdb_id` 精确匹配（与排重/刮削共用一列），没刮削过不猜；
 * - favorited：当前账号在 `discover_favorites` 里的记录（每用户独立）；
 * - downloadState：`pt_downloads` 里同一部片的活跃 / 已完成记录（删了种子也保留已完成）。
 */
async function markFlags(
  k: KernelApi,
  items: Array<{ id: number }>,
  media: string,
  uid: string,
) {
  type Flagged = { id: number; owned?: boolean; favorited?: boolean; downloadState?: string };
  const ids = items.map((i) => Number(i.id)).filter((n) => n > 0);
  if (ids.length === 0) return items as Flagged[];
  try {
    const inList = sql.join(ids.map((n) => sql`${n}`), sql`, `);
    const ownedRows = (
      await sql<{ nfo_tmdb_id: number }>`
        select distinct nfo_tmdb_id from video_items
         where nfo_tmdb_id in (${inList})
      `.execute(k.db)
    ).rows;
    const owned = new Set(ownedRows.map((r) => Number(r.nfo_tmdb_id)));
    const fav = new Map<number, string>();
    if (uid) {
      const favRows = (
        await sql<{ tmdb_id: number; state: string }>`
          select tmdb_id, state from discover_favorites
           where uid = ${uid} and media_type = ${media}
             and tmdb_id in (${inList})
        `.execute(k.db)
      ).rows;
      for (const r of favRows) fav.set(Number(r.tmdb_id), String(r.state || 'watching'));
    }
    // 下载台账：按 media_id 关联（173 迁移补齐），拿不到就当没下载过
    const downloading = new Set<number>();
    const completed = new Set<number>();
    if (uid) {
      try {
        const rows = (
          await sql<{ media_id: number; status: string }>`
            select media_id, status from pt_downloads
             where uid = ${uid} and media_type = ${media}
               and media_id in (${inList})
          `.execute(k.db)
        ).rows;
        for (const r of rows) {
          const st = String(r.status || '');
          if (st === 'completed') completed.add(Number(r.media_id));
          else if (st === 'added' || st === 'paused' || st === 'downloading') {
            downloading.add(Number(r.media_id));
          }
        }
      } catch { /* pt 模块未启用时忽略 */ }
    }
    return (items as Flagged[]).map((it) => {
      const id = Number(it.id);
      const state = fav.get(id) || '';
      const isDownloading = downloading.has(id) || state === 'downloading';
      const isDownloaded = completed.has(id) || state === 'downloaded';
      return {
        ...it,
        owned: owned.has(id),
        favorited: fav.has(id),
        downloadState: isDownloading ? 'downloading' : isDownloaded ? 'downloaded' : '',
      };
    });
  } catch {
    return items as Flagged[];
  }
}

/** 递归统计目录里的文件数与总字节数；目录不存在等异常一律按 0 处理 */
async function dirStats(dir: string): Promise<{ files: number; bytes: number }> {
  let files = 0;
  let bytes = 0;
  try {
    const entries = await fs.promises.readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      const full = path.join(dir, e.name);
      try {
        if (e.isDirectory()) {
          const sub = await dirStats(full);
          files += sub.files;
          bytes += sub.bytes;
        } else if (e.isFile()) {
          bytes += (await fs.promises.stat(full)).size;
          files += 1;
        }
      } catch {
        /* 单个文件读不到就跳过 */
      }
    }
  } catch {
    /* 目录不存在 */
  }
  return { files, bytes };
}

interface CacheEntry {
  at: number;
  value: unknown;
}

export async function registerDiscoverApi(app: any, k: KernelApi): Promise<void> {
  for (const schema of SCHEMAS) app.addSchema(schema);

  const cache = new Map<string, CacheEntry>();

  const config = (): TmdbConfig => normalizeConfig(k.config.get('discover.tmdb'));

  /**
   * 列表统一收尾：带上当前评分体系；豆瓣模式下把**已缓存**的豆瓣分贴到卡片上
   * （不发网络请求，真正缺失的由前端再调 douban/enrich 批量补）。
   */
  const finishList = async <T extends { id: number }>(
    items: T[],
    media: string,
  ): Promise<{ items: T[]; ratingProvider: string }> => {
    const provider = ratingProviderOf(k);
    if (provider !== 'douban' || items.length === 0) return { items, ratingProvider: provider };
    return { items: await attachCachedRatings(k, items, media), ratingProvider: provider };
  };

  // 启动时清一次过期快照：只靠"写入时顺带清"的话，用户不再打开发现页就永远不清理
  void pruneSnapshots(k.db, { retainSec: RETAIN_SEC }).catch(() => 0);

  interface CatalogHit<T> {
    value: T;
    stale: boolean;
    snapshotAt: number;
  }

  /**
   * 三层取数：进程内 1 分钟 → 数据库快照（6 小时内视为新鲜，不联网）→ 上游。
   * 上游失败且有过快照时返回 `stale`，而不是把空列表丢给用户。
   */
  const cached = async <T>(
    key: string,
    fn: () => Promise<T>,
    itemCountOf?: (v: T) => number,
  ): Promise<CatalogHit<T>> => {
    const hit = cache.get(key);
    if (hit && Date.now() - hit.at < L1_TTL_MS) {
      return { value: hit.value as T, stale: false, snapshotAt: Math.floor(hit.at / 1000) };
    }
    const snap = await readSnapshot(k.db, 'tmdb', key).catch(() => null);
    if (snap && isFresh(snap.snapshotAt, FRESH_SEC)) {
      cache.set(key, { at: Date.now(), value: snap.payload });
      return { value: snap.payload as T, stale: false, snapshotAt: snap.snapshotAt };
    }
    try {
      const value = await fn();
      cache.set(key, { at: Date.now(), value });
      await writeSnapshot(k.db, 'tmdb', key, value, {
        itemCount: itemCountOf ? itemCountOf(value) : 0,
        retainSec: RETAIN_SEC,
      }).catch(() => undefined);
      return { value, stale: false, snapshotAt: Math.floor(Date.now() / 1000) };
    } catch (err) {
      if (snap) {
        k.log?.warn?.(
          { key, err: String((err as Error)?.message || err) },
          'discover: fallback to stale catalog snapshot',
        );
        return { value: snap.payload as T, stale: true, snapshotAt: snap.snapshotAt };
      }
      throw err;
    }
  };

  app.get(
    '/api/v1/discover/settings',
    secured('discover:read', {
      schema: {
        operationId: 'discoverSettingsGet',
        tags: TAG,
        summary: '影视发现设置（只回是否已配置 key，不回 key 本身）',
        response: { 200: ref('DiscoverSettings') },
      },
    }),
    async () => {
      const cfg = config();
      return {
        apiKeyConfigured: isConfigured(cfg),
        apiKey: cfg.apiKey,
        baseUrl: cfg.baseUrl,
        language: cfg.language,
        imageBase: cfg.imageBase,
        ratingProvider: ratingProviderOf(k),
        proxyUrl: activeProxy(),
      };
    },
  );

  app.post(
    '/api/v1/discover/settings',
    secured('discover:write', {
      schema: {
        operationId: 'discoverSettingsSet',
        tags: TAG,
        summary: '保存影视发现设置（apiKey 留空 = 不改）',
        body: ref('DiscoverSettingsBody'),
        response: { 200: ref('DiscoverSettings') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        apiKey?: string;
        baseUrl?: string;
        language?: string;
        imageBase?: string;
        ratingProvider?: string;
      };
      const current = (k.config.get<Record<string, unknown>>('discover.tmdb') || {}) as Record<string, unknown>;
      const next = {
        ...current,
        ...(body.apiKey !== undefined && body.apiKey !== '' ? { apiKey: body.apiKey } : {}),
        ...(body.baseUrl ? { baseUrl: body.baseUrl } : {}),
        ...(body.language ? { language: body.language } : {}),
        ...(body.imageBase ? { imageBase: body.imageBase } : {}),
      };
      await k.config.set('discover.tmdb', next);
      if (body.ratingProvider !== undefined) {
        await setRatingProvider(k, body.ratingProvider);
      }
      cache.clear();
      const cfg = normalizeConfig(next);
      return {
        apiKeyConfigured: isConfigured(cfg),
        apiKey: cfg.apiKey,
        baseUrl: cfg.baseUrl,
        language: cfg.language,
        imageBase: cfg.imageBase,
        ratingProvider: ratingProviderOf(k),
        proxyUrl: activeProxy(),
      };
    },
  );

  app.get(
    '/api/v1/discover/catalog',
    secured('discover:read', {
      schema: {
        operationId: 'discoverCatalog',
        tags: TAG,
        summary: '发现目录（trending / popular / top_rated / upcoming / now_playing / on_air）',
        querystring: ref('DiscoverCatalogQuery'),
        response: { 200: ref('DiscoverCatalogResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as {
        kind?: string;
        media?: string;
        page?: number;
        genre?: string;
        year?: number;
        yearFrom?: number;
        yearTo?: number;
        language?: string;
        sort?: string;
        country?: string;
        minVote?: number;
      };
      const media = q.media === 'tv' ? 'tv' : 'movie';
      const kind = String(q.kind || 'trending');
      const page = Math.max(1, Math.min(Number(q.page) || 1, 50));
      // 多选风格：`28|12` / `28,12` / `28 12` 统一成 TMDB 的 `28|12`
      const genre = String(q.genre || '')
        .trim()
        .replace(/[\s,]+/g, '|')
        .replace(/\|+/g, '|');
      const year = Number(q.year) || 0;
      const yearFrom = Math.max(0, Number(q.yearFrom) || 0);
      const yearTo = Math.max(0, Number(q.yearTo) || 0);
      const languages = String(q.language || '')
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .filter(Boolean)
        .slice(0, 4);
      const sort = String(q.sort || '').trim();
      const country = String(q.country || '').trim().toUpperCase();
      const minVote = Number.isFinite(Number(q.minVote)) ? Number(q.minVote) : 0;
      const cfg = config();
      if (!isConfigured(cfg)) {
        return {
          items: [],
          page,
          totalPages: 0,
          degraded: true,
          reason: '未配置 TMDB API Key',
          ratingProvider: ratingProviderOf(k),
        };
      }

      // 有筛选条件时走 TMDB /discover（trending 等榜单接口不支持筛选）
      const filtered =
        genre !== '' ||
        year > 0 ||
        yearFrom > 0 ||
        yearTo > 0 ||
        languages.length > 0 ||
        sort !== '' ||
        country !== '' ||
        minVote > 0;
      // TV 没有 upcoming / now_playing 端点：统一落到 on_the_air（既有实现的合法端点）
      const apiPath = filtered
        ? `/discover/${media}`
        : kind === 'trending_day'
          ? `/trending/${media}/day`
          : kind === 'trending' || kind === 'trending_week'
            ? `/trending/${media}/week`
            : kind === 'top_rated'
              ? `/${media}/top_rated`
              : kind === 'upcoming'
                ? media === 'tv'
                  ? '/tv/on_the_air'
                  : '/movie/upcoming'
                : kind === 'on_air'
                  ? '/tv/on_the_air'
                  : kind === 'now_playing'
                    ? media === 'tv'
                      ? '/tv/on_the_air'
                      : '/movie/now_playing'
                    : `/${media}/popular`;
      const params: Record<string, string | number> = { page };
      if (filtered) {
        if (genre) params.with_genres = genre;
        // 年份：精确年优先；否则按区间（TMDB 用 gte/lte 的完整日期）
        const dateField = media === 'tv' ? 'first_air_date' : 'primary_release_date';
        if (year > 0) {
          if (media === 'tv') params.first_air_date_year = year;
          else params.primary_release_year = year;
        } else {
          if (yearFrom > 0) params[`${dateField}.gte`] = `${yearFrom}-01-01`;
          if (yearTo > 0) params[`${dateField}.lte`] = `${yearTo}-12-31`;
        }
        if (languages.length === 1) params.with_original_language = languages[0];
        if (country) params.with_origin_country = country;
        if (minVote > 0) params['vote_average.gte'] = minVote;
        // 给了最低评分时按评分排更符合预期（否则高评分片会被热度排序埋掉）
        params.sort_by = sort || (minVote > 0 ? 'vote_average.desc' : 'popularity.desc');
        params.include_adult = 'false';
      }
      const cacheKey = filtered
        ? `catalog:${media}:discover:${genre}:${year}:${yearFrom}:${yearTo}:${languages.join('+')}:${country}:${minVote}:${params.sort_by}:${page}`
        : `catalog:${media}:${kind}:${page}`;
      try {
        // TMDB 的 with_original_language 只接受单值：多选时按语言分别请求第一页，
        // 去重后按 popularity 降序合并（分页退化为单页，这是多选本身的语义代价）。
        if (languages.length > 1) {
          const multiKey = `catalog:${media}:discover:${genre}:${year}:${yearFrom}:${yearTo}:${languages.join('+')}:${country}:${minVote}:${params.sort_by}:multi`;
          const base: Record<string, string | number> = { ...params };
          delete base.with_original_language;
          const hit = await cached(
            multiKey,
            async () => {
              const pages = await Promise.all(
                languages.slice(0, 3).map((lang) =>
                  tmdbGet(cfg, apiPath, {
                    ...base,
                    page: 1,
                    with_original_language: lang,
                  }),
                ),
              );
              const seen = new Set<number>();
              const merged: any[] = [];
              for (const data of pages) {
                for (const r of data?.results || []) {
                  const id = Number(r?.id) || 0;
                  if (!id || seen.has(id)) continue;
                  seen.add(id);
                  merged.push(r);
                }
              }
              merged.sort(
                (a, b) => (Number(b?.popularity) || 0) - (Number(a?.popularity) || 0),
              );
              return { page: 1, total_pages: 1, results: merged };
            },
            (v: any) => (Array.isArray(v?.results) ? v.results.length : 0),
          );
          const data = hit.value as any;
          const multi = await finishList(
            await markFlags(
              k,
              (data?.results || []).map((r: any) => toCard(r, media)),
              media,
              String(req.user?.sub || ''),
            ),
            media,
          );
          return {
            items: multi.items,
            ratingProvider: multi.ratingProvider,
            page: 1,
            totalPages: 1,
            degraded: false,
            reason: '',
            stale: hit.stale,
            snapshotAt: hit.snapshotAt,
          };
        }
        const hit = await cached(
          cacheKey,
          () => tmdbGet(cfg, apiPath, params),
          (v: any) => (Array.isArray(v?.results) ? v.results.length : 0),
        );
        const data = hit.value as any;
        const items = (data?.results || []).map((r: any) => toCard(r, media));
        const single = await finishList(
          await markFlags(k, items, media, String(req.user?.sub || '')),
          media,
        );
        return {
          items: single.items,
          ratingProvider: single.ratingProvider,
          page,
          totalPages: Number(data?.total_pages) || 0,
          degraded: false,
          reason: '',
          stale: hit.stale,
          snapshotAt: hit.snapshotAt,
        };
      } catch (err) {
        return {
          items: [],
          page,
          totalPages: 0,
          degraded: true,
          reason: String((err as Error)?.message || err).slice(0, 200),
        };
      }
    },
  );

  app.get(
    '/api/v1/discover/search',
    secured('discover:read', {
      schema: {
        operationId: 'discoverSearch',
        tags: TAG,
        summary: '搜索影视',
        querystring: ref('DiscoverSearchQuery'),
        response: { 200: ref('DiscoverCatalogResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { q?: string; media?: string; page?: number };
      const media = q.media === 'tv' ? 'tv' : 'movie';
      const page = Math.max(1, Math.min(Number(q.page) || 1, 50));
      const keyword = String(q.q || '').trim().slice(0, 100);
      const cfg = config();
      if (!isConfigured(cfg)) {
        return {
          items: [],
          page,
          totalPages: 0,
          degraded: true,
          reason: '未配置 TMDB API Key',
          ratingProvider: ratingProviderOf(k),
        };
      }
      if (!keyword) {
        return { items: [], page, totalPages: 0, degraded: false, reason: '' };
      }
      try {
        const data = await tmdbGet(cfg, `/search/${media}`, { query: keyword, page });
        const cards = (data?.results || []).map((r: any) => toCard(r, media));
        const fin = await finishList(
          await markFlags(k, cards, media, String(req.user?.sub || '')),
          media,
        );
        return {
          items: fin.items,
          ratingProvider: fin.ratingProvider,
          page,
          totalPages: Number(data?.total_pages) || 0,
          degraded: false,
          reason: '',
        };
      } catch (err) {
        return {
          items: [],
          page,
          totalPages: 0,
          degraded: true,
          reason: String((err as Error)?.message || err).slice(0, 200),
        };
      }
    },
  );

  app.post(
    '/api/v1/discover/favorites/set',
    secured('discover:write', {
      schema: {
        operationId: 'discoverFavoriteSet',
        tags: TAG,
        summary: '收藏 / 取消收藏发现条目（每用户独立）',
        body: ref('DiscoverFavoriteBody'),
        response: { 200: ref('DiscoverFavoriteResponse'), 400: ref('DiscoverApiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const b = (req.body || {}) as {
        id?: number;
        mediaType?: string;
        favorite?: boolean;
        state?: string;
      };
      const uid = String(req.user?.sub || '');
      const id = Number(b.id) || 0;
      const mediaType = b.mediaType === 'tv' ? 'tv' : 'movie';
      if (!uid || id <= 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
      }
      const raw = typeof b.state === 'string' ? b.state.trim() : '';
      const state = FAVORITE_STATES.has(raw) ? raw : 'watching';
      const now = Math.floor(Date.now() / 1000);
      if (b.favorite === true) {
        await sql`
          insert into discover_favorites (uid, media_type, tmdb_id, created_at, state, updated_at)
          values (${uid}, ${mediaType}, ${id}, ${now}, ${state}, ${now})
          on conflict (uid, media_type, tmdb_id) do update set
            state = excluded.state, updated_at = excluded.updated_at
        `.execute(k.db);
      } else {
        await sql`
          delete from discover_favorites
           where uid = ${uid} and media_type = ${mediaType} and tmdb_id = ${id}
        `.execute(k.db);
      }
      return { favorite: b.favorite === true, state: b.favorite === true ? state : '' };
    },
  );

  app.get(
    '/api/v1/discover/favorites',
    secured('discover:read', {
      schema: {
        operationId: 'discoverFavorites',
        tags: TAG,
        summary: '当前账号的发现收藏（id + mediaType + state）',
        querystring: ref('DiscoverFavoriteListQuery'),
        response: { 200: ref('DiscoverFavoriteListResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String(req.user?.sub || '');
      const q = (req.query || {}) as { state?: string };
      const state = typeof q.state === 'string' ? q.state.trim() : '';
      const rows = (
        state
          ? await sql<{
              tmdb_id: number;
              media_type: string;
              state: string | null;
              download_task_id: string | null;
            }>`
              select tmdb_id, media_type, state, download_task_id
                from discover_favorites
               where uid = ${uid} and state = ${state}
               order by created_at desc limit 500
            `.execute(k.db)
          : await sql<{
              tmdb_id: number;
              media_type: string;
              state: string | null;
              download_task_id: string | null;
            }>`
              select tmdb_id, media_type, state, download_task_id
                from discover_favorites
               where uid = ${uid}
               order by created_at desc limit 500
            `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: Number(r.tmdb_id),
          mediaType: r.media_type,
          state: String(r.state || 'watching'),
          downloadTaskId: r.download_task_id == null ? null : String(r.download_task_id),
        })),
      };
    },
  );

  app.get(
    '/api/v1/discover/detail',
    secured('discover:read', {
      schema: {
        operationId: 'discoverDetail',
        tags: TAG,
        summary: '影视详情（简介 / 类型 / 时长 / 主要演员）',
        querystring: ref('DiscoverDetailQuery'),
        response: { 200: ref('DiscoverDetailResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { id?: number; media?: string };
      const media = q.media === 'tv' ? 'tv' : 'movie';
      const id = Number(q.id) || 0;
      const cfg = config();
      const empty = {
        id,
        mediaType: media,
        title: '',
        originalTitle: '',
        overview: '',
        posterPath: null,
        backdropPath: null,
        year: null,
        runtime: null,
        rating: null,
        genres: [] as string[],
        cast: [] as string[],
        castMembers: [] as Array<{
          name: string;
          character: string;
          profilePath: string | null;
        }>,
        imdbId: null as string | null,
        doubanId: null as string | null,
        doubanUrl: null as string | null,
        ratingDouban: null as number | null,
        seasons: [] as Array<{ season: number; name: string; episodes: number }>,
        status: '',
        tagline: '',
        originalLanguage: '',
        voteCount: 0,
        numberOfSeasons: 0,
        numberOfEpisodes: 0,
        countries: [] as string[],
        networks: [] as string[],
        companies: [] as string[],
        createdBy: [] as string[],
      };
      if (!isConfigured(cfg)) {
        return {
          ...empty,
          degraded: true,
          reason: '未配置 TMDB API Key',
          ratingProvider: ratingProviderOf(k),
        };
      }
      try {
        const hit = await cached(`detail:${media}:${id}`, () =>
          tmdbGet(cfg, `/${media}/${id}`, { append_to_response: 'credits,external_ids' }),
        );
        const data = hit.value as any;
        const date = String(data?.release_date || data?.first_air_date || '');
        // 豆瓣条目：只读本地缓存，不为了详情页再打一次豆瓣
        const douban = (await cachedRatings(k, media, [id])).get(id) ?? null;
        return {
          ...empty,
          title: String(data?.title || data?.name || ''),
          originalTitle: String(data?.original_title || data?.original_name || ''),
          overview: String(data?.overview || ''),
          posterPath: data?.poster_path ? String(data.poster_path) : null,
          backdropPath: data?.backdrop_path ? String(data.backdrop_path) : null,
          year: /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null,
          runtime: Number(data?.runtime) || null,
          rating: Number.isFinite(Number(data?.vote_average)) ? Number(data.vote_average) : null,
          genres: (data?.genres || []).map((g: any) => String(g?.name || '')).filter(Boolean),
          cast: (data?.credits?.cast || []).slice(0, 12).map((c: any) => String(c?.name || '')).filter(Boolean),
          castMembers: (data?.credits?.cast || [])
            .slice(0, 12)
            .map((c: any) => ({
              name: String(c?.name || ''),
              character: String(c?.character || ''),
              profilePath: c?.profile_path ? String(c.profile_path) : null,
            }))
            .filter((c: { name: string }) => c.name.length > 0),
          imdbId: data?.external_ids?.imdb_id
            ? String(data.external_ids.imdb_id)
            : data?.imdb_id
              ? String(data.imdb_id)
              : null,
          doubanId: douban?.doubanId ?? null,
          doubanUrl: douban?.url ?? null,
          ratingDouban: douban?.rating ?? null,
          seasons: (data?.seasons || [])
            .map((s: any) => ({
              season: Number(s?.season_number) || 0,
              name: String(s?.name || ''),
              episodes: Number(s?.episode_count) || 0,
            }))
            .filter((s: { season: number }) => s.season > 0),
          // 详情页「信息」区：电影的国家来自 production_countries，
          // 剧集用 origin_country（ISO 码，没有中文名）。
          status: String(data?.status || ''),
          tagline: String(data?.tagline || ''),
          originalLanguage: String(data?.original_language || ''),
          voteCount: Number(data?.vote_count) || 0,
          numberOfSeasons: Number(data?.number_of_seasons) || 0,
          numberOfEpisodes: Number(data?.number_of_episodes) || 0,
          countries: (
            (data?.production_countries || []).map((c: any) => String(c?.name || ''))
              .filter(Boolean) as string[]
          ).concat(
            (data?.origin_country || []).map((c: any) => String(c || '')).filter(Boolean),
          ).filter((v, i, arr) => arr.indexOf(v) === i),
          networks: (data?.networks || [])
            .map((n: any) => String(n?.name || ''))
            .filter(Boolean),
          companies: (data?.production_companies || [])
            .map((c: any) => String(c?.name || ''))
            .filter(Boolean),
          createdBy: (data?.created_by || [])
            .map((c: any) => String(c?.name || ''))
            .filter(Boolean),
          degraded: false,
          reason: '',
        };
      } catch (err) {
        return {
          ...empty,
          degraded: true,
          reason: String((err as Error)?.message || err).slice(0, 200),
          ratingProvider: ratingProviderOf(k),
        };
      }
    },
  );

  app.get(
    '/api/v1/discover/image',
    secured('discover:read', {
      schema: {
        operationId: 'discoverImage',
        tags: TAG,
        summary: '海报 / 剧照代理（磁盘缓存；客户端不需要知道图片域）',
        querystring: ref('DiscoverImageQuery'),
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as { path?: string; size?: string };
      const raw = String(q.path || '');
      // 只接受 TMDB 的相对路径：拒绝任何带协议的输入，避免被当成开放代理
      if (!raw.startsWith('/') || raw.includes('..') || /^[a-z]+:\/\//i.test(raw)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid image path' });
      }
      const cfg = config();
      const dir = path.join(k.paths.dataDir, 'discover-images');
      const got = await fetchImageTo(cfg, raw, String(q.size || 'w342'), dir);
      if (!got) {
        return reply.code(404).send({ error: Err.notFound, message: 'image unavailable' });
      }
      const buf = fs.readFileSync(got.file);
      return reply.type(got.contentType).header('cache-control', 'public, max-age=86400').send(buf);
    },
  );

  // 供客户端直接拼图片地址（与 /discover/image 参数一致）
  app.get(
    '/api/v1/discover/image-url',
    secured('discover:read', {
      schema: {
        operationId: 'discoverImageUrl',
        tags: TAG,
        summary: '图片地址（本机代理路径）',
        querystring: ref('DiscoverImageQuery'),
        response: {
          200: Type.Object(
            { url: Type.String() },
            { $id: 'DiscoverImageUrl' },
          ),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { path?: string; size?: string };
      const raw = String(q.path || '');
      const size = String(q.size || 'w342');
      return {
        url: `${(req.protocol || 'http')}://${req.headers.host || 'localhost'}/api/v1/discover/image?path=${encodeURIComponent(
          raw,
        )}&size=${size}`,
      };
    },
  );
  // 榜单快照状态：哪些 key 落了库、多旧、还算不算新鲜。
  // 存在的主要理由是「出问题时有据可查」——重启后榜单空了，看这个就知道是没快照还是快照过期。
  app.get(
    '/api/v1/discover/catalog/snapshots',
    secured('discover:read', {
      schema: {
        operationId: 'discoverCatalogSnapshots',
        tags: TAG,
        summary: '榜单快照清单（含 age / fresh，不含 payload）',
        response: { 200: ref('DiscoverCatalogSnapshotList') },
      },
    }),
    async () => {
      const now = Math.floor(Date.now() / 1000);
      const rows = await listSnapshots(k.db);
      return {
        items: rows.map((r) => ({
          ...r,
          ageSec: Math.max(0, now - r.snapshotAt),
          fresh: isFresh(r.snapshotAt, FRESH_SEC),
        })),
      };
    },
  );

  // 手动清理过期快照（启动与写入时已自动清理，这里给"想立刻腾空间"的场合）
  app.post(
    '/api/v1/discover/catalog/prune',
    secured('discover:write', {
      schema: {
        operationId: 'discoverCatalogPrune',
        tags: TAG,
        summary: '清理超过保留期的榜单快照',
        response: { 200: ref('DiscoverCatalogPruneResponse') },
      },
    }),
    async () => ({ pruned: await pruneSnapshots(k.db, { retainSec: RETAIN_SEC }) }),
  );

  // TMDB 连通性自检：真打一次轻量端点。baseUrl 已含 /3（见 tmdb.ts 的 DEFAULT_BASE），
  // 所以这里只传 /configuration；任何失败都收敛成 ok=false，绝不把异常抛成 500。
  app.post(
    '/api/v1/discover/settings/test',
    secured('discover:read', {
      schema: {
        operationId: 'discoverSettingsTest',
        tags: TAG,
        summary: '测试 TMDB 连通性（请求 /3/configuration）',
        response: {
          200: Type.Object({
            ok: Type.Boolean(),
            elapsedMs: Type.Integer(),
            proxyUrl: Type.String(),
            imageBaseUrl: Type.String(),
            message: Type.String(),
          }),
        },
      },
    }),
    async () => {
      const cfg = config();
      const proxyUrl = activeProxy();
      const started = Date.now();
      try {
        await tmdbGet(cfg, '/configuration');
        return {
          ok: true,
          elapsedMs: Date.now() - started,
          proxyUrl,
          imageBaseUrl: cfg.imageBase,
          message: '连接成功',
        };
      } catch (err) {
        return {
          ok: false,
          elapsedMs: Date.now() - started,
          proxyUrl,
          imageBaseUrl: cfg.imageBase,
          message: `连接失败：${String((err as Error)?.message || err).slice(0, 200)}`,
        };
      }
    },
  );

  // 缓存占用：图片落盘目录（不存在按 0）+ media_rating 表（不存在按 0）。
  // 纯只读统计，所有异常吞掉，绝不影响发现页主链路。
  app.get(
    '/api/v1/discover/cache/stats',
    secured('discover:read', {
      schema: {
        operationId: 'discoverCacheStats',
        tags: TAG,
        summary: '发现缓存统计（图片文件数 / 字节、评分数）',
        response: {
          200: Type.Object({
            images: Type.Object({
              tmdb: Type.Object({ files: Type.Integer(), bytes: Type.Integer() }),
              douban: Type.Object({ files: Type.Integer(), bytes: Type.Integer() }),
            }),
            ratings: Type.Object({
              tmdb: Type.Integer(),
              douban: Type.Integer(),
            }),
            douban: Type.Optional(
              Type.Object(
                {
                  ratingRows: Type.Integer(),
                  chartRows: Type.Integer(),
                  provider: Type.String(),
                },
                { additionalProperties: true },
              ),
            ),
          }),
        },
      },
    }),
    async () => {
      const tmdb = await dirStats(path.join(k.paths.dataDir, 'discover-images'));
      const douban = await dirStats(path.join(k.paths.dataDir, 'discover-douban-images'));
      const ratings = { tmdb: 0, douban: 0 };
      try {
        // 表存在时按来源分组统计；列名不同时退回 count(*) 兜底。
        const rows = (
          await sql<{ provider: string; n: number }>`
            select provider, count(*) as n from media_rating group by provider
          `.execute(k.db)
        ).rows;
        for (const r of rows) {
          const n = Number(r.n) || 0;
          if (String(r.provider).toLowerCase() === 'douban') ratings.douban += n;
          else ratings.tmdb += n;
        }
      } catch {
        try {
          const total = (
            await sql<{ n: number }>`select count(*) as n from media_rating`.execute(k.db)
          ).rows[0];
          ratings.tmdb = Number(total?.n) || 0;
        } catch {
          /* 表不存在 → 保持 0 */
        }
      }
      // 豆瓣评分走自己的缓存表（douban_ratings / douban_chart）
      const doubanStats = await doubanCacheStats(k);
      ratings.douban = Math.max(ratings.douban, doubanStats.ratingRows);
      return {
        images: { tmdb, douban },
        ratings,
        douban: { ...doubanStats, provider: ratingProviderOf(k) },
      };
    },
  );

  // 批量补豆瓣评分：读缓存 → 缺失的按 TMDB 详情（标题/年份）查豆瓣，落 douban_ratings。
  app.post(
    '/api/v1/discover/douban/enrich',
    secured('discover:write', {
      schema: {
        operationId: 'discoverDoubanEnrich',
        tags: TAG,
        summary: '批量补豆瓣评分（带缓存，缺的才联网）',
        body: Type.Object({
          mediaIds: Type.Array(Type.Integer(), { maxItems: 60 }),
          mediaType: Type.Optional(Type.String({ maxLength: 8 })),
        }),
        response: {
          200: Type.Object({
            items: Type.Record(
              Type.String(),
              Type.Object(
                {
                  rating: Type.Union([Type.Number(), Type.Null()]),
                  vote_count: Type.Union([Type.Integer(), Type.Null()]),
                  douban_id: Type.Union([Type.String(), Type.Null()]),
                  url: Type.Union([Type.String(), Type.Null()]),
                },
                { additionalProperties: true },
              ),
            ),
            provider: Type.String(),
          }),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const b = (req.body || {}) as { mediaIds?: number[]; mediaType?: string };
      const media = b.mediaType === 'tv' ? 'tv' : 'movie';
      const res = await enrichDouban(k, config(), media, b.mediaIds || []);
      return { items: res.items, provider: ratingProviderOf(k) };
    },
  );

  // 豆瓣榜单：豆瓣给排名/评分，TMDB 反查补海报与简介。
  // fast=true 只回已落库的条目（首屏秒开），未命中的由客户端再取完整数据。
  app.post(
    '/api/v1/discover/douban/catalogs/:kind',
    secured('discover:read', {
      schema: {
        operationId: 'discoverDoubanCatalogs',
        tags: TAG,
        summary: '豆瓣榜单（按 code 取豆瓣榜，TMDB 反查补卡片）',
        params: Type.Object({ kind: Type.String({ maxLength: 8 }) }),
        body: Type.Object({
          code: Type.String({ maxLength: 32 }),
          count: Type.Optional(Type.Integer({ minimum: 1, maximum: 40 })),
          fast: Type.Optional(Type.Boolean()),
        }),
        response: {
          200: Type.Object({
            items: Type.Array(Type.Ref('DiscoverMediaCard')),
            page: Type.Integer(),
            totalPages: Type.Integer(),
            degraded: Type.Boolean(),
            reason: Type.String(),
            ratingProvider: Type.String(),
            tag: Type.String(),
            cached: Type.Integer(),
          }),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const p = (req.params || {}) as { kind?: string };
      const b = (req.body || {}) as { code?: string; count?: number; fast?: boolean };
      const kind = p.kind === 'tv' ? 'tv' : 'movie';
      const code = String(b.code || 'hot').slice(0, 32);
      const cookie = String(k.config.get('discover.doubanCookie') || '');
      const res = await doubanCatalog(k, config(), {
        kind,
        code,
        count: Number(b.count) || 20,
        fast: b.fast === true,
        cookie: cookie || undefined,
      });
      return {
        items: res.items,
        page: 1,
        totalPages: 1,
        degraded: res.degraded,
        reason: res.reason,
        ratingProvider: 'douban',
        tag: res.tag,
        cached: res.cached,
      };
    },
  );

  // 风格表：TMDB 官方 id + 中文名（静态常量，不联网）。
  app.get(
    '/api/v1/discover/genres/:mediaType',
    secured('discover:read', {
      schema: {
        operationId: 'discoverGenres',
        tags: TAG,
        summary: '风格表（TMDB 官方 id + 中文名）',
        params: Type.Object({ mediaType: Type.String() }),
        response: {
          200: Type.Object({
            mediaType: Type.String(),
            items: Type.Array(Type.Object({ id: Type.Integer(), name: Type.String() })),
          }),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const p = (req.params || {}) as { mediaType?: string };
      const mediaType = p.mediaType === 'tv' ? 'tv' : 'movie';
      return { mediaType, items: mediaType === 'tv' ? TV_GENRES : MOVIE_GENRES };
    },
  );
}
export { DiscoverUnavailable, imageUrl };
