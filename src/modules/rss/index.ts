import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { addTorrent } from '../pt/transmission';
import { fetchTorrentBytes } from '../pt/mteam';
import {
  defaultDownloadDir,
  libraryOfDir,
  normalizeDir,
  resolveTransmission,
} from '../pt/shared';
import type { ServerModule } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';

/**
 * SP3-11 的 RSS 子集（transmission / PT 依赖外部 BT 客户端，未纳入）。
 *
 *   POST /api/v1/rss/feeds            订阅（url 或直接给 xml，便于内网/离线）
 *   GET  /api/v1/rss/feeds            列表
 *   POST /api/v1/rss/feeds/refresh    刷新（抓取或解析传入 xml）
 *   GET  /api/v1/rss/items            条目（按发布时间倒序）
 *   POST /api/v1/rss/feeds/remove     取消订阅（级联删条目）
 *
 * 解析器只处理 RSS 2.0 的常见字段（title/link/guid/pubDate/description），
 * 不引入 XML 依赖；生产环境可在后续替换为流式解析器。
 */
const TAG = ['rss'];
const MAX_XML = 8 * 1024 * 1024;

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const AddBody = Type.Object({
  url: Type.Optional(Type.String({ maxLength: 2048 })),
  xml: Type.Optional(Type.String({ maxLength: MAX_XML })),
  title: Type.Optional(Type.String({ maxLength: 200 })),
  /** 下载目录（服务端相对路径，空 = 用「下载设置」里的默认目录） */
  savePath: Type.Optional(Type.String({ maxLength: 512 })),
  /** true = 命中就开下；false = 只加种、任务保持暂停 */
  immediate: Type.Optional(Type.Boolean()),
});

const FeedItem = Type.Object({
  id: Type.String(),
  url: Type.String(),
  title: Type.String(),
  lastFetch: Type.Union([Type.Integer(), Type.Null()]),
  createdAt: Type.Integer(),
  autoDownload: Type.Boolean(),
  /** 参考页卡片标题用 name（没有就用 title） */
  name: Type.String(),
  /** 打码地址（只露域名 + 前几位），参考页副标题显示这个 */
  urlMasked: Type.String(),
  /** 最近一次抓取是否成功（lastFetch 有值即视为 ok） */
  lastFetchStatus: Type.String(),
  /** 该源的下载目录（空 = 默认目录） */
  savePath: Type.String(),
  /** true = 立即下载；false = 只加种、暂停 */
  immediate: Type.Boolean(),
});

/** `https://a.b.com/path?token=xxx` → `a.b.com/path?••••`：别把私有 RSS token 打到界面上 */
function maskUrl(raw: string): string {
  try {
    const u = new URL(raw);
    const path = u.pathname.length > 24 ? `${u.pathname.slice(0, 24)}…` : u.pathname;
    return `${u.host}${path}${u.search ? '?••••' : ''}`;
  } catch {
    return raw.length > 40 ? `${raw.slice(0, 40)}…` : raw;
  }
}

const FeedListResponse = Type.Object({ items: Type.Array(FeedItem) });

const RefreshBody = Type.Object({
  id: Type.Optional(Type.String()),
  url: Type.Optional(Type.String({ maxLength: 2048 })),
  xml: Type.Optional(Type.String({ maxLength: MAX_XML })),
});

const RefreshResponse = Type.Object({
  fed: Type.Integer(),
  added: Type.Integer(),
  skipped: Type.Integer(),
});

const RssEntry = Type.Object({
  guid: Type.String(),
  feedId: Type.String(),
  feedTitle: Type.String(),
  title: Type.String(),
  link: Type.String(),
  published: Type.Union([Type.Integer(), Type.Null()]),
  summary: Type.String(),
  state: Type.String(),
});

const ItemsResponse = Type.Object({ items: Type.Array(RssEntry), total: Type.Integer() });

const RuleItem = Type.Object({
  id: Type.String(),
  feedId: Type.String(),
  feedTitle: Type.String(),
  titleRegex: Type.String(),
  enabled: Type.Boolean(),
  lastRunAt: Type.Union([Type.Integer(), Type.Null()]),
  createdAt: Type.Integer(),
});
const RuleListResponse = Type.Object({ items: Type.Array(RuleItem) });
const RuleUpsertBody = Type.Object({
  id: Type.Optional(Type.String()),
  feedId: Type.String({ minLength: 1, maxLength: 64 }),
  titleRegex: Type.String({ minLength: 1, maxLength: 200 }),
  enabled: Type.Optional(Type.Boolean()),
});
const RuleRunResponse = Type.Object({
  matched: Type.Integer(),
  created: Type.Integer(),
});

const IdBody = Type.Object({ id: Type.String({ minLength: 1 }) });
const OkResponse = Type.Object({ ok: Type.Boolean() });

// ---- 参考实现 影视发现 1:1 兼容：条目状态 / 下载台账 / feed 自动下载
const EntryActionBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  action: Type.Union([Type.Literal('confirm'), Type.Literal('reject')]),
});
const EntryActionResponse = Type.Object({
  ok: Type.Boolean(),
  state: Type.String(),
  autoSubmitted: Type.Boolean(),
});

