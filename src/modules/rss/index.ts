import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
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
});

const FeedItem = Type.Object({
  id: Type.String(),
  url: Type.String(),
  title: Type.String(),
  lastFetch: Type.Union([Type.Integer(), Type.Null()]),
  createdAt: Type.Integer(),
});

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

interface ParsedItem {
  guid: string;
  title: string;
  link: string;
  published: number | null;
  summary: string;
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
    items.push({
      guid,
      title: tag(block, 'title') || '(untitled)',
      link,
      published: Number.isNaN(ts) ? null : Math.floor(ts / 1000),
      summary: stripHtml(tag(block, 'description') || tag(block, 'summary')).slice(0, 500),
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
        const existing = await sql`
          select 1 from rss_items where feed_id = ${feedId} and guid = ${it.guid}
        `.execute(k.db);
        if (existing.rows.length > 0) {
          skipped += 1;
          continue;
        }
        await sql`
          insert into rss_items (feed_id, guid, title, link, published, summary)
          values (${feedId}, ${it.guid}, ${it.title}, ${it.link}, ${it.published}, ${it.summary})
        `.execute(k.db);
        added += 1;
      }
      return { added, skipped };
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
        await sql`
          insert into rss_feeds (id, url, title, last_fetch, created_at)
          values (${id}, ${body.url || ''}, ${title}, ${null}, ${now()})
        `.execute(k.db);

        // 内联 xml 的订阅没有 url 可供后续抓取，因此添加时就把条目落库
        if (parsedXml) await insertItems(id, parsedXml.items);

        return { id, url: body.url || '', title, lastFetch: null, createdAt: now() };
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
        const res = await sql<{ id: string; url: string; title: string; last_fetch: number | null; created_at: number }>`
          select * from rss_feeds order by created_at desc
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            url: r.url,
            title: r.title,
            lastFetch: r.last_fetch,
            createdAt: r.created_at,
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
          ? (await sql<{ id: string; url: string }>`select id, url from rss_feeds where id = ${body.id}`.execute(k.db)).rows
          : (await sql<{ id: string; url: string }>`select id, url from rss_feeds`.execute(k.db)).rows;

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
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500 })),
          }),
          response: { 200: ItemsResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { feedId?: string; limit?: number };
        const limit = Math.min(Math.max(q.limit ?? 50, 1), 500);
        const base = `
          select i.guid, i.feed_id, f.title as feed_title, i.title, i.link, i.published, i.summary
          from rss_items i join rss_feeds f on f.id = i.feed_id
        `;
        const res = q.feedId
          ? await sql<Record<string, string | number | null>>`${sql.raw(base)} where i.feed_id = ${q.feedId} order by i.published desc, i.title limit ${limit}`.execute(k.db)
          : await sql<Record<string, string | number | null>>`${sql.raw(base)} order by i.published desc, i.title limit ${limit}`.execute(k.db);

        const count = q.feedId
          ? await sql<{ n: number }>`select count(*) as n from rss_items where feed_id = ${q.feedId}`.execute(k.db)
          : await sql<{ n: number }>`select count(*) as n from rss_items`.execute(k.db);

        return {
          items: res.rows.map((r) => ({
            guid: String(r.guid),
            feedId: String(r.feed_id),
            feedTitle: String(r.feed_title ?? ''),
            title: String(r.title ?? ''),
            link: String(r.link ?? ''),
            published: r.published === null ? null : Number(r.published),
            summary: String(r.summary ?? ''),
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