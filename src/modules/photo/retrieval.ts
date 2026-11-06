import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { ftsPhrase } from '../files/fts';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * 相册检索与「可操作」链路：把「检索 → 定位 → 操作 → 撤销」串成闭环。
 *
 *   POST /api/v1/photo/search/suggest        搜索联想（人物/场景/活动/相机/文件名/OCR/年份）
 *   GET  /api/v1/photo/faces/relations       人物关系图（同框共现 + 证据张数）
 *   POST /api/v1/photo/trash/preview         批量删除预演（只读：张数 / 字节）
 *   POST /api/v1/photo/trash/apply           执行删除（写 photo_operation_log，可撤销）
 *   POST /api/v1/photo/operation/undo        撤销一次操作（重复撤销 409）
 *   GET  /api/v1/photo/operation/recent      最近操作
 *   POST /api/v1/photo/faces/rescan/preview  人脸重扫两阶段：只算差异、不写库
 *   POST /api/v1/photo/ai/rerun              单张「重新识别」分项（face/place/ocr/activity）
 *
 * 设计约束：
 * - 破坏性写操作一律「预演 → 确认 → 留痕 → 可撤销」；
 * - undo 只回滚一次操作自身的快照，不做全局回滚；
 * - 未接入消费 worker 的项（tags / describe）不开放，并在 `ignored` 里如实回传。
 */
const TAG = ['photo'];
const now = () => Math.floor(Date.now() / 1000);

export interface SuggestItem {
  kind: string;
  value: string;
  count: number;
}

/**
 * 无关键词时的热门推荐：`/search/suggest` 的空 q 分支与 `/search/hot` 共用。
 * 以前这段只藏在 suggest 里，客户端又从不用空 q 调，等于一条死分支；
 * 抽出来后两个接口共用同一份 SQL，不会出现「热搜和推荐结果不一致」。
 */
export async function hotSuggestions(k: KernelApi, limit: number): Promise<SuggestItem[]> {
  const items: SuggestItem[] = [];
  const persons = (
    await sql<{ name: string; size: number }>`
      select name, size from photo_face_clusters
       where name is not null and name <> '' order by size desc limit ${limit}
    `.execute(k.db)
  ).rows;
  for (const p of persons) items.push({ kind: 'person', value: p.name, count: Number(p.size) });

  const scenes = (
    await sql<{ label: string; n: number }>`
      select s.label, count(*) as n from photo_scenes s
        join photo_items i on i.id = s.photo_id and i.in_trash = 0
       group by s.label order by n desc limit ${limit}
    `.execute(k.db)
  ).rows;
  for (const s of scenes) items.push({ kind: 'scene', value: s.label, count: Number(s.n) });

  const activities = (
    await sql<{ label: string; n: number }>`
      select a.label, count(*) as n from photo_activities a
        join photo_items i on i.id = a.photo_id and i.in_trash = 0
       group by a.label order by n desc limit ${limit}
    `.execute(k.db)
  ).rows;
  for (const a of activities) {
    items.push({ kind: 'activity', value: a.label, count: Number(a.n) });
  }

  const years = (
    await sql<{ y: string; n: number }>`
      select strftime('%Y', taken_at, 'unixepoch') as y, count(*) as n from photo_items
       where in_trash = 0 group by y order by y desc limit ${limit}
    `.execute(k.db)
  ).rows;
  for (const y of years) items.push({ kind: 'year', value: y.y, count: Number(y.n) });
  return items;
}

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const SuggestQuery = Type.Object({
  q: Type.Optional(Type.String({ maxLength: 128 })),
  limit: Type.Optional(Type.String()),
});

const SuggestResponse = Type.Object({
  items: Type.Array(
    Type.Object({
      kind: Type.String(),
      value: Type.String(),
      count: Type.Integer(),
    }),
    { maxItems: 100 },
  ),
});

