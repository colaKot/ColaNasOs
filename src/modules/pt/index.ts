import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { isSealed, openSecret, sealSecret } from '../../../kernel/secret-box';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';
import {
  buildKeywordVariants,
  selectBest,
  type PtCandidate,
  type PtMedia,
  type PtRule,
} from './selection';
import { resolutionOf, searchSite } from './search';
import { searchMTeam } from './mteam';
import { addTorrent, torrentAction, transmissionStatus, type TransmissionConfig } from './transmission';
import { filesRoot, resolveAnyPath } from '../files/fs-root';

/**
 * PT 自动下载：站点 → 搜索 → 筛选 → 择种 → 交给 transmission → 留痕。
 *
 * 约束：
 * - 站点 cookie 密文落库（AES-256-GCM），不返回明文；
 * - 站点**串行**搜索（并发会把 NexusPHP 站点打成 403/空结果，实测并发 3 即失败）；
 * - 订阅每小时跑一次（进程内定时器，unref），也可手动触发；
 * - 「已拥有」判定由调用方用 TMDB/番号精确匹配，不靠标题相似。
 */
const TAG = ['pt'];
const COOKIE_SALT = 'colanas-pt-cookie-v1';
const now = () => Math.floor(Date.now() / 1000);

const ErrorResponse = Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) });
const OkResponse = Type.Object({ ok: Type.Boolean() });

const DOWNLOAD_KEY = 'pt.download';
const DownloadSettings = Type.Object(
  {
    movieLibraryId: Type.String({ maxLength: 64 }),
    tvLibraryId: Type.String({ maxLength: 64 }),
    siteIds: Type.Array(Type.String({ maxLength: 64 }), { maxItems: 100 }),
    quality: Type.String({ maxLength: 16 }),
    hdr: Type.String({ maxLength: 16 }),
    audioLangs: Type.Array(Type.String({ maxLength: 16 }), { maxItems: 20 }),
    maxSizeBytes: Type.Integer({ minimum: 0 }),
    minSeeders: Type.Integer({ minimum: 0, maximum: 1000 }),
    excludedKeywords: Type.Array(Type.String({ maxLength: 64 }), { maxItems: 100 }),
    scanIntervalMin: Type.Integer({ minimum: 5, maximum: 360 }),
    autoDownload: Type.Boolean(),
  },
  { $id: 'PtDownloadSettings' },
);
const DownloadSettingsBody = Type.Object(
  {
    movieLibraryId: Type.Optional(Type.String({ maxLength: 64 })),
    tvLibraryId: Type.Optional(Type.String({ maxLength: 64 })),
    siteIds: Type.Optional(Type.Array(Type.String({ maxLength: 64 }), { maxItems: 100 })),
    quality: Type.Optional(Type.String({ maxLength: 16 })),
    hdr: Type.Optional(Type.String({ maxLength: 16 })),
    audioLangs: Type.Optional(Type.Array(Type.String({ maxLength: 16 }), { maxItems: 20 })),
    maxSizeBytes: Type.Optional(Type.Integer({ minimum: 0 })),
    minSeeders: Type.Optional(Type.Integer({ minimum: 0, maximum: 1000 })),
    excludedKeywords: Type.Optional(
      Type.Array(Type.String({ maxLength: 64 }), { maxItems: 100 }),
    ),
    scanIntervalMin: Type.Optional(Type.Integer({ minimum: 5, maximum: 360 })),
    autoDownload: Type.Optional(Type.Boolean()),
  },
  { $id: 'PtDownloadSettingsBody' },
);
const DownloadSettingsResponse = Type.Object(
  {
    settings: Type.Ref('PtDownloadSettings'),
    /** 解析后的绝对下载目录（空 = 未选库） */
    movieDir: Type.String(),
    tvDir: Type.String(),
  },
  { $id: 'PtDownloadSettingsResponse' },
);

const DEFAULT_DOWNLOAD = {
  movieLibraryId: '',
  tvLibraryId: '',
  siteIds: [] as string[],
  quality: 'all',
  hdr: 'all',
  audioLangs: [] as string[],
  maxSizeBytes: 0,
  minSeeders: 3,
  excludedKeywords: [] as string[],
  scanIntervalMin: 360,
  autoDownload: true,
};

const QUALITIES = new Set(['all', '1080p', '1440p', '4k']);
const HDRS = new Set(['all', 'hdr', 'hdr10', 'hdr10plus', 'dolby']);

