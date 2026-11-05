import { subtitleConf } from './routes/settings';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { jpMetaOf } from './media-type';
import { actorKey, actorProfileOrPlaceholder } from './jp-actor';
import {
  parseActorNames,
  pruneOrphanActors,
  rebuildActorLinks,
  syncActorLinks,
} from './jp-links';
import { toItem, type MediaRow } from './util';
import { offlineCond, offlineSmbPrefixes } from './sources';
import { clearRankSnapshots, fetchJpRank, type JpRankKind, type JpRankPeriod } from './jp-rank';
import { fetchSubtitle, SUB_STATE, writeSubtitleBeside } from './subtitle-fetch';
import { fetchNormalSubtitle, findSubtitleBeside } from './subtitle-normal';
import { Err } from '../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * 日本片：演员档案 / 榜单 / 自动字幕 的路由集合。
 *
 * 与 `video/index.ts` 解耦（那边已经很长）；这里自己查库，不依赖外部闭包。
 * 所有外部站点请求都「失败返回空 + 明确状态」，不阻断列表与扫描。
 */
const TAG = ['video'];

const ErrorResponse = Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) });

const OkResponse = Type.Object({ ok: Type.Boolean() });

const AutoSubtitleBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  enabled: Type.Boolean(),
});

const IdBody = Type.Object({ id: Type.String({ minLength: 1 }) });

const SubtitleFetchResponse = Type.Object(
  {
    state: Type.Integer(),
    reason: Type.String(),
    path: Type.Union([Type.String(), Type.Null()]),
    limitReached: Type.Optional(Type.Boolean()),
  },
  { additionalProperties: true },
);

const ActorNameBody = Type.Object({ name: Type.String({ minLength: 1, maxLength: 64 }) });

const ActorProfileResponse = Type.Object(
  {
    key: Type.String(),
    name: Type.String(),
    avatarUrl: Type.Union([Type.String(), Type.Null()]),
    birthday: Type.Union([Type.String(), Type.Null()]),
    heightCm: Type.Union([Type.Integer(), Type.Null()]),
    bust: Type.Union([Type.Integer(), Type.Null()]),
    waist: Type.Union([Type.Integer(), Type.Null()]),
    hips: Type.Union([Type.Integer(), Type.Null()]),
    birthplace: Type.Union([Type.String(), Type.Null()]),
    source: Type.Array(Type.String()),
  },
  { additionalProperties: true },
);

const ActorListQuery = Type.Object({
  libraryId: Type.Optional(Type.String()),
  limit: Type.Optional(Type.String()),
});

const ActorListItem = Type.Object(
  {
    key: Type.String(),
    name: Type.String(),
    items: Type.Integer({ description: '影片数（= count，保留旧字段名）' }),
    favorite: Type.Boolean(),
    avatarUrl: Type.Union([Type.String(), Type.Null()]),
    sampleCover: Type.Union([Type.String(), Type.Null()]),
    /** 影片数（与 items 同值，新字段名） */
    count: Type.Optional(Type.Integer()),
    unwatchedCount: Type.Optional(Type.Integer({ description: '当前用户未看数' })),
    /** JavDB 评价人数最大值（热度） */
    hot: Type.Optional(Type.Integer()),
    hotTotal: Type.Optional(Type.Integer()),
    scoreAvg: Type.Optional(Type.Number()),
    ratedCount: Type.Optional(Type.Integer()),
    latestCreateTime: Type.Optional(Type.Integer({ description: '最新一部入库时间（秒）' })),
    /** 网格封面片：她「最热的未看片」，全看过退化为全部里最热的一部 */
    coverItem: Type.Optional(Type.Union([Type.Ref('VideoItem'), Type.Null()])),
    heightCm: Type.Optional(Type.Integer()),
    weightKg: Type.Optional(Type.Integer()),
    bust: Type.Optional(Type.Integer()),
    waist: Type.Optional(Type.Integer()),
    hip: Type.Optional(Type.Integer()),
    cup: Type.Optional(Type.String()),
    birthday: Type.Optional(Type.String()),
  },
  { additionalProperties: true },
);