const DownloadedQuery = Type.Object({
  keyword: Type.Optional(Type.String()),
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 2000 })),
});
const DownloadedItem = Type.Object({
  id: Type.String(),
  feedId: Type.String(),
  guid: Type.String(),
  infoHash: Type.String(),
  title: Type.String(),
  sizeBytes: Type.Integer(),
  enclosureUrl: Type.String(),
  downloadTaskId: Type.String(),
  createTime: Type.Integer(),
});
const DownloadedListResponse = Type.Object({ items: Type.Array(DownloadedItem) });
const DownloadedDeleteResponse = Type.Object({ ok: Type.Boolean(), deleted: Type.Boolean() });
const DownloadedClearResponse = Type.Object({ ok: Type.Boolean(), deleted: Type.Integer() });
const FeedAutoDownloadBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  enabled: Type.Boolean(),
});

interface ParsedItem {
  guid: string;
  title: string;
  link: string;
  published: number | null;
  summary: string;
  /** 种子直链：`<enclosure url>`，其次 torznab 的 `<link>`、magnet */
  enclosureUrl: string;
  sizeBytes: number | null;
}

function decodeEntities(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/&amp;/g, '&')
    .trim();
}

function tag(block: string, name: string): string {
  const m = new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, 'i').exec(block);
  return m ? decodeEntities(m[1]) : '';
}