function normalizeDownload(raw: unknown): typeof DEFAULT_DOWNLOAD {
  const r = (raw || {}) as Record<string, unknown>;
  const arr = (v: unknown, max: number): string[] =>
    Array.isArray(v)
      ? [...new Set(v.map((e) => String(e).trim()).filter(Boolean))].slice(0, max)
      : [];
  const quality = String(r.quality ?? 'all');
  const hdr = String(r.hdr ?? 'all');
  return {
    movieLibraryId: String(r.movieLibraryId ?? '').slice(0, 64),
    tvLibraryId: String(r.tvLibraryId ?? '').slice(0, 64),
    siteIds: arr(r.siteIds, 100),
    quality: QUALITIES.has(quality) ? quality : 'all',
    hdr: HDRS.has(hdr) ? hdr : 'all',
    audioLangs: arr(r.audioLangs, 20),
    maxSizeBytes: Math.max(0, Number(r.maxSizeBytes) || 0),
    minSeeders: Math.max(0, Math.min(1000, Number(r.minSeeders) || 0)),
    excludedKeywords: arr(r.excludedKeywords, 100),
    scanIntervalMin: Math.max(5, Math.min(360, Number(r.scanIntervalMin) || 360)),
    autoDownload: r.autoDownload !== false,
  };
}