const ActorListResponse = Type.Object({ items: Type.Array(ActorListItem) });

const ActorWorksQuery = Type.Object({
  key: Type.Optional(Type.String({ description: '演员身份键（actorKey）' })),
  name: Type.Optional(Type.String({ description: '演员名；没有 key 时用它算 key' })),
  limit: Type.Optional(Type.String()),
});

const ActorWorksResponse = Type.Object(
  {
    items: Type.Array(Type.Ref('VideoItem')),
    total: Type.Integer({ description: '本次返回的条数（不是全库总数）' }),
  },
  { additionalProperties: true },
);

const RankBody = Type.Object({
  period: Type.Optional(
    Type.Union([Type.Literal('daily'), Type.Literal('weekly'), Type.Literal('monthly')], {
      default: 'daily',
    }),
  ),
});

const RankResponse = Type.Object(
  {
    kind: Type.String(),
    period: Type.String(),
    /** true = 站点抓取失败，本次用的是落库快照（内容可能偏旧） */
    stale: Type.Optional(Type.Boolean()),
    /** 快照抓取时间（Unix 秒）；0 = 既没抓到也没快照 */
    snapshotAt: Type.Optional(Type.Integer()),
    items: Type.Array(
      Type.Object(
        {
          rank: Type.Integer(),
          code: Type.Union([Type.String(), Type.Null()]),
          title: Type.String(),
          coverUrl: Type.Union([Type.String(), Type.Null()]),
          url: Type.Union([Type.String(), Type.Null()]),
          inLibrary: Type.Boolean(),
        },
        { additionalProperties: true },
      ),
    ),
  },
  { additionalProperties: true },
);

const VIDEO_ROOT = () => filesRoot();
const now = () => Math.floor(Date.now() / 1000);

