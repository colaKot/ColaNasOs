import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import { TRASH_RETENTION_DAYS } from './delete';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * 重复与相似清理：**预演 → 执行 → 撤销**。
 *
 * 三层口径：
 *   ① 内容重复：`content_md5` 相同（真正同一份字节）；
 *   ② 同名同大小：不同目录里 `filename + size` 相同（复制/备份的常态，md5 未算也能发现）；
 *   ③ 相似：CLIP 特征余弦 ≥ 阈值（连拍、轻微裁剪、重新压缩）。
 *
 * 为什么必须分批记录：清理是不可逆的用户操作，执行后要能按批次退回原样。
 * 从属关系（收藏 / 相册 / 场景 / 活动 / 人脸 / 位置）只在「恰好留一张」时合并，
 * 因为多留几张时合并会把同一段回忆重复挂到一张照片上。
 */
const TAG = ['photo'];

const CleanupItem = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    size: Type.Integer(),
    absent: Type.Boolean({ description: '文件已不在磁盘（仍可清理索引）' }),
  },
  { $id: 'PhotoCleanupItem' },
);

const CleanupGroup = Type.Object(
  {
    key: Type.String(),
    kind: Type.String({ description: 'content / name / similar' }),
    count: Type.Integer(),
    bytesEach: Type.Integer(),
    wastedBytes: Type.Integer(),
    keepId: Type.String({ description: '建议保留的一张' }),
    ids: Type.Array(Type.String({ description: '组内全部照片 id（items 只用于展示，可能截断）' })),
    items: Type.Array(Type.Ref(CleanupItem)),
  },
  { $id: 'PhotoCleanupGroup' },
);

const PreviewBody = Type.Object(
  {
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })),
    similarity: Type.Optional(Type.Number({ minimum: 0.5, maximum: 0.999, default: 0.92 })),
    includeSimilar: Type.Optional(Type.Boolean({ default: true })),
  },
  { $id: 'PhotoCleanupPreviewBody' },
);

const PreviewResponse = Type.Object(
  {
    duplicate: Type.Object({
      groups: Type.Array(Type.Ref(CleanupGroup)),
      totalGroups: Type.Integer(),
      totalWastedBytes: Type.Integer(),
    }),
    nameDuplicate: Type.Object({
      groups: Type.Array(Type.Ref(CleanupGroup)),
      totalGroups: Type.Integer(),
      totalWastedBytes: Type.Integer(),
    }),
    similar: Type.Object({
      groups: Type.Array(Type.Ref(CleanupGroup)),
      totalGroups: Type.Integer(),
      totalWastedBytes: Type.Integer(),
      note: Type.String(),
    }),
    missingMd5: Type.Integer(),
    md5Candidates: Type.Integer(),
  },
  { $id: 'PhotoCleanupPreviewResponse' },
);

const ApplyGroup = Type.Object(
  {
    key: Type.Optional(Type.String()),
    keepId: Type.String({ minLength: 1 }),
    removeIds: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
  },
  { $id: 'PhotoCleanupApplyGroup' },
);

const ApplyBody = Type.Object(
  {
    kind: Type.String({ maxLength: 32 }),
    groups: Type.Array(Type.Ref(ApplyGroup), { minItems: 1, maxItems: 200 }),
  },
  { $id: 'PhotoCleanupApplyBody' },
);

const ApplyResponse = Type.Object(
  {
    batchId: Type.String(),
    trashed: Type.Integer(),
    merged: Type.Integer(),
  },
  { $id: 'PhotoCleanupApplyResponse' },
);

const UndoBody = Type.Object(
  { batchId: Type.String({ minLength: 1 }) },
  { $id: 'PhotoCleanupUndoBody' },
);

const UndoResponse = Type.Object(
  { restored: Type.Integer(), batchId: Type.String() },
  { $id: 'PhotoCleanupUndoResponse' },
);

const Batch = Type.Object(
  {
    id: Type.String(),
    kind: Type.String(),
    createdAt: Type.Integer(),
    undoneAt: Type.Union([Type.Integer(), Type.Null()]),
    summary: Type.String(),
  },
  { $id: 'PhotoCleanupBatch' },
);

const BatchList = Type.Object(
  { items: Type.Array(Type.Ref(Batch)) },
  { $id: 'PhotoCleanupBatchList' },
);

const BackfillBody = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 5000, default: 500 })) },
  { $id: 'PhotoCleanupBackfillBody' },
);

const BackfillResponse = Type.Object(
  {
    candidates: Type.Integer(),
    hashed: Type.Integer(),
    failed: Type.Integer(),
    remaining: Type.Integer(),
  },
  { $id: 'PhotoCleanupBackfillResponse' },
);

const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'PhotoCleanupOk' });

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'PhotoCleanupError' },
);