export const pt: ServerModule = {
  id: 'pt',
  prefix: '/api/v1/pt',
  permissions: ['pt:read', 'pt:write'],

  migrations: [
    {
      id: '069_pt',
      async up(db) {
        await sql`
          create table if not exists pt_sites (
            id text primary key,
            name text not null,
            base_url text not null unique,
            kind text not null default 'nexusphp',
            cookie_enc text,
            ua text,
            enabled integer not null default 1,
            priority integer not null default 100,
            timeout_ms integer not null default 12000,
            download_client text not null default 'transmission',
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists pt_candidates (
            site_id text not null,
            torrent_id text not null,
            info_hash text,
            title text not null,
            size_bytes integer,
            seeders integer,
            leechers integer,
            resolution text,
            published_at text,
            download_url text,
            detail_url text,
            last_seen_at integer not null,
            primary key (site_id, torrent_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_pt_candidates_seen
          on pt_candidates (last_seen_at desc)
        `.execute(db);
        await sql`
          create table if not exists pt_subscriptions (
            id text primary key,
            uid text not null default '',
            media_title text not null,
            media_year text,
            season integer not null default 0,
            quality text not null default 'all',
            hdr text not null default 'all',
            audio_langs_json text not null default '[]',
            resolution_order_json text not null default '[]',
            min_seeders integer not null default 3,
            max_size_bytes integer not null default 0,
            excluded_keywords_json text not null default '[]',
            enabled integer not null default 1,
            last_run_at integer,
            last_result text,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_pt_subscriptions_uid
          on pt_subscriptions (uid, updated_at desc)
        `.execute(db);
        await sql`
          create table if not exists pt_downloads (
            id text primary key,
            uid text not null default '',
            subscription_id text,
            site_id text not null,
            torrent_id text not null,
            title text not null,
            download_url text,
            status text not null,
            message text,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_pt_downloads_created
          on pt_downloads (created_at desc)
        `.execute(db);
      },
    },
    {
      id: '070_pt_mteam',
      async up(db) {
        // M-Team 等专有 API 站点的密钥（与 cookie 分开存，密文落库）
        const cols = (
          (await sql`pragma table_info(pt_sites)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('api_key_enc')) {
          await sql`alter table pt_sites add column api_key_enc text`.execute(db);
        }
      },
    },
    {
      id: '102_pt_download_hash',
      async up(db) {
        // 下载台账记下 transmission 的 info hash，供暂停/恢复/移除使用
        const cols = (
          (await sql`pragma table_info(pt_downloads)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('info_hash')) {
          await sql`alter table pt_downloads add column info_hash text`.execute(db);
        }
      },
    },
  ],

  async register(app, k) {
    for (const schema of [DownloadSettings, DownloadSettingsBody, DownloadSettingsResponse]) {
      app.addSchema(schema);
    }
    const uidOf = (req: FastifyRequest) => String(req.user?.sub || '');

    const sites = async () =>
      (
        await sql<{
          id: string;
          name: string;
          base_url: string;
          kind: string;
          cookie_enc: string | null;
          api_key_enc: string | null;
          ua: string | null;
          enabled: number;
          priority: number;
          timeout_ms: number;
          download_client: string;
        }>`select * from pt_sites order by priority asc, created_at asc limit 100`.execute(k.db)
      ).rows;

    const cookieOf = (enc: string | null): string | undefined => {
      if (!enc) return undefined;
      try {
        return isSealed(enc) ? (openSecret(enc, COOKIE_SALT) ?? undefined) : enc;
      } catch {
        return undefined;
      }
    };

    const transmissionCfg = (): TransmissionConfig | null => {
      const raw = k.config.get<TransmissionConfig>('pt.transmission');
      if (!raw || !raw.url) return null;
      return raw;
    };

    /** 下载目录 / 筛选设置（单键存储；未配置时用 DEFAULT_DOWNLOAD） */
    const readDownload = (): typeof DEFAULT_DOWNLOAD =>
      normalizeDownload(k.config.get<Record<string, unknown>>(DOWNLOAD_KEY));

    /** 影视库根 → 绝对路径（transmission 可见路径）；库不存在或越界返回空串 */
    const libraryDir = async (id: string): Promise<string> => {
      if (!id) return '';
      const row = (
        await sql<{ root_path: string }>`
          select root_path from video_libraries where id = ${id}
        `.execute(k.db)
      ).rows[0];
      if (!row?.root_path) return '';
      try {
        return resolveAnyPath(filesRoot(), row.root_path);
      } catch {
        return '';
      }
    };

    /** 串行搜索所有启用站点；结果落 pt_candidates 并返回 */
    const searchAll = async (
      media: PtMedia,
      season: number,
    ): Promise<Array<PtCandidate & { siteId: string; siteName: string }>> => {
      const keywords = buildKeywordVariants(media, season).slice(0, 3);
      if (keywords.length === 0) return [];
      const list = (await sites()).filter((s) => Number(s.enabled));
      const wanted = new Set(readDownload().siteIds);
      const results: Array<PtCandidate & { siteId: string; siteName: string }> = [];
      for (const site of list) {
        if (wanted.size > 0 && !wanted.has(site.id)) continue;
        // M-Team 走专有 JSON API（api-key），其余走 NexusPHP HTML
        if (site.kind === 'mteam') {
          const apiKey = cookieOf(site.api_key_enc);
          if (!apiKey) continue;
          const found = await searchMTeam({
            baseUrl: site.base_url,
            apiKey,
            keyword: keywords[0],
            timeoutMs: Number(site.timeout_ms) || undefined,
          });
          for (const item of found.items) {
            results.push({
              siteId: site.id,
              siteName: site.name,
              torrentId: item.torrentId,
              infoHash: item.infoHash,
              title: item.title,
              sizeBytes: item.sizeBytes,
              seeders: item.seeders,
              leechers: item.leechers,
              resolution: resolutionOf(item.title),
              publishedAt: item.publishedAt,
              downloadUrl: item.downloadUrl,
            });
          }
          continue;
        }

        for (const keyword of keywords) {
          const found = await searchSite({
            baseUrl: site.base_url,
            keyword,
            cookie: cookieOf(site.cookie_enc),
            userAgent: site.ua ?? undefined,
            timeoutMs: Number(site.timeout_ms) || undefined,
          });
          for (const item of found.items) {
            results.push({
              siteId: site.id,
              siteName: site.name,
              torrentId: item.torrentId,
              infoHash: item.infoHash,
              title: item.title,
              sizeBytes: item.sizeBytes,
              seeders: item.seeders,
              leechers: item.leechers,
              resolution: item.resolution,
              publishedAt: item.publishedAt,
              downloadUrl: item.downloadUrl,
            });
          }
          // 同一个站第一个关键词命中就不再用后面的变体打它
          if (found.items.length > 0) break;
        }
      }

      // 落库（只留最近候选，避免无限膨胀）
      for (const c of results) {
        await sql`
          insert into pt_candidates
            (site_id, torrent_id, info_hash, title, size_bytes, seeders, leechers,
             resolution, published_at, download_url, detail_url, last_seen_at)
          values (${c.siteId}, ${c.torrentId}, ${c.infoHash ?? null}, ${c.title},
                  ${c.sizeBytes ?? null}, ${c.seeders ?? null}, ${c.leechers ?? null},
                  ${c.resolution ?? null}, ${c.publishedAt ?? null}, ${c.downloadUrl ?? null},
                  ${null}, ${now()})
          on conflict(site_id, torrent_id) do update set
            title = excluded.title, size_bytes = excluded.size_bytes,
            seeders = excluded.seeders, leechers = excluded.leechers,
            resolution = excluded.resolution, download_url = excluded.download_url,
            last_seen_at = excluded.last_seen_at
        `.execute(k.db);
      }
      return results;
    };

    const parseRule = (row: {
      quality: string;
      hdr: string;
      audio_langs_json: string;
      resolution_order_json: string;
      min_seeders: number;
      max_size_bytes: number;
      excluded_keywords_json: string;
      season: number;
    }): PtRule => ({
      quality: (['all', '1080p', '1440p', '4k'].includes(row.quality)
        ? row.quality
        : 'all') as PtRule['quality'],
      hdr: (['all', 'hdr', 'hdr10', 'hdr10plus', 'dolby'].includes(row.hdr)
        ? row.hdr
        : 'all') as PtRule['hdr'],
      audioLangs: JSON.parse(row.audio_langs_json || '[]') as string[],
      resolutionOrder: JSON.parse(row.resolution_order_json || '[]') as string[],
      minSeeders: Number(row.min_seeders) || 0,
      maxSizeBytes: Number(row.max_size_bytes) || 0,
      excludedKeywords: JSON.parse(row.excluded_keywords_json || '[]') as string[],
      season: Number(row.season) || 0,
    });

    // ---------------------------------------------------------------- 站点
    app.get(
      '/api/v1/pt/sites',
      secured('pt:read', {
        schema: {
          operationId: 'ptSiteList',
          tags: TAG,
          summary: 'PT 站点列表（不返回 cookie 明文）',
          response: {
            200: Type.Object({
              items: Type.Array(
                Type.Object(
                  {
                    id: Type.String(),
                    name: Type.String(),
                    baseUrl: Type.String(),
                    enabled: Type.Boolean(),
                    priority: Type.Integer(),
                    hasCookie: Type.Boolean(),
                  },
                  { additionalProperties: true },
                ),
              ),
            }),
          },
        },
      }),
      async () => ({
        items: (await sites()).map((s) => ({
          id: s.id,
          name: s.name,
          baseUrl: s.base_url,
          kind: s.kind,
          enabled: Number(s.enabled) === 1,
          priority: Number(s.priority),
          hasCookie: Boolean(s.cookie_enc),
          downloadClient: s.download_client,
        })),
      }),
    );

    app.post(
      '/api/v1/pt/sites/upsert',
      secured('pt:write', {
        schema: {
          operationId: 'ptSiteUpsert',
          tags: TAG,
          summary: '新增 / 更新 PT 站点（cookie 密文落库）',
          body: Type.Object({
            id: Type.Optional(Type.String()),
            name: Type.String({ minLength: 1, maxLength: 64 }),
            baseUrl: Type.String({ minLength: 8, maxLength: 256 }),
            enabled: Type.Optional(Type.Boolean()),
            priority: Type.Optional(Type.Integer({ minimum: 0, maximum: 9999 })),
            timeoutMs: Type.Optional(Type.Integer({ minimum: 1000, maximum: 60000 })),
            cookie: Type.Optional(Type.String({ maxLength: 4096 })),
            kind: Type.Optional(Type.String({ maxLength: 16 })),
            apiKey: Type.Optional(Type.String({ maxLength: 256 })),
            userAgent: Type.Optional(Type.String({ maxLength: 256 })),
          }),
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const body = (req.body || {}) as {
          id?: string;
          name?: string;
          baseUrl?: string;
          enabled?: boolean;
          priority?: number;
          timeoutMs?: number;
          cookie?: string;
          userAgent?: string;
          kind?: string;
          apiKey?: string;
        };
        const baseUrl = String(body.baseUrl || '')
          .trim()
          .replace(/\/$/, '');
        if (!body.name || !/^https?:\/\//i.test(baseUrl)) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'name and http baseUrl required' });
        }
        const cookieEnc = body.cookie ? sealSecret(body.cookie, COOKIE_SALT) : null;
        const apiKeyEnc = body.apiKey ? sealSecret(body.apiKey, COOKIE_SALT) : null;
        const kind = body.kind === 'mteam' ? 'mteam' : 'nexusphp';
        const ts = now();

        if (body.id) {
          const exists = (
            await sql<{ id: string }>`select id from pt_sites where id = ${body.id}`.execute(k.db)
          ).rows[0];
          if (!exists)
            return reply.code(404).send({ error: Err.notFound, message: 'site not found' });
          await sql`
            update pt_sites
               set name = ${body.name}, base_url = ${baseUrl}, kind = ${kind},
                   enabled = ${body.enabled === false ? 0 : 1},
                   priority = ${Number(body.priority ?? 100)},
                   timeout_ms = ${Number(body.timeoutMs ?? 12000)},
                   cookie_enc = coalesce(${cookieEnc}, cookie_enc),
                   api_key_enc = coalesce(${apiKeyEnc}, api_key_enc),
                   ua = ${body.userAgent ?? null},
                   updated_at = ${ts}
             where id = ${body.id}
          `.execute(k.db);
          return { ok: true };
        }

        const id = crypto.randomBytes(8).toString('base64url');
        await sql`
          insert into pt_sites
            (id, name, base_url, kind, cookie_enc, api_key_enc, ua, enabled, priority, timeout_ms,
             download_client, created_at, updated_at)
          values (${id}, ${body.name}, ${baseUrl}, ${kind}, ${cookieEnc}, ${apiKeyEnc},
                  ${body.userAgent ?? null}, ${body.enabled === false ? 0 : 1},
                  ${Number(body.priority ?? 100)}, ${Number(body.timeoutMs ?? 12000)},
                  'transmission', ${ts}, ${ts})
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/pt/sites/delete',
      secured('pt:write', {
        schema: {
          operationId: 'ptSiteDelete',
          tags: TAG,
          summary: '删除站点',
          body: Type.Object({ id: Type.String({ minLength: 1 }) }),
          response: { 200: OkResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as { id?: string };
        await sql`delete from pt_sites where id = ${body.id ?? ''}`.execute(k.db);
        return { ok: true };
      },
    );

    // ---------------------------------------------------------------- 搜索与订阅
    app.post(
      '/api/v1/pt/search',
      secured('pt:read', {
        schema: {
          operationId: 'ptSearch',
          tags: TAG,
          summary: '按媒体信息搜索所有启用站点（串行）',
          body: Type.Object({
            title: Type.String({ minLength: 1 }),
            originalTitle: Type.Optional(Type.String()),
            year: Type.Optional(Type.String()),
            season: Type.Optional(Type.Integer({ minimum: 0, maximum: 100 })),
          }),
          response: {
            200: Type.Object(
              {
                items: Type.Array(
                  Type.Object(
                    {
                      siteId: Type.String(),
                      siteName: Type.String(),
                      torrentId: Type.String(),
                      title: Type.String(),
                      sizeBytes: Type.Union([Type.Integer(), Type.Null()]),
                      seeders: Type.Union([Type.Integer(), Type.Null()]),
                      resolution: Type.Union([Type.String(), Type.Null()]),
                      downloadUrl: Type.Union([Type.String(), Type.Null()]),
                    },
                    { additionalProperties: true },
                  ),
                ),
              },
              { additionalProperties: true },
            ),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as {
          title?: string;
          originalTitle?: string;
          year?: string;
          season?: number;
        };
        const items = await searchAll(
          {
            title: body.title ?? '',
            originalTitle: body.originalTitle ?? null,
            year: body.year ?? null,
          },
          Number(body.season) || 0,
        );
        return { items };
      },
    );

    app.get(
      '/api/v1/pt/subscriptions',
      secured('pt:read', {
        schema: {
          operationId: 'ptSubscriptionList',
          tags: TAG,
          summary: '我的订阅',
          response: {
            200: Type.Object({
              items: Type.Array(
                Type.Object(
                  {
                    id: Type.String(),
                    mediaTitle: Type.String(),
                    season: Type.Integer(),
                    enabled: Type.Boolean(),
                    lastRunAt: Type.Union([Type.Integer(), Type.Null()]),
                    lastResult: Type.Union([Type.String(), Type.Null()]),
                  },
                  { additionalProperties: true },
                ),
              ),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const rows = (
          await sql<any>`
            select * from pt_subscriptions where uid = ${uidOf(req)}
             order by updated_at desc limit 200
          `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            id: r.id,
            mediaTitle: r.media_title,
            mediaYear: r.media_year,
            season: Number(r.season),
            quality: r.quality,
            hdr: r.hdr,
            minSeeders: Number(r.min_seeders),
            maxSizeBytes: Number(r.max_size_bytes),
            excludedKeywords: JSON.parse(r.excluded_keywords_json || '[]'),
            audioLangs: JSON.parse(r.audio_langs_json || '[]'),
            enabled: Number(r.enabled) === 1,
            lastRunAt: r.last_run_at === null ? null : Number(r.last_run_at),
            lastResult: r.last_result,
          })),
        };
      },
    );

    app.post(
      '/api/v1/pt/subscriptions/upsert',
      secured('pt:write', {
        schema: {
          operationId: 'ptSubscriptionUpsert',
          tags: TAG,
          summary: '新增 / 更新订阅',
          body: Type.Object({
            id: Type.Optional(Type.String()),
            mediaTitle: Type.String({ minLength: 1, maxLength: 200 }),
            mediaYear: Type.Optional(Type.String({ maxLength: 8 })),
            season: Type.Optional(Type.Integer({ minimum: 0, maximum: 100 })),
            quality: Type.Optional(Type.String()),
            hdr: Type.Optional(Type.String()),
            audioLangs: Type.Optional(Type.Array(Type.String())),
            resolutionOrder: Type.Optional(Type.Array(Type.String())),
            minSeeders: Type.Optional(Type.Integer({ minimum: 0 })),
            maxSizeBytes: Type.Optional(Type.Integer({ minimum: 0 })),
            excludedKeywords: Type.Optional(Type.Array(Type.String())),
            enabled: Type.Optional(Type.Boolean()),
          }),
          response: { 200: OkResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const b = (req.body || {}) as any;
        const ts = now();
        // 未显式传筛选时用「下载筛选」里的全局默认值（发现页订阅只传片名/年份）
        const dl = readDownload();
        const quality = b.quality ?? dl.quality;
        const hdr = b.hdr ?? dl.hdr;
        const audioLangs = b.audioLangs ?? dl.audioLangs;
        const resolutionOrder = b.resolutionOrder ?? [];
        const minSeeders = b.minSeeders === undefined ? dl.minSeeders : Number(b.minSeeders) || 0;
        const maxSizeBytes =
          b.maxSizeBytes === undefined ? dl.maxSizeBytes : Number(b.maxSizeBytes) || 0;
        const excludedKeywords = b.excludedKeywords ?? dl.excludedKeywords;
        if (b.id) {
          await sql`
            update pt_subscriptions
               set media_title = ${b.mediaTitle}, media_year = ${b.mediaYear ?? null},
                   season = ${Number(b.season) || 0},
                   quality = ${quality}, hdr = ${hdr},
                   audio_langs_json = ${JSON.stringify(audioLangs)},
                   resolution_order_json = ${JSON.stringify(resolutionOrder)},
                   min_seeders = ${minSeeders},
                   max_size_bytes = ${maxSizeBytes},
                   excluded_keywords_json = ${JSON.stringify(excludedKeywords)},
                   enabled = ${b.enabled === false ? 0 : 1}, updated_at = ${ts}
             where id = ${b.id} and uid = ${uidOf(req)}
          `.execute(k.db);
          return { ok: true };
        }
        const id = crypto.randomBytes(8).toString('base64url');
        await sql`
          insert into pt_subscriptions
            (id, uid, media_title, media_year, season, quality, hdr,
             audio_langs_json, resolution_order_json, min_seeders, max_size_bytes,
             excluded_keywords_json, enabled, last_run_at, last_result, created_at, updated_at)
          values (${id}, ${uidOf(req)}, ${b.mediaTitle}, ${b.mediaYear ?? null},
                  ${Number(b.season) || 0}, ${quality}, ${hdr},
                  ${JSON.stringify(audioLangs)}, ${JSON.stringify(resolutionOrder)},
                  ${minSeeders}, ${maxSizeBytes},
                  ${JSON.stringify(excludedKeywords)}, ${b.enabled === false ? 0 : 1},
                  null, null, ${ts}, ${ts})
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/pt/subscriptions/delete',
      secured('pt:write', {
        schema: {
          operationId: 'ptSubscriptionDelete',
          tags: TAG,
          summary: '删除订阅',
          body: Type.Object({ id: Type.String({ minLength: 1 }) }),
          response: { 200: OkResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const body = (req.body || {}) as { id?: string };
        await sql`
          delete from pt_subscriptions where id = ${body.id ?? ''} and uid = ${uidOf(req)}
        `.execute(k.db);
        return { ok: true };
      },
    );

    /** 跑一条订阅：搜索 → 筛选 → 选种 → 下载 → 留痕 */
    const runSubscription = async (
      sub: any,
      uid: string,
    ): Promise<{ ok: boolean; message: string }> => {
      const rule = parseRule(sub);
      const media: PtMedia = {
        title: sub.media_title,
        year: sub.media_year,
        season: Number(sub.season) || 0,
      };
      const found = await searchAll(media, Number(sub.season) || 0);
      if (found.length === 0) {
        await sql`
          update pt_subscriptions set last_run_at = ${now()}, last_result = 'no_candidate'
           where id = ${sub.id}
        `.execute(k.db);
        return { ok: false, message: 'no candidate' };
      }

      const result = selectBest(rule, found, media);
      if (!result.selected) {
        await sql`
          update pt_subscriptions set last_run_at = ${now()}, last_result = ${result.reason}
           where id = ${sub.id}
        `.execute(k.db);
        return { ok: false, message: result.reason };
      }

      const candidate = result.selected as PtCandidate & { siteId: string; downloadUrl?: string };
      const cfg = transmissionCfg();
      const dl = readDownload();
      const downloadDir =
        Number(sub.season) > 0
          ? await libraryDir(dl.tvLibraryId)
          : await libraryDir(dl.movieLibraryId);
      let status = 'proposed';
      let message = '未配置 transmission：只给出候选';
      let infoHash: string | null = null;

      if (!dl.autoDownload) {
        message = '自动下载已关闭：只给出候选';
      } else if (cfg && candidate.downloadUrl) {
        const added = await addTorrent(cfg, candidate.downloadUrl, {
          downloadDir: downloadDir || undefined,
        });
        status = added.ok ? 'added' : 'failed';
        message = added.message;
        infoHash = added.hash ?? null;
      }

      await sql`
        insert into pt_downloads
          (id, uid, subscription_id, site_id, torrent_id, title, download_url,
           info_hash, status, message, created_at)
        values (${crypto.randomBytes(8).toString('base64url')}, ${uid}, ${sub.id},
                ${candidate.siteId}, ${candidate.torrentId}, ${candidate.title},
                ${candidate.downloadUrl ?? null}, ${infoHash}, ${status}, ${message}, ${now()})
      `.execute(k.db);
      await sql`
        update pt_subscriptions
           set last_run_at = ${now()}, last_result = ${`${status}: ${message}`.slice(0, 300)}
         where id = ${sub.id}
      `.execute(k.db);
      return { ok: status === 'added', message };
    };

    app.post(
      '/api/v1/pt/subscriptions/run',
      secured('pt:write', {
        schema: {
          operationId: 'ptSubscriptionRun',
          tags: TAG,
          summary: '立即执行一条订阅',
          body: Type.Object({ id: Type.String({ minLength: 1 }) }),
          response: {
            200: Type.Object({ ok: Type.Boolean(), message: Type.String() }),
            404: ErrorResponse,
          },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const body = (req.body || {}) as { id?: string };
        const sub = (
          await sql<any>`
            select * from pt_subscriptions where id = ${body.id ?? ''} and uid = ${uidOf(req)}
          `.execute(k.db)
        ).rows[0];
        if (!sub)
          return reply.code(404).send({ error: Err.notFound, message: 'subscription not found' });
        return runSubscription(sub, uidOf(req));
      },
    );

    app.get(
      '/api/v1/pt/downloads',
      secured('pt:read', {
        schema: {
          operationId: 'ptDownloads',
          tags: TAG,
          summary: '下载留痕（最近 200 条）',
          response: {
            200: Type.Object({
              items: Type.Array(
                Type.Object(
                  {
                    id: Type.String(),
                    title: Type.String(),
                    status: Type.String(),
                    createdAt: Type.Integer(),
                  },
                  { additionalProperties: true },
                ),
              ),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const rows = (
          await sql<any>`
            select * from pt_downloads where uid = ${uidOf(req)}
             order by created_at desc limit 200
          `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            id: r.id,
            title: r.title,
            status: r.status,
            message: r.message,
            infoHash: r.info_hash ?? null,
            canControl: (r.status === 'added' || r.status === 'paused') && !!r.info_hash,
            createdAt: Number(r.created_at),
          })),
        };
      },
    );

    // ---------------------------------------------------------------- 下载台账操作
    app.post(
      '/api/v1/pt/downloads/action',
      secured('pt:write', {
        schema: {
          operationId: 'ptDownloadAction',
          tags: TAG,
          summary: '暂停 / 恢复 / 移除下载任务（移除不删本地数据）',
          body: Type.Object({
            id: Type.String({ minLength: 1 }),
            action: Type.Union([
              Type.Literal('pause'),
              Type.Literal('resume'),
              Type.Literal('remove'),
            ]),
          }),
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const b = (req.body || {}) as { id?: string; action?: string };
        const row = (
          await sql<any>`
            select * from pt_downloads where id = ${b.id || ''} and uid = ${uidOf(req)}
          `.execute(k.db)
        ).rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'download not found' });
        const cfg = transmissionCfg();
        if (!cfg) {
          return reply.code(400).send({ error: Err.badRequest, message: 'transmission not configured' });
        }
        const hash = String(row.info_hash || '');
        if (!hash) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'torrent hash missing for this download' });
        }
        const action = b.action === 'pause' ? 'stop' : b.action === 'resume' ? 'start' : 'remove';
        const res = await torrentAction(cfg, action, hash);
        if (!res.ok) {
          return reply.code(400).send({ error: Err.badRequest, message: res.message });
        }
        const nextStatus =
          b.action === 'pause' ? 'paused' : b.action === 'resume' ? 'added' : 'removed';
        await sql`
          update pt_downloads set status = ${nextStatus}, message = ${res.message}
           where id = ${row.id}
        `.execute(k.db);
        return { ok: true };
      },
    );

    // ---------------------------------------------------------------- 下载目录 / 筛选（发现设置页）
    app.get(
      '/api/v1/pt/download/settings',
      secured('pt:read', {
        schema: {
          operationId: 'ptDownloadSettingsGet',
          tags: TAG,
          summary: '下载目录与筛选设置（发现设置页）',
          response: { 200: Type.Ref('PtDownloadSettingsResponse') },
        },
      }),
      async () => {
        const settings = readDownload();
        return {
          settings,
          movieDir: await libraryDir(settings.movieLibraryId),
          tvDir: await libraryDir(settings.tvLibraryId),
        };
      },
    );

    app.post(
      '/api/v1/pt/download/settings',
      secured('pt:write', {
        schema: {
          operationId: 'ptDownloadSettingsSet',
          tags: TAG,
          summary: '保存下载目录与筛选（自动下载 / 扫描间隔立即生效）',
          body: Type.Ref('PtDownloadSettingsBody'),
          response: {
            200: Type.Ref('PtDownloadSettingsResponse'),
            400: ErrorResponse,
          },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const body = (req.body || {}) as Record<string, unknown>;
        const next = normalizeDownload({ ...readDownload(), ...body });
        for (const [label, id] of [
          ['movieLibraryId', next.movieLibraryId],
          ['tvLibraryId', next.tvLibraryId],
        ] as const) {
          if (!id) continue;
          const exists = await sql`
            select 1 from video_libraries where id = ${id}
          `.execute(k.db);
          if (exists.rows.length === 0) {
            return reply
              .code(400)
              .send({ error: Err.badRequest, message: `${label} not found` });
          }
        }
        const movieDir = await libraryDir(next.movieLibraryId);
        const tvDir = await libraryDir(next.tvLibraryId);
        if (next.movieLibraryId && !movieDir) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'movie library path escapes files root' });
        }
        if (next.tvLibraryId && !tvDir) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'tv library path escapes files root' });
        }
        await k.config.set(DOWNLOAD_KEY, next);
        return { settings: next, movieDir, tvDir };
      },
    );

    // ---------------------------------------------------------------- 设置与探活
    app.post(
      '/api/v1/pt/settings',
      secured('pt:write', {
        schema: {
          operationId: 'ptSettingsSet',
          tags: TAG,
          summary: '设置 transmission（url / 账号）',
          body: Type.Object({
            url: Type.String({ maxLength: 256 }),
            username: Type.Optional(Type.String({ maxLength: 128 })),
            password: Type.Optional(Type.String({ maxLength: 256 })),
          }),
          response: { 200: OkResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const b = (req.body || {}) as { url?: string; username?: string; password?: string };
        await k.config.set('pt.transmission', {
          url: String(b.url || '').trim(),
          username: b.username ?? null,
          password: b.password ?? null,
        });
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/pt/transmission/test',
      secured('pt:read', {
        schema: {
          operationId: 'ptTransmissionTest',
          tags: TAG,
          summary: '探测 transmission 连通性',
          response: {
            200: Type.Object(
              { ok: Type.Boolean(), message: Type.String() },
              { additionalProperties: true },
            ),
          },
        },
      }),
      async () => {
        const cfg = transmissionCfg();
        if (!cfg) return { ok: false, message: 'transmission url not configured' };
        return transmissionStatus(cfg);
      },
    );

    // ---------------------------------------------------------------- 后台任务：单个订阅
    // 入队而不是就地执行：重启不丢当轮、失败按退避重试、`/api/v1/tasks` 可见
    k.tasks.register('pt.subscription', async (payload) => {
      const id = String((payload as { id?: string } | null)?.id || '');
      if (!id) return null;
      const row = (
        await sql<any>`select * from pt_subscriptions where id = ${id} and enabled = 1`.execute(k.db)
      ).rows[0];
      if (!row) return null;
      await runSubscription(row, String(row.uid || ''));
      return { id };
    });

    // 调度：每分钟检查一次，按「下载筛选」里的扫描间隔（5–360 分钟）决定谁到期；
    // 改设置后无需重启，下一分钟即按新间隔生效。
    const timer = setInterval(() => {
      void (async () => {
        const cutoff = now() - readDownload().scanIntervalMin * 60;
        const rows = (
          await sql<any>`
            select id from pt_subscriptions where enabled = 1
             and (last_run_at is null or last_run_at < ${cutoff})
             order by last_run_at asc limit 20
          `.execute(k.db)
        ).rows;
        for (const sub of rows) {
          try {
            await k.tasks.enqueueIfIdle('pt.subscription', { id: String(sub.id) }, { maxAttempts: 2 });
          } catch (err) {
            k.log.warn({ err: String(err), id: sub.id }, 'pt subscription enqueue failed');
          }
        }
      })();
    }, 60_000);
    timer.unref?.();
    app.addHook('onClose', async () => clearInterval(timer));
  },
};