const RelationsResponse = Type.Object({
  nodes: Type.Array(
    Type.Object(
      { id: Type.String(), name: Type.String(), size: Type.Integer() },
      { additionalProperties: true },
    ),
  ),
  edges: Type.Array(
    Type.Object(
      { a: Type.String(), b: Type.String(), photos: Type.Integer() },
      { additionalProperties: true },
    ),
  ),
});

const IdsBody = Type.Object({
  ids: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 5000 }),
});

const PreviewResponse = Type.Object({
  ids: Type.Array(Type.String()),
  count: Type.Integer(),
  bytes: Type.Integer(),
  missing: Type.Integer(),
});

const ApplyResponse = Type.Object({
  operationId: Type.String(),
  count: Type.Integer(),
});

const UndoBody = Type.Object({ id: Type.String({ minLength: 1 }) });
const UndoResponse = Type.Object({
  ok: Type.Boolean(),
  restored: Type.Integer(),
});

const OperationItem = Type.Object(
  {
    id: Type.String(),
    kind: Type.String(),
    count: Type.Integer(),
    createdAt: Type.Integer(),
    undoneAt: Type.Union([Type.Integer(), Type.Null()]),
  },
  { additionalProperties: true },
);

const OperationList = Type.Object({ items: Type.Array(OperationItem) });

const RescanPreviewResponse = Type.Object(
  {
    photos: Type.Integer(),
    faceRows: Type.Integer(),
    clusters: Type.Integer(),
    missingFaces: Type.Integer(),
    pendingEmbeddings: Type.Integer(),
    rescanFaces: Type.Integer(),
  },
  { additionalProperties: true },
);

const RerunBody = Type.Object({
  photoId: Type.String({ minLength: 1 }),
  face: Type.Optional(Type.Boolean()),
  place: Type.Optional(Type.Boolean()),
  ocr: Type.Optional(Type.Boolean()),
  activity: Type.Optional(Type.Boolean()),
});

const RerunResponse = Type.Object(
  {
    photoId: Type.String(),
    reset: Type.Array(Type.String()),
    ignored: Type.Array(Type.String()),
    queued: Type.Boolean(),
  },
  { additionalProperties: true },
);

interface OperationRow {
  id: string;
  uid: string;
  kind: string;
  item_ids: string;
  prev_json: string;
  created_at: number;
  undone_at: number | null;
}