export const PHOTO_CLEANUP_SCHEMAS = [
  CleanupItem,
  CleanupGroup,
  PreviewBody,
  PreviewResponse,
  ApplyGroup,
  ApplyBody,
  ApplyResponse,
  UndoBody,
  UndoResponse,
  Batch,
  BatchList,
  BackfillBody,
  BackfillResponse,
  OkResponse,
  ErrorResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });
const now = () => Math.floor(Date.now() / 1000);

interface ItemRow {
  id: string;
  rel_path: string;
  taken_at: number;
  size: number;
  content_md5: string | null;
}

function toItem(r: ItemRow): {
  id: string;
  path: string;
  takenAt: number;
  size: number;
  absent: boolean;
} {
  return {
    id: r.id,
    path: r.rel_path,
    takenAt: Number(r.taken_at),
    size: Number(r.size) || 0,
    // 文件存在性由扫描保证；这里只标「索引里还在、扫描后消失」的粗判
    absent: false,
  };
}

/** 内容重复：只捞「同一 md5 至少出现两次」的行，让 SQL 先筛（不在 JS 里分组全量） */
async function contentGroups(db: any, limit: number, uid: string) {
  const rows = (
    await sql<ItemRow>`
      select id, rel_path, taken_at, size, content_md5
        from photo_items
       where in_trash = 0
         and content_md5 is not null
         and content_md5 <> ''
         and library_id in (select id from photo_libraries where owner_id = ${uid})
         and content_md5 in (
           select content_md5 from photo_items
            where in_trash = 0 and content_md5 is not null and content_md5 <> ''
              and library_id in (select id from photo_libraries where owner_id = ${uid})
            group by content_md5 having count(*) >= 2
         )
       order by size desc, taken_at asc
    `.execute(db)
  ).rows;

  const byMd5 = new Map<string, ItemRow[]>();
  for (const r of rows) {
    const key = String(r.content_md5 || '');
    if (!key) continue;
    if (!byMd5.has(key)) byMd5.set(key, []);
    byMd5.get(key)!.push(r);
  }

  const groups = [];
  for (const [md5, list] of byMd5) {
    if (list.length < 2) continue;
    const size = Number(list[0].size) || 0;
    groups.push({
      key: `md5:${md5}`,
      kind: 'content',
      count: list.length,
      bytesEach: size,
      wastedBytes: (list.length - 1) * size,
      keepId: list[0].id,
      ids: list.map((r) => r.id),
      items: list.slice(0, 20).map(toItem),
    });
  }
  groups.sort((a, b) => b.wastedBytes - a.wastedBytes);
  return {
    groups: groups.slice(0, limit),
    totalGroups: groups.length,
    totalWastedBytes: groups.reduce((s, g) => s + g.wastedBytes, 0),
  };
}

/**
 * 同名同大小（不同目录）——内容完全一致的那批不重复展示。
 *
 * ⚠️ `photo_items` 只有 `rel_path`，没有 `filename` 列：先按 size 撞车筛候选，
 * 再在 JS 里按 basename 分组（SQL 侧不做 basename，避免表达式导致索引失效）。
 */
async function nameGroups(db: any, limit: number, uid: string) {
  const rows = (
    await sql<ItemRow>`
      select p.id, p.rel_path, p.taken_at, p.size, p.content_md5
        from photo_items p
       where p.in_trash = 0
         and p.library_id in (select id from photo_libraries where owner_id = ${uid})
         and p.size in (
           select size from photo_items
            where in_trash = 0
              and library_id in (select id from photo_libraries where owner_id = ${uid})
            group by size having count(*) >= 2
         )
       order by p.size desc
       limit 20000
    `.execute(db)
  ).rows;

  const byKey = new Map<string, ItemRow[]>();
  for (const r of rows) {
    const filename = r.rel_path.split('/').pop() || '';
    const key = `${filename}\u0000${Number(r.size) || 0}`;
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key)!.push(r);
  }

  const groups = [];
  for (const [key, list] of byKey) {
    if (list.length < 2) continue;
    const md5s = new Set(list.map((r) => String(r.content_md5 || '')).filter(Boolean));
    if (md5s.size === 1 && list.every((r) => String(r.content_md5 || ''))) continue;
    const size = Number(list[0].size) || 0;
    groups.push({
      key: `name:${key}`,
      kind: 'name',
      count: list.length,
      bytesEach: size,
      wastedBytes: (list.length - 1) * size,
      keepId: list[0].id,
      ids: list.map((r) => r.id),
      items: list.slice(0, 20).map(toItem),
    });
  }
  groups.sort((a, b) => b.wastedBytes - a.wastedBytes);
  return {
    groups: groups.slice(0, limit),
    totalGroups: groups.length,
    totalWastedBytes: groups.reduce((s, g) => s + g.wastedBytes, 0),
  };
}