export async function registerJpRoutes(app: any, k: KernelApi): Promise<void> {
  const uidOf = (req: FastifyRequest) => String(req.user?.sub || '');

  // ---------------------------------------------------------------- 自动字幕开关
  app.post(
    '/api/v1/video/library/auto_subtitle',
    secured('video:write', {
      schema: {
        operationId: 'videoAutoSubtitle',
        tags: TAG,
        summary: '开关日本片自动字幕（打开时异步补一轮，不等下次扫描）',
        body: AutoSubtitleBody,
        response: { 200: OkResponse, 404: ErrorResponse },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { id?: string; enabled?: boolean };
      const lib = (
        await sql<{
          id: string;
        }>`select id from video_libraries where id = ${body.id ?? ''}`.execute(k.db)
      ).rows[0];
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
      await sql`
        update video_libraries set auto_subtitle = ${body.enabled ? 1 : 0} where id = ${lib.id}
      `.execute(k.db);
      if (body.enabled) {
        void k.tasks
          .enqueueIfIdle('video.subtitle.fetch', { libraryId: lib.id }, { maxAttempts: 2 })
          .catch((err) => k.log.warn({ err: String(err) }, 'enqueue subtitle task failed'));
      }
      return { ok: true };
    },
  );

  // 单条手动抓字幕
  app.post(
    '/api/v1/video/subtitle/fetch',
    secured('video:write', {
      schema: {
        operationId: 'videoSubtitleFetch',
        tags: TAG,
        summary: '手动抓取一条日本片的字幕（avsubtitles 五步链路）',
        body: IdBody,
        response: { 200: SubtitleFetchResponse, 404: ErrorResponse },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { id?: string };
      const item = (
        await sql<{ id: string; rel_path: string; code: string | null }>`
          select id, rel_path, code from video_items where id = ${body.id ?? ''}
        `.execute(k.db)
      ).rows[0];
      if (!item) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });

      const code = item.code || jpMetaOf(item.rel_path).code;
      if (!code) {
        await markSubState(k, item.id, SUB_STATE.NO_CODE);
        return { state: SUB_STATE.NO_CODE, reason: 'no_code', path: null };
      }

      let abs: string;
      try {
        abs = resolveAnyPath(VIDEO_ROOT(), item.rel_path);
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'file missing' });
      }

      const result = await fetchSubtitle(code, { waitMs: 0 });
      if (result.state === SUB_STATE.OK && result.text) {
        const written = writeSubtitleBeside(abs, result.text, '.srt');
        await markSubState(k, item.id, SUB_STATE.OK);
        return { state: SUB_STATE.OK, reason: 'ok', path: written };
      }
      await markSubState(k, item.id, result.state);
      return {
        state: result.state,
        reason: result.reason,
        path: null,
        limitReached: result.limitReached === true,
      };
    },
  );

  // ---------------------------------------------------------------- 演员
  app.post(
    '/api/v1/video/jp_actor/profile',
    secured('video:read', {
      schema: {
        operationId: 'videoJpActorProfile',
        tags: TAG,
        summary: '演员档案（JavDB 确认身份 + 日文维基补三围；失败返回空档案）',
        body: ActorNameBody,
        response: { 200: ActorProfileResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { name?: string };
      const profile = await actorProfileOrPlaceholder(String(body.name || ''), {
        dataDir: k.paths.dataDir,
      });
      // 顺手把档案写回 jp_actors（有就更新，没有就建）
      const key = actorKey(profile.name);
      await sql`
        insert into jp_actors (id, name, thumb_path, profile, updated_at)
        values (${key}, ${profile.name}, ${profile.avatarUrl}, ${JSON.stringify(profile)}, ${now()})
        on conflict(id) do update set
          name = excluded.name, thumb_path = excluded.thumb_path,
          profile = excluded.profile, updated_at = excluded.updated_at
      `.execute(k.db);
      return {
        key: profile.key,
        name: profile.name,
        avatarUrl: profile.avatarUrl,
        birthday: profile.birthday,
        heightCm: profile.heightCm,
        bust: profile.bust,
        waist: profile.waist,
        hips: profile.hips,
        birthplace: profile.birthplace,
        source: profile.source,
      };
    },
  );

  app.get(
    '/api/v1/video/jp_actor/list',
    secured('video:read', {
      schema: {
        operationId: 'videoJpActorList',
        tags: TAG,
        summary: '演员列表（影片数 / 未看数 / 热度 / 封面片 / 收藏 / 档案）',
        querystring: ActorListQuery,
        response: { 200: ActorListResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { libraryId?: string; limit?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 500, 2000));
      const owner = uidOf(req);

      // ① 轻量投影：一条「演员 × 作品」的关系行。判重 / 收藏 / 排序都在内存里做，
      //    一次捞完再聚合（注意 limit 20000 的上限）。
      const rows = (
        await sql<{
          actor_id: string;
          name: string;
          thumb_path: string | null;
          profile: string | null;
          item_id: string;
          created_at: number | null;
          jp_hot_votes: number | null;
          jp_hot_score: number | null;
          watched: number | null;
        }>`
          select a.id as actor_id, a.name, a.thumb_path, a.profile,
                 i.id as item_id, i.created_at,
                 coalesce(i.jp_hot_votes, 0) as jp_hot_votes,
                 coalesce(i.jp_hot_score, 0) as jp_hot_score,
                 exists(select 1 from video_watch w
                         where w.item_id = i.id and w.owner_id = ${owner}) as watched
            from jp_actors a
            join jp_actor_items ai on ai.actor_id = a.id
            join video_items i on i.id = ai.item_id
           where i.media_type = 'video'
             ${q.libraryId ? sql`and i.library_id = ${q.libraryId}` : sql``}
           limit 60000
        `.execute(k.db)
      ).rows;

      const favs = new Set(
        (
          await sql<{ actor_key: string }>`
            select actor_key from video_actor_favorite where uid = ${owner}
          `.execute(k.db)
        ).rows.map((r) => r.actor_key),
      );

      interface Agg {
        key: string;
        name: string;
        thumb: string;
        profile: string | null;
        count: number;
        unwatched: number;
        hot: number;
        hotTotal: number;
        scoreSum: number;
        rated: number;
        latest: number;
        /** 未看池（没未看时 = 全部）里「热度高 → 新」的第一部，作网格封面 */
        coverId: string | null;
        coverHot: number;
        coverAt: number;
      }
      const map = new Map<string, Agg>();
      for (const r of rows) {
        let g = map.get(r.actor_id);
        if (!g) {
          g = {
            key: r.actor_id,
            name: r.name,
            thumb: String(r.thumb_path || ''),
            profile: r.profile ?? null,
            count: 0,
            unwatched: 0,
            hot: 0,
            hotTotal: 0,
            scoreSum: 0,
            rated: 0,
            latest: 0,
            coverId: null,
            coverHot: -1,
            coverAt: -1,
          };
          map.set(r.actor_id, g);
        }
        const votes = Number(r.jp_hot_votes) || 0;
        const score = Number(r.jp_hot_score) || 0;
        const at = Number(r.created_at) || 0;
        g.count += 1;
        if (!Number(r.watched)) g.unwatched += 1;
        if (votes > g.hot) g.hot = votes;
        g.hotTotal += votes;
        if (votes > 0) {
          g.scoreSum += score;
          g.rated += 1;
        }
        if (at > g.latest) g.latest = at;
        // 封面只在「未看」里挑：全看过的人退化成全部（此时没有更好的选择）
        const eligible = !Number(r.watched);
        if (eligible || g.unwatched === 0) {
          if (votes > g.coverHot || (votes === g.coverHot && at > g.coverAt)) {
            g.coverId = r.item_id;
            g.coverHot = votes;
            g.coverAt = at;
          }
        }
      }

      // ② 封面片补全：网格要的是「影片列表同构的一行」，前端才能直接按
      //    海报 / 剧照两套 URL 取值（封面图 ⇄ 缩略图切换天然支持）。
      const coverIds = [...map.values()].map((g) => g.coverId).filter(Boolean) as string[];
      const offline = await offlineSmbPrefixes(k.db);
      const covers = new Map<string, ReturnType<typeof toItem>>();
      if (coverIds.length > 0) {
        const full = (
          await sql<MediaRow>`
            select v.*, cast(v.mtime / 1000 as integer) as taken_at,
                   exists(select 1 from video_watch w
                           where w.item_id = v.id and w.owner_id = ${owner}) as watched,
                   exists(select 1 from video_favorites f
                           where f.item_id = v.id and f.owner_id = ${owner}
                             and f.media_type = 'video') as favorite
              from video_items v
             where v.id in (${sql.join(coverIds.map((id) => sql`${id}`), sql`, `)})
               ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
          `.execute(k.db)
        ).rows;
        for (const row of full) covers.set(row.id, toItem(row));
      }

      const items = [...map.values()].map((g) => {
        let profile: Record<string, unknown> = {};
        if (g.profile) {
          try {
            profile = JSON.parse(g.profile) as Record<string, unknown>;
          } catch {
            profile = {};
          }
        }
        const num = (v: unknown) => {
          const n = Number(v);
          return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
        };
        return {
          key: g.key,
          name: g.name,
          // 兼容旧字段名（历史 UI 读 items / favorite / sampleCover）
          items: g.count,
          favorite: favs.has(g.key),
          avatarUrl: g.thumb || String(profile.avatarUrl ?? '') || null,
          sampleCover: null,
          // —— 排序与卡片用的聚合值
          count: g.count,
          unwatchedCount: g.unwatched,
          hot: g.hot,
          hotTotal: g.hotTotal,
          scoreAvg: g.rated > 0 ? Math.round((g.scoreSum / g.rated) * 100) / 100 : 0,
          ratedCount: g.rated,
          latestCreateTime: g.latest,
          coverItem: g.coverId ? (covers.get(g.coverId) ?? null) : null,
          // —— 档案（抓不到就是 0 / 空串，前端整项不渲染）
          heightCm: num(profile.heightCm),
          weightKg: num(profile.weightKg),
          bust: num(profile.bust),
          waist: num(profile.waist),
          hip: num(profile.hip ?? profile.hips),
          cup: String(profile.cup ?? ''),
          birthday: String(profile.birthday ?? ''),
          birthplace: String(profile.birthplace ?? ''),
        };
      });

      // ③ 排序（2026-10-24 口径，逐级降级）：
      //    ① 已收藏 ② 有未看 ③ 未看多的 ④ 最新入库 ⑤ 热度 ⑥ 名字
      items.sort((a, b) => {
        let c = Number(b.favorite) - Number(a.favorite);
        if (c !== 0) return c;
        c = Number(b.unwatchedCount > 0) - Number(a.unwatchedCount > 0);
        if (c !== 0) return c;
        c = b.unwatchedCount - a.unwatchedCount;
        if (c !== 0) return c;
        c = b.latestCreateTime - a.latestCreateTime;
        if (c !== 0) return c;
        c = b.hot - a.hot;
        if (c !== 0) return c;
        return a.name.localeCompare(b.name, 'zh');
      });

      return { items: items.slice(0, limit), total: items.length };
    },
  );

  app.post(
    '/api/v1/video/jp_actor/favorite',
    secured('video:write', {
      schema: {
        operationId: 'videoJpActorFavorite',
        tags: TAG,
        summary: '收藏 / 取消收藏演员',
        body: Type.Object({ name: Type.String({ minLength: 1 }), favorite: Type.Boolean() }),
        response: { 200: OkResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { name?: string; favorite?: boolean };
      const key = actorKey(String(body.name || ''));
      if (body.favorite) {
        await sql`
          insert into video_actor_favorite (uid, actor_key, actor_name, created_at)
          values (${uidOf(req)}, ${key}, ${String(body.name || '')}, ${now()})
          on conflict(uid, actor_key) do nothing
        `.execute(k.db);
      } else {
        await sql`
          delete from video_actor_favorite where uid = ${uidOf(req)} and actor_key = ${key}
        `.execute(k.db);
      }
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/video/jp_actor/favorites',
    secured('video:read', {
      schema: {
        operationId: 'videoJpActorFavorites',
        tags: TAG,
        summary: '我的演员收藏',
        response: {
          200: Type.Object({
            items: Type.Array(
              Type.Object(
                { key: Type.String(), name: Type.String() },
                { additionalProperties: true },
              ),
            ),
          }),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const rows = (
        await sql<{ actor_key: string; actor_name: string }>`
          select actor_key, actor_name from video_actor_favorite
           where uid = ${uidOf(req)} order by created_at desc limit 500
        `.execute(k.db)
      ).rows;
      return { items: rows.map((r) => ({ key: r.actor_key, name: r.actor_name })) };
    },
  );

  // ---------------------------------------------------------------- 演员作品
  app.get(
    '/api/v1/video/jp_actor/works',
    secured('video:read', {
      schema: {
        operationId: 'videoJpActorWorks',
        tags: TAG,
        summary: '某演员在库的作品（未看优先，再按入库时间倒序）',
        querystring: ActorWorksQuery,
        response: { 200: ActorWorksResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { key?: string; name?: string; limit?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 120, 500));
      const owner = uidOf(req);
      const key = String(q.key || '').trim() || actorKey(String(q.name || ''));
      const name = String(q.name || '').trim();
      const offline = await offlineSmbPrefixes(k.db);

      const selectItems = async (where: any) =>
        (
          await sql<MediaRow>`
            select v.*, cast(v.mtime / 1000 as integer) as taken_at,
                   exists(select 1 from video_watch w
                           where w.item_id = v.id and w.owner_id = ${owner}) as watched,
                   exists(select 1 from video_favorites f
                           where f.item_id = v.id and f.owner_id = ${owner}
                             and f.media_type = 'video') as favorite
              from video_items v
             where v.media_type = 'video' and ${where}
               ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
             -- 综合排序（收藏 → 未看 → 热度 → 评分 → 年份 → 入库 → id）
             -- ⚠️ 热度/评分必须在年份前面：用户要的是「同一女优内部按热度口碑排」，
             --    年份只作为热度口碑都相同时的兜底。
             order by
               case when exists (
                 select 1 from video_favorites f2
                  where f2.item_id = v.id and f2.owner_id = ${owner}
                    and f2.media_type = 'video'
               ) then 0 else 1 end,
               case when exists (
                 select 1 from video_watch w2
                  where w2.item_id = v.id and w2.owner_id = ${owner}
               ) then 1 else 0 end,
               coalesce(v.jp_hot_votes, 0) desc,
               coalesce(v.jp_hot_score, 0) desc,
               coalesce(v.nfo_year, 0) desc,
               v.created_at desc,
               v.id desc
             limit ${limit}
          `.execute(k.db)
        ).rows;

      // 优先走关联表；关联表可能是老库（还没重建过），此时退回 nfo_actors 模糊匹配
      let rows: MediaRow[] = [];
      if (key) {
        rows = await selectItems(
          sql`v.id in (select item_id from jp_actor_items where actor_id = ${key})`,
        );
      }
      if (rows.length === 0 && name) {
        rows = await selectItems(sql`v.nfo_actors like ${'%' + name + '%'}`);
      }
      return { items: rows.map(toItem), total: rows.length };
    },
  );

  // 老库补齐：从 nfo_actors 全量派生演员关联（纯本地，不联网）
  app.post(
    '/api/v1/video/jp_actor/rebuild',
    secured('video:write', {
      schema: {
        operationId: 'videoJpActorRebuild',
        tags: TAG,
        summary: '从 nfo_actors 重建演员作品关联（老库补齐用）',
        body: Type.Object(
          {
            libraryId: Type.Optional(Type.String()),
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200000 })),
          },
          { additionalProperties: true },
        ),
        response: {
          200: Type.Object(
            {
              items: Type.Integer(),
              actors: Type.Integer(),
              links: Type.Integer(),
              pruned: Type.Integer(),
            },
            { additionalProperties: true },
          ),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { libraryId?: string; limit?: number };
      const result = await rebuildActorLinks(k.db, {
        libraryId: body.libraryId,
        limit: body.limit,
      });
      const pruned = await pruneOrphanActors(k.db);
      // 顺带入队「从 NFO 补演员头像」：重建只补关联，头像在 NFO 的 <actor><thumb> 里，
      // 老库不重读 NFO 永远是空的。任务里没缺口时秒退，重复点也不会有额外开销。
      void k.tasks
        .enqueueIfIdle('video.actor.thumbs', { libraryId: body.libraryId }, { maxAttempts: 1 })
        .catch(() => null);
      // 档案（身高 / 生日 / 出身地）要联网抓维基，慢；排在头像后面由队列串行跑
      void k.tasks
        .enqueueIfIdle('video.actor.profile', {}, { maxAttempts: 1 })
        .catch(() => null);
      return { ...result, pruned };
    },
  );

  // ---------------------------------------------------------------- 榜单
  const rankHandler = (kind: JpRankKind) => async (req: FastifyRequest) => {
    const body = (req.body || {}) as { period?: JpRankPeriod };
    const period: JpRankPeriod =
      body.period === 'weekly' || body.period === 'monthly' ? body.period : 'daily';
    const res = await fetchJpRank(kind, period, { db: k.db });
    const items = res.items;
    const codes = items.map((x) => x.code).filter(Boolean) as string[];
    const inLib = new Set(
      codes.length === 0
        ? []
        : (
            await sql<{ code: string }>`
                select distinct code from video_items
                 where code in (${sql.join(
                   codes.map((c) => sql`${c}`),
                   sql`, `,
                 )})
              `.execute(k.db)
          ).rows.map((r) => String(r.code)),
    );
    return {
      kind,
      period,
      stale: res.stale,
      snapshotAt: res.snapshotAt,
      items: items.map((x) => ({ ...x, inLibrary: x.code ? inLib.has(x.code) : false })),
    };
  };

  app.post(
    '/api/v1/video/jp_rank/movie',
    secured('video:read', {
      schema: {
        operationId: 'videoJpRankMovie',
        tags: TAG,
        summary: '日本片榜单（日/周/月），标出已在库',
        body: RankBody,
        response: { 200: RankResponse },
      },
    }),
    rankHandler('movie'),
  );

  app.post(
    '/api/v1/video/jp_rank/actor',
    secured('video:read', {
      schema: {
        operationId: 'videoJpRankActor',
        tags: TAG,
        summary: '日本演员榜单（日/周/月）',
        body: RankBody,
        response: { 200: RankResponse },
      },
    }),
    rankHandler('actor'),
  );

  // 清空榜单缓存（内存 + 落库快照）。站点改版后想立刻重抓，不必等新鲜期
  app.post(
    '/api/v1/video/jp_rank/clear',
    secured('video:write', {
      schema: {
        operationId: 'videoJpRankClear',
        tags: TAG,
        summary: '清空日系榜单缓存（内存 + 快照）',
        response: { 200: Type.Object({ cleared: Type.Integer() }) },
      },
    }),
    async () => ({ cleared: await clearRankSnapshots(k.db) }),
  );
}

async function markSubState(k: KernelApi, itemId: string, state: number): Promise<void> {
  await sql`
    update video_items set sub_fetch_state = ${state}, sub_fetch_at = ${now()} where id = ${itemId}
  `.execute(k.db);
}

/**
 * 自动补字幕（日本片 + 普通影视）。
 *
 * 分派规则：
 *   * 日本电影库：先按番号走 avsubtitles；提不出番号 / 站内无中字时，
 *     退回普通多源（迅雷 / Assrt / OpenSubtitles）；
 *   * 其它库：直接走普通多源。
 *
 * 状态 3/4/5（站内无 / 无中文 / 失败）默认 7 天后重回候选，
 * 因为站点后来补了字幕也能被发现；状态 2（文件名提不出片号）不重试。
 * 命中 avsubtitles 每日上限立刻中止整轮，不做重试风暴。
 */
export async function fetchSubtitlesForLibrary(
  k: KernelApi,
  libraryId: string,
  onProgress?: (pct: number, done?: number, total?: number) => void,
): Promise<number> {
  const lib = (
    await sql<{ id: string; auto_subtitle: number; lib_type: string | null; jp_movie: number }>`
      select id, auto_subtitle, lib_type, jp_movie from video_libraries where id = ${libraryId}
    `.execute(k.db)
  ).rows[0];
  if (!lib || !Number(lib.auto_subtitle)) return 0;

  const isJp =
    String(lib.lib_type || '').trim().toLowerCase() === 'jp_movie' || Number(lib.jp_movie) === 1;
  const rawRetry = Number(k.config.get('video.subtitleRetryDays'));
  const retryDays = Number.isFinite(rawRetry) ? Math.max(0, Math.min(rawRetry, 365)) : 7;
  const cutoff = retryDays > 0 ? now() - retryDays * 24 * 60 * 60 : 0;
  // 普通影视一部要 2~4 次外网请求，一轮只处理 12 条，别把扫描收尾拖成十几分钟
  const limit = isJp ? 30 : 12;
  // 离线来源上的文件连读都读不到，别去下字幕（会一路超时/失败）
  const offline = await offlineSmbPrefixes(k.db);

  const items = (
    await sql<{
      id: string;
      rel_path: string;
      code: string | null;
      nfo_name: string | null;
      nfo_year: number | null;
      nfo_imdb_id: string | null;
    }>`
      select id, rel_path, code, nfo_name, nfo_year, nfo_imdb_id
        from video_items
       where library_id = ${libraryId} and media_type = 'video'
         ${offline.length > 0 ? sql`and ${offlineCond(offline, 'rel_path')}` : sql``}
         and (
           sub_fetch_state = ${SUB_STATE.PENDING}
           ${
             cutoff > 0
               ? sql`or (
                   sub_fetch_state in (${SUB_STATE.NOT_FOUND}, ${SUB_STATE.NO_CHINESE}, ${SUB_STATE.FAILED})
                   and coalesce(sub_fetch_at, 0) <= ${cutoff}
                 )`
               : sql``
           }
         )
       order by created_at asc limit ${limit}
    `.execute(k.db)
  ).rows;

  // 字幕源凭据来自「影视设置 → 字幕」（k.config 的 video.subtitle 对象）；
  // 环境变量作为回退，方便容器部署时不进界面也能配。
  const subCfg = subtitleConf(k);
  const normalOpts = {
    assrtToken: (subCfg.assrtToken || String(process.env.COLANAS_ASSRT_TOKEN || '')).trim(),
    openSubtitlesKey: (
      subCfg.openSubtitlesKey || String(process.env.COLANAS_OPENSUBTITLES_KEY || '')
    ).trim(),
    xunlei: subCfg.xunlei,
  };

  let done = 0;
  for (let i = 0; i < items.length; i += 1) {
    // 条数一起报：一轮只处理 12~30 条，光看百分号会误以为没动
    onProgress?.(Math.round((i / items.length) * 100), i, items.length);
    const item = items[i];
    // 已有同名字幕就跳过（不覆盖用户自己放的字幕）
    let abs: string;
    try {
      // 影视库来源可以是任意本机盘 / UNC，必须走 resolveAnyPath；
      // 只用 resolveInRoot(filesRoot) 会把绝对路径全部判成越界，任务秒退、一条都不处理
      abs = resolveAnyPath(VIDEO_ROOT(), item.rel_path);
    } catch {
      continue;
    }
    if (findSubtitleBeside(abs)) {
      await markSubState(k, item.id, SUB_STATE.OK);
      continue;
    }

    // ① 日本片：先按番号找中文站字幕
    if (isJp) {
      const code = item.code || jpMetaOf(item.rel_path).code;
      if (code) {
        const result = await fetchSubtitle(code, { waitMs: 0 });
        if (result.limitReached) {
          k.log.warn('avsubtitles daily limit reached, stop this round');
          break;
        }
        if (result.state === SUB_STATE.OK && result.text) {
          writeSubtitleBeside(abs, result.text, '.srt');
          await markSubState(k, item.id, SUB_STATE.OK);
          done += 1;
          continue;
        }
        // 提不出番号 / 站点没有中字：继续走普通多源兜底
      }
    }

    // ② 普通多源（迅雷免配置；Assrt / OpenSubtitles 配了才用）
    const normal = await fetchNormalSubtitle(
      abs,
      {
        filename: path.basename(abs),
        nfoName: item.nfo_name,
        year: item.nfo_year,
        imdbId: item.nfo_imdb_id,
      },
      normalOpts,
    );
    await markSubState(k, item.id, normal.state);
    if (normal.state === SUB_STATE.OK) done += 1;
  }
  return done;
}