function stripHtml(s: string): string {
  return decodeEntities(s.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

/**
 * 从 `<item>` 里取种子地址与体积。
 *
 * PT / BT 站的 RSS 有两种写法：
 * - RSS 2.0 标准：`<enclosure url="..." length="..." type="application/x-bittorrent"/>`
 * - torznab / Jackett：`<link>https://.../download.php?id=1</link>` 本身就是种子直链
 * 以前完全没解析 enclosure，`rss_items.enclosure_url` 一直是空，
 * 于是「自动下载」永远筛不到条目、「确认」也只是改状态、什么都不下。
 */
function torrentOf(block: string, link: string): { url: string; size: number | null } {
  const enc = /<enclosure\b([^>]*)\/?>/i.exec(block);
  if (enc) {
    const attrs = enc[1] || '';
    const url = /url\s*=\s*["']([^"']+)["']/i.exec(attrs)?.[1] || '';
    const len = Number(/length\s*=\s*["'](\d+)["']/i.exec(attrs)?.[1] || 0);
    if (url) return { url: decodeEntities(url), size: len > 0 ? len : null };
  }
  // 没有 enclosure 时，link 是 .torrent / magnet / 常见下载直链就当种子地址
  const guess = String(link || '').trim();
  if (/^magnet:/i.test(guess) || /\.torrent(\?|$)/i.test(guess) || /\/download\b/i.test(guess)) {
    return { url: guess, size: null };
  }
  // M-Team / NexusPHP 的 guid 有时直接就是下载地址
  if (/^https?:\/\/[^/]+\/.*download/i.test(guess)) return { url: guess, size: null };
  return { url: '', size: null };
}

export function parseRss(xml: string): { title: string; items: ParsedItem[] } {
  const channel = /<channel[^>]*>([\s\S]*?)<\/channel>/i.exec(xml);
  const channelBlock = channel ? channel[1] : xml;
  const title = tag(channelBlock.replace(/<item[\s\S]*?<\/item>/gi, ''), 'title') || 'Untitled feed';

  const items: ParsedItem[] = [];
  const re = /<item[^>]*>([\s\S]*?)<\/item>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const block = m[1];
    const link = tag(block, 'link');
    const guid = tag(block, 'guid') || link || tag(block, 'title');
    if (!guid) continue;
    const dateStr = tag(block, 'pubDate') || tag(block, 'date');
    const ts = dateStr ? Date.parse(dateStr) : NaN;
    const t = torrentOf(block, link);
    items.push({
      guid,
      title: tag(block, 'title') || '(untitled)',
      link,
      published: Number.isNaN(ts) ? null : Math.floor(ts / 1000),
      summary: stripHtml(tag(block, 'description') || tag(block, 'summary')).slice(0, 500),
      enclosureUrl: t.url,
      sizeBytes: t.size,
    });
  }
  return { title, items };
}

async function fetchXml(url: string): Promise<string> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw Object.assign(new Error('invalid url'), { code: 'E_URL' });
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw Object.assign(new Error(`unsupported protocol: ${parsed.protocol}`), { code: 'E_URL' });
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10_000);
  try {
    const res = await fetch(url, { signal: controller.signal, headers: { 'user-agent': 'ColaNasOs/0.1' } });
    if (!res.ok) throw Object.assign(new Error(`http ${res.status}`), { code: 'E_FETCH' });
    const text = await res.text();
    if (text.length > MAX_XML) throw Object.assign(new Error('feed too large'), { code: 'E_FETCH' });
    return text;
  } finally {
    clearTimeout(timer);
  }
}

export const rss: ServerModule = {
  id: 'rss',
  prefix: '/api/v1/rss',
  permissions: ['rss:read', 'rss:write'],

  migrations: [
    {
      id: '004_rss_feeds',
      async up(db) {
        await sql`
          create table if not exists rss_feeds (
            id text primary key,
            url text not null,
            title text not null default '',
            last_fetch integer,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists rss_items (
            feed_id text not null,
            guid text not null,
            title text not null default '',
            link text not null default '',
            published integer,
            summary text not null default '',
            primary key (feed_id, guid)
          )
        `.execute(db);
        await sql`create index if not exists idx_rss_items_pub on rss_items(published desc)`.execute(db);
      },
    },
    {
      id: '104_rss_rules',
      async up(db) {
        // RSS 自动下载：命中标题正则的新条目 → 自动建 PT 订阅（后续由 PT 调度搜索+加种）
        await sql`
          create table if not exists rss_rules (
            id text primary key,
            uid text not null default '',
            feed_id text not null,
            title_regex text not null,
            enabled integer not null default 1,
            last_run_at integer,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists rss_rule_hits (
            rule_id text not null,
            guid text not null,
            created_at integer not null,
            primary key (rule_id, guid)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_rss_rules_uid on rss_rules (uid, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '155_rss_compat',
      async up(db) {
        // 逐列守卫补列：SQLite 的 add column 允许「带 default 的 not null」
        const itemCols = await sql<{ name: string }>`pragma table_info(rss_items)`.execute(db);
        const hasItem = (name: string) => itemCols.rows.some((c) => c.name === name);
        if (!hasItem('state')) {
          await sql`alter table rss_items add column state text not null default 'Pending'`.execute(db);
        }
        if (!hasItem('size_bytes')) {
          await sql`alter table rss_items add column size_bytes integer`.execute(db);
        }
        if (!hasItem('info_hash')) {
          await sql`alter table rss_items add column info_hash text`.execute(db);
        }
        if (!hasItem('enclosure_url')) {
          await sql`alter table rss_items add column enclosure_url text`.execute(db);
        }
        if (!hasItem('state_updated_at')) {
          await sql`alter table rss_items add column state_updated_at integer`.execute(db);
        }

        const feedCols = await sql<{ name: string }>`pragma table_info(rss_feeds)`.execute(db);
        if (!feedCols.rows.some((c) => c.name === 'auto_download')) {
          await sql`alter table rss_feeds add column auto_download integer not null default 0`.execute(db);
        }

        await sql`
          create table if not exists rss_downloaded (
            id text primary key,
            uid text not null default '',
            feed_id text,
            guid text,
            info_hash text,
            title text,
            size_bytes integer,
            enclosure_url text,
            download_task_id text,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_rss_downloaded_uid_created on rss_downloaded (uid, created_at desc)
        `.execute(db);
        await sql`
          create index if not exists idx_rss_downloaded_guid on rss_downloaded (guid)
        `.execute(db);
      },
    },
    {
      // 每个 RSS 源自己的下载目标：目录 + 是否立即开始。
      // 之前 feed 级只有 auto_download 开关，下载目录全靠全局设置，
      // 「这个源下到剧集目录、那个源下到电影目录」做不到（2026-11-10 反馈）。
      id: '172_rss_feed_download_target',
      async up(db) {
        const cols = await sql<{ name: string }>`pragma table_info(rss_feeds)`.execute(db);
        const has = (name: string) => cols.rows.some((c) => c.name === name);
        if (!has('save_path')) {
          await sql`alter table rss_feeds add column save_path text`.execute(db);
        }
        if (!has('paused_default')) {
          await sql`alter table rss_feeds add column paused_default integer not null default 0`.execute(db);
        }
      },
    },
  ],

  async register(app, k) {
    const now = () => Math.floor(Date.now() / 1000);

    /** 解析结果落库（同 guid 幂等跳过）：add（内联 xml）与 refresh 共用 */
    const insertItems = async (
      feedId: string,
      items: ReturnType<typeof parseRss>['items'],
    ): Promise<{ added: number; skipped: number }> => {
      let added = 0;
      let skipped = 0;
      for (const it of items) {
        const existing = (
          await sql<{ enclosure_url: string | null; size_bytes: number | null }>`
            select enclosure_url, size_bytes from rss_items
             where feed_id = ${feedId} and guid = ${it.guid}
          `.execute(k.db)
        ).rows[0];
        if (existing) {
          // 老条目（解析器还不认 enclosure 时存下的）补一次种子地址，
          // 否则「确认下载」会一直提示没有种子地址。
          if (!existing.enclosure_url && it.enclosureUrl) {
            await sql`
              update rss_items
                 set enclosure_url = ${it.enclosureUrl},
                     size_bytes = coalesce(size_bytes, ${it.sizeBytes ?? null})
               where feed_id = ${feedId} and guid = ${it.guid}
            `.execute(k.db);
          }
          skipped += 1;
          continue;
        }
        await sql`
          insert into rss_items
            (feed_id, guid, title, link, published, summary, enclosure_url, size_bytes)
          values (${feedId}, ${it.guid}, ${it.title}, ${it.link}, ${it.published},
                  ${it.summary}, ${it.enclosureUrl || null}, ${it.sizeBytes ?? null})
        `.execute(k.db);
        added += 1;
      }
      return { added, skipped };
    };

    /**
     * 按该源自己的设置加种：目录用 feed.save_path（空 = 下载设置里的默认目录），
     * paused 用 feed.paused_default。返回 hash（成功才写 rss_downloaded），失败返回 ''。
     *
     * 两个关键点：
     * - 下载器走 `resolveTransmission()`（手填 RPC → 随包内置 daemon → 本机探测）。
     *   以前只读 `pt.transmission`，没手填地址就永远「未配置」，RSS 一个种子都下不动。
     * - http(s) 直链由**内核**先抓成 .torrent 再以 metainfo 提交：RSS 地址一般自带
     *   passkey，但站点会挡下载器 UA / 要求 Referer，直接甩给 transmission 常拿到
     *   错误页（"invalid or corrupt torrent file"）。
     */
    const submitFeedTorrent = async (
      feed: { id?: string | null; save_path?: string | null; paused_default?: number | null },
      item: { url: string; guid: string; title?: string | null; uid: string },
    ): Promise<{ hash: string; message: string }> => {
      const url = String(item.url || '').trim();
      if (!url) return { hash: '', message: '该条目没有种子地址' };
      const cfg = await resolveTransmission(k);
      if (!cfg) {
        return { hash: '', message: '没探测到下载器（内置 transmission 未能启动）' };
      }
      // 目录：源里选的优先，没选就用「下载设置」里的电影库 / 剧集库根
      const dir = normalizeDir(String(feed.save_path || '')) || (await defaultDownloadDir(k));
      const paused = Number(feed.paused_default || 0) === 1;
      const opts = { downloadDir: dir || undefined, paused };

      let res;
      if (/^magnet:/i.test(url)) {
        res = await addTorrent(cfg, url, opts);
      } else {
        const bytes = await fetchTorrentBytes({ url });
        res = bytes
          ? await addTorrent(cfg, url, { ...opts, metainfo: bytes.toString('base64') })
          : // 抓不到（响应不是 bencode）就退回让下载器自己下，失败原因会原样带回
            await addTorrent(cfg, url, opts);
      }
      if (!res.ok) return { hash: '', message: res.message };
      const hash = String(res.hash || '');
      // 顺手在 PT 台账里也记一条：下载完成时心跳会自动归档进影视库，
      // 发现页「任务」里也能看到这个 RSS 任务的进度。
      // 幂等键用 rss: 前缀，避免和 PT 手动下载的 ih:<hash> 撞唯一索引。
      try {
        const lib = await libraryOfDir(k, dir);
        const idem = `rss:${String(feed.id || '')}:${item.guid}`;
        const dup = (
          await sql<any>`select id from pt_downloads where idempotency_key = ${idem} limit 1`
            .execute(k.db)
        ).rows[0];
        if (!dup) {
          await sql`
            insert into pt_downloads
              (id, uid, site_id, torrent_id, title, download_url, info_hash, status,
               message, created_at, idempotency_key, media_id, media_type,
               library_id, save_path)
            values (${crypto.randomBytes(8).toString('base64url')}, ${String(item.uid)},
                    'rss', ${item.guid}, ${String(item.title || '')}, ${url}, ${hash || null},
                    ${paused ? 'paused' : 'added'}, 'RSS 自动下载', ${now()}, ${idem},
                    null, ${lib ? (lib.type === 'tv' ? 'tv' : 'movie') : null},
                    ${lib?.id || null}, ${dir || null})
          `.execute(k.db);
        }
      } catch { /* 台账写失败不影响加种 */ }
      return { hash, message: res.message };
    };

    app.post(
      '/api/v1/rss/feeds',
      secured('rss:write', {
        schema: {
          operationId: 'rssAddFeed',
          tags: TAG,
          summary: '添加订阅（url 或直接给 xml）',
          body: AddBody,
          response: { 200: FeedItem, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { url?: string; xml?: string; title?: string };
        if (!body.url && !body.xml) {
          return reply.code(400).send({ error: Err.badRequest, message: 'url or xml required' });
        }

        let title = body.title || '';
        let parsedXml: ReturnType<typeof parseRss> | null = null;
        if (body.xml) {
          try {
            parsedXml = parseRss(body.xml);
            title = title || parsedXml.title;
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'xml parse failed' });
          }
        }
        if (!title && body.url) {
          try {
            title = new URL(body.url).host;
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'invalid url' });
          }
        }

        const id = crypto.randomBytes(8).toString('base64url');
        const savePath = String((body as { savePath?: string }).savePath || '').trim();
        const pausedDefault = (body as { immediate?: boolean }).immediate === false ? 1 : 0;
        await sql`
          insert into rss_feeds (id, url, title, last_fetch, created_at, save_path, paused_default)
          values (${id}, ${body.url || ''}, ${title}, ${null}, ${now()},
                  ${savePath || null}, ${pausedDefault})
        `.execute(k.db);

        // 内联 xml 的订阅没有 url 可供后续抓取，因此添加时就把条目落库
        if (parsedXml) await insertItems(id, parsedXml.items);

        // 复用 FeedItem schema：**所有必填字段都要给**（少一个就 500，P3 栽过）
        return {
          id,
          url: body.url || '',
          title,
          name: String(title || body.url || ''),
          urlMasked: maskUrl(String(body.url || '')),
          lastFetchStatus: '',
          lastFetch: null,
          createdAt: now(),
          autoDownload: false,
          savePath,
          immediate: pausedDefault === 0,
        };
      },
    );

    app.get(
      '/api/v1/rss/feeds',
      secured('rss:read', {
        schema: {
          operationId: 'rssListFeeds',
          tags: TAG,
          summary: '订阅列表',
          response: { 200: FeedListResponse },
        },
      }),
      async () => {
        const res = await sql<
          {
            id: string;
            url: string;
            title: string;
            last_fetch: number | null;
            created_at: number;
            auto_download?: number | null;
            save_path?: string | null;
            paused_default?: number | null;
          }
        >`
          select * from rss_feeds order by created_at desc
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            url: r.url,
            title: r.title,
            name: String(r.title || r.url || ''),
            urlMasked: maskUrl(String(r.url || '')),
            lastFetchStatus: r.last_fetch ? 'ok' : '',
            lastFetch: r.last_fetch,
            createdAt: r.created_at,
            autoDownload: Number(r.auto_download || 0) === 1,
            savePath: String(r.save_path || ''),
            immediate: Number(r.paused_default || 0) === 0,
          })),
        };
      },
    );

    app.post(
      '/api/v1/rss/feeds/refresh',
      secured('rss:write', {
        schema: {
          operationId: 'rssRefresh',
          tags: TAG,
          summary: '刷新订阅（抓取 url 或解析传入 xml）',
          body: RefreshBody,
          response: { 200: RefreshResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; url?: string; xml?: string };
        const rows = body.id
          ? (await sql<any>`select * from rss_feeds where id = ${body.id}`.execute(k.db)).rows
          : (await sql<any>`select * from rss_feeds`.execute(k.db)).rows;

        if (body.id && rows.length === 0) {
          return reply.code(404).send({ error: Err.notFound, message: 'feed not found' });
        }

        // 共用 xml：显式传入优先，其次显式 url；逐 feed 抓取时各自用 url
        let sharedXml: string | null = body.xml || null;
        if (!sharedXml && body.url) {
          try {
            sharedXml = await fetchXml(body.url);
          } catch (err) {
            return reply.code(400).send({ error: Err.badRequest, message: String((err as Error).message) });
          }
        }

        let added = 0;
        let skipped = 0;
        let fed = 0;
        for (const feed of body.id ? [rows[0]] : rows) {
          if (!feed) continue;
          let xml = sharedXml;
          if (!xml) {
            if (!feed.url) continue; // 无 url 且未传 xml（内联订阅）：跳过，不让整批失败
            try {
              xml = await fetchXml(feed.url);
            } catch {
              continue;
            }
          }

          let parsed: ReturnType<typeof parseRss>;
          try {
            parsed = parseRss(xml);
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'xml parse failed' });
          }

          const r = await insertItems(feed.id, parsed.items);
          added += r.added;
          skipped += r.skipped;
          fed += 1;
          await sql`update rss_feeds set last_fetch = ${now()} where id = ${feed.id}`.execute(k.db);

          // 该源开了「自动下载」：把还没处理过、带种子地址的新条目直接加种。
          // 目录与该源自己的「立即下载」设置一致（不加 paused 就是只挂种子）。
          if (Number(feed.auto_download || 0) === 1) {
            const uid = String(req.user?.sub || '');
            const pending = (
              await sql<any>`
                select i.guid, i.title, i.size_bytes, i.info_hash, i.enclosure_url
                  from rss_items i
                 where i.feed_id = ${feed.id}
                   and coalesce(i.enclosure_url, '') <> ''
                   and coalesce(i.state, 'Pending') = 'Pending'
                   and not exists (
                     select 1 from rss_downloaded d
                      where d.feed_id = i.feed_id and d.guid = i.guid
                   )
                 order by i.published desc
                 limit 10
              `.execute(k.db)
            ).rows;
            for (const it of pending) {
              const sent = await submitFeedTorrent(feed, {
                url: String(it.enclosure_url),
                guid: String(it.guid),
                title: String(it.title || ''),
                uid,
              });
              if (!sent.hash) {
                // 失败必须留痕：否则表现是「开了自动下载但什么都不发生」，
                // 页面和日志都查不出原因（2026-11-10 排查过一轮）。
                k.log.warn(
                  { feedId: feed.id, guid: it.guid, message: sent.message },
                  'rss auto download failed',
                );
                continue;
              }
              await sql`
                insert into rss_downloaded
                  (id, uid, feed_id, guid, info_hash, title, size_bytes,
                   enclosure_url, download_task_id, created_at)
                values (${crypto.randomBytes(8).toString('base64url')}, ${uid},
                        ${feed.id}, ${it.guid}, ${it.info_hash ?? sent.hash},
                        ${it.title ?? null}, ${it.size_bytes ?? null},
                        ${it.enclosure_url}, ${sent.hash}, ${now()})
              `.execute(k.db);
              await sql`
                update rss_items set state = 'Confirmed', state_updated_at = ${now()}
                 where feed_id = ${feed.id} and guid = ${it.guid}
              `.execute(k.db);
            }
          }
        }

        if (fed === 0) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: 'no feed can be refreshed (missing url)' });
        }

        return { fed, added, skipped };
      },
    );

    app.get(
      '/api/v1/rss/items',
      secured('rss:read', {
        schema: {
          operationId: 'rssItems',
          tags: TAG,
          summary: '条目列表（发布时间倒序）',
          querystring: Type.Object({
            feedId: Type.Optional(Type.String()),
            state: Type.Optional(Type.String()),
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500 })),
          }),
          response: { 200: ItemsResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { feedId?: string; state?: string; limit?: number };
        const limit = Math.min(Math.max(q.limit ?? 50, 1), 500);
        const feedId = q.feedId ?? null;
        const state = q.state ?? null;
        const res = await sql<Record<string, string | number | null>>`
          select i.guid, i.feed_id, f.title as feed_title, i.title, i.link, i.published, i.summary, i.state
          from rss_items i join rss_feeds f on f.id = i.feed_id
          where (${feedId} is null or i.feed_id = ${feedId})
            and (${state} is null or i.state = ${state})
          order by i.published desc, i.title limit ${limit}
        `.execute(k.db);

        const count = await sql<{ n: number }>`
          select count(*) as n from rss_items
          where (${feedId} is null or feed_id = ${feedId})
            and (${state} is null or state = ${state})
        `.execute(k.db);

        return {
          items: res.rows.map((r) => ({
            guid: String(r.guid),
            feedId: String(r.feed_id),
            feedTitle: String(r.feed_title ?? ''),
            title: String(r.title ?? ''),
            link: String(r.link ?? ''),
            published: r.published === null ? null : Number(r.published),
            summary: String(r.summary ?? ''),
            state: String(r.state ?? 'Pending'),
          })),
          total: count.rows[0]?.n ?? 0,
        };
      },
    );

    app.post(
      '/api/v1/rss/feeds/remove',
      secured('rss:write', {
        schema: {
          operationId: 'rssRemoveFeed',
          tags: TAG,
          summary: '取消订阅（级联删条目）',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        if (!body.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
        await sql`delete from rss_items where feed_id = ${body.id}`.execute(k.db);
        await sql`delete from rss_feeds where id = ${body.id}`.execute(k.db);
        return { ok: true };
      },
    );

    // ------------------------------------------------ 参考实现 影视发现兼容
    app.post(
      '/api/v1/rss/entries/action',
      secured('rss:write', {
        schema: {
          operationId: 'rssEntryAction',
          tags: TAG,
          summary: '确认 / 拒绝 RSS 条目（兼容 guid 或 feedId:guid）',
          body: EntryActionBody,
          response: { 200: EntryActionResponse },
        },
      }),
      async (req) => {
        const uid = String(req.user?.sub || '');
        const b = (req.body || {}) as { id?: string; action?: 'confirm' | 'reject' };
        const id = b.id || '';
        const state = b.action === 'reject' ? 'Rejected' : 'Confirmed';

        // rss_items 主键是 (feed_id, guid)，没有单列 id，也没法按 uid 过滤：
        // 优先把整个 id 当 guid 全表查，未命中再按 feedId:guid 拆复合键
        let rows = (
          await sql<any>`select * from rss_items where guid = ${id}`.execute(k.db)
        ).rows;
        if (rows.length === 0) {
          const sep = id.indexOf(':');
          if (sep > 0) {
            rows = (
              await sql<any>`
                select * from rss_items
                 where feed_id = ${id.slice(0, sep)} and guid = ${id.slice(sep + 1)}
              `.execute(k.db)
            ).rows;
          }
        }

        for (const row of rows) {
          await sql`
            update rss_items set state = ${state}, state_updated_at = ${now()}
             where feed_id = ${row.feed_id} and guid = ${row.guid}
          `.execute(k.db);
        }

        let autoSubmitted = false;
        if (b.action === 'confirm') {
          for (const row of rows) {
            const feed = (
              await sql<any>`select * from rss_feeds where id = ${row.feed_id}`.execute(k.db)
            ).rows[0];
            // 幂等：这条 guid 只要下过一次就永远跳过（台账按账号记录，但去重不看账号：
            // RSS 是单机单实例，同一台机器换个登录账号也不该把同一颗种子再下一遍）。
            // 用户删掉种子 / 删掉文件后**不会**重新下载 —— 想重下得自己删台账。
            const dup = await sql`
              select 1 from rss_downloaded
               where feed_id = ${row.feed_id} and guid = ${row.guid}
            `.execute(k.db);
            if (dup.rows.length > 0) continue;
            // 真加种：目录/是否暂停都按这个源自己的设置（以前只写留痕、什么都没下）
            let hash = '';
            if (row.enclosure_url) {
              const r = await submitFeedTorrent(feed ?? {}, {
                url: String(row.enclosure_url),
                guid: String(row.guid),
                title: String(row.title || ''),
                uid,
              });
              hash = r.hash;
            }
            await sql`
              insert into rss_downloaded
                (id, uid, feed_id, guid, info_hash, title, size_bytes,
                 enclosure_url, download_task_id, created_at)
              values (${crypto.randomBytes(8).toString('base64url')}, ${uid},
                      ${row.feed_id}, ${row.guid}, ${row.info_hash ?? hash ?? null},
                      ${row.title ?? null}, ${row.size_bytes ?? null},
                      ${row.enclosure_url ?? null}, ${hash || null}, ${now()})
            `.execute(k.db);
            autoSubmitted = true;
          }
        }

        return { ok: true, state, autoSubmitted };
      },
    );

    app.get(
      '/api/v1/rss/downloaded',
      secured('rss:read', {
        schema: {
          operationId: 'rssDownloadedList',
          tags: TAG,
          summary: '永久下载台账（按账号隔离）',
          querystring: DownloadedQuery,
          response: { 200: DownloadedListResponse },
        },
      }),
      async (req) => {
        const uid = String(req.user?.sub || '');
        const q = (req.query || {}) as { keyword?: string; limit?: number };
        const limit = Math.min(Math.max(q.limit ?? 200, 1), 2000);
        const kw = q.keyword ? `%${q.keyword}%` : null;
        const rows = (
          kw
            ? await sql<any>`
                select * from rss_downloaded
                 where uid = ${uid}
                   and (title like ${kw} or guid like ${kw} or info_hash like ${kw})
                 order by created_at desc limit ${limit}
              `.execute(k.db)
            : await sql<any>`
                select * from rss_downloaded
                 where uid = ${uid}
                 order by created_at desc limit ${limit}
              `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            id: String(r.id),
            feedId: String(r.feed_id ?? ''),
            guid: String(r.guid ?? ''),
            infoHash: String(r.info_hash ?? ''),
            title: String(r.title ?? ''),
            sizeBytes: Number(r.size_bytes ?? 0),
            enclosureUrl: String(r.enclosure_url ?? ''),
            downloadTaskId: String(r.download_task_id ?? ''),
            createTime: Number(r.created_at),
          })),
        };
      },
    );

    app.post(
      '/api/v1/rss/downloaded/delete',
      secured('rss:write', {
        schema: {
          operationId: 'rssDownloadedDelete',
          tags: TAG,
          summary: '删除一条下载台账',
          body: IdBody,
          response: { 200: DownloadedDeleteResponse },
        },
      }),
      async (req) => {
        const uid = String(req.user?.sub || '');
        const b = (req.body || {}) as { id?: string };
        const res = await sql`
          delete from rss_downloaded where id = ${b.id || ''} and uid = ${uid}
        `.execute(k.db);
        return { ok: true, deleted: Number(res.numAffectedRows ?? 0) > 0 };
      },
    );

    app.post(
      '/api/v1/rss/downloaded/clear',
      secured('rss:write', {
        schema: {
          operationId: 'rssDownloadedClear',
          tags: TAG,
          summary: '清空当前账号的下载台账',
          response: { 200: DownloadedClearResponse },
        },
      }),
      async (req) => {
        const uid = String(req.user?.sub || '');
        const res = await sql`delete from rss_downloaded where uid = ${uid}`.execute(k.db);
        return { ok: true, deleted: Number(res.numAffectedRows ?? 0) };
      },
    );

    app.post(
      '/api/v1/rss/feeds/auto-download',
      secured('rss:write', {
        schema: {
          operationId: 'rssFeedAutoDownload',
          tags: TAG,
          summary: '设置 feed 级自动下载开关',
          body: FeedAutoDownloadBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const b = (req.body || {}) as { id?: string; enabled?: boolean };
        await sql`
          update rss_feeds set auto_download = ${b.enabled === true ? 1 : 0}
           where id = ${b.id || ''}
        `.execute(k.db);
        return { ok: true };
      },
    );

    // ------------------------------------------------ RSS 自动下载规则
    const runRuleOnce = async (rule: any): Promise<{ matched: number; created: number }> => {
      const feed = (
        await sql<{ id: string; url: string }>`
          select id, url from rss_feeds where id = ${rule.feed_id}
        `.execute(k.db)
      ).rows[0];
      let items: Array<{ guid: string; title: string }>;
      if (feed?.url) {
        try {
          const parsed = parseRss(await fetchXml(feed.url));
          await insertItems(feed.id, parsed.items);
          items = parsed.items;
        } catch {
          return { matched: 0, created: 0 };
        }
      } else {
        // 内联 XML 订阅没有 url：直接用已落库的条目做匹配
        items = (
          await sql<{ guid: string; title: string }>`
            select guid, title from rss_items where feed_id = ${rule.feed_id} limit 500
          `.execute(k.db)
        ).rows;
      }
      let re: RegExp;
      try {
        re = new RegExp(String(rule.title_regex), 'i');
      } catch {
        re = /(?!)/;
      }
      let matched = 0;
      let created = 0;
      for (const it of items) {
        if (!re.test(it.title)) continue;
        matched += 1;
        const hit = await sql`
          select 1 from rss_rule_hits where rule_id = ${rule.id} and guid = ${it.guid}
        `.execute(k.db);
        if (hit.rows.length > 0) continue;
        const title = it.title.trim().slice(0, 200);
        if (!title) continue;
        const year = title.match(/(19|20)\d{2}/)?.[0] ?? null;
        const season = Number(title.match(/S(\d{1,2})/i)?.[1] ?? 0) || 0;
        const dup = await sql`
          select 1 from pt_subscriptions where uid = ${rule.uid} and media_title = ${title}
        `.execute(k.db);
        if (dup.rows.length === 0) {
          await sql`
            insert into pt_subscriptions
              (id, uid, media_title, media_year, season, quality, hdr,
               audio_langs_json, resolution_order_json, min_seeders, max_size_bytes,
               excluded_keywords_json, enabled, last_run_at, last_result, created_at, updated_at)
            values (${crypto.randomBytes(8).toString('base64url')}, ${rule.uid}, ${title},
                    ${year}, ${season}, 'all', 'all', '[]', '[]', 3, 0, '[]', 1,
                    null, 'rss: created', ${now()}, ${now()})
          `.execute(k.db);
          created += 1;
        }
        await sql`
          insert into rss_rule_hits (rule_id, guid, created_at)
          values (${rule.id}, ${it.guid}, ${now()})
          on conflict (rule_id, guid) do nothing
        `.execute(k.db);
      }
      await sql`update rss_rules set last_run_at = ${now()} where id = ${rule.id}`.execute(k.db);
      return { matched, created };
    };

    app.get(
      '/api/v1/rss/rules',
      secured('rss:read', {
        schema: {
          operationId: 'rssRuleList',
          tags: TAG,
          summary: 'RSS 自动下载规则（按账号隔离）',
          response: { 200: RuleListResponse },
        },
      }),
      async (req) => {
        const uid = String(req.user?.sub || '');
        const rows = (
          await sql<any>`
            select r.*, f.title as feed_title
              from rss_rules r left join rss_feeds f on f.id = r.feed_id
             where r.uid = ${uid} order by r.created_at desc limit 200
          `.execute(k.db)
        ).rows;
        return {
          items: rows.map((r) => ({
            id: r.id,
            feedId: r.feed_id,
            feedTitle: r.feed_title ?? '',
            titleRegex: r.title_regex,
            enabled: Number(r.enabled) === 1,
            lastRunAt: r.last_run_at === null ? null : Number(r.last_run_at),
            createdAt: Number(r.created_at),
          })),
        };
      },
    );

    app.post(
      '/api/v1/rss/rules/upsert',
      secured('rss:write', {
        schema: {
          operationId: 'rssRuleUpsert',
          tags: TAG,
          summary: '新增 / 编辑 RSS 自动下载规则',
          body: RuleUpsertBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const b = (req.body || {}) as {
          id?: string;
          feedId?: string;
          titleRegex?: string;
          enabled?: boolean;
        };
        if (!b.feedId || !b.titleRegex) {
          return reply.code(400).send({ error: Err.badRequest, message: 'feedId/titleRegex required' });
        }
        try {
          new RegExp(b.titleRegex);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'invalid titleRegex' });
        }
        const feed = await sql`select 1 from rss_feeds where id = ${b.feedId}`.execute(k.db);
        if (feed.rows.length === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'feed not found' });
        }
        const uid = String(req.user?.sub || '');
        if (b.id) {
          const res = await sql`
            update rss_rules
               set feed_id = ${b.feedId}, title_regex = ${b.titleRegex},
                   enabled = ${b.enabled === false ? 0 : 1}
             where id = ${b.id} and uid = ${uid}
          `.execute(k.db);
          if (Number(res.numAffectedRows ?? 0) === 0) {
            return reply.code(404).send({ error: Err.notFound, message: 'rule not found' });
          }
          return { ok: true };
        }
        await sql`
          insert into rss_rules (id, uid, feed_id, title_regex, enabled, last_run_at, created_at)
          values (${crypto.randomBytes(8).toString('base64url')}, ${uid}, ${b.feedId},
                  ${b.titleRegex}, ${b.enabled === false ? 0 : 1}, null, ${now()})
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/rss/rules/delete',
      secured('rss:write', {
        schema: {
          operationId: 'rssRuleDelete',
          tags: TAG,
          summary: '删除 RSS 自动下载规则',
          body: IdBody,
          response: { 200: OkResponse },
        },
      }),
      async (req) => {
        const b = (req.body || {}) as { id?: string };
        const uid = String(req.user?.sub || '');
        await sql`delete from rss_rule_hits where rule_id = ${b.id || ''}`.execute(k.db);
        await sql`delete from rss_rules where id = ${b.id || ''} and uid = ${uid}`.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/rss/rules/run',
      secured('rss:write', {
        schema: {
          operationId: 'rssRuleRun',
          tags: TAG,
          summary: '立即扫描一条规则（命中后自动建 PT 订阅）',
          body: IdBody,
          response: { 200: RuleRunResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const b = (req.body || {}) as { id?: string };
        const uid = String(req.user?.sub || '');
        const rule = (
          await sql<any>`
            select * from rss_rules where id = ${b.id || ''} and uid = ${uid}
          `.execute(k.db)
        ).rows[0];
        if (!rule) return reply.code(404).send({ error: Err.notFound, message: 'rule not found' });
        return runRuleOnce(rule);
      },
    );

    // 每 15 分钟扫一遍启用规则（改规则/重启用后最迟 15 分钟生效）
    const ruleTimer = setInterval(() => {
      void (async () => {
        const cutoff = now() - 15 * 60;
        const rules = (
          await sql<any>`
            select * from rss_rules
             where enabled = 1 and (last_run_at is null or last_run_at < ${cutoff})
             order by last_run_at asc limit 20
          `.execute(k.db)
        ).rows;
        for (const rule of rules) {
          try {
            await runRuleOnce(rule);
          } catch (err) {
            k.log.warn({ err: String(err), id: rule.id }, 'rss rule failed');
          }
        }
      })();
    }, 15 * 60_000);
    ruleTimer.unref?.();
    app.addHook('onClose', async () => {
      clearInterval(ruleTimer);
    });
  },
};