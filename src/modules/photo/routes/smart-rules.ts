import { sql } from 'kysely';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, PhotoItemRow, toItem, encodeCursor, decodeCursor, newId, likePattern } from '../util';
import type { PhotoHelpers } from '../helpers';

/**
 * 智能相册规则：用户自定义条件组合（场景 / 人物 / 地点 / 时间 / 收藏）。
 *
 * 只存条件 JSON，不物化成员；列表的计数、条目、封面与「打开规则」始终用**同一份**
 * where 条件算，避免计数与内容漂移（与影视 smart-albums 的约定一致）。
 *
 *   GET  /api/v1/photo/smart-rules         规则列表（带命中张数与封面）
 *   POST /api/v1/photo/smart-rules         新建
 *   POST /api/v1/photo/smart-rules/update  改名 / 改条件
 *   POST /api/v1/photo/smart-rules/delete  删除
 *   GET  /api/v1/photo/smart-rules/items   规则命中的照片（时间轴序 + cursor）
 */
interface PlaceCondition {
  latitude: number;
  longitude: number;
  radiusKm?: number;
}

interface Conditions {
  scene?: string;
  activity?: string;
  faceClusterId?: string;
  place?: PlaceCondition;
  from?: number;
  to?: number;
  favorite?: boolean;
}

interface RuleRow {
  id: string;
  owner_id: string;
  name: string;
  conditions: string;
  created_at: number;
  updated_at: number;
}

const ACTIVITY_THRESHOLD = 0.078;

function hasCondition(c: Conditions): boolean {
  return Boolean(
    c.scene ||
      c.activity ||
      c.faceClusterId ||
      c.place ||
      c.from != null ||
      c.to != null ||
      c.favorite === true,
  );
}