/** 相似：CLIP 余弦贪心聚簇（单批上限 3000 张，避免全量进内存） */
async function similarGroups(db: any, limit: number, threshold: number, uid: string) {
  const rows = (
    await sql<{ photo_id: string; vec: Buffer }>`
      select e.photo_id, e.vec
        from photo_embeddings e
        join photo_items i on i.id = e.photo_id
       where i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${uid})
       limit 3000
    `.execute(db)
  ).rows;
  if (rows.length < 2) {
    return {
      groups: [],
      totalGroups: 0,
      totalWastedBytes: 0,
      note: rows.length === 0 ? '尚未生成图像特征（先跑一次 AI 分析）' : '样本不足',
    };
  }

  const vectors = rows.map((r) => ({
    id: r.photo_id,
    vec: new Float32Array(r.vec.buffer, r.vec.byteOffset, Math.floor(r.vec.byteLength / 4)),
  }));

  const cosine = (a: Float32Array, b: Float32Array): number => {
    let dot = 0;
    let na = 0;
    let nb = 0;
    for (let i = 0; i < a.length; i += 1) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
  };

  const used = new Set<number>();
  const buckets: number[][] = [];
  for (let i = 0; i < vectors.length; i += 1) {
    if (used.has(i)) continue;
    used.add(i);
    const bucket = [i];
    for (let j = i + 1; j < vectors.length; j += 1) {
      if (used.has(j)) continue;
      if (cosine(vectors[i].vec, vectors[j].vec) >= threshold) {
        used.add(j);
        bucket.push(j);
      }
    }
    if (bucket.length >= 2) buckets.push(bucket);
  }

  const ids = buckets.flat().map((i) => vectors[i].id);
  const info = new Map<string, ItemRow>();
  if (ids.length > 0) {
    const rowsInfo = (
      await sql<ItemRow>`
        select id, rel_path, taken_at, size, content_md5
          from photo_items
         where id in (${sql.join(
           ids.map((id) => sql`${id}`),
           sql`, `,
         )})
      `.execute(db)
    ).rows;
    for (const r of rowsInfo) info.set(r.id, r);
  }

  const groups = buckets
    .map((bucket) => {
      const items = bucket
        .map((i) => info.get(vectors[i].id))
        .filter(Boolean)
        .sort((a, b) => Number(a!.taken_at) - Number(b!.taken_at)) as ItemRow[];
      if (items.length < 2) return null;
      const size = Math.max(...items.map((r) => Number(r.size) || 0));
      return {
        key: `similar:${items.map((r) => r.id).sort()[0]}`,
        kind: 'similar',
        count: items.length,
        bytesEach: size,
        wastedBytes: (items.length - 1) * size,
        keepId: items[0].id,
        ids: items.map((r) => r.id),
        items: items.slice(0, 20).map(toItem),
      };
    })
    .filter(Boolean) as Array<Record<string, unknown>>;

  groups.sort((a, b) => Number(b.wastedBytes) - Number(a.wastedBytes));
  return {
    groups: groups.slice(0, limit),
    totalGroups: groups.length,
    totalWastedBytes: groups.reduce((s, g) => s + Number(g.wastedBytes), 0),
    note: '按 CLIP 特征聚类；阈值越低越激进',
  };
}

/** 感知哈希相似组（pHash 两阶段扫描的结果）；尚未扫描时回退 CLIP 并说明。 */
async function phashGroups(db: any, limit: number, threshold: number, uid: string) {
  const groupRows = (
    await sql<{
      id: string;
      leader_id: string;
      member_ids: string;
      distance: number;
    }>`
      select id, leader_id, member_ids, distance from photo_phash_groups
       where owner_id = ${uid}
       order by created_at desc
    `.execute(db)
  ).rows;
  if (groupRows.length === 0) {
    const fallback = await similarGroups(db, limit, threshold, uid);
    return { ...fallback, note: '尚未扫描相似照片（先点「开始扫描」）；当前按 CLIP 特征临时展示' };
  }

  const allIds = new Set<string>();
  const parsed = groupRows.map((g) => {
    let ids: string[] = [];
    try {
      const v = JSON.parse(String(g.member_ids || '[]'));
      if (Array.isArray(v)) ids = v.map((x) => String(x));
    } catch {
      /* 损坏的组忽略 */
    }
    for (const id of ids) allIds.add(id);
    return { ...g, ids };
  });

  const info = new Map<string, ItemRow>();
  const ids = [...allIds];
  for (let i = 0; i < ids.length; i += 500) {
    const chunk = ids.slice(i, i + 500);
    const rows = (
      await sql<ItemRow>`
        select id, rel_path, taken_at, size, content_md5 from photo_items
         where in_trash = 0 and id in (${sql.join(
           chunk.map((id) => sql`${id}`),
           sql`, `,
         )})
      `.execute(db)
    ).rows;
    for (const r of rows) info.set(r.id, r);
  }

  const groups = parsed
    .map((g) => {
      const items = g.ids
        .map((id) => info.get(id))
        .filter(Boolean)
        .sort((a, b) => Number(a!.taken_at) - Number(b!.taken_at)) as ItemRow[];
      if (items.length < 2) return null;
      const size = Math.max(...items.map((r) => Number(r.size) || 0));
      const keep = items.find((r) => r.id === g.leader_id) || items[0];
      return {
        key: `similar:${g.id}`,
        kind: 'similar',
        count: items.length,
        bytesEach: size,
        wastedBytes: (items.length - 1) * size,
        keepId: keep.id,
        ids: items.map((r) => r.id),
        items: items.slice(0, 20).map(toItem),
      };
    })
    .filter(Boolean) as Array<Record<string, unknown>>;

  groups.sort((a, b) => Number(b.wastedBytes) - Number(a.wastedBytes));
  return {
    groups: groups.slice(0, limit),
    totalGroups: groups.length,
    totalWastedBytes: groups.reduce((s, g) => s + Number(g.wastedBytes), 0),
    note: '按感知哈希（pHash）分组，汉明距离 ≤ 6',
  };
}

