import crypto from 'node:crypto';
import path from 'node:path';
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
  titleMatchScore,
  TITLE_MATCH_THRESHOLD,
  type PtCandidate,
  type PtMedia,
  type PtRule,
} from './selection';
import { resolutionOf, searchSite } from './search';
import { searchMTeam } from './mteam';
import {
  addTorrent,
  torrentAction,
  torrentGet,
  torrentList,
  transmissionStatus,
  type TransmissionConfig,
} from './transmission';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { normalizeConfig, tmdbGet } from '../discover/tmdb';
import { resolveSecret, signToken } from '../../../kernel/auth';
import { registerTransmissionWebUi, transmissionWebDir } from './webui';
import { ensureDaemon, stopDaemon } from './daemon';

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
    {
      // 参考实现 1:1：预览候选 → 提交下载闭环需要幂等键与来源列
      id: '153_pt_download_idem',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(pt_downloads)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('candidate_id')) {
          await sql`alter table pt_downloads add column candidate_id text`.execute(db);
        }
        if (!cols.includes('rss_entry_id')) {
          await sql`alter table pt_downloads add column rss_entry_id text`.execute(db);
        }
        if (!cols.includes('idempotency_key')) {
          await sql`alter table pt_downloads add column idempotency_key text`.execute(db);
        }
        if (!cols.includes('torrent_name')) {
          await sql`alter table pt_downloads add column torrent_name text`.execute(db);
        }
        await sql`
          create unique index if not exists idx_pt_downloads_idem
            on pt_downloads (idempotency_key) where idempotency_key is not null
        `.execute(db);
      },
    },
    {
      // 择种规则 CRUD + 订阅按 TMDB media_id 绑定 + 站点连通性测试留痕。
      // 三件事共用一次迁移：都只是补列 / 建小表，互不依赖。
      id: '157_pt_rules_sub_media',
      async up(db) {
        await sql`
          create table if not exists pt_rules (
            id text primary key,
            uid text not null default '',
            name text not null,
            enabled integer not null default 1,
            priority integer not null default 100,
            quality text not null default 'all',
            hdr text not null default 'all',
            resolution_order_json text not null default '[]',
            audio_langs_json text not null default '[]',
            min_seeders integer not null default 3,
            max_size_bytes integer not null default 0,
            excluded_keywords_json text not null default '[]',
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_pt_rules_uid
          on pt_rules (uid, priority asc)
        `.execute(db);

        const subCols = (
          (await sql`pragma table_info(pt_subscriptions)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        for (const [col, ddl] of [
          ['media_id', 'alter table pt_subscriptions add column media_id integer'],
          ['media_type', "alter table pt_subscriptions add column media_type text not null default 'movie'"],
          ['rule_id', 'alter table pt_subscriptions add column rule_id text'],
          ['poster_path', 'alter table pt_subscriptions add column poster_path text'],
        ] as Array<[string, string]>) {
          if (!subCols.includes(col)) await sql.raw(ddl).execute(db);
        }
        await sql`
          create index if not exists idx_pt_subscriptions_media
            on pt_subscriptions (uid, media_type, media_id)
        `.execute(db);

        const siteCols = (
          (await sql`pragma table_info(pt_sites)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        for (const [col, ddl] of [
          ['last_test_at', 'alter table pt_sites add column last_test_at integer'],
          ['last_test_status', 'alter table pt_sites add column last_test_status text'],
          ['last_test_message', 'alter table pt_sites add column last_test_message text'],
          ['rss_url', 'alter table pt_sites add column rss_url text'],
        ] as Array<[string, string]>) {
          if (!siteCols.includes(col)) await sql.raw(ddl).execute(db);
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

        /**
     * 本机没配置时自动找 transmission：探 127.0.0.1:9091 的 RPC。
     * 409 也算「在」——transmission 首次请求必然 409 + session-id 头。
     * 结果缓存 60s，避免每 5 秒轮询都去敲端口。
     */
    let probedCfg: { at: number; cfg: TransmissionConfig | null } = { at: 0, cfg: null };
    const probeLocalTransmission = async (): Promise<TransmissionConfig | null> => {
      const nowMs = Date.now();
      if (nowMs - probedCfg.at < 60_000) return probedCfg.cfg;
      for (const port of [9091, 9092]) {
        const url = `http://127.0.0.1:${port}/transmission/rpc`;
        try {
          const ctl = new AbortController();
          const timer = setTimeout(() => ctl.abort(), 1200);
          const res = await fetch(url, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ method: 'session-get' }),
            signal: ctl.signal,
          });
          clearTimeout(timer);
          if (res.status === 200 || res.status === 409) {
            probedCfg = { at: nowMs, cfg: { url } };
            return probedCfg.cfg;
          }
        } catch {
          /* 端口没开，继续下一个 */
        }
      }
      probedCfg = { at: nowMs, cfg: null };
      return null;
    };

    /** 下载器来源：embedded=我们拉起的 daemon / external=用户自己装的 / none */
    let downloaderMode: 'embedded' | 'external' | 'none' = 'none';

    /**
     * 解析当前用哪个下载器：
     *  1. 用户在设置里填了地址 → 用它；
     *  2. 否则用**内置** daemon（随包带的 transmission-daemon，直接拉起来，不用用户装）；
     *  3. 内置不可用（没二进制/起不来）→ 探测本机已有的。
     */
    const resolveTransmission = async (): Promise<TransmissionConfig | null> => {
      const configured = transmissionCfg();
      if (configured) {
        downloaderMode = 'external';
        return configured;
      }
      const dl = readDownload();
      const dir =
        (await libraryDir(dl.movieLibraryId)) || path.join(k.paths.dataDir, 'downloads');
      const embedded = await ensureDaemon({
        dataDir: k.paths.dataDir,
        downloadDir: dir,
      });
      if (embedded) {
        downloaderMode = 'embedded';
        return { url: embedded };
      }
      const probed = await probeLocalTransmission();
      downloaderMode = probed ? 'external' : 'none';
      return probed;
    };

    /** 下载目录 / 筛选设置（单键存储；未配置时用 DEFAULT_DOWNLOAD） */
    const readDownload = (): typeof DEFAULT_DOWNLOAD =>
      normalizeDownload(k.config.get<Record<string, unknown>>(DOWNLOAD_KEY));

    /**
     * 「参与自动下载的站点」默认值兜底。
     *
     * 这个列表同时决定**搜索哪些站**和**自动下载从哪些站取种**。新装/刚加站点时它是空的，
     * 用户不加站点勾选就会觉得「搜索什么都没有」——所以：
     *  - 加站点时，如果还没选过站点（或原来选的站点都被删了），自动把第一个站点选上；
     *  - 删站点时，把它从列表里摘掉，别留死 id 让搜索永远空转。
     */
    const syncDefaultSite = async (): Promise<void> => {
      const dl = readDownload();
      const alive = (
        await sql<{ id: string }>`select id from pt_sites order by created_at asc`.execute(k.db)
      ).rows.map((r) => r.id);
      const kept = dl.siteIds.filter((id) => alive.includes(id));
      // 已经选过（且都还在）就尊重用户的选择；否则默认用「第一个站点」
      const nextIds = kept.length > 0 ? kept : alive.slice(0, 1);
      if (nextIds.join(',') === dl.siteIds.join(',')) return; // 没变化就不写库
      await k.config.set(DOWNLOAD_KEY, { ...dl, siteIds: nextIds });
    };

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

    /**
     * 关键词 → TMDB 反查（中文名 → 英文原名 + 年份）。
     *
     * PT 站点的种子标题基本是英文（"Resident Evil 2026"），拿中文关键词去搜，
     * 搜回来的标题和媒体名对不上 → 全被判 TITLE_MISMATCH 排除，
     * 页面表现就是「搜索什么都没有」。补上原名就好办了。
     */
    const tmdbLookup = async (
      keyword: string,
      mediaType: string,
    ): Promise<{ originalTitle: string; year: string } | null> => {
      try {
        const cfg = normalizeConfig(k.config.get('discover.tmdb'));
        if (!cfg.apiKey) return null;
        const apiPath = mediaType === 'tv' ? '/search/tv' : '/search/movie';
        const data = await tmdbGet(cfg, apiPath, { query: keyword, language: 'zh-CN' });
        const list = Array.isArray(data?.results) ? (data.results as any[]) : [];
        const hit = list[0];
        if (!hit) return null;
        return {
          originalTitle: String(hit.original_name || hit.original_title || '').trim(),
          year: String(hit.release_date || hit.first_air_date || '').slice(0, 4),
        };
      } catch {
        return null;
      }
    };

    /**
     * 搜索结果的短 TTL 缓存（进程内）。
     *
     * 发现页「搜索」经常被连点 / 换个筛选条件又点一次，每次都去敲站点网络（单次 1~3s），
     * 体感就是「点了搜索特别卡」。同一个关键词 90 秒内直接复用上次结果。
     * 缓存只在内存里，进程重启即失效；站点集合变了 key 也变，不会串味。
     */
    const searchCache = new Map<string, { at: number; items: Array<PtCandidate & { siteId: string; siteName: string }> }>();
    const SEARCH_CACHE_TTL_MS = 90_000;

    /**
     * 搜索所有启用站点；结果落 pt_candidates 并返回。
     *
     * 并发策略：**M-Team（JSON API）之间并发，NexusPHP（HTML）之间串行**。
     * 之前全部串行时总耗时=各家相加，一个慢站（默认超时 12s）能把整次搜索拖住十几秒；
     * 但 NexusPHP 站点实测并发会被打成 403/空结果（见文件头注释），不能一起并发。
     */
    const searchAll = async (
      media: PtMedia,
      season: number,
      /** 出参：逐站点结果（参考页「站点异常」区块要 site_name + error） */
      statuses?: Array<{ site_id: string; site_name: string; error: string }>,
    ): Promise<Array<PtCandidate & { siteId: string; siteName: string }>> => {
      const keywords = buildKeywordVariants(media, season).slice(0, 3);
      if (keywords.length === 0) return [];
      const enabled = (await sites()).filter((s) => Number(s.enabled));
      const wanted = new Set(readDownload().siteIds);
      // 选中的站点可能已被删除/停用。这时**不能**把站点全过滤掉（结果会永远是空），
      // 退化成搜全部启用站点。
      const picked = enabled.filter((s) => wanted.has(s.id));
      const list = wanted.size > 0 && picked.length > 0 ? picked : enabled;

      const cacheKey = [
        media.title,
        media.originalTitle ?? '',
        media.year ?? '',
        season,
        list.map((s) => s.id).join(','),
      ].join('|');
      const cached = searchCache.get(cacheKey);
      if (cached && Date.now() - cached.at < SEARCH_CACHE_TTL_MS) {
        if (statuses) {
          for (const site of list) statuses.push({ site_id: site.id, site_name: site.name, error: '' });
        }
        return cached.items;
      }

      const note = (site: { id: string; name: string }, error: string) => {
        if (statuses) {
          statuses.push({ site_id: site.id, site_name: site.name, error });
        }
      };

      // M-Team 专用关键词顺序：**纯标题优先**。
      // 带年份的查询（"Resident Evil 2026"）在 M-Team 上又慢（单次 ~2.5s）又少，
      // 纯标题（"Resident Evil"）一次就能命中，年份留给筛选环节兜。
      const mteamKeywords = (() => {
        const out: string[] = [];
        const push = (v: unknown) => {
          const s = String(v || '').trim();
          if (s && !out.includes(s)) out.push(s);
        };
        push(media.originalTitle);
        push(media.title);
        if (season > 0) {
          const pad = String(season).padStart(2, '0');
          push(`${media.originalTitle || media.title} S${pad}`);
        } else if (media.year) {
          push(`${media.originalTitle || media.title} ${media.year}`);
        }
        return out.slice(0, 3);
      })();

      type Found = Array<PtCandidate & { siteId: string; siteName: string }>;
      const searchOne = async (
        site: (typeof list)[number],
      ): Promise<{ items: Found; error: string }> => {
        const out: Found = [];
        // M-Team 走专有 JSON API（api-key），其余走 NexusPHP HTML
        if (site.kind === 'mteam') {
          const apiKey = cookieOf(site.api_key_enc);
          if (!apiKey) return { items: out, error: 'missing_api_key' };
          // 站点种子标题基本是英文：中文关键词常常搜不到，
          // 所以多个关键词变体依次试，直到出现「标题对得上」的结果为止。
          const seen = new Set<string>();
          let lastReason = 'empty';
          for (const keyword of mteamKeywords) {
            const found = await searchMTeam({
              baseUrl: site.base_url,
              apiKey,
              keyword,
              timeoutMs: Number(site.timeout_ms) || undefined,
            });
            lastReason = found.reason || lastReason;
            for (const item of found.items) {
              if (seen.has(item.torrentId)) continue;
              seen.add(item.torrentId);
              out.push({
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
            // 已经有对得上标题的结果就别再打这个站了（省一次网络往返）
            if (out.some((o) => titleMatchScore(o.title, media) >= TITLE_MATCH_THRESHOLD)) break;
          }
          return { items: out, error: out.length > 0 ? '' : lastReason };
        }

        let siteError = '';
        for (const keyword of keywords) {
          const found = await searchSite({
            baseUrl: site.base_url,
            keyword,
            cookie: cookieOf(site.cookie_enc),
            userAgent: site.ua ?? undefined,
            timeoutMs: Number(site.timeout_ms) || undefined,
          });
          if (found.reason !== 'ok' && found.reason !== 'empty') {
            siteError = found.reason;
          }
          for (const item of found.items) {
            out.push({
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
          if (found.items.length > 0) {
            siteError = '';
            break;
          }
        }
        return { items: out, error: siteError };
      };

      // M-Team（JSON API）之间并发；NexusPHP（HTML）实测并发会被打成 403，
      // 必须一个一个来。
      const apiSites = list.filter((s) => s.kind === 'mteam');
      const htmlSites = list.filter((s) => s.kind !== 'mteam');
      const results: Found = [];
      const errors = new Map<string, string>();

      const apiSettled = await Promise.allSettled(apiSites.map(searchOne));
      apiSettled.forEach((r, i) => {
        const site = apiSites[i];
        if (r.status === 'fulfilled') {
          results.push(...r.value.items);
          errors.set(site.id, r.value.error);
        } else {
          errors.set(site.id, String((r.reason as Error)?.message ?? r.reason ?? 'error').slice(0, 80));
        }
      });
      for (const site of htmlSites) {
        try {
          const r = await searchOne(site);
          results.push(...r.items);
          errors.set(site.id, r.error);
        } catch (err) {
          errors.set(site.id, String((err as Error)?.message ?? err).slice(0, 80));
        }
      }
      // 按站点原始顺序回报状态，页面上的「站点异常」顺序才稳定
      for (const site of list) note(site, errors.get(site.id) ?? '');

      // 落库：拼成多行 values 一条语句写。一条条 await 时 50 条要走 50 次
      // prepare+commit，搜索一慢就顶在这里。
      const seenAt = now();
      for (let i = 0; i < results.length; i += 40) {
        const group = results.slice(i, i + 40);
        const values = group.map(
          (c) => sql`(${c.siteId}, ${c.torrentId}, ${c.infoHash ?? null}, ${c.title},
                     ${c.sizeBytes ?? null}, ${c.seeders ?? null}, ${c.leechers ?? null},
                     ${c.resolution ?? null}, ${c.publishedAt ?? null}, ${c.downloadUrl ?? null},
                     ${null}, ${seenAt})`,
        );
        await sql`
          insert into pt_candidates
            (site_id, torrent_id, info_hash, title, size_bytes, seeders, leechers,
             resolution, published_at, download_url, detail_url, last_seen_at)
          values ${sql.join(values, sql`, `)}
          on conflict(site_id, torrent_id) do update set
            title = excluded.title, size_bytes = excluded.size_bytes,
            seeders = excluded.seeders, leechers = excluded.leechers,
            resolution = excluded.resolution, download_url = excluded.download_url,
            last_seen_at = excluded.last_seen_at
        `.execute(k.db);
      }
      searchCache.set(cacheKey, { at: Date.now(), items: results });
      // 只留最近 20 条，防止长时间运行把内存吃满
      if (searchCache.size > 20) {
        const oldest = [...searchCache.entries()].sort((a, b) => a[1].at - b[1].at)[0];
        if (oldest) searchCache.delete(oldest[0]);
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
          hasApiKey: Boolean((s as any).api_key_enc),
          downloadClient: s.download_client,
          lastTestAt: (s as any).last_test_at == null ? null : Number((s as any).last_test_at),
          lastTestStatus: (s as any).last_test_status ?? null,
          lastTestMessage: (s as any).last_test_message ?? null,
          rssUrl: (s as any).rss_url ?? null,
        })),
      }),
    );

    // 内置 transmission 官方 Web UI（静态 + RPC 反代），见 ./webui.ts
    registerTransmissionWebUi(app, k, { cfg: () => resolveTransmission() });

    /** 站点连通性测试：真打一次搜索（mteam 走 API、其余走 HTML），结果留痕 */
    app.post(
      '/api/v1/pt/sites/:id/test',
      secured('pt:read', {
        schema: {
          operationId: 'ptSiteTest',
          tags: TAG,
          summary: '测试 PT 站点连通性（真搜一次，结果落库）',
          params: Type.Object({ id: Type.String({ minLength: 1 }) }),
          response: {
            200: Type.Object({
              ok: Type.Boolean(),
              siteId: Type.String(),
              status: Type.String(),
              message: Type.String(),
              elapsedMs: Type.Integer(),
              items: Type.Integer(),
            }),
            404: ErrorResponse,
          },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const p = (req.params || {}) as { id?: string };
        const site = (await sites()).find((s) => s.id === p.id);
        if (!site) {
          return reply.code(404).send({ error: Err.notFound, message: 'site not found' });
        }
        const started = Date.now();
        let status = 'ok';
        let message = '';
        let count = 0;
        const keyword = '1080p';
        if (site.kind === 'mteam') {
          const apiKey = cookieOf(site.api_key_enc);
          if (!apiKey) {
            status = 'no-credential';
            message = '未配置 API Key';
          } else {
            try {
              const found = await searchMTeam({
                baseUrl: site.base_url,
                apiKey,
                keyword,
                timeoutMs: Number(site.timeout_ms) || undefined,
              });
              count = found.items.length;
              message = `返回 ${count} 条`;
            } catch (err) {
              status = 'fail';
              message = String((err as Error)?.message || err).slice(0, 200);
            }
          }
        } else {
          const cookie = cookieOf(site.cookie_enc);
          if (!cookie) {
            status = 'no-credential';
            message = '未配置 Cookie';
          } else {
            try {
              const found = await searchSite({
                baseUrl: site.base_url,
                keyword,
                cookie,
                userAgent: site.ua ?? undefined,
                timeoutMs: Number(site.timeout_ms) || undefined,
              });
              count = found.items.length;
              message = found.reason ? `返回 ${count} 条（${found.reason}）` : `返回 ${count} 条`;
            } catch (err) {
              status = 'fail';
              message = String((err as Error)?.message || err).slice(0, 200);
            }
          }
        }
        const ts = now();
        await sql`
          update pt_sites
             set last_test_at = ${ts}, last_test_status = ${status},
                 last_test_message = ${message}
           where id = ${site.id}
        `.execute(k.db);
        return {
          ok: status === 'ok',
          siteId: site.id,
          status,
          message,
          elapsedMs: Date.now() - started,
          items: count,
        };
      },
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
            // 只改凭据时（发现页「设置 Token」按钮）可以不带 name / baseUrl
            name: Type.Optional(Type.String({ maxLength: 64 })),
            baseUrl: Type.Optional(Type.String({ maxLength: 256 })),
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
        // 新增必须给全；更新（带 id）允许只传要改的字段
        if (!body.id && (!body.name || !/^https?:\/\//i.test(baseUrl))) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'name and http baseUrl required' });
        }
        if (body.baseUrl && !/^https?:\/\//i.test(baseUrl)) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'baseUrl must be http(s)' });
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
               set name = coalesce(${body.name ?? null}, name),
                   base_url = coalesce(${baseUrl || null}, base_url),
                   kind = coalesce(${body.kind === undefined ? null : kind}, kind),
                   enabled = coalesce(${body.enabled === undefined ? null : body.enabled ? 1 : 0}, enabled),
                   priority = coalesce(${body.priority === undefined ? null : Number(body.priority)}, priority),
                   timeout_ms = coalesce(${body.timeoutMs === undefined ? null : Number(body.timeoutMs)}, timeout_ms),
                   cookie_enc = coalesce(${cookieEnc}, cookie_enc),
                   api_key_enc = coalesce(${apiKeyEnc}, api_key_enc),
                   ua = coalesce(${body.userAgent ?? null}, ua),
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
        // 新站默认接管「搜索站点 / 自动下载站点」，否则用户勾选前搜索是空的
        await syncDefaultSite();
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
        // 顺手把死 id 从「搜索/自动下载站点」里摘掉，并兜底选上仍存在的第一个站点
        await syncDefaultSite();
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
        const title = String(body.title || '').trim();
        let originalTitle = body.originalTitle;
        let year = body.year;
        // 中文标题 → 英文原名（PT 站点种子标题基本都是英文）
        if (!originalTitle && title) {
          const hit = await tmdbLookup(title, 'movie');
          if (hit?.originalTitle) {
            originalTitle = hit.originalTitle;
            if (!year && hit.year) year = hit.year;
          }
        }
        const items = await searchAll(
          {
            title,
            originalTitle: originalTitle ?? null,
            year: year ?? null,
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
            mediaId: r.media_id == null ? null : Number(r.media_id),
            mediaType: r.media_type ?? 'movie',
            mediaTitle: r.media_title,
            mediaYear: r.media_year,
            posterPath: r.poster_path ?? null,
            ruleId: r.rule_id ?? null,
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
            /** 按 TMDB media_id 绑定（发现页订阅只传 id + 类型；同名不同片不再串） */
            mediaId: Type.Optional(Type.Integer({ minimum: 1 })),
            mediaType: Type.Optional(Type.String({ maxLength: 8 })),
            ruleId: Type.Optional(Type.String({ maxLength: 64 })),
            posterPath: Type.Optional(Type.String({ maxLength: 200 })),
            mediaTitle: Type.Optional(Type.String({ maxLength: 200 })),
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
        const mediaId = b.mediaId === undefined || b.mediaId === null ? null : Number(b.mediaId) || null;
        const mediaType = b.mediaType === 'tv' ? 'tv' : 'movie';
        const mediaTitle = String(b.mediaTitle || (mediaId ? `TMDB ${mediaId}` : '')).slice(0, 200);
        // 传了 media_id 但没给片名：回查 TMDB 补标题（失败就先用占位名，不阻断订阅）
        if (mediaId && !b.mediaTitle) {
          try {
            const cfg = normalizeConfig(k.config.get('discover.tmdb'));
            const detail = await tmdbGet(cfg, `/${mediaType}/${mediaId}`);
            const title = String(detail?.title || detail?.name || '');
            if (title) (b as any).mediaTitle = title;
          } catch {
            /* 无 TMDB 也能订阅，标题后续扫描时再补 */
          }
        }
        const finalTitle = String((b as any).mediaTitle || mediaTitle || `TMDB ${mediaId ?? ''}`).slice(0, 200);
        if (!b.id && !finalTitle) {
          return { ok: false };
        }
        // 按 media_id 去重：同一部片只留一条订阅（存在则改成启用 / 换规则）
        if (!b.id && mediaId) {
          const dup = (
            await sql<any>`
              select id from pt_subscriptions
               where uid = ${uidOf(req)} and media_type = ${mediaType} and media_id = ${mediaId}
               limit 1
            `.execute(k.db)
          ).rows[0];
          if (dup) {
            await sql`
              update pt_subscriptions
                 set enabled = 1, rule_id = ${b.ruleId ?? null},
                     poster_path = coalesce(${b.posterPath ?? null}, poster_path),
                     media_title = ${finalTitle}, updated_at = ${ts}
               where id = ${dup.id} and uid = ${uidOf(req)}
            `.execute(k.db);
            return { ok: true, id: dup.id };
          }
        }
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
               set media_title = ${finalTitle}, media_year = ${b.mediaYear ?? null},
                   media_id = coalesce(${mediaId}, media_id),
                   media_type = ${mediaType},
                   rule_id = coalesce(${b.ruleId ?? null}, rule_id),
                   poster_path = coalesce(${b.posterPath ?? null}, poster_path),
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
            (id, uid, media_id, media_type, rule_id, poster_path,
             media_title, media_year, season, quality, hdr,
             audio_langs_json, resolution_order_json, min_seeders, max_size_bytes,
             excluded_keywords_json, enabled, last_run_at, last_result, created_at, updated_at)
          values (${id}, ${uidOf(req)}, ${mediaId}, ${mediaType}, ${b.ruleId ?? null},
                  ${b.posterPath ?? null},
                  ${finalTitle}, ${b.mediaYear ?? null},
                  ${Number(b.season) || 0}, ${quality}, ${hdr},
                  ${JSON.stringify(audioLangs)}, ${JSON.stringify(resolutionOrder)},
                  ${minSeeders}, ${maxSizeBytes},
                  ${JSON.stringify(excludedKeywords)}, ${b.enabled === false ? 0 : 1},
                  null, null, ${ts}, ${ts})
        `.execute(k.db);
        return { ok: true, id };
      },
    );

    // ---------------------------------------------------------------- 择种规则
    const ruleOf = (r: any) => ({
      id: r.id,
      name: r.name,
      enabled: Number(r.enabled) === 1,
      priority: Number(r.priority),
      quality: r.quality,
      hdr: r.hdr,
      resolutionOrder: JSON.parse(r.resolution_order_json || '[]'),
      audioLangs: JSON.parse(r.audio_langs_json || '[]'),
      minSeeders: Number(r.min_seeders),
      maxSizeBytes: Number(r.max_size_bytes),
      excludedKeywords: JSON.parse(r.excluded_keywords_json || '[]'),
      createdAt: Number(r.created_at),
      updatedAt: Number(r.updated_at),
    });

    app.post(
      '/api/v1/pt/rules/list',
      secured('pt:read', {
        schema: {
          operationId: 'ptRuleList',
          tags: TAG,
          summary: '择种规则列表',
          body: Type.Object({}),
          response: { 200: Type.Object({ items: Type.Array(Type.Any()) }) },
        },
      }),
      async (req: FastifyRequest) => {
        const rows = (
          await sql<any>`
            select * from pt_rules where uid = ${uidOf(req)}
             order by priority asc, created_at asc limit 100
          `.execute(k.db)
        ).rows;
        return { items: rows.map(ruleOf) };
      },
    );

    app.post(
      '/api/v1/pt/rules/add',
      secured('pt:write', {
        schema: {
          operationId: 'ptRuleAdd',
          tags: TAG,
          summary: '新增择种规则',
          body: Type.Object({
            name: Type.String({ minLength: 1, maxLength: 64 }),
            enabled: Type.Optional(Type.Boolean()),
            priority: Type.Optional(Type.Integer({ minimum: 0, maximum: 9999 })),
            quality: Type.Optional(Type.String({ maxLength: 16 })),
            hdr: Type.Optional(Type.String({ maxLength: 16 })),
            resolutionOrder: Type.Optional(Type.Array(Type.String())),
            audioLangs: Type.Optional(Type.Array(Type.String())),
            minSeeders: Type.Optional(Type.Integer({ minimum: 0 })),
            maxSizeBytes: Type.Optional(Type.Integer({ minimum: 0 })),
            excludedKeywords: Type.Optional(Type.Array(Type.String())),
          }),
          response: { 200: Type.Object({ ok: Type.Boolean(), id: Type.String() }) },
        },
      }),
      async (req: FastifyRequest) => {
        const b = (req.body || {}) as any;
        const dl = readDownload();
        const id = crypto.randomBytes(8).toString('base64url');
        const ts = now();
        await sql`
          insert into pt_rules
            (id, uid, name, enabled, priority, quality, hdr, resolution_order_json,
             audio_langs_json, min_seeders, max_size_bytes, excluded_keywords_json,
             created_at, updated_at)
          values (${id}, ${uidOf(req)}, ${String(b.name).slice(0, 64)},
                  ${b.enabled === false ? 0 : 1}, ${Number(b.priority ?? 100)},
                  ${String(b.quality ?? dl.quality)}, ${String(b.hdr ?? dl.hdr)},
                  ${JSON.stringify(b.resolutionOrder ?? [])},
                  ${JSON.stringify(b.audioLangs ?? dl.audioLangs)},
                  ${Number(b.minSeeders ?? dl.minSeeders) || 0},
                  ${Number(b.maxSizeBytes ?? dl.maxSizeBytes) || 0},
                  ${JSON.stringify(b.excludedKeywords ?? dl.excludedKeywords)},
                  ${ts}, ${ts})
        `.execute(k.db);
        return { ok: true, id };
      },
    );

    app.post(
      '/api/v1/pt/rules/update',
      secured('pt:write', {
        schema: {
          operationId: 'ptRuleUpdate',
          tags: TAG,
          summary: '修改择种规则',
          body: Type.Object({
            id: Type.String({ minLength: 1 }),
            name: Type.Optional(Type.String({ maxLength: 64 })),
            enabled: Type.Optional(Type.Boolean()),
            priority: Type.Optional(Type.Integer({ minimum: 0, maximum: 9999 })),
            quality: Type.Optional(Type.String({ maxLength: 16 })),
            hdr: Type.Optional(Type.String({ maxLength: 16 })),
            resolutionOrder: Type.Optional(Type.Array(Type.String())),
            audioLangs: Type.Optional(Type.Array(Type.String())),
            minSeeders: Type.Optional(Type.Integer({ minimum: 0 })),
            maxSizeBytes: Type.Optional(Type.Integer({ minimum: 0 })),
            excludedKeywords: Type.Optional(Type.Array(Type.String())),
          }),
          response: { 200: OkResponse, 404: ErrorResponse },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const b = (req.body || {}) as any;
        const row = (
          await sql<any>`
            select * from pt_rules where id = ${b.id} and uid = ${uidOf(req)}
          `.execute(k.db)
        ).rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'rule not found' });
        await sql`
          update pt_rules
             set name = ${String(b.name ?? row.name).slice(0, 64)},
                 enabled = ${b.enabled === undefined ? row.enabled : b.enabled ? 1 : 0},
                 priority = ${Number(b.priority ?? row.priority)},
                 quality = ${String(b.quality ?? row.quality)},
                 hdr = ${String(b.hdr ?? row.hdr)},
                 resolution_order_json = ${JSON.stringify(b.resolutionOrder ?? JSON.parse(row.resolution_order_json || '[]'))},
                 audio_langs_json = ${JSON.stringify(b.audioLangs ?? JSON.parse(row.audio_langs_json || '[]'))},
                 min_seeders = ${Number(b.minSeeders ?? row.min_seeders) || 0},
                 max_size_bytes = ${Number(b.maxSizeBytes ?? row.max_size_bytes) || 0},
                 excluded_keywords_json = ${JSON.stringify(b.excludedKeywords ?? JSON.parse(row.excluded_keywords_json || '[]'))},
                 updated_at = ${now()}
           where id = ${b.id} and uid = ${uidOf(req)}
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/pt/rules/delete',
      secured('pt:write', {
        schema: {
          operationId: 'ptRuleDelete',
          tags: TAG,
          summary: '删除择种规则',
          body: Type.Object({ id: Type.String({ minLength: 1 }) }),
          response: { 200: OkResponse },
        },
      }),
      async (req: FastifyRequest) => {
        const b = (req.body || {}) as { id?: string };
        await sql`
          delete from pt_rules where id = ${b.id ?? ''} and uid = ${uidOf(req)}
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
        // size / 分辨率从候选缓存补：下载表只存「提交那一刻」的信息，
        // 参考页任务卡还要显示文件名与体积（size_bytes / torrent_name）。
        const rows = (
          await sql<any>`
            select d.*, c.size_bytes, c.seeders, c.resolution
              from pt_downloads d
              left join pt_candidates c
                on c.site_id = d.site_id and c.torrent_id = d.torrent_id
             where d.uid = ${uidOf(req)}
             order by d.created_at desc limit 200
          `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            id: r.id,
            title: r.title,
            torrentName: r.torrent_name ?? r.title,
            status: r.status,
            message: r.message,
            infoHash: r.info_hash ?? null,
            siteId: r.site_id ?? '',
            torrentId: r.torrent_id ?? '',
            candidateId: r.candidate_id == null ? null : String(r.candidate_id),
            rssEntryId: r.rss_entry_id ?? null,
            sizeBytes: r.size_bytes == null ? null : Number(r.size_bytes),
            resolution: r.resolution ?? null,
            canControl: (r.status === 'added' || r.status === 'paused') && !!r.info_hash,
            createdAt: Number(r.created_at),
            updatedAt: Number(r.created_at),
          })),
        };
      },
    );

    /**
     * Transmission 实时任务（一级「下载器」页面用）。
     *
     * 只回传列表需要的字段；海报/片名从台账（pt_downloads → pt_subscriptions.poster_path）
     * 补 —— transmission 自己只有种子名，没有影视元数据。
     */
    app.get(
      '/api/v1/pt/torrents',
      secured('pt:read', {
        schema: {
          operationId: 'ptTorrents',
          tags: TAG,
          summary: 'Transmission 实时任务（下载中 / 暂停 / 做种）',
          response: {
            200: Type.Object({
              ok: Type.Boolean(),
              message: Type.String(),
              /** 内置 transmission Web UI 的入口路径（同源） */
              webPath: Type.String(),
              /** 一次性票据：拼成 `webPath?t=` 打开，内核换 Cookie 后 302 掉 */
              webTicket: Type.String(),
              /** Web UI 静态包是否就位（没 fetch 时为 false） */
              webReady: Type.Boolean(),
              items: Type.Array(
                Type.Object({
                  hash: Type.String(),
                  name: Type.String(),
                  status: Type.Integer(),
                  percent: Type.Number(),
                  rateDownload: Type.Integer(),
                  rateUpload: Type.Integer(),
                  sizeBytes: Type.Integer(),
                  downloadedBytes: Type.Integer(),
                  uploadRatio: Type.Number(),
                  eta: Type.Integer(),
                  addedAt: Type.Integer(),
                  error: Type.String(),
                  downloadDir: Type.String(),
                  title: Type.String(),
                  posterPath: Type.Union([Type.String(), Type.Null()]),
                }),
              ),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        // 内置 Web UI 的票据：12 小时有效，客户端拼成 `<webPath>?t=<ticket>` 打开，
        // 内核校验后换 HttpOnly Cookie（浏览器里的静态页拿不到 JWT）。
        const secret = await resolveSecret(k.paths.dataDir);
        const webTicket = signToken(
          { sub: uidOf(req), scopes: ['pt:read'] },
          secret,
          { ttlSec: 12 * 3600 },
        );
        const webReady = transmissionWebDir() !== '';
        const webPath = '/transmission/web/';
        const configured = transmissionCfg();
        // 注意：走 resolveTransmission（配置 → 内置 daemon → 探测外部），
        // 别直接调 probe，否则内置那条路永远不生效。
        const cfg = await resolveTransmission();
        if (!cfg)
          return {
            ok: false,
            message:
              '没探测到下载器：装一个 transmission（默认 127.0.0.1:9091），或在「发现 → 设置」里填 RPC 地址。',
            webPath,
            webTicket,
            webReady,
            items: [] as any[],
          };
        const res = await torrentList(cfg);
        // 自动发现的地址连不上（下载器被关了）：清掉探测缓存，下次重新找，
        // 别让用户一直看到 "fetch failed"。
        if (!res.ok && !configured) {
          probedCfg = { at: 0, cfg: null };
          return {
            ok: false,
            message:
              '没探测到下载器：装一个 transmission（默认 127.0.0.1:9091），或在「发现 → 设置」里填 RPC 地址。',
            webPath,
            webTicket,
            webReady,
            items: [] as any[],
          };
        }
        const ledger = (
          await sql<any>`
            select d.info_hash, s.poster_path, s.media_title
              from pt_downloads d
              left join pt_subscriptions s on s.id = d.subscription_id
             where d.uid = ${uidOf(req)} and coalesce(d.info_hash, '') <> ''
          `.execute(k.db)
        ).rows;
        const byHash = new Map<string, { posterPath: string | null; title: string }>();
        for (const r of ledger) {
          const h = String(r.info_hash || '');
          if (!h || byHash.has(h)) continue;
          byHash.set(h, {
            posterPath: (r.poster_path as string) ?? null,
            title: String(r.media_title || ''),
          });
        }
        return {
          ok: res.ok,
          // 说清楚在用哪个下载器，否则用户不知道消息从哪来
          message:
            downloaderMode === 'embedded'
              ? `${res.message}（内置下载器 ${cfg.url}）`
              : configured
                ? res.message
                : `${res.message}（自动发现 ${cfg.url}）`,
          webPath,
          webTicket,
          webReady,
          items: res.items.map((t) => {
            const extra = byHash.get(t.hashString);
            return {
              hash: t.hashString,
              name: t.name,
              status: t.status,
              percent: t.percentDone,
              rateDownload: t.rateDownload,
              rateUpload: t.rateUpload,
              sizeBytes: t.totalSize,
              downloadedBytes: t.downloadedEver,
              uploadRatio: t.uploadRatio,
              eta: t.eta,
              addedAt: t.addedDate,
              error: t.errorString,
              downloadDir: t.downloadDir,
              title: extra?.title ?? '',
              posterPath: extra?.posterPath ?? null,
            };
          }),
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
              // 参考页有「重试」：失败/移除后重新加种
              Type.Literal('retry'),
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
        // retry：用原 download_url 重新加种（失败的种子重下，比让人去搜索页重来省事）
        if (b.action === 'retry') {
          const url = String(row.download_url || '');
          if (!url) {
            return reply
              .code(400)
              .send({ error: Err.badRequest, message: 'download url missing for this task' });
          }
          const dl = readDownload();
          const dir = await libraryDir(dl.movieLibraryId);
          const added = await addTorrent(cfg, url, dir ? { downloadDir: dir } : {});
          const nextStatus = added.ok ? 'added' : 'failed';
          await sql`
            update pt_downloads
               set status = ${nextStatus}, message = ${added.message},
                   info_hash = coalesce(${added.hash ?? null}, info_hash)
             where id = ${row.id}
          `.execute(k.db);
          if (!added.ok) {
            return reply.code(400).send({ error: Err.badRequest, message: added.message });
          }
          return { ok: true };
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


    // ------------------------------------------------ 参考实现 1:1：预览 → 提交 → 状态同步
    /** 从榜单快照里补 title / 海报（收藏分区用；快照结构不固定，全部 try/catch） */
    const catalogMeta = async (): Promise<Map<string, any>> => {
      const out = new Map<string, any>();
      try {
        const snaps = (
          await sql<{ payload: string }>`
            select payload from media_catalog order by snapshot_at desc limit 20
          `.execute(k.db)
        ).rows;
        for (const s of snaps) {
          try {
            const parsed = JSON.parse(s.payload);
            const list = Array.isArray(parsed) ? parsed : (parsed?.items ?? []);
            for (const it of list) {
              const id = String(it?.id ?? it?.tmdbId ?? it?.tmdb_id ?? '');
              if (id && !out.has(id)) out.set(id, it);
            }
          } catch { /* 快照结构不固定，跳过这一条 */ }
        }
      } catch { /* 表可能还没建 */ }
      return out;
    };

    // ------------------------------------------------ 收藏自动下载（HTTP 与定时器共用）
    // 「立即扫描」按钮和后台调度都走这里，保证两条路径用的是同一套
    // 下载筛选 + 择种优先级，不会出现「手动扫能下、自动扫乱下第一个」。
    let lastFavoriteScanAt = 0;

    const parseFavoriteMeta = (raw: unknown): Record<string, any> => {
      try {
        const v = typeof raw === 'string' ? JSON.parse(raw) : raw;
        return v && typeof v === 'object' ? (v as Record<string, any>) : {};
      } catch {
        return {};
      }
    };

    const genreNames = (v: unknown): string[] => {
      if (!Array.isArray(v)) return [];
      return v
        .map((g) => (g && typeof g === 'object' ? String((g as any).name ?? '') : String(g ?? '')))
        .map((s) => (/动画/.test(s) ? 'Animation' : s))
        .filter(Boolean);
    };

    /**
     * 扫描一个用户的 watching 收藏：本地已有 → owned；否则
     * 搜索 → 硬过滤（画质/HDR/动画音轨/体积/做种/排除词/标题匹配）
     *      → 按优先级择种（分辨率 → 做种 → 体积 → 发布时间）→ 加种留痕。
     * 没有符合条件的候选时保持 watching，下一轮继续试，不会误标成下载中。
     */
    const scanFavorites = async (
      uid: string,
    ): Promise<{
      scanned: number;
      submitted: number;
      owned: number;
      skipped: number;
      auto_download: boolean;
    }> => {
      const dl = readDownload();
      if (!dl.autoDownload) {
        return { scanned: 0, submitted: 0, owned: 0, skipped: 0, auto_download: false };
      }
      const rows = (
        await sql<any>`
          select * from discover_favorites where uid = ${uid} and state = 'watching'
           order by created_at asc limit 50
        `.execute(k.db)
      ).rows;
      const meta = await catalogMeta();
      const cfg = transmissionCfg();
      const tmdbCfg = normalizeConfig(k.config.get('discover.tmdb'));
      // 规则直接取设置页的实时值（不是订阅表里的快照），改完筛选下一轮就生效。
      const rule: PtRule = {
        maxSizeBytes: dl.maxSizeBytes,
        minSeeders: dl.minSeeders,
        excludedKeywords: dl.excludedKeywords,
        quality: dl.quality as PtRule['quality'],
        hdr: dl.hdr as PtRule['hdr'],
        audioLangs: dl.audioLangs,
        season: 0,
      };
      let submitted = 0;
      let owned = 0;
      let skipped = 0;
      for (const r of rows) {
        try {
          const hit = (
            await sql<any>`
              select 1 from video_items where nfo_tmdb_id = ${Number(r.tmdb_id)} limit 1
            `.execute(k.db)
          ).rows[0];
          if (hit) {
            await sql`
              update discover_favorites set state = 'owned', updated_at = ${now()}
               where uid = ${uid} and media_type = ${r.media_type} and tmdb_id = ${r.tmdb_id}
            `.execute(k.db);
            owned += 1;
            continue;
          }
        } catch { /* video_items 表/列不存在时跳过 owned 判定 */ }

        const snap = meta.get(String(r.tmdb_id)) || {};
        const own = parseFavoriteMeta(r.meta);
        let title = String(snap.title ?? snap.name ?? own.title ?? '').trim();
        let originalTitle = String(
          snap.originalTitle ?? snap.original_title ?? own.originalTitle ?? own.original_title ?? '',
        ).trim();
        let year = String(snap.releaseDate ?? snap.release_date ?? own.releaseDate ?? '').slice(0, 4);
        let genres = genreNames(snap.genres ?? own.genres);
        let originalLanguage = String(
          snap.originalLanguage ?? snap.original_language ?? own.originalLanguage ?? '',
        ).trim();

        // 榜单快照通常没有原名 / 类型 / 原声语言：缺原名会让英文种子全被判
        // TITLE_MISMATCH，缺类型会让「动画音频」门槛失效。抓一次 TMDB 详情写回 meta。
        if (!originalTitle || (dl.audioLangs.length > 0 && (genres.length === 0 || !originalLanguage))) {
          try {
            const mt = String(r.media_type) === 'tv' ? 'tv' : 'movie';
            const d: any = await tmdbGet(tmdbCfg, `/${mt}/${Number(r.tmdb_id)}`, {});
            if (!originalTitle) originalTitle = String(d?.original_title ?? d?.original_name ?? '').trim();
            if (!year) year = String(d?.release_date ?? d?.first_air_date ?? '').slice(0, 4);
            if (!title) title = String(d?.title ?? d?.name ?? '').trim();
            if (genres.length === 0) genres = genreNames(d?.genres);
            if (!originalLanguage) originalLanguage = String(d?.original_language ?? '').trim();
            await sql`
              update discover_favorites set meta = ${JSON.stringify({
                ...own,
                title,
                originalTitle,
                releaseDate: year,
                genres,
                originalLanguage,
              })}
               where uid = ${uid} and media_type = ${r.media_type} and tmdb_id = ${Number(r.tmdb_id)}
            `.execute(k.db);
          } catch {
            // 没配 TMDB Key / 网络不通：动画音轨门槛降级，其余筛选照常生效
          }
        }

        if (!title || !cfg) { skipped += 1; continue; }
        const media: PtMedia = {
          title,
          originalTitle: originalTitle || null,
          year: year || null,
          season: 0,
          genres,
          originalLanguage: originalLanguage || null,
        };
        let results: Array<PtCandidate & { siteId: string; siteName: string }>;
        try {
          results = await searchAll(media, 0);
        } catch (err) {
          skipped += 1;
          k.log.warn({ err: String(err), uid, tmdbId: r.tmdb_id }, 'pt favorite scan search failed');
          continue;
        }
        const picked = selectBest(rule, results, media);
        const c = picked.selected as
          | (PtCandidate & { siteId: string; downloadUrl?: string | null })
          | null;
        if (!c?.downloadUrl) {
          skipped += 1;
          if (results.length > 0) {
            k.log.info(
              { uid, tmdbId: r.tmdb_id, reason: picked.reason },
              'pt favorite scan: candidates all filtered out',
            );
          }
          continue;
        }
        // 电视剧落到剧集库，电影落到电影库（之前一律用电影库）。
        const dir = await libraryDir(
          String(r.media_type) === 'tv' ? dl.tvLibraryId : dl.movieLibraryId,
        );
        const added = await addTorrent(cfg, String(c.downloadUrl), {
          downloadDir: dir || undefined,
        });
        if (!added.ok) { skipped += 1; continue; }
        const id = crypto.randomBytes(8).toString('base64url');
        // 任务卡上同时留「为什么选它」和下载器返回信息，便于回查筛选是否生效。
        const message = `${picked.reason}｜${added.message}`.slice(0, 300);
        await sql`
          insert into pt_downloads
            (id, uid, site_id, torrent_id, title, download_url, info_hash,
             status, message, created_at, idempotency_key)
          values (${id}, ${uid}, ${c.siteId}, ${c.torrentId}, ${c.title},
                  ${c.downloadUrl}, ${added.hash ?? c.infoHash ?? null}, 'added',
                  ${message}, ${now()},
                  ${added.hash ? `ih:${String(added.hash).toLowerCase()}` : `st:${c.siteId}:${c.torrentId}`})
        `.execute(k.db);
        await sql`
          update discover_favorites
             set state = 'downloading', download_task_id = ${id}, updated_at = ${now()}
           where uid = ${uid} and media_type = ${r.media_type} and tmdb_id = ${r.tmdb_id}
        `.execute(k.db);
        submitted += 1;
      }
      return { scanned: rows.length, submitted, owned, skipped, auto_download: true };
    };

    const taskOf = (r: any) => ({
      id: String(r.id ?? ''),
      status: String(r.status ?? ''),
      title: String(r.title ?? ''),
      info_hash: r.info_hash ?? null,
      torrent_name: r.torrent_name ?? null,
      candidate_id: r.candidate_id ?? null,
      create_time: Number(r.created_at || 0),
      message: r.message ?? '',
    });

    /** 预览即「搜索 + 落候选缓存」，不建下载任务；candidate_id 用 pt_candidates 的 rowid */
    app.post(
      '/api/v1/pt/downloads/preview',
      secured('pt:read', {
        schema: {
          operationId: 'ptDownloadPreview',
          tags: TAG,
          summary: '预览候选（搜索并落候选缓存，不建下载任务）',
          body: Type.Object({
            keyword: Type.Optional(Type.String({ maxLength: 200 })),
            title: Type.Optional(Type.String({ maxLength: 200 })),
            originalTitle: Type.Optional(Type.String({ maxLength: 200 })),
            year: Type.Optional(Type.String({ maxLength: 8 })),
            season: Type.Optional(Type.Integer({ minimum: 0, maximum: 100 })),
            /** 发现页按 TMDB id 搜索（关键词为空时用 id 回查标题） */
            mediaId: Type.Optional(Type.Integer({ minimum: 1 })),
            mediaType: Type.Optional(Type.String({ maxLength: 8 })),
          }),
          response: {
            200: Type.Object({
              items: Type.Array(Type.Any()),
              excluded: Type.Array(Type.Any()),
              sites: Type.Array(Type.Any()),
              keyword: Type.String(),
              selected: Type.Any(),
              reason: Type.String(),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const b = (req.body || {}) as {
          keyword?: string; title?: string; originalTitle?: string; year?: string;
          season?: number; mediaId?: number; mediaType?: string;
        };
        let keyword = (b.keyword || b.title || '').trim();
        // 只有 media_id 时回查 TMDB 拿标题/年份（发现页卡片右键「搜索 PT 资源」走这条）
        if (!keyword && b.mediaId) {
          const mediaType = b.mediaType === 'tv' ? 'tv' : 'movie';
          try {
            const cfg = normalizeConfig(k.config.get('discover.tmdb'));
            const detail = await tmdbGet(cfg, `/${mediaType}/${b.mediaId}`);
            keyword = String(detail?.title || detail?.name || '').trim();
            if (!b.originalTitle) {
              (b as any).originalTitle = String(
                detail?.original_title || detail?.original_name || '',
              );
            }
            if (!b.year) {
              const date = String(detail?.release_date || detail?.first_air_date || '');
              if (/^\d{4}/.test(date)) (b as any).year = date.slice(0, 4);
            }
          } catch {
            /* TMDB 不可用时退回空搜索 */
          }
        }
        if (!keyword) {
          return { items: [], excluded: [], sites: [], keyword: '', selected: null, reason: 'keyword required' };
        }
        // 只给了中文关键词时，用 TMDB 反查英文原名 + 年份：
        // 没有原名的话，搜回来的英文标题会被判 TITLE_MISMATCH 全排除（= 搜不到）。
        if (!b.originalTitle) {
          const hit = await tmdbLookup(keyword, b.mediaType === 'tv' ? 'tv' : 'movie');
          if (hit?.originalTitle) {
            b.originalTitle = hit.originalTitle;
            if (!b.year && hit.year) b.year = hit.year;
          }
        }
        const started = now();
        const siteStatus: Array<{ site_id: string; site_name: string; error: string }> = [];
        const results = await searchAll(
          { title: keyword, originalTitle: b.originalTitle, year: b.year },
          Number(b.season) || 0,
          siteStatus,
        );
        // 候选 id 按 (站点, 种子) 精确查：早先按「最近 N 秒」窗口查，
        // 命中搜索缓存时查不到行，下载按钮就没有 candidate_id。
        const keyRows = results.map((c) => sql`(${c.siteId}, ${c.torrentId})`);
        const rows = keyRows.length
          ? (
              await sql<any>`
                select rowid as candidate_id, c.* from pt_candidates c
                 where (c.site_id, c.torrent_id) in (${sql.join(keyRows, sql`, `)})
              `.execute(k.db)
            ).rows
          : [];
        const byKey = new Map<string, any>();
        for (const r of rows) byKey.set(`${r.site_id}:${r.torrent_id}`, r);
        const items = results.map((c) => {
          const r = byKey.get(`${c.siteId}:${c.torrentId}`) || {};
          return {
            candidate_id: Number(r.candidate_id || 0),
            site_id: c.siteId,
            site_name: c.siteName,
            torrent_id: c.torrentId,
            title: c.title,
            size_bytes: c.sizeBytes ?? null,
            seeders: c.seeders ?? null,
            leechers: c.leechers ?? null,
            resolution: c.resolution ?? null,
            info_hash: c.infoHash ?? null,
            detail_url: r.detail_url ?? null,
            published_at: c.publishedAt ?? null,
            download_url: c.downloadUrl ?? null,
            matched_by_id: c.matchedById ?? false,
          };
        });
        // 与自动下载同一套「下载筛选 + 择种优先级」：硬过滤后按
        // 分辨率偏好 → 做种降序 → 体积升序 → 发布时间降序 排序，取第一个为选中。
        // 之前只做硬过滤、items 保持站点返回顺序，selected 就等于「第一个站的第一条」。
        const dl = readDownload();
        const media: PtMedia = {
          title: keyword,
          originalTitle: b.originalTitle ?? null,
          year: b.year ?? null,
          season: Number(b.season) || 0,
        };
        const rule: PtRule = {
          maxSizeBytes: dl.maxSizeBytes,
          minSeeders: dl.minSeeders,
          excludedKeywords: dl.excludedKeywords,
          season: Number(b.season) || 0,
          quality: dl.quality as PtRule['quality'],
          hdr: dl.hdr as PtRule['hdr'],
          audioLangs: dl.audioLangs,
        };
        const candidates: PtCandidate[] = items.map((it) => ({
          siteId: String(it.site_id),
          torrentId: String(it.torrent_id),
          infoHash: it.info_hash ?? null,
          title: String(it.title),
          sizeBytes: it.size_bytes == null ? null : Number(it.size_bytes),
          seeders: it.seeders == null ? null : Number(it.seeders),
          resolution: it.resolution ?? null,
          publishedAt: it.published_at ?? null,
          matchedById: Boolean(it.matched_by_id),
          downloadUrl: it.download_url ?? null,
        }));
        const selection = selectBest(rule, candidates, media);
        const itemByKey = new Map<string, (typeof items)[number]>();
        for (let i = 0; i < candidates.length; i += 1) {
          itemByKey.set(`${candidates[i].siteId}:${candidates[i].torrentId}`, items[i]);
        }
        const keyOf = (c: { siteId: string; torrentId: string }) =>
          `${c.siteId}:${c.torrentId}`;
        const sortedItems = selection.sorted
          .map((c) => itemByKey.get(keyOf(c)))
          .filter((it): it is (typeof items)[number] => it != null);
        const excluded = selection.excluded.map((c) => ({
          ...(itemByKey.get(keyOf(c)) ?? {}),
          excluded_reason: c.excludedReason,
        }));
        return {
          items: sortedItems,
          excluded,
          sites: siteStatus,
          keyword,
          selected: sortedItems.length ? sortedItems[0] : null,
          reason: sortedItems.length === 0 && excluded.length > 0 ? 'all_filtered' : '',
        };
      },
    );

    /** 提交候选 → Transmission；幂等键 ih:<hash> / st:<site>:<torrent> */
    app.post(
      '/api/v1/pt/downloads/submit',
      secured('pt:write', {
        schema: {
          operationId: 'ptDownloadSubmit',
          tags: TAG,
          summary: '提交候选到 Transmission（幂等）',
          body: Type.Object({
            candidateId: Type.Optional(Type.Integer({ minimum: 1 })),
            rssEntryId: Type.Optional(Type.String({ maxLength: 200 })),
            savePath: Type.Optional(Type.String({ maxLength: 500 })),
            paused: Type.Optional(Type.Boolean()),
            season: Type.Optional(Type.Integer({ minimum: 0, maximum: 100 })),
          }),
          response: {
            200: Type.Object({
              task: Type.Any(),
              submitted: Type.Boolean(),
              duplicated: Type.Optional(Type.Boolean()),
            }),
            404: ErrorResponse,
          },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const b = (req.body || {}) as {
          candidateId?: number; rssEntryId?: string; savePath?: string;
          paused?: boolean; season?: number;
        };
        const uid = uidOf(req);
        const candidateId = Number(b.candidateId || 0);
        const rssEntryId = String(b.rssEntryId || '');
        let cand: any = null;
        if (candidateId > 0) {
          cand = (
            await sql<any>`
              select rowid as candidate_id, c.* from pt_candidates c where rowid = ${candidateId}
            `.execute(k.db)
          ).rows[0] ?? null;
        } else if (rssEntryId) {
          const e = (
            await sql<any>`select * from rss_items where guid = ${rssEntryId} limit 1`.execute(k.db)
          ).rows[0];
          if (e) {
            cand = {
              candidate_id: 0, site_id: '', torrent_id: '', title: e.title,
              download_url: e.enclosure_url ?? e.link ?? null,
              info_hash: e.info_hash ?? null, size_bytes: e.size_bytes ?? null,
              feed_id: e.feed_id, guid: e.guid,
            };
          }
        }
        if (!cand) {
          return reply.code(404).send({ error: Err.notFound, message: 'candidate not found' });
        }
        const idem = cand.info_hash
          ? `ih:${String(cand.info_hash).toLowerCase()}`
          : `st:${cand.site_id || 0}:${cand.torrent_id || cand.download_url || rssEntryId}`;
        const existing = (
          await sql<any>`
            select * from pt_downloads where uid = ${uid} and idempotency_key = ${idem} limit 1
          `.execute(k.db)
        ).rows[0];
        if (existing && !['failed', 'removed'].includes(String(existing.status))) {
          return { task: taskOf(existing), submitted: true, duplicated: true };
        }
        const cfg = transmissionCfg();
        const dl = readDownload();
        const downloadDir = (b.savePath || '').trim() ||
          (Number(b.season) > 0
            ? await libraryDir(dl.tvLibraryId)
            : await libraryDir(dl.movieLibraryId));
        let status = 'proposed';
        let message = '未配置 transmission：只给出候选';
        let infoHash: string | null = cand.info_hash ?? null;
        if (cfg && cand.download_url) {
          const added = await addTorrent(cfg, String(cand.download_url), {
            downloadDir: downloadDir || undefined,
          });
          status = added.ok ? 'added' : 'failed';
          message = added.message;
          infoHash = added.hash ?? infoHash;
          if (added.ok && b.paused && infoHash) {
            await torrentAction(cfg, 'stop', infoHash);
            status = 'paused';
          }
        }
        const id = existing?.id || crypto.randomBytes(8).toString('base64url');
        if (existing) {
          await sql`
            update pt_downloads set status = ${status}, info_hash = ${infoHash},
              message = ${message}, created_at = ${now()}
             where id = ${id}
          `.execute(k.db);
        } else {
          await sql`
            insert into pt_downloads
              (id, uid, site_id, torrent_id, title, download_url, info_hash, status,
               message, created_at, candidate_id, rss_entry_id, idempotency_key)
            values (${id}, ${uid}, ${String(cand.site_id || '')}, ${String(cand.torrent_id || '')},
                    ${String(cand.title || '')}, ${cand.download_url ?? null}, ${infoHash},
                    ${status}, ${message}, ${now()},
                    ${candidateId ? String(candidateId) : null},
                    ${rssEntryId || null}, ${idem})
          `.execute(k.db);
        }
        // RSS 条目确认 + 永久台账（删台账后才允许再次下载）
        if (rssEntryId) {
          try {
            await sql`
              update rss_items set state = 'Submitted' where guid = ${rssEntryId}
            `.execute(k.db);
            await sql`
              insert into rss_downloaded
                (id, uid, feed_id, guid, info_hash, title, size_bytes,
                 enclosure_url, download_task_id, created_at)
              values (${crypto.randomBytes(8).toString('base64url')}, ${uid},
                      ${cand.feed_id ?? null}, ${cand.guid ?? rssEntryId}, ${infoHash},
                      ${String(cand.title || '')}, ${cand.size_bytes ?? null},
                      ${cand.download_url ?? null}, ${id}, ${now()})
              on conflict(id) do nothing
            `.execute(k.db);
          } catch { /* RSS 台账表还没建时不影响提交 */ }
        }
        return {
          task: taskOf({ ...cand, id, status, info_hash: infoHash, message, created_at: now() }),
          submitted: status === 'added' || status === 'paused',
          duplicated: false,
        };
      },
    );

    /** 从 Transmission 同步进度；首次完成的下载把收藏 downloading → downloaded */
    app.post(
      '/api/v1/pt/downloads/sync-status',
      secured('pt:write', {
        schema: {
          operationId: 'ptDownloadSyncStatus',
          tags: TAG,
          summary: '同步下载进度与完成状态',
          response: {
            200: Type.Object({
              updated: Type.Integer(),
              finished: Type.Integer(),
              message: Type.Optional(Type.String()),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        const cfg = transmissionCfg();
        if (!cfg) return { updated: 0, finished: 0, message: 'transmission not configured' };
        const rows = (
          await sql<any>`
            select * from pt_downloads where uid = ${uidOf(req)}
              and status in ('added', 'paused', 'downloading')
              and info_hash is not null and info_hash <> '' limit 200
          `.execute(k.db)
        ).rows;
        if (!rows.length) return { updated: 0, finished: 0 };
        const got = await torrentGet(cfg, rows.map((r) => String(r.info_hash)));
        if (!got.ok) return { updated: 0, finished: 0, message: got.message };
        const byHash = new Map(got.items.map((t) => [t.hashString.toLowerCase(), t]));
        let updated = 0;
        let finished = 0;
        const doneIds: string[] = [];
        for (const r of rows) {
          const t = byHash.get(String(r.info_hash).toLowerCase());
          if (!t) continue;
          const status = t.status === 6 || t.percentDone >= 1
            ? 'completed'
            : t.status === 0 ? 'paused' : 'downloading';
          if (status === String(r.status)) continue;
          await sql`update pt_downloads set status = ${status} where id = ${r.id}`.execute(k.db);
          updated += 1;
          if (status === 'completed' && r.status !== 'completed') {
            finished += 1;
            doneIds.push(String(r.id));
          }
        }
        for (const id of doneIds) {
          try {
            await sql`
              update discover_favorites set state = 'downloaded', updated_at = ${now()}
               where download_task_id = ${id} and state = 'downloading'
            `.execute(k.db);
          } catch { /* 迁移未跑时忽略 */ }
        }
        return { updated, finished };
      },
    );

    /** 收藏三态列表：按 state 过滤，标题/海报从榜单快照补 */
    app.get(
      '/api/v1/pt/favorites',
      secured('pt:read', {
        schema: {
          operationId: 'ptFavoriteList',
          tags: TAG,
          summary: '收藏三态列表（watching/downloading/downloaded/owned）',
          querystring: Type.Object({ state: Type.Optional(Type.String({ maxLength: 32 })) }),
          response: { 200: Type.Object({ items: Type.Array(Type.Any()) }) },
        },
      }),
      async (req: FastifyRequest) => {
        const state = String((req.query as { state?: string } | null)?.state || '');
        const all = (
          await sql<any>`
            select * from discover_favorites where uid = ${uidOf(req)}
             order by created_at desc limit 500
          `.execute(k.db)
        ).rows;
        const meta = await catalogMeta();
        // 缺元数据的收藏：抓一次 TMDB 详情写回 meta 列，之后不再请求。
        // 不补的话，「搜索」里收藏的条目（不在榜单快照里）只会显示 `TMDB #123`、没有海报，
        // 用户会以为「收藏了但待下载里没有」（2026-11-10 反馈）。
        const cfg = normalizeConfig(k.config.get('discover.tmdb'));
        const missing = all.filter((r) => !r.meta && !meta.has(String(r.tmdb_id))).slice(0, 12);
        await Promise.all(
          missing.map(async (r) => {
            try {
              const mt = String(r.media_type) === 'tv' ? 'tv' : 'movie';
              const d = await tmdbGet(cfg, `/${mt}/${Number(r.tmdb_id)}`, {});
              const own = {
                title: String(d?.title ?? d?.name ?? '').trim(),
                posterPath: (d?.poster_path as string) ?? null,
                releaseDate: String(d?.release_date ?? d?.first_air_date ?? '').trim(),
              };
              if (!own.title) return;
              r.meta = JSON.stringify(own);
              await sql`
                update discover_favorites set meta = ${r.meta}
                 where uid = ${uidOf(req)} and media_type = ${r.media_type}
                   and tmdb_id = ${Number(r.tmdb_id)}
              `.execute(k.db);
            } catch {
              // 没配 TMDB Key / 网络不通：保持占位标题，不影响列表
            }
          }),
        );
        // 「已下载」卡要显示种子文件名 + 入库时间（参考页 _FavItemCard showDownloadInfo）
        const taskIds = all
          .map((r) => String(r.download_task_id || ''))
          .filter((v) => v.length > 0);
        const taskById = new Map<string, { title: string; updatedAt: number }>();
        for (const id of taskIds) {
          const row = (
            await sql<any>`select id, title, created_at from pt_downloads where id = ${id} limit 1`
              .execute(k.db)
          ).rows[0];
          if (row) {
            taskById.set(id, {
              title: String(row.title || ''),
              updatedAt: Number(row.created_at || 0),
            });
          }
        }
        const items = all
          .filter((r) => !state || String(r.state || 'watching') === state)
          .map((r) => {
            const m = meta.get(String(r.tmdb_id)) || {};
            let own: Record<string, any> = {};
            try {
              own = r.meta ? JSON.parse(String(r.meta)) : {};
            } catch {
              own = {};
            }
            const task = taskById.get(String(r.download_task_id || ''));
            return {
              id: Number(r.tmdb_id),
              media_id: Number(r.tmdb_id),
              tmdb_id: Number(r.tmdb_id),
              media_type: r.media_type,
              title: own.title || m.title || m.name || `TMDB #${r.tmdb_id}`,
              poster_path: own.posterPath ?? m.posterPath ?? m.poster_path ?? null,
              release_date: own.releaseDate || m.releaseDate || m.release_date || null,
              state: String(r.state || 'watching'),
              download_task_id: r.download_task_id ?? null,
              torrent_name: task?.title ?? '',
              task_updated_at: task?.updatedAt ? task.updatedAt : null,
              create_time: Number(r.created_at || 0),
            };
          });
        return { items };
      },
    );

    /** 扫描 watching 收藏：命中本地影视库 → owned，否则搜索并自动加种 */
    app.post(
      '/api/v1/pt/favorites/scan',
      secured('pt:write', {
        schema: {
          operationId: 'ptFavoriteScan',
          tags: TAG,
          summary: '扫描待下载收藏并自动提交',
          response: {
            200: Type.Object({
              scanned: Type.Integer(), submitted: Type.Integer(),
              owned: Type.Integer(), skipped: Type.Integer(),
              auto_download: Type.Boolean(),
            }),
          },
        },
      }),
      async (req: FastifyRequest) => {
        // 手动扫过就记时间，别让后台心跳紧接着又扫一遍。
        lastFavoriteScanAt = now();
        return scanFavorites(uidOf(req));
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

    // 后台任务：收藏自动下载扫描（覆盖所有有 watching 收藏的账号）。
    // 心跳只负责入队，队列负责串行、失败重试与重启后不丢当轮。
    k.tasks.register('pt.favorite-scan', async () => {
      const uids = (
        await sql<{ uid: string }>`
          select distinct uid from discover_favorites where state = 'watching'
        `.execute(k.db)
      ).rows.map((r) => String(r.uid || ''));
      const total = { scanned: 0, submitted: 0, owned: 0, skipped: 0 };
      for (const uid of uids.filter(Boolean)) {
        const r = await scanFavorites(uid);
        total.scanned += r.scanned;
        total.submitted += r.submitted;
        total.owned += r.owned;
        total.skipped += r.skipped;
      }
      return total;
    });

    // 调度：每分钟心跳检查一次，订阅与收藏扫描都按「下载筛选」的间隔判断谁到期，
    // 改设置后无需重启。另外：
    //  - 自动下载关闭时收藏扫描整体跳过；
    //  - 新收藏（created_at 晚于上次扫描）立刻触发一轮，不必干等一整个间隔；
    //  - 启动 15s 先跑一轮，避免新收藏要等默认 360 分钟。
    const tick = async () => {
      try {
        const dl = readDownload();
        const cutoff = now() - dl.scanIntervalMin * 60;
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

        if (dl.autoDownload) {
          const fresh = lastFavoriteScanAt > 0
            ? (
                await sql<any>`
                  select 1 from discover_favorites
                   where state = 'watching' and created_at > ${lastFavoriteScanAt} limit 1
                `.execute(k.db)
              ).rows[0]
            : null;
          if (lastFavoriteScanAt <= 0 || lastFavoriteScanAt <= cutoff || fresh) {
            lastFavoriteScanAt = now();
            try {
              await k.tasks.enqueueIfIdle('pt.favorite-scan', {}, { maxAttempts: 1 });
            } catch (err) {
              k.log.warn({ err: String(err) }, 'pt favorite scan enqueue failed');
            }
          }
        }
      } catch (err) {
        k.log.warn({ err: String(err) }, 'pt scheduler tick failed');
      }
    };
    const timer = setInterval(() => {
      void tick();
    }, 60_000);
    timer.unref?.();
    const bootTimer = setTimeout(() => {
      void tick();
    }, 15_000);
    bootTimer.unref?.();
    app.addHook('onClose', async () => {
      clearInterval(timer);
      clearTimeout(bootTimer);
    });
  },
};