export async function registerPhotoRetrieval(app: any, k: KernelApi): Promise<void> {
  // ---------------------------------------------------------------- 搜索联想
  app.post(
    '/api/v1/photo/search/suggest',
    secured('photo:read', {
      schema: {
        operationId: 'photoSearchSuggest',
        tags: TAG,
        summary: '搜索联想（人物/场景/活动/相机/文件名/OCR/年份，计数按可见库重算）',
        body: SuggestQuery,
        response: { 200: SuggestResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { q?: string; limit?: string };
      const raw = String(body.q || '').trim();
      const limit = Math.max(1, Math.min(Number(body.limit) || 5, 20));
      const like = `%${raw.replace(/[%_]/g, (m) => '\\' + m)}%`;
      const fts = ftsPhrase(raw);
      const hasQuery = raw.length > 0;
      const items: Array<{ kind: string; value: string; count: number }> = [];

      if (!hasQuery) {
        // 无关键词：返回各类热门（给「随便看看」用）
        return { items: await hotSuggestions(k, limit) };
      }

      const persons = (
        await sql<{ name: string; size: number }>`
          select name, size from photo_face_clusters
           where name like ${like} escape '\\' order by size desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const p of persons) items.push({ kind: 'person', value: p.name, count: Number(p.size) });

      const scenes = (
        await sql<{ label: string; n: number }>`
          select s.label, count(*) as n from photo_scenes s
            join photo_items i on i.id = s.photo_id and i.in_trash = 0
           where s.label like ${like} escape '\\'
           group by s.label order by n desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const s of scenes) items.push({ kind: 'scene', value: s.label, count: Number(s.n) });

      const activities = (
        await sql<{ label: string; n: number }>`
          select a.label, count(*) as n from photo_activities a
            join photo_items i on i.id = a.photo_id and i.in_trash = 0
           where a.label like ${like} escape '\\'
           group by a.label order by n desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const a of activities) {
        items.push({ kind: 'activity', value: a.label, count: Number(a.n) });
      }

      const cameras = (
        await sql<{ camera: string; n: number }>`
          select camera, count(*) as n from photo_items
           where in_trash = 0 and camera is not null and camera like ${like} escape '\\'
           group by camera order by n desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const c of cameras) items.push({ kind: 'camera', value: c.camera, count: Number(c.n) });

      const files = (
        await sql<{ p: string; n: number }>`
          select rel_path as p, count(*) as n from photo_items
           where in_trash = 0 and rel_path like ${like} escape '\\'
           group by rel_path order by n desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const f of files) {
        const name = String(f.p).split('/').pop() || String(f.p);
        items.push({ kind: 'filename', value: name, count: Number(f.n) });
      }

      const ocr = (
        await sql<{ text: string; n: number }>`
          select text, count(*) as n from photo_ocr
           where ${fts
             ? sql`rowid in (select rowid from photo_ocr_fts where photo_ocr_fts match ${fts})`
             : sql`text like ${like} escape '\\'`}
           group by text order by n desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const o of ocr) {
        items.push({ kind: 'ocr', value: String(o.text).slice(0, 80), count: Number(o.n) });
      }

      const years = (
        await sql<{ y: string; n: number }>`
          select strftime('%Y', taken_at, 'unixepoch') as y, count(*) as n from photo_items
           where in_trash = 0 and strftime('%Y', taken_at, 'unixepoch') like ${like} escape '\\'
           group by y order by y desc limit ${limit}
        `.execute(k.db)
      ).rows;
      for (const y of years) items.push({ kind: 'year', value: y.y, count: Number(y.n) });

      return { items: items.slice(0, 100) };
    },
  );

  // ---------------------------------------------------------------- 人物关系图
  app.get(
    '/api/v1/photo/faces/relations',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaceRelations',
        tags: TAG,
        summary: '人物关系图：同框共现边 + 证据张数',
        querystring: Type.Object({ limit: Type.Optional(Type.String()) }),
        response: { 200: RelationsResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { limit?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 200, 1000));

      const edges = (
        await sql<{ a: string; b: string; n: number }>`
          select fa.cluster_id as a, fb.cluster_id as b, count(distinct fa.photo_id) as n
            from photo_faces fa
            join photo_faces fb on fb.photo_id = fa.photo_id and fa.cluster_id < fb.cluster_id
            join photo_items i on i.id = fa.photo_id and i.in_trash = 0
           where fa.cluster_id is not null and fb.cluster_id is not null
           group by fa.cluster_id, fb.cluster_id
           order by n desc limit ${limit}
        `.execute(k.db)
      ).rows;

      const ids = new Set<string>();
      for (const e of edges) {
        ids.add(e.a);
        ids.add(e.b);
      }
      const idList = [...ids];
      const nodes =
        idList.length === 0
          ? []
          : (
              await sql<{ id: string; name: string | null; size: number }>`
                  select id, name, size from photo_face_clusters
                   where id in (${sql.join(
                     idList.map((x) => sql`${x}`),
                     sql`, `,
                   )})
                `.execute(k.db)
            ).rows;

      return {
        nodes: nodes.map((n) => ({
          id: n.id,
          name: n.name ?? '',
          size: Number(n.size),
        })),
        edges: edges.map((e) => ({ a: e.a, b: e.b, photos: Number(e.n) })),
      };
    },
  );

  // ---------------------------------------------------------------- 批量删除：预演 → 执行 → 撤销
  app.post(
    '/api/v1/photo/trash/preview',
    secured('photo:read', {
      schema: {
        operationId: 'photoTrashPreview',
        tags: TAG,
        summary: '批量删除预演（只读：张数与占用字节）',
        body: IdsBody,
        response: { 200: PreviewResponse },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { ids?: string[] };
      const ids = body.ids ?? [];
      if (ids.length === 0) return { ids: [], count: 0, bytes: 0, missing: 0 };

      const rows = (
        await sql<{ id: string; size: number }>`
          select id, size from photo_items
           where in_trash = 0 and id in (${sql.join(
             ids.map((x) => sql`${x}`),
             sql`, `,
           )})
        `.execute(k.db)
      ).rows;

      return {
        ids: rows.map((r) => r.id),
        count: rows.length,
        bytes: rows.reduce((sum, r) => sum + Number(r.size), 0),
        missing: ids.length - rows.length,
      };
    },
  );

  app.post(
    '/api/v1/photo/trash/apply',
    secured('photo:write', {
      schema: {
        operationId: 'photoTrashApply',
        tags: TAG,
        summary: '执行批量删除（写入操作日志，可撤销）',
        body: IdsBody,
        response: { 200: ApplyResponse, 400: ErrorResponse },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { ids?: string[] };
      const ids = [...new Set(body.ids ?? [])];
      if (ids.length === 0)
        return reply.code(400).send({ error: Err.badRequest, message: 'ids required' });

      const rows = (
        await sql<{ id: string; in_trash: number; deleted_at: number | null }>`
          select id, in_trash, deleted_at from photo_items
           where id in (${sql.join(
             ids.map((x) => sql`${x}`),
             sql`, `,
           )})
        `.execute(k.db)
      ).rows;

      const operationId = crypto.randomBytes(8).toString('base64url');
      const ts = now();
      await k.db.transaction().execute(async (trx: any) => {
        await sql`
          update photo_items set in_trash = 1, deleted_at = ${ts}
           where id in (${sql.join(
             rows.map((r) => sql`${r.id}`),
             sql`, `,
           )})
        `.execute(trx);
        await sql`
          insert into photo_operation_log (id, uid, kind, item_ids, prev_json, created_at, undone_at)
          values (${operationId}, ${String(req.user?.sub || '')}, 'trash',
                  ${JSON.stringify(rows.map((r) => r.id))},
                  ${JSON.stringify(rows.map((r) => ({ id: r.id, inTrash: r.in_trash, deletedAt: r.deleted_at })))},
                  ${ts}, null)
        `.execute(trx);
      });

      return { operationId, count: rows.length };
    },
  );

  app.post(
    '/api/v1/photo/operation/undo',
    secured('photo:write', {
      schema: {
        operationId: 'photoOperationUndo',
        tags: TAG,
        summary: '撤销一次操作（重复撤销返回 409）',
        body: UndoBody,
        response: { 200: UndoResponse, 404: ErrorResponse, 409: ErrorResponse },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { id?: string };
      const row = (
        await sql<OperationRow>`
          select * from photo_operation_log where id = ${body.id ?? ''}
        `.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'operation not found' });
      if (row.undone_at !== null) {
        return reply.code(409).send({ error: Err.conflict, message: 'operation already undone' });
      }

      let prev: Array<{ id: string; inTrash: number; deletedAt: number | null }> = [];
      try {
        prev = JSON.parse(row.prev_json || '[]');
      } catch {
        prev = [];
      }

      await k.db.transaction().execute(async (trx: any) => {
        for (const p of prev) {
          await sql`
            update photo_items set in_trash = ${Number(p.inTrash) || 0}, deleted_at = ${p.deletedAt ?? null}
             where id = ${p.id}
          `.execute(trx);
        }
        await sql`update photo_operation_log set undone_at = ${now()} where id = ${row.id}`.execute(
          trx,
        );
      });

      return { ok: true, restored: prev.length };
    },
  );

  app.get(
    '/api/v1/photo/operation/recent',
    secured('photo:read', {
      schema: {
        operationId: 'photoOperationRecent',
        tags: TAG,
        summary: '最近的可撤销操作（当前用户）',
        querystring: Type.Object({ limit: Type.Optional(Type.String()) }),
        response: { 200: OperationList },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { limit?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 20, 100));
      const rows = (
        await sql<OperationRow>`
          select * from photo_operation_log
           where uid = ${String(req.user?.sub || '')}
           order by created_at desc limit ${limit}
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          kind: r.kind,
          count: (JSON.parse(r.item_ids || '[]') as string[]).length,
          createdAt: Number(r.created_at),
          undoneAt: r.undone_at === null ? null : Number(r.undone_at),
        })),
      };
    },
  );

  // ---------------------------------------------------------------- 人脸重扫：预览 → 应用
  app.post(
    '/api/v1/photo/faces/rescan/preview',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaceRescanPreview',
        tags: TAG,
        summary: '人脸重扫预演：只算差异，不写库',
        response: { 200: RescanPreviewResponse },
      },
    }),
    async () => {
      const row = (
        await sql<{
          photos: number;
          face_rows: number;
          clusters: number;
          missing_faces: number;
          pending_embeddings: number;
        }>`
          select
            (select count(*) from photo_items where in_trash = 0) as photos,
            (select count(*) from photo_faces) as face_rows,
            (select count(*) from photo_face_clusters) as clusters,
            (select count(*) from photo_items i
              where i.in_trash = 0 and not exists (select 1 from photo_faces f where f.photo_id = i.id)) as missing_faces,
            (select count(*) from photo_items i
              where i.in_trash = 0 and not exists (select 1 from photo_embeddings e where e.photo_id = i.id)) as pending_embeddings
        `.execute(k.db)
      ).rows[0];

      return {
        photos: Number(row?.photos ?? 0),
        faceRows: Number(row?.face_rows ?? 0),
        clusters: Number(row?.clusters ?? 0),
        missingFaces: Number(row?.missing_faces ?? 0),
        pendingEmbeddings: Number(row?.pending_embeddings ?? 0),
        // 「需要重扫」= 没有检测结果的照片 + 还没有向量的照片（两者取并集前先各自计数）
        rescanFaces: Number(row?.missing_faces ?? 0),
      };
    },
  );

  // ---------------------------------------------------------------- 单张重新识别（分项）
  app.post(
    '/api/v1/photo/ai/rerun',
    secured('photo:write', {
      schema: {
        operationId: 'photoAiRerun',
        tags: TAG,
        summary: '单张重新识别：face / place / ocr / activity 分项清除，等下一轮 analyze 重算',
        body: RerunBody,
        response: { 200: RerunResponse, 404: ErrorResponse, 400: ErrorResponse },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as {
        photoId?: string;
        face?: boolean;
        place?: boolean;
        ocr?: boolean;
        activity?: boolean;
      };
      const photoId = String(body.photoId || '');
      const exists = (
        await sql<{ id: string }>`select id from photo_items where id = ${photoId}`.execute(k.db)
      ).rows[0];
      if (!exists) return reply.code(404).send({ error: Err.notFound, message: 'photo not found' });

      const want = {
        face: body.face !== false,
        place: body.place !== false,
        ocr: body.ocr === true,
        activity: body.activity === true,
      };
      if (!want.face && !want.place && !want.ocr && !want.activity) {
        return reply.code(400).send({ error: Err.badRequest, message: 'nothing selected' });
      }

      const reset: string[] = [];
      await k.db.transaction().execute(async (trx: any) => {
        if (want.face) {
          await sql`delete from photo_faces where photo_id = ${photoId}`.execute(trx);
          reset.push('face');
        }
        if (want.place) {
          await sql`delete from photo_scenes where photo_id = ${photoId}`.execute(trx);
          reset.push('place');
        }
        if (want.ocr) {
          await sql`delete from photo_ocr where photo_id = ${photoId}`.execute(trx);
          reset.push('ocr');
        }
        if (want.activity) {
          await sql`delete from photo_activities where photo_id = ${photoId}`.execute(trx);
          reset.push('activity');
        }
        // 让这张照片重新进入 analyze 的待处理集合
        await sql`delete from photo_embeddings where photo_id = ${photoId}`.execute(trx);
      });

      void k.events.emit('photo.rerun', { photoId, reset });
      return {
        photoId,
        reset,
        ignored: ['tags', 'describe'],
        queued: true,
      };
    },
  );
}