export async function registerPhotoCleanup(app: any, k: KernelApi): Promise<void> {
  for (const schema of PHOTO_CLEANUP_SCHEMAS) app.addSchema(schema);

  app.post(
    '/api/v1/photo/cleanup/preview',
    secured('photo:read', {
      schema: {
        operationId: 'photoCleanupPreview',
        tags: TAG,
        summary: '清理预演：内容重复 / 同名同大小 / 相似（只读，不改库）',
        body: ref('PhotoCleanupPreviewBody'),
        response: { 200: ref('PhotoCleanupPreviewResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { limit?: number; similarity?: number; includeSimilar?: boolean };
      const limit = Math.max(1, Math.min(Number(body.limit) || 50, 200));
      const threshold = Math.max(0.5, Math.min(Number(body.similarity) || 0.92, 0.999));
      const uid = String((req as any).user?.sub || '');

      const duplicate = await contentGroups(k.db, limit, uid);
      const nameDuplicate = await nameGroups(k.db, limit, uid);
      const similar =
        body.includeSimilar === false
          ? { groups: [], totalGroups: 0, totalWastedBytes: 0, note: '已关闭' }
          : await phashGroups(k.db, limit, threshold, uid);

      const missRow = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items
           where in_trash = 0 and (content_md5 is null or content_md5 = '')
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db)
      ).rows[0];
      const candRow = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items p
           where p.in_trash = 0
             and (p.content_md5 is null or p.content_md5 = '')
             and p.library_id in (select id from photo_libraries where owner_id = ${uid})
             and p.size in (
               select size from photo_items
                where in_trash = 0
                  and library_id in (select id from photo_libraries where owner_id = ${uid})
                group by size having count(*) >= 2
             )
        `.execute(k.db)
      ).rows[0];

      return {
        duplicate,
        nameDuplicate,
        similar,
        missingMd5: Number(missRow?.n) || 0,
        md5Candidates: Number(candRow?.n) || 0,
      };
    },
  );

  app.post(
    '/api/v1/photo/cleanup/apply',
    secured('photo:write', {
      schema: {
        operationId: 'photoCleanupApply',
        tags: TAG,
        summary: '执行清理（移入回收站，可按批次撤销）',
        body: ref('PhotoCleanupApplyBody'),
        response: { 200: ref('PhotoCleanupApplyResponse'), 400: ref('PhotoCleanupError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as {
        kind?: string;
        groups?: Array<{ key?: string; keepId: string; removeIds: string[] }>;
      };
      const groups = body.groups || [];
      if (groups.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'groups required' });
      }

      const owner = req.user?.sub || '';
      const batchId = `cl_${crypto.randomBytes(8).toString('hex')}`;
      const ts = now();
      let trashed = 0;
      let merged = 0;

      await k.db.transaction().execute(async (trx: any) => {
        await sql`
          insert into photo_cleanup_batches (id, kind, owner_id, created_at, summary)
          values (${batchId}, ${String(body.kind || 'duplicate').slice(0, 32)}, ${owner}, ${ts},
                  ${JSON.stringify({ groups: groups.length })})
        `.execute(trx);

        for (const group of groups) {
          const keepId = group.keepId;
          const removeIds = (group.removeIds || []).filter((id) => id && id !== keepId).slice(0, 500);
          if (!keepId || removeIds.length === 0) continue;

          // 记账：撤销时按 prev_trash / prev_deleted_at 精确还原
          for (const id of removeIds) {
            const prev = (
              await sql<{ in_trash: number; deleted_at: number | null }>`
                select in_trash, deleted_at from photo_items
                 where id = ${id}
                   and library_id in (select id from photo_libraries where owner_id = ${owner})
              `.execute(trx)
            ).rows[0];
            if (!prev) continue;
            await sql`
              insert or replace into photo_cleanup_items
                (batch_id, item_id, action, keep_id, prev_trash, prev_deleted_at)
              values (${batchId}, ${id}, 'trash', ${keepId}, ${Number(prev.in_trash) || 0}, ${prev.deleted_at})
            `.execute(trx);
            await sql`
              update photo_items set in_trash = 1, deleted_at = ${ts}
               where id = ${id}
                 and library_id in (select id from photo_libraries where owner_id = ${owner})
            `.execute(trx);
            trashed += 1;
          }

          // 只在「恰好留一张」时合并从属关系
          if (removeIds.length >= 1) {
            const keep = (
              await sql<{ favorite: number; latitude: number | null; longitude: number | null }>`
                select favorite, latitude, longitude from photo_items
                 where id = ${keepId}
                   and library_id in (select id from photo_libraries where owner_id = ${owner})
              `.execute(trx)
            ).rows[0];

            const favRow = (
              await sql<{ favorite: number }>`
                select max(favorite) as favorite from photo_items
                 where id in (${sql.join(
                   [keepId, ...removeIds].map((id) => sql`${id}`),
                   sql`, `,
                 )})
              `.execute(trx)
            ).rows[0];
            if (Number(favRow?.favorite) === 1) {
              await sql`update photo_items set favorite = 1 where id = ${keepId}`.execute(trx);
            }

            // 位置：保留的这张没坐标时，借用被清理那张的
            if (keep && keep.latitude == null) {
              const geo = (
                await sql<{
                  latitude: number;
                  longitude: number;
                  geohash: string | null;
                  geohash2: string | null;
                  geohash3: string | null;
                  geohash4: string | null;
                  geohash5: string | null;
                  geohash6: string | null;
                  geohash7: string | null;
                }>`
                  select latitude, longitude, geohash, geohash2, geohash3, geohash4, geohash5,
                         geohash6, geohash7
                    from photo_items
                   where id in (${sql.join(
                     removeIds.map((id) => sql`${id}`),
                     sql`, `,
                   )}) and latitude is not null
                   limit 1
                `.execute(trx)
              ).rows[0];
              if (geo) {
                await sql`
                  update photo_items set latitude = ${geo.latitude}, longitude = ${geo.longitude},
                    geohash = ${geo.geohash}, geohash2 = ${geo.geohash2}, geohash3 = ${geo.geohash3},
                    geohash4 = ${geo.geohash4}, geohash5 = ${geo.geohash5}, geohash6 = ${geo.geohash6},
                    geohash7 = ${geo.geohash7}
                  where id = ${keepId}
                `.execute(trx);
              }
            }

            // 相册成员：把成员关系迁到保留的那张，再删掉旧的
            for (const id of removeIds) {
              await sql`
                insert or ignore into photo_album_items (album_id, item_id, added_at)
                select album_id, ${keepId}, added_at from photo_album_items where item_id = ${id}
              `.execute(trx);
            }
            await sql`
              delete from photo_album_items
               where item_id in (${sql.join(
                 removeIds.map((id) => sql`${id}`),
                 sql`, `,
               )})
            `.execute(trx);

            // 场景 / 活动：保留的这张没有标签时补上（不覆盖已有）
            for (const id of removeIds) {
              await sql`
                insert or ignore into photo_scenes (photo_id, label, score, updated_at)
                select ${keepId}, label, score, updated_at from photo_scenes where photo_id = ${id}
               on conflict(photo_id) do nothing
              `.execute(trx);
              await sql`
                insert or ignore into photo_activities (photo_id, label, score, updated_at)
                select ${keepId}, label, score, updated_at from photo_activities where photo_id = ${id}
              `.execute(trx);
            }

            // 人脸：同一个人在同一张照片里只保留一条，按 embedding 先去重太难；
            // 这里只做「迁到保留照片」，重复由人脸页的合并逻辑处理。
            await sql`
              update photo_faces set photo_id = ${keepId}
               where photo_id in (${sql.join(
                 removeIds.map((id) => sql`${id}`),
                 sql`, `,
               )})
            `.execute(trx);

            merged += 1;
          }
        }
      });

      return { batchId, trashed, merged };
    },
  );

  app.post(
    '/api/v1/photo/cleanup/undo',
    secured('photo:write', {
      schema: {
        operationId: 'photoCleanupUndo',
        tags: TAG,
        summary: '撤销一个清理批次（恢复回收站状态）',
        body: ref('PhotoCleanupUndoBody'),
        response: { 200: ref('PhotoCleanupUndoResponse'), 404: ref('PhotoCleanupError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { batchId?: string };
      const batchId = String(body.batchId || '');
      const batch = (
        await sql<{ id: string; undone_at: number | null }>`
          select id, undone_at from photo_cleanup_batches where id = ${batchId}
        `.execute(k.db)
      ).rows[0];
      if (!batch) return reply.code(404).send({ error: Err.notFound, message: 'batch not found' });

      let restored = 0;
      await k.db.transaction().execute(async (trx: any) => {
        const items = (
          await sql<{ item_id: string; prev_trash: number; prev_deleted_at: number | null }>`
            select item_id, prev_trash, prev_deleted_at from photo_cleanup_items
             where batch_id = ${batchId}
          `.execute(trx)
        ).rows;
        for (const item of items) {
          await sql`
            update photo_items set in_trash = ${Number(item.prev_trash) || 0},
              deleted_at = ${item.prev_deleted_at}
            where id = ${item.item_id}
          `.execute(trx);
          restored += 1;
        }
        await sql`update photo_cleanup_batches set undone_at = ${now()} where id = ${batchId}`.execute(
          trx,
        );
      });

      return { restored, batchId };
    },
  );

  app.get(
    '/api/v1/photo/cleanup/batches',
    secured('photo:read', {
      schema: {
        operationId: 'photoCleanupBatches',
        tags: TAG,
        summary: '最近的清理批次',
        response: { 200: ref('PhotoCleanupBatchList') },
      },
    }),
    async (req: FastifyRequest) => {
      const owner = req.user?.sub || '';
      const rows = (
        await sql<{
          id: string;
          kind: string;
          created_at: number;
          undone_at: number | null;
          summary: string;
        }>`
          select id, kind, created_at, undone_at, summary from photo_cleanup_batches
           where owner_id = ${owner}
           order by created_at desc limit 50
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          kind: r.kind,
          createdAt: Number(r.created_at),
          undoneAt: r.undone_at == null ? null : Number(r.undone_at),
          summary: r.summary,
        })),
      };
    },
  );

  app.post(
    '/api/v1/photo/cleanup/md5',
    secured('photo:write', {
      schema: {
        operationId: 'photoCleanupBackfillMd5',
        tags: TAG,
        summary: '补齐候选照片的 content_md5（只算 size 撞车的那批）',
        body: ref('PhotoCleanupBackfillBody'),
        response: { 200: ref('PhotoCleanupBackfillResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(Number(body.limit) || 500, 5000));

      const candidates = (
        await sql<{ id: string; rel_path: string }>`
          select p.id, p.rel_path from photo_items p
           where p.in_trash = 0
             and (p.content_md5 is null or p.content_md5 = '')
             and p.size in (
               select size from photo_items where in_trash = 0 group by size having count(*) >= 2
             )
           limit ${limit}
        `.execute(k.db)
      ).rows;

      const { filesRoot, resolveInRoot } = await import('../files/fs-root');
      const { createReadStream } = await import('node:fs');
      const root = filesRoot();
      let hashed = 0;
      let failed = 0;

      // 流式哈希：原实现是 `readFile` 整个读进内存再算 md5 —— 一张 20 MB 的原图就是
      // 20 MB Buffer，长边还可能是 RAW / HEIC，5000 个候选会把堆顶穿。
      const hashFile = (abs: string) =>
        new Promise<string>((resolve, reject) => {
          const h = crypto.createHash('md5');
          const s = createReadStream(abs);
          s.on('data', (chunk) => h.update(chunk as Buffer));
          s.on('end', () => resolve(h.digest('hex')));
          s.on('error', reject);
        });

      // 每 200 条提交一次：原来是「每条一个 update」，即每条一个写事务
      //（WAL 一次 fsync）。5000 条就是 5000 次落盘。
      const pending: Array<{ id: string; md5: string }> = [];
      const flush = async () => {
        if (pending.length === 0) return;
        const batch = pending.splice(0, pending.length);
        await k.db.transaction().execute(async (trx: any) => {
          for (const row of batch) {
            await sql`update photo_items set content_md5 = ${row.md5} where id = ${row.id}`.execute(trx);
          }
        });
      };

      for (const row of candidates) {
        try {
          const abs = resolveInRoot(root, row.rel_path);
          pending.push({ id: row.id, md5: await hashFile(abs) });
          hashed += 1;
          if (pending.length >= 200) await flush();
        } catch {
          failed += 1;
        }
      }
      await flush();

      const remaining = (
        await sql<{ n: number }>`
          select count(*) as n from photo_items p
           where p.in_trash = 0
             and (p.content_md5 is null or p.content_md5 = '')
             and p.size in (
               select size from photo_items where in_trash = 0 group by size having count(*) >= 2
             )
        `.execute(k.db)
      ).rows[0];

      return {
        candidates: candidates.length,
        hashed,
        failed,
        remaining: Number(remaining?.n) || 0,
      };
    },
  );

  // ---------------------------------------------------------------- 回收站

  app.get(
    '/api/v1/photo/trash',
    secured('photo:read', {
      schema: {
        operationId: 'photoTrashList',
        tags: TAG,
        summary: '回收站（清理与删除的照片）',
        querystring: Type.Object(
          {
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
            cursor: Type.Optional(Type.String()),
            batchId: Type.Optional(
              Type.String({ description: '只看某一次删除（见 /photo/trash/batches）' }),
            ),
          },
          { $id: 'PhotoTrashQuery' },
        ),
        response: {
          200: Type.Object(
            {
              total: Type.Integer(),
              items: Type.Array(
                Type.Object(
                  {
                    id: Type.String(),
                    path: Type.String(),
                    takenAt: Type.Integer(),
                    deletedAt: Type.Union([Type.Integer(), Type.Null()]),
                    batchId: Type.Union([Type.String(), Type.Null()], {
                      description: '删除批次；null 表示清理链路或历史数据',
                    }),
                  },
                  { $id: 'PhotoTrashItem' },
                ),
              ),
              nextCursor: Type.Union([Type.String(), Type.Null()]),
            },
            { $id: 'PhotoTrashList' },
          ),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { limit?: number; cursor?: string; batchId?: string };
      const limit = Math.max(1, Math.min(Number(q.limit) || 60, 200));
      const uid = String((req as any).user?.sub || '');
      const batchFilter = q.batchId
        ? q.batchId === 'none'
          ? sql`and delete_batch_id is null`
          : sql`and delete_batch_id = ${q.batchId}`
        : sql``;
      const total = (
        await sql<{ n: number }>`select count(*) as n from photo_items
           where in_trash = 1
             and library_id in (select id from photo_libraries where owner_id = ${uid})
             ${batchFilter}`.execute(k.db)
      ).rows[0];
      const offset = Math.max(0, Number(q.cursor) || 0);
      const rows = (
        await sql<{
          id: string;
          rel_path: string;
          taken_at: number;
          deleted_at: number | null;
          delete_batch_id: string | null;
        }>`
          select id, rel_path, taken_at, deleted_at, delete_batch_id from photo_items
           where in_trash = 1
             and library_id in (select id from photo_libraries where owner_id = ${uid})
             ${batchFilter}
           order by deleted_at desc, id asc
           limit ${limit} offset ${offset}
        `.execute(k.db)
      ).rows;
      return {
        total: Number(total?.n) || 0,
        items: rows.map((r) => ({
          id: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          deletedAt: r.deleted_at == null ? null : Number(r.deleted_at),
          batchId: r.delete_batch_id ?? null,
        })),
        nextCursor: rows.length === limit ? String(offset + limit) : null,
      };
    },
  );

  // 回收站分组：一次删除 = 一个批次。清理链路（cleanup）的照片没有 delete_batch_id，
  // 用批次的 null 组承接，保证"总数 = 各批次之和"，界面上不会凭空少照片。
  app.get(
    '/api/v1/photo/trash/batches',
    secured('photo:read', {
      schema: {
        operationId: 'photoTrashBatches',
        tags: TAG,
        summary: '回收站按删除批次分组',
        response: {
          200: Type.Object(
            {
              total: Type.Integer(),
              items: Type.Array(
                Type.Object(
                  {
                    batchId: Type.Union([Type.String(), Type.Null()]),
                    count: Type.Integer(),
                    createdAt: Type.Union([Type.Integer(), Type.Null()]),
                    coverPath: Type.Union([Type.String(), Type.Null()]),
                    daysLeft: Type.Union([Type.Integer(), Type.Null()], {
                      description: '距 30 天保留期结束的剩余天数',
                    }),
                  },
                  { $id: 'PhotoTrashBatch' },
                ),
              ),
            },
            { $id: 'PhotoTrashBatchList' },
          ),
        },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      // 有批次号的：批次表 + 实时计数（照片可能被单独还原过，item_count 只是删除时的快照）
      const owned = (
        await sql<{
          id: string;
          created_at: number;
          n: number;
          cover: string | null;
        }>`
          select b.id, b.created_at,
                 (select count(*) from photo_items i
                   where i.delete_batch_id = b.id and i.in_trash = 1) as n,
                 (select i.rel_path from photo_items i
                   where i.delete_batch_id = b.id and i.in_trash = 1
                   order by i.deleted_at desc, i.id asc limit 1) as cover
            from photo_delete_batches b
           where b.owner_id = ${uid}
           order by b.created_at desc
           limit 200
        `.execute(k.db)
      ).rows;
      // 没有批次号的：迁移前的历史回收站数据 + 清理链路（cleanup）直接改 in_trash 的行
      const legacy = (
        await sql<{ n: number; oldest: number | null; cover: string | null }>`
          select count(*) as n, min(deleted_at) as oldest,
                 (select i.rel_path from photo_items i
                   where i.in_trash = 1 and i.delete_batch_id is null
                     and i.library_id in (select id from photo_libraries where owner_id = ${uid})
                   order by i.deleted_at desc, i.id asc limit 1) as cover
            from photo_items
           where in_trash = 1 and delete_batch_id is null
             and library_id in (select id from photo_libraries where owner_id = ${uid})
        `.execute(k.db)
      ).rows[0];
      const nowSec = Math.floor(Date.now() / 1000);
      const daysLeftOf = (createdAt: number | null) =>
        createdAt == null
          ? null
          : Math.max(0, Math.ceil((createdAt + TRASH_RETENTION_DAYS * 86400 - nowSec) / 86400));
      const items: Array<{
        batchId: string | null;
        count: number;
        createdAt: number | null;
        coverPath: string | null;
        daysLeft: number | null;
      }> = owned
        .filter((r) => Number(r.n) > 0)
        .map((r) => ({
          batchId: r.id,
          count: Number(r.n) || 0,
          createdAt: Number(r.created_at),
          coverPath: r.cover ?? null,
          daysLeft: daysLeftOf(Number(r.created_at)),
        }));
      if (legacy && Number(legacy.n) > 0) {
        const createdAt = legacy.oldest == null ? null : Number(legacy.oldest);
        items.push({
          batchId: null,
          count: Number(legacy.n),
          createdAt,
          coverPath: legacy.cover ?? null,
          daysLeft: daysLeftOf(createdAt),
        });
      }
      return {
        total: items.reduce((sum, x) => sum + x.count, 0),
        items,
      };
    },
  );

  app.post(
    '/api/v1/photo/trash/restore',
    secured('photo:write', {
      schema: {
        operationId: 'photoTrashRestore',
        tags: TAG,
        summary: '从回收站恢复',
        body: Type.Object(
          {
            ids: Type.Optional(
              Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
            ),
            batchId: Type.Optional(
              Type.String({ minLength: 1, description: '整批还原；与 ids 二选一' }),
            ),
          },
          { $id: 'PhotoTrashRestoreBody' },
        ),
        response: { 200: ref('PhotoCleanupUndoResponse') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { ids?: string[]; batchId?: string };
      const owner = String((req as any).user?.sub || '');
      const scoped = sql`library_id in (select id from photo_libraries where owner_id = ${owner})`;

      if (body.batchId) {
        const scope = body.batchId === 'none'
          ? sql`delete_batch_id is null`
          : sql`delete_batch_id = ${body.batchId}`;
        const res = await sql`
          update photo_items set in_trash = 0, deleted_at = null, delete_batch_id = null
           where ${scope} and in_trash = 1 and ${scoped}
        `.execute(k.db);
        if (body.batchId !== 'none') {
          await sql`
            update photo_delete_batches set item_count = 0
             where id = ${body.batchId} and owner_id = ${owner}
          `.execute(k.db);
        }
        return { restored: Number(res.numAffectedRows || 0), batchId: body.batchId };
      }

      const ids = (body.ids || []).slice(0, 500);
      if (ids.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'ids or batchId required' });
      }
      const res = await sql`
        update photo_items set in_trash = 0, deleted_at = null, delete_batch_id = null
         where id in (${sql.join(
           ids.map((id) => sql`${id}`),
           sql`, `,
         )})
           and ${scoped}
      `.execute(k.db);
      return { restored: Number(res.numAffectedRows || 0), batchId: '' };
    },
  );

  app.post(
    '/api/v1/photo/trash/empty',
    secured('photo:write', {
      schema: {
        operationId: 'photoTrashEmpty',
        tags: TAG,
        summary: '清空回收站（只删索引，不动磁盘文件）；传 batchId 只清一个批次',
        body: Type.Optional(
          Type.Object(
            { batchId: Type.Optional(Type.String({ minLength: 1 })) },
            { $id: 'PhotoTrashEmptyBody' },
          ),
        ),
        response: { 200: ref('PhotoCleanupOk') },
      },
    }),
    async (req: FastifyRequest) => {
      const uid = String((req as any).user?.sub || '');
      const body = (req.body || {}) as { batchId?: string };
      const scoped = sql`library_id in (select id from photo_libraries where owner_id = ${uid})`;
      if (body.batchId) {
        await sql`delete from photo_items
           where in_trash = 1 and ${scoped}
             ${body.batchId === 'none' ? sql`and delete_batch_id is null` : sql`and delete_batch_id = ${body.batchId}`}`.execute(
          k.db,
        );
        if (body.batchId !== 'none') {
          await sql`
            delete from photo_delete_batches where id = ${body.batchId} and owner_id = ${uid}
          `.execute(k.db);
        }
        return { ok: true };
      }
      await sql`delete from photo_items where in_trash = 1 and ${scoped}`.execute(k.db);
      await sql`delete from photo_delete_batches where owner_id = ${uid}`.execute(k.db);
      return { ok: true };
    },
  );
}