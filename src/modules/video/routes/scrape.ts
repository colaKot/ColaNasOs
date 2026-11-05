import { tmdbGet } from '../../discover/tmdb';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { thumbHandler } from '../../files/thumb';
import { findLocalFanart, findLocalPoster } from '../nfo';
import { isOfflinePath, offlineSmbPrefixes } from '../sources';
import { TAG } from '../util';
import {
  cleanupScrape,
  readScrapeSettings,
  scrapeItem,
  setMatchNfo,
  tmdbConfigOf,
  type ScrapeOutcome,
} from '../scrape';
import { searchTmdb, tmdbReady } from '../tmdb';import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/**
 * 刮削 / TMDB 配置 / 海报出口。
 *
 * 分工：
 *   - `/video/scrape/*`   —— 写库的显式动作（单条 / 批量 / 清理 / 排除）
 *   - `/video/tmdb/*`     —— 只读查询 + 配置，绝不写条目
 *   - `/video/art`        —— 刮削海报的唯一出口（本地文件读流；远端 URL 302）
 *
 * 为什么海报不直接暴露文件路径：库可以是任意本机目录、也可以是 SMB，
 * 客户端拿到绝对路径既没用也不安全。统一走 id + kind，服务端只认库里登记过的图。
 */
export async function registerVideoScrape(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  // ---------------------------------------------------------------- 单条刮削

  app.post(
    '/api/v1/video/scrape/start',
    secured('video:write', {
      schema: {
        operationId: 'videoScrapeStart',
        tags: TAG,
        summary: '刮削单条（番号优先，失败回退 TMDB）',
        body: h.ref('VideoScrapeBody'),
        response: { 200: h.ref('VideoScrapeResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as {
        id?: string;
        mode?: 'auto' | 'force';
        mediaType?: 'movie' | 'tv';
        tmdbId?: number;
        writeSidecar?: boolean;
      };
      if (!body.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
      const out = await scrapeItem(k, body.id, {
        mode: body.mode === 'force' ? 'force' : 'auto',
        mediaType: body.mediaType,
        tmdbId: body.tmdbId,
        writeSidecar: body.writeSidecar,
      });
      return out;
    },
  );

  // ---------------------------------------------------------------- 批量刮削

  app.post(
    '/api/v1/video/scrape/batch',
    secured('video:write', {
      schema: {
        operationId: 'videoScrapeBatch',
        tags: TAG,
        summary: '批量刮削（缺省只刮还没元数据的条目）',
        body: h.ref('VideoScrapeBatchBody'),
        response: { 200: h.ref('VideoScrapeBatchResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        libraryId?: string;
        ids?: string[];
        scope?: 'missing' | 'all';
        mode?: 'auto' | 'force';
        limit?: number;
      };
      const limit = Math.max(1, Math.min(Number(body.limit) || 200, 5000));

      let ids: string[];
      if (Array.isArray(body.ids) && body.ids.length > 0) {
        ids = body.ids.slice(0, limit);
      } else {
        const rows = (
          await sql<{ id: string }>`
            select id from video_items
             where media_type = 'video'
               and coalesce(match_nfo, 1) = 1
               ${body.libraryId ? sql`and library_id = ${body.libraryId}` : sql``}
               ${body.scope === 'all' ? sql`` : sql`and (nfo_name is null or nfo_name = '')`}
             order by mtime desc
             limit ${limit}
          `.execute(k.db)
        ).rows;
        ids = rows.map((r) => r.id);
      }

      const counts = { scraped: 0, skipped: 0, notfound: 0, unavailable: 0 };
      const results: ScrapeOutcome[] = [];
      // 串行：刮削是网络动作，并发打同一站点容易被限流；几百条的量级串行够用
      for (const id of ids) {
        const out = await scrapeItem(k, id, {
          mode: body.mode === 'force' ? 'force' : 'auto',
        });
        results.push(out);
        if (out.status === 'scraped') counts.scraped += 1;
        else if (out.status === 'skipped') counts.skipped += 1;
        else if (out.status === 'notfound') counts.notfound += 1;
        else counts.unavailable += 1;
      }

      return {
        queued: 0,
        scanned: ids.length,
        scraped: counts.scraped,
        skipped: counts.skipped,
        notfound: counts.notfound,
        unavailable: counts.unavailable,
      };
    },
  );

  // ---------------------------------------------------------------- 清理 / 排除

  app.post(
    '/api/v1/video/scrape/cleanup',
    secured('video:write', {
      schema: {
        operationId: 'videoScrapeCleanup',
        tags: TAG,
        summary: '清空一条的刮削结果',
        body: h.ref('VideoScrapeCleanupBody'),
        response: { 200: h.ref('VideoScrapeCleanupResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string };
      if (!body.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
      return cleanupScrape(k, body.id);
    },
  );

  app.post(
    '/api/v1/video/scrape/match',
    secured('video:write', {
      schema: {
        operationId: 'videoScrapeMatch',
        tags: TAG,
        summary: '设置该条目是否参与自动刮削',
        body: h.ref('VideoMatchNfoBody'),
        response: { 200: h.ref('VideoOkResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { id?: string; match?: boolean };
      if (!body.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
      const ok = await setMatchNfo(k, body.id, body.match !== false);
      return { ok };
    },
  );

  // ---------------------------------------------------------------- TMDB 搜索（手动匹配）

  app.post(
    '/api/v1/video/tmdb/search',
    secured('video:read', {
      schema: {
        operationId: 'videoTmdbSearch',
        tags: TAG,
        summary: '手动搜索 TMDB 条目（用于「匹配到别的片子」时纠正）',
        body: h.ref('VideoTmdbSearchBody'),
        response: { 200: h.ref('VideoTmdbSearchResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as { q?: string; mediaType?: 'movie' | 'tv'; year?: number };
      const q = String(body.q || '').trim();
      if (!q) return reply.code(400).send({ error: Err.badRequest, message: 'q required' });
      const cfg = tmdbConfigOf(readScrapeSettings(k));
      if (!tmdbReady(cfg)) return { items: [], configured: false };
      const items = await searchTmdb(
        cfg,
        q,
        body.mediaType === 'tv' ? 'tv' : 'movie',
        Number(body.year) || undefined,
      );
      return { items, configured: true };
    },
  );

  // ---------------------------------------------------------------- TMDB 配置

  app.get(
    '/api/v1/video/tmdb/settings',
    secured('video:read', {
      schema: {
        operationId: 'videoTmdbSettingsGet',
        tags: TAG,
        summary: '刮削设置（Key / 语言 / 是否写 .nfo / 置信度阈值）',
        response: { 200: h.ref('VideoTmdbSettings') },
      },
    }),
    async () => {
      const s = readScrapeSettings(k);
      return {
        // 明文回传：用户要能确认「现在配的是哪个 Key」（自用 NAS，不做多租户隔离）
        apiKey: s.apiKey,
        language: s.language,
        writeSidecar: s.writeSidecar,
        minScore: s.minScore,
        configured: Boolean(s.apiKey),
      };
    },
  );

  app.post(
    '/api/v1/video/tmdb/settings',
    secured('video:write', {
      schema: {
        operationId: 'videoTmdbSettingsSet',
        tags: TAG,
        summary: '写刮削设置（Key 传空字符串表示沿用发现页的 Key）',
        body: h.ref('VideoTmdbSettingsBody'),
        response: { 200: h.ref('VideoTmdbSettings') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        apiKey?: string;
        language?: string;
        writeSidecar?: boolean;
        minScore?: number;
      };
      const current = (k.config.get<Record<string, unknown>>('video.tmdb') || {}) as Record<
        string,
        unknown
      >;
      const next: Record<string, unknown> = { ...current };
      if (body.apiKey !== undefined) next.apiKey = String(body.apiKey).trim();
      if (body.language !== undefined) next.language = String(body.language).trim() || 'zh-CN';
      if (body.writeSidecar !== undefined) next.writeSidecar = body.writeSidecar === true;
      if (body.minScore !== undefined) {
        const n = Number(body.minScore);
        if (Number.isFinite(n) && n >= 0 && n <= 20) next.minScore = n;
      }
      await k.config.set('video.tmdb', next);
      const s = readScrapeSettings(k);
      return {
        apiKey: s.apiKey,
        language: s.language,
        writeSidecar: s.writeSidecar,
        minScore: s.minScore,
        configured: Boolean(s.apiKey),
      };
    },
  );

  // 连通性自检：拿当前配置的 Key 真打一次 TMDB，界面上的「测试」按钮用它。
  // 用 /movie/550 而不是 /configuration —— 后者不需要 Key，无效 Key 也会返回 200。
  app.post(
    '/api/v1/video/tmdb/test',
    secured('video:read', {
      schema: {
        operationId: 'videoTmdbTest',
        tags: TAG,
        summary: '测试 TMDB 连通性（用当前配置的 Key）',
        body: Type.Object({
          apiKey: Type.Optional(Type.String({ maxLength: 200, description: '不传 = 用已保存的 Key' })),
        }),
        response: {
          200: Type.Object({
            ok: Type.Boolean(),
            message: Type.String(),
            latencyMs: Type.Integer(),
          }),
        },
      },
    }),
    async (req) => {
      const body = (req.body || {}) as { apiKey?: string };
      const s = readScrapeSettings(k);
      const apiKey = String(body.apiKey ?? '').trim() || s.apiKey;
      if (!apiKey) {
        return { ok: false, message: '未配置 TMDB API Key', latencyMs: 0 };
      }
      const cfg = tmdbConfigOf({ ...s, apiKey });
      const started = Date.now();
      try {
        const r = await tmdbGet(cfg, '/movie/550');
        const title = r && typeof r === 'object' ? String((r as any).title || '') : '';
        return {
          ok: true,
          message: title ? `连接成功：${title}` : '连接成功',
          latencyMs: Date.now() - started,
        };
      } catch (err) {
        const msg = String((err as Error)?.message || err);
        const unauthorized = /401|unauthorized|api key/i.test(msg);
        return {
          ok: false,
          message: unauthorized ? 'Key 无效或被拒绝（401）' : `连接失败：${msg}`,
          latencyMs: Date.now() - started,
        };
      }
    },
  );

  // ---------------------------------------------------------------- 海报 / 剧照出口

  app.get(
    '/api/v1/video/art',
    secured('video:read', {
      schema: {
        operationId: 'videoArt',
        tags: TAG,
        summary: '刮削海报 / 剧照（本地文件读流，远端 URL 302 跳转）',
        querystring: h.ref('VideoArtQuery'),
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { id?: string; kind?: string };
      if (!q.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
      const row = (
        await sql<{
          nfo_poster: string | null;
          nfo_fanart: string | null;
          nfo_thumb: string | null;
          mtime: number;
          rel_path: string;
        }>`
          select nfo_poster, nfo_fanart, nfo_thumb, mtime, rel_path from video_items where id = ${q.id}
        `.execute(k.db)
      ).rows[0];
      if (!row) {
        // 图片库 / 混合库：图片封面直接输出原图
        const img = (
          await sql<{ rel_path: string; mime: string }>`
            select rel_path, mime from image_items where id = ${q.id}
          `.execute(k.db)
        ).rows[0];
        if (!img) return reply.code(404).send({ error: Err.notFound, message: 'item not found' });
        if (isOfflinePath(img.rel_path, await offlineSmbPrefixes(k.db))) {
          return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
        }
        try {
          const abs = resolveAnyPath(filesRoot(), img.rel_path);
          reply.type(img.mime || 'application/octet-stream');
          reply.header('cache-control', 'private, max-age=86400');
          return reply.send(fs.createReadStream(abs));
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
      }

      // SMB 已离线：不要再走读盘 / 现场找图，直接 404，让前端显示占位图而不是卡住
      if (isOfflinePath(row.rel_path, await offlineSmbPrefixes(k.db))) {
        return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
      }

      const kind = String(q.kind || 'poster');
      const raw =
        kind === 'fanart'
          ? row.nfo_fanart || row.nfo_poster || row.nfo_thumb
          : row.nfo_poster || row.nfo_thumb || row.nfo_fanart;
      let target = String(raw ?? '').trim();

      // 兜底：库里没登记图（老库没重扫 / 用户刚补了图还没扫）时，现场按文件名再找一次。
      // 只认 `-poster/-post/-cover/-folder` 与 `-fanart/-backdrop/-landscape` 这些约定名，
      // 找不到就正常 404 —— 这条路径只在「本来就 404」时跑，不增加正常请求的开销。
      if (!target) {
        try {
          const abs = resolveAnyPath(filesRoot(), row.rel_path);
          const hit =
            kind === 'fanart' ? await findLocalFanart(abs) : await findLocalPoster(abs);
          if (hit) target = hit;
        } catch {
          /* 路径越界 / 离线：维持 404 */
        }
      }
      if (!target) return reply.code(404).send({ error: Err.notFound, message: 'no art' });

      // 远端图：直接 302（不代理，避免把三方流量算进来）
      if (/^https?:\/\//i.test(target)) return reply.redirect(target, 302);

      let stat: fs.Stats;
      try {
        stat = fs.statSync(target);
        if (!stat.isFile() || stat.size === 0) throw new Error('empty');
      } catch {
        // 登记过图但文件没了（用户清理了 data 目录 / 换了机器）：
        // 回退到服务端抽帧，别让客户端显示裂图
        return reply.redirect(`/api/v1/video/poster?id=${encodeURIComponent(q.id)}`, 302);
      }

      const etag = `"${crypto.createHash('sha1').update(`${target}:${stat.mtimeMs}:${stat.size}`).digest('hex').slice(0, 20)}"`;
      // 列表页只要小图：原图（1000×1500 的海报常有 1~2 MB）直传时，
      // SMB 库一屏几十张就是几十 MB 的网络盘读盘，这就是「打开库很慢」的主因。
      // 交给缩略图出口后，第一次生成、之后全部命中 dataDir/thumbs 本地缓存。
      const wantSize = Number((req.query as { size?: unknown }).size) || 0;
      if (wantSize > 0) {
        return thumbHandler(req, reply, { path: target, size: wantSize }, k);
      }
      if (String(req.headers['if-none-match'] || '') === etag) return reply.code(304).send();
      const ext = path.extname(target).toLowerCase();
      const type =
        ext === '.png' ? 'image/png' : ext === '.webp' ? 'image/webp' : 'image/jpeg';
      reply.header('etag', etag);
      reply.header('content-type', type);
      reply.header('cache-control', 'private, max-age=86400');
      return reply.send(fs.createReadStream(target));
    },
  );
}