function parseConditions(raw: string): Conditions {
  try {
    const parsed = JSON.parse(raw) as Conditions;
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

/** 圆形半径 → 经纬度光边框（纬度 1°≈111.32km；经度按 cos 收缩） */
function boundingBox(p: PlaceCondition) {
  const latitude = Number(p.latitude);
  const longitude = Number(p.longitude);
  const radiusKm = Math.max(0.1, Math.min(Number(p.radiusKm ?? 10) || 10, 500));
  const dLat = radiusKm / 111.32;
  const cos = Math.max(Math.abs(Math.cos((latitude * Math.PI) / 180)), 0.01);
  const dLng = radiusKm / (111.32 * cos);
  return { latitude, longitude, dLat, dLng };
}

/** 只拼「条件」部分（不含 owner / in_trash），供批量聚合复用 */
function condOf(c: Conditions) {
  const parts: ReturnType<typeof sql>[] = [];
  if (c.scene) {
    parts.push(sql`exists (select 1 from photo_scenes s where s.photo_id = i.id and s.label = ${c.scene})`);
  }
  if (c.activity) {
    parts.push(
      sql`exists (select 1 from photo_activities a where a.photo_id = i.id
                   and a.label = ${c.activity} and a.score >= ${ACTIVITY_THRESHOLD})`,
    );
  }
  if (c.faceClusterId) {
    parts.push(
      sql`exists (select 1 from photo_faces f where f.photo_id = i.id and f.cluster_id = ${c.faceClusterId})`,
    );
  }
  if (c.from != null) parts.push(sql`i.taken_at >= ${Number(c.from)}`);
  if (c.to != null) parts.push(sql`i.taken_at <= ${Number(c.to)}`);
  if (c.favorite === true) parts.push(sql`i.favorite = 1`);
  if (c.place) {
    const { latitude, longitude, dLat, dLng } = boundingBox(c.place);
    parts.push(
      sql`i.latitude is not null and i.longitude is not null
          and i.latitude between ${latitude - dLat} and ${latitude + dLat}
          and i.longitude between ${longitude - dLng} and ${longitude + dLng}`,
    );
  }
  return parts.length > 0 ? sql.join(parts, sql` and `) : sql`1 = 1`;
}

function whereOf(owner: string, c: Conditions) {
  return sql`i.in_trash = 0
    and i.library_id in (select id from photo_libraries where owner_id = ${owner})
    and (${condOf(c)})`;
}

/**
 * 批量算「每条规则的命中数」。
 *
 * 原实现是一条规则发两条查询（count + 取封面），200 条规则 = 400 次全表扫，
 * 十万张的库上单次请求就是分钟级。现在：
 * - 命中数用一条 `sum(case when <条件> then 1 else 0 end)` 聚合算完（一次扫描）；
 * - 封面仍逐条取，但 `order by taken_at desc limit 1` 沿索引倒序、命中即停，很便宜。
 *
 * 分批 50 条：单条 SQL 带 200 个 `case when` + `exists` 子查询会让语句过长，
 * 也让优化器失去判断力；50 条一批仍是「从 200 次扫库降到 4 次」。
 */
const RULE_AGG_BATCH = 50;

async function statsOfMany(
  k: KernelApi,
  owner: string,
  condsList: Conditions[],
): Promise<Array<{ items: number; coverPath: string | null }>> {
  const out: Array<{ items: number; coverPath: string | null }> = [];
  for (let start = 0; start < condsList.length; start += RULE_AGG_BATCH) {
    const batch = condsList.slice(start, start + RULE_AGG_BATCH);
    // 别名必须走 sql.raw：sql`` 里所有插值都会被参数化成 `?`，
    // 写成 `as c${i}` 会生成 `as c?` —— 语法错误，整条请求 500。
    const cols = batch.map(
      (c, i) => sql`sum(case when (${condOf(c)}) then 1 else 0 end) as ${sql.raw(`c${i}`)}`,
    );
    const row = (
      await sql`
        select ${sql.join(cols, sql`, `)}
          from photo_items i
         where i.in_trash = 0
           and i.library_id in (select id from photo_libraries where owner_id = ${owner})
      `.execute(k.db)
    ).rows[0] as Record<string, number> | undefined;

    for (let i = 0; i < batch.length; i += 1) {
      const cover = (
        await sql<{ rel_path: string | null }>`
          select i.rel_path from photo_items i
           where ${whereOf(owner, batch[i])}
           order by i.taken_at desc, i.id limit 1
        `.execute(k.db)
      ).rows[0];
      out.push({
        items: Number(row?.[`c${i}`]) || 0,
        coverPath: cover?.rel_path ?? null,
      });
    }
  }
  return out;
}

async function statsOf(k: KernelApi, owner: string, c: Conditions) {
  const where = whereOf(owner, c);
  const count = (
    await sql<{ n: number }>`select count(*) as n from photo_items i where ${where}`.execute(k.db)
  ).rows[0];
  const cover = (
    await sql<{ rel_path: string | null }>`
      select i.rel_path from photo_items i
       where ${where}
       order by i.taken_at desc, i.id limit 1
    `.execute(k.db)
  ).rows[0];
  return { items: Number(count?.n) || 0, coverPath: cover?.rel_path ?? null };
}

function ruleOut(row: RuleRow, items: number, coverPath: string | null) {
  return {
    id: row.id,
    name: row.name,
    conditions: parseConditions(row.conditions),
    items,
    coverPath,
    createdAt: Number(row.created_at),
    updatedAt: Number(row.updated_at),
  };
}

export async function registerPhotoSmartRules(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  const uidOf = (req: { user?: { sub?: string } }) => String(req.user?.sub || '');
  const now = () => Math.floor(Date.now() / 1000);

  const loadOwned = async (id: string, owner: string): Promise<RuleRow | null> => {
    const rows = (
      await sql<RuleRow>`
        select * from photo_smart_rules where id = ${id || ''} and owner_id = ${owner}
      `.execute(k.db)
    ).rows;
    return rows[0] ?? null;
  };

  app.get(
    '/api/v1/photo/smart-rules',
    secured('photo:read', {
      schema: {
        operationId: 'photoSmartRuleList',
        tags: TAG,
        summary: '智能规则列表（含命中张数与封面）',
        response: { 200: h.ref('PhotoSmartRuleListResponse') },
      },
    }),
    async (req) => {
      const owner = uidOf(req as any);
      const rows = (
        await sql<RuleRow>`
          select * from photo_smart_rules
           where owner_id = ${owner}
           order by created_at desc, id
           limit 200
        `.execute(k.db)
      ).rows;
      // 一条聚合算完所有规则的命中数（原来是每条规则 2 次全表扫）
      const conds = rows.map((row) => parseConditions(row.conditions));
      const stats = await statsOfMany(k, owner, conds);
      const items = rows.map((row, i) => ruleOut(row, stats[i].items, stats[i].coverPath));
      return { items };
    },
  );

  app.post(
    '/api/v1/photo/smart-rules',
    secured('photo:write', {
      schema: {
        operationId: 'photoSmartRuleCreate',
        tags: TAG,
        summary: '新建智能规则',
        body: h.ref('PhotoSmartRuleCreateBody'),
        response: { 200: h.ref('PhotoSmartRule'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { name?: string; conditions?: Conditions };
      const name = (body.name || '').trim();
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      const conditions = body.conditions || {};
      if (!hasCondition(conditions)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'conditions required' });
      }
      if (conditions.from != null && conditions.to != null && conditions.from > conditions.to) {
        return reply.code(400).send({ error: Err.badRequest, message: 'from must be <= to' });
      }
      const owner = uidOf(req as any);
      const id = newId();
      const ts = now();
      await sql`
        insert into photo_smart_rules (id, owner_id, name, conditions, created_at, updated_at)
        values (${id}, ${owner}, ${name}, ${JSON.stringify(conditions)}, ${ts}, ${ts})
      `.execute(k.db);
      const stats = await statsOf(k, owner, conditions);
      return ruleOut(
        { id, owner_id: owner, name, conditions: JSON.stringify(conditions), created_at: ts, updated_at: ts },
        stats.items,
        stats.coverPath,
      );
    },
  );

  app.post(
    '/api/v1/photo/smart-rules/update',
    secured('photo:write', {
      schema: {
        operationId: 'photoSmartRuleUpdate',
        tags: TAG,
        summary: '修改智能规则（改名 / 改条件）',
        body: h.ref('PhotoSmartRuleUpdateBody'),
        response: { 200: h.ref('PhotoSmartRule'), 400: h.ref('PhotoErrorResponse'), 404: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string; name?: string; conditions?: Conditions };
      const owner = uidOf(req as any);
      const row = await loadOwned(body.id || '', owner);
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'rule not found' });

      const name = body.name === undefined ? row.name : (body.name || '').trim();
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      const conditions = body.conditions === undefined ? parseConditions(row.conditions) : body.conditions;
      if (!hasCondition(conditions)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'conditions required' });
      }
      if (conditions.from != null && conditions.to != null && conditions.from > conditions.to) {
        return reply.code(400).send({ error: Err.badRequest, message: 'from must be <= to' });
      }
      const ts = now();
      await sql`
        update photo_smart_rules
           set name = ${name}, conditions = ${JSON.stringify(conditions)}, updated_at = ${ts}
         where id = ${row.id} and owner_id = ${owner}
      `.execute(k.db);
      const stats = await statsOf(k, owner, conditions);
      return ruleOut({ ...row, name, conditions: JSON.stringify(conditions), updated_at: ts }, stats.items, stats.coverPath);
    },
  );

  app.post(
    '/api/v1/photo/smart-rules/delete',
    secured('photo:write', {
      schema: {
        operationId: 'photoSmartRuleDelete',
        tags: TAG,
        summary: '删除智能规则（只删规则，不动照片）',
        body: h.ref('PhotoSmartRuleDeleteBody'),
        response: { 200: h.ref('PhotoOkResponse'), 404: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string };
      const owner = uidOf(req as any);
      const row = await loadOwned(body.id || '', owner);
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'rule not found' });
      await sql`delete from photo_smart_rules where id = ${row.id} and owner_id = ${owner}`.execute(k.db);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/photo/smart-rules/items',
    secured('photo:read', {
      schema: {
        operationId: 'photoSmartRuleItems',
        tags: TAG,
        summary: '智能规则命中的照片（时间轴序）',
        querystring: h.ref('PhotoSmartRuleItemsQuery'),
        response: { 200: h.ref('PhotoTimelineResponse'), 404: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { id?: string; cursor?: string; limit?: number };
      const owner = uidOf(req as any);
      const row = await loadOwned(q.id || '', owner);
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'rule not found' });

      const limit = h.limitOf(q.limit, 60, 200);
      const cur = decodeCursor(q.cursor);
      const where = whereOf(owner, parseConditions(row.conditions));
      const cursorPart = cur
        ? sql` and (i.taken_at < ${cur.takenAt} or (i.taken_at = ${cur.takenAt} and i.id > ${cur.id}))`
        : sql``;
      const rows = (
        await sql<PhotoItemRow>`
          select i.* from photo_items i
           where ${where}${cursorPart}
           order by i.taken_at desc, i.id
           limit ${limit + 1}
        `.execute(k.db)
      ).rows;
      const page = rows.slice(0, limit);
      const last = page[page.length - 1];
      return {
        items: page.map(toItem),
        nextCursor: rows.length > limit && last ? encodeCursor(Number(last.taken_at), last.id) : null,
      };
    },
  );

  // 时间轴交叉筛选：同一套条件判据，但由客户端临时传（不落库）。
  // 条件为空时返回空集而不是全库 —— 否则一个前端 bug 就会把整库照片拉出来。
  app.post(
    '/api/v1/photo/filter',
    secured('photo:read', {
      schema: {
        operationId: 'photoFilter',
        tags: TAG,
        summary: '按条件组合筛选照片（与智能规则同一套判据，不落库）',
        body: h.ref('PhotoFilterBody'),
        response: { 200: h.ref('PhotoFilterResponse'), 400: h.ref('PhotoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as {
        conditions?: Conditions;
        q?: string;
        cursor?: string;
        limit?: number;
        order?: string;
      };
      const owner = uidOf(req as any);
      const c = (body.conditions || {}) as Conditions;
      const kw = String(body.q || '').trim();
      // 只有关键词也算"有筛选条件"；两者都空才是空请求（返回空集，不倒全库）
      if (!hasCondition(c) && !kw) return { items: [], nextCursor: null };
      const limit = h.limitOf(body.limit, 60, 200);
      const cur = decodeCursor(body.cursor);
      if (body.cursor && !cur) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
      }
      const asc = body.order === 'asc';
      // 关键词与条件是**与**关系：筛选面板开着、搜索框也打了字时，
      // 以前搜索词被静默丢掉（有字但结果不变），这里补上。
      const qText = String(body.q || '').trim();
      const qPart = qText
        ? sql` and (i.rel_path like ${likePattern(qText)} escape '\\'
                   or exists (select 1 from photo_ocr o
                               where o.photo_id = i.id and o.text like ${likePattern(qText)} escape '\\'))`
        : sql``;
      const where = sql`${whereOf(owner, c)}${qPart}`;
      const cursorPart = cur
        ? asc
          ? sql` and (i.taken_at > ${cur.takenAt} or (i.taken_at = ${cur.takenAt} and i.id > ${cur.id}))`
          : sql` and (i.taken_at < ${cur.takenAt} or (i.taken_at = ${cur.takenAt} and i.id < ${cur.id}))`
        : sql``;
      const dir = sql.raw(asc ? 'asc' : 'desc');
      const rows = (
        await sql<PhotoItemRow>`
          select i.* from photo_items i
           where ${where}${cursorPart}
           order by i.taken_at ${dir}, i.id ${dir}
           limit ${limit + 1}
        `.execute(k.db)
      ).rows;
      const page = rows.slice(0, limit);
      const last = page[page.length - 1];
      // 总数只在第一页算：条件里带 exists 子查询，翻页时重复 count 太贵
      const total = cur
        ? null
        : Number(
            (
              await sql<{ n: number }>`
                select count(*) as n from photo_items i where ${where}
              `.execute(k.db)
            ).rows[0]?.n,
          ) || 0;
      return {
        items: page.map(toItem),
        nextCursor: rows.length > limit && last ? encodeCursor(Number(last.taken_at), last.id) : null,
        ...(total == null ? {} : { total }),
      };
    },
  );
}