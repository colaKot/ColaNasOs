import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import { EMB_DIM, now, ref } from './schemas';
import { ALGO_VERSION, clusterSamples, paramsFromEnv, type ClusterSample } from './cluster-v2';
import { aiConfig, faceTuning, FACE_MIN_WIDTH_RATIO } from './config';
import { ensureSidecar, ffmpegPath } from './sidecar';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { Err } from '../../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * 人脸：检测结果的归属、命名、合并与全库重建。
 *
 * 归属算法 = **最近邻按组投票**，不是「最近质心」：
 *   一个组混进几张侧脸/遮挡后，质心会被拉偏，后面同一个人反而进不来；
 *   而「K 近邻里同组至少 2 票」对单张坏样本不敏感 —— 坏样本只会投自己一票。
 *
 * 参数（2026-10-20 定案口径，可用环境变量覆盖）：
 *   matchSim 0.45     近邻票的有效下限
 *   minVotes 2        至少两张同组近邻才认领
 *   cold 0.52 / 一致性 0.58：单张簇更严，否则第一张就定调，后面全是碎片
 *   minShowCount 3    展示门；具名组豁免（用户既然命名了，就该看见）
 */
/** 小事务包装：Kysely 的 transaction 需要 await execute，这里统一一下写法 */
async function db_transaction(k: KernelApi, fn: (trx: any) => Promise<void>): Promise<void> {
  await k.db.transaction().execute(fn);
}

export const FACE_MATCH_SIM = Number(process.env.COLANAS_FACE_MATCH_SIM) || 0.45;
export const FACE_MIN_VOTES = Number(process.env.COLANAS_FACE_MIN_VOTES) || 2;
export const FACE_NEIGHBOR_K = Number(process.env.COLANAS_FACE_NEIGHBOR_K) || 48;
export const FACE_COLD_SIM = Number(process.env.COLANAS_FACE_COLD_SIM) || 0.52;
export const FACE_CONSISTENCY_SIM = Number(process.env.COLANAS_FACE_CONSISTENCY_SIM) || 0.58;
export const FACE_MIN_SHOW_COUNT = Number(process.env.COLANAS_FACE_MIN_SHOW_COUNT) || 3;

export const toBuffer = (vec: number[]): Buffer => Buffer.from(new Float32Array(vec).buffer);
export const fromBuffer = (buf: Buffer): Float32Array =>
  new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.byteLength / 4));

/** 内存暴力 KNN（TypedArray）。实测比 sqlite-vec 快，且不受扩展加载影响。 */
export class FaceVectorIndex {
  ids: string[] = [];
  clusters: string[] = [];
  private data = new Float32Array(0);
  count = 0;
  private loaded = false;
  private loading: Promise<void> | null = null;

  reset(): void {
    this.ids = [];
    this.clusters = [];
    this.data = new Float32Array(0);
    this.count = 0;
    this.loaded = true;
  }

  async load(db: any): Promise<void> {
    if (this.loaded) return;
    if (this.loading) return this.loading;
    this.loading = (async () => {
      const rows = (
        await sql<{ id: string; cluster_id: string | null; emb: Buffer }>`
          select id, cluster_id, emb from photo_faces where cluster_id is not null
        `.execute(db)
      ).rows;
      const n = rows.length;
      const data = new Float32Array(n * EMB_DIM);
      const ids: string[] = [];
      const clusters: string[] = [];
      for (let i = 0; i < n; i += 1) {
        const vec = fromBuffer(rows[i].emb);
        data.set(vec.subarray(0, EMB_DIM), i * EMB_DIM);
        ids.push(rows[i].id);
        clusters.push(String(rows[i].cluster_id));
      }
      this.ids = ids;
      this.clusters = clusters;
      this.data = data;
      this.count = n;
      this.loaded = true;
    })().finally(() => {
      this.loading = null;
    });
    return this.loading;
  }

  add(id: string, clusterId: string, vec: Float32Array): void {
    const need = (this.count + 1) * EMB_DIM;
    if (this.data.length < need) {
      const next = new Float32Array(Math.max(need, this.data.length * 2, 1024 * EMB_DIM));
      next.set(this.data);
      this.data = next;
    }
    this.data.set(vec.subarray(0, EMB_DIM), this.count * EMB_DIM);
    this.ids.push(id);
    this.clusters.push(clusterId);
    this.count += 1;
  }

  /** 只在簇迁移时改归属，向量不动 */
  setCluster(faceId: string, clusterId: string): void {
    const idx = this.ids.indexOf(faceId);
    if (idx >= 0) this.clusters[idx] = clusterId;
  }

  /** 点积即可（存库前已 L2 归一化） */
  neighbors(vec: Float32Array, k = FACE_NEIGHBOR_K): Array<{ clusterId: string; sim: number }> {
    const n = this.count;
    if (n === 0) return [];
    const data = this.data;
    const best: Array<{ clusterId: string; sim: number }> = [];
    const limit = Math.max(1, Math.min(k, n));
    for (let i = 0; i < n; i += 1) {
      const base = i * EMB_DIM;
      let dot = 0;
      for (let d = 0; d < EMB_DIM; d += 1) dot += data[base + d] * vec[d];
      if (best.length < limit) {
        best.push({ clusterId: this.clusters[i], sim: dot });
        best.sort((a, b) => a.sim - b.sim);
      } else if (dot > best[0].sim) {
        best[0] = { clusterId: this.clusters[i], sim: dot };
        best.sort((a, b) => a.sim - b.sim);
      }
    }
    return best.reverse();
  }
}

export const faceIndex = new FaceVectorIndex();

/** 按投票给一张脸定归属（不写 photo_faces，重建时可复用已有行） */
export async function assignClusterId(k: KernelApi, emb: Float32Array): Promise<string> {
  await faceIndex.load(k.db);
  const tuning = faceTuning(k);

  const neighbors = faceIndex.neighbors(emb).filter((n) => n.sim >= tuning.matchSim);
  const votes = new Map<string, { count: number; best: number }>();
  for (const n of neighbors) {
    if (!n.clusterId) continue;
    const rec = votes.get(n.clusterId) || { count: 0, best: 0 };
    rec.count += 1;
    if (n.sim > rec.best) rec.best = n.sim;
    votes.set(n.clusterId, rec);
  }

  let picked: { id: string; count: number; best: number } | null = null;
  for (const [id, rec] of votes) {
    if (rec.count < tuning.minVotes) continue;
    if (
      !picked ||
      rec.count > picked.count ||
      (rec.count === picked.count && rec.best > picked.best)
    ) {
      picked = { id, count: rec.count, best: rec.best };
    }
  }

  // 冷启动：库里只有一张锚点时凑不出两票，但相似度足够高就应该先认领，
  // 否则每张新照片都会开一个新簇，越用越碎。
  if (!picked) {
    for (const [id, rec] of votes) {
      if (rec.count < 1 || rec.best < FACE_COLD_SIM) continue;
      if (!picked || rec.best > picked.best) picked = { id, count: rec.count, best: rec.best };
    }
  }

  if (picked) {
    const row = (
      await sql<{ centroid: Buffer; size: number }>`
        select centroid, size from photo_face_clusters where id = ${picked.id}
      `.execute(k.db)
    ).rows[0];
    const size = Number(row?.size) || 0;
    const need = size <= 1 ? FACE_COLD_SIM : FACE_CONSISTENCY_SIM;
    if (!row || picked.best < need) picked = null;
  }

  if (picked) {
    const clusterId = picked.id;
    const row = (
      await sql<{ centroid: Buffer; size: number }>`
        select centroid, size from photo_face_clusters where id = ${clusterId}
      `.execute(k.db)
    ).rows[0];
    const centroid = fromBuffer(row.centroid);
    const w = Number(row.size) || 0;
    const merged = new Float32Array(EMB_DIM);
    let norm = 0;
    for (let i = 0; i < EMB_DIM; i += 1) {
      merged[i] = (centroid[i] * w + emb[i]) / (w + 1);
      norm += merged[i] * merged[i];
    }
    norm = Math.sqrt(norm) || 1;
    for (let i = 0; i < EMB_DIM; i += 1) merged[i] /= norm;
    await sql`
      update photo_face_clusters
         set centroid = ${toBuffer(Array.from(merged))}, size = ${w + 1}, updated_at = ${now()}
       where id = ${clusterId}
    `.execute(k.db);
    return clusterId;
  }

  const clusterId = crypto.randomUUID();
  await sql`
    insert into photo_face_clusters (id, name, size, cover_photo_id, centroid, created_at, updated_at)
    values (${clusterId}, ${null}, 1, ${null}, ${toBuffer(Array.from(emb))}, ${now()}, ${now()})
  `.execute(k.db);
  return clusterId;
}

export interface FaceBox {
  left: number;
  top: number;
  width: number;
  height: number;
  imgWidth?: number;
  imgHeight?: number;
}

/** 分析流程用：投票 + 插入人脸（含 bbox）+ 更新索引 + 补封面 */
export async function assignCluster(
  k: KernelApi,
  emb: Float32Array,
  photoId: string,
  box?: FaceBox | null,
  score = 1,
): Promise<{ clusterId: string; faceId: string }> {
  const clusterId = await assignClusterId(k, emb);
  const faceId = crypto.randomUUID();
  await sql`
    insert into photo_faces
      (id, photo_id, emb, cluster_id, score, created_at,
       box_left, box_top, box_width, box_height, img_width, img_height)
    values (${faceId}, ${photoId}, ${toBuffer(Array.from(emb))}, ${clusterId}, ${score}, ${now()},
            ${box ? Math.round(box.left) : null}, ${box ? Math.round(box.top) : null},
            ${box ? Math.round(box.width) : null}, ${box ? Math.round(box.height) : null},
            ${box?.imgWidth ?? null}, ${box?.imgHeight ?? null})
  `.execute(k.db);
  await sql`
    update photo_face_clusters set cover_photo_id = ${photoId}
     where id = ${clusterId} and (cover_photo_id is null or cover_photo_id = '')
  `.execute(k.db);
  faceIndex.add(faceId, clusterId, emb);
  return { clusterId, faceId };
}

/**
 * 合并两个簇（from → to）的唯一实现。
 *
 * 手动合并、候选逐对确认、`merge-similar` 批量合并都走这里，
 * 保证「size 重算成照片数 + 封面补齐 + 内存索引同步 + 审计可回滚」只有一份口径。
 * 审计表 `photo_face_merge_log` 记下被并掉簇的 id / 名称 / 质心 / 成员 face id，
 * 撤消时按成员 id 精确搬回（不能只按 to_id 反查，那样会把原属 to 的脸一起搬走）。
 */
export async function mergeClusterPair(
  k: KernelApi,
  fromId: string,
  toId: string,
  owner = '',
): Promise<{ moved: number }> {
  const source = (
    await sql<{
      id: string;
      name: string | null;
      centroid: Buffer | null;
      cover_face_id: string | null;
    }>`
      select id, name, centroid, cover_face_id from photo_face_clusters where id = ${fromId}
    `.execute(k.db)
  ).rows[0];
  const target = (
    await sql<{ id: string; cover_photo_id: string | null }>`
      select id, cover_photo_id from photo_face_clusters where id = ${toId}
    `.execute(k.db)
  ).rows[0];
  if (!source || !target) throw new Error('cluster not found');

  const faces = (
    await sql<{ id: string }>`select id from photo_faces where cluster_id = ${fromId}`.execute(k.db)
  ).rows;

  await k.db.transaction().execute(async (trx: any) => {
    await sql`update photo_faces set cluster_id = ${toId} where cluster_id = ${fromId}`.execute(trx);
    await sql`
      insert into photo_face_merge_log
        (id, owner_id, from_id, to_id, from_name, from_cover_face_id, from_centroid,
         faces, face_ids, created_at)
      values (${crypto.randomBytes(9).toString('base64url')}, ${owner}, ${fromId}, ${toId},
              ${source.name}, ${source.cover_face_id}, ${source.centroid},
              ${faces.length}, ${JSON.stringify(faces.map((f) => f.id))}, ${now()})
    `.execute(trx);
    await sql`delete from photo_face_clusters where id = ${fromId}`.execute(trx);
    // size 统一成「照片数」：同一张合照里的两张脸不重复计数
    await sql`
      update photo_face_clusters
         set size = (select count(distinct photo_id) from photo_faces where cluster_id = ${toId}),
             cover_face_id = coalesce(
               cover_face_id,
               (select id from photo_faces where cluster_id = ${toId}
                 order by (coalesce(box_width, 0) * coalesce(box_height, 0)) desc limit 1)),
             cover_photo_id = coalesce(
               cover_photo_id,
               (select photo_id from photo_faces where cluster_id = ${toId} limit 1)),
             updated_at = ${now()}
       where id = ${toId}
    `.execute(trx);
  });

  for (const f of faces) faceIndex.setCluster(f.id, toId);
  return { moved: faces.length };
}

/** 按簇重算 size（照片数）与封面，移动单张脸后两侧都要修（db 可传事务句柄） */
async function refreshClusterStats(db: any, clusterId: string | null): Promise<void> {
  if (!clusterId) return;
  await sql`
    update photo_face_clusters
       set size = (select count(distinct photo_id) from photo_faces where cluster_id = ${clusterId}),
           updated_at = ${now()}
     where id = ${clusterId}
  `.execute(db);
}

export async function registerPhotoFaces(app: any, k: KernelApi): Promise<void> {
  app.get(
    '/api/v1/photo/faces/clusters',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaceClusters',
        tags: ['photo'],
        summary: '人脸聚类列表（按人数倒序；少于 minCount 的碎片组不显示，具名组豁免）',
        querystring: ref('PhotoFaceClusterFilter'),
        response: { 200: ref('PhotoFaceClusterList') },
      },
    }),
    async (req: FastifyRequest) => {
      const minCount = Math.max(
        1,
        Math.min(
          Number(((req.query || {}) as { minCount?: number }).minCount) ||
            aiConfig(k).faceMinShowCount,
          1000,
        ),
      );
      const rows = (
        await sql<{
          id: string;
          name: string | null;
          size: number;
          cover_photo_id: string | null;
          cover_face_id: string | null;
        }>`
          select id, name, size, cover_photo_id, cover_face_id from photo_face_clusters
           where size >= ${minCount} or (name is not null and name <> '')
           order by size desc limit 500
        `.execute(k.db)
      ).rows;

      // 没有登记头像的在内存里补挑一个：优先面积最大（脸最大最清楚），
      // 退而求其次任意一张 —— 客户端只要有脸就能画头像，不能因为没登记就退化成图标。
      const items = [];
      for (const r of rows) {
        let faceId = r.cover_face_id;
        if (!faceId) {
          const pick = (
            await sql<{ id: string }>`
              select id from photo_faces
               where cluster_id = ${r.id}
               order by coalesce(box_width * box_height, 0) desc, created_at asc
               limit 1
            `.execute(k.db)
          ).rows[0];
          faceId = pick?.id ?? null;
        }
        items.push({
          id: r.id,
          name: r.name,
          size: Number(r.size),
          coverPhotoId: r.cover_photo_id,
          coverFaceId: faceId,
        });
      }
      return { items };
    },
  );

  app.get(
    '/api/v1/photo/faces',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaces',
        tags: ['photo'],
        summary: '某个人脸簇下的照片',
        querystring: ref('PhotoFaceClusterQuery'),
        response: { 200: ref('PhotoFaceList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { id?: string };
      const rows = (
        await sql<{
          id: string;
          photo_id: string;
          score: number;
          rel_path: string;
          taken_at: number;
          box_left: number | null;
          box_top: number | null;
          box_width: number | null;
          box_height: number | null;
        }>`
          select f.id, f.photo_id, f.score, i.rel_path, i.taken_at,
                 f.box_left, f.box_top, f.box_width, f.box_height
          from photo_faces f join photo_items i on i.id = f.photo_id
          where f.cluster_id = ${q.id ?? ''} and i.in_trash = 0
          order by i.taken_at desc limit 500
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          photoId: r.photo_id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          score: Number(r.score),
          boxLeft: r.box_left == null ? null : Number(r.box_left),
          boxTop: r.box_top == null ? null : Number(r.box_top),
          boxWidth: r.box_width == null ? null : Number(r.box_width),
          boxHeight: r.box_height == null ? null : Number(r.box_height),
        })),
      };
    },
  );

  /**
   * 人脸裁剪图（簇头像 / 照片里的人脸角标）。
   *
   * 构图照参考实现：以人脸框中心为基准，按最长边外扩 `FACE_IMAGE_EXTEND`（默认 30%），
   * 再向上偏移 `FACE_IMAGE_TOP_EXTRA`（默认 10%）—— 人脸在头像里偏下一点才自然，
   * 否则头顶被切一半。裁剪结果落文件缓存，key 带 box 与 size，box 变了自然失效。
   */
  app.get(
    '/api/v1/photo/face/image',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaceImage',
        tags: ['photo'],
        summary: '人脸裁剪图（JPEG；无 bbox 的老数据回退整图缩略图）',
        querystring: ref('PhotoFaceImageQuery'),
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as { id?: string; size?: number };
      const faceId = String(q.id || '').trim();
      const size = Math.max(48, Math.min(Number(q.size) || 160, 512));
      if (!faceId) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });

      const row = (
        await sql<{
          photo_id: string;
          rel_path: string;
          box_left: number | null;
          box_top: number | null;
          box_width: number | null;
          box_height: number | null;
          img_width: number | null;
          img_height: number | null;
        }>`
          select f.photo_id, i.rel_path, f.box_left, f.box_top, f.box_width, f.box_height,
                 f.img_width, f.img_height
            from photo_faces f join photo_items i on i.id = f.photo_id
           where f.id = ${faceId}
        `.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'face not found' });

      const hasBox =
        row.box_left != null && row.box_top != null && Number(row.box_width) > 0 && Number(row.box_height) > 0;
      if (!hasBox) {
        // 老数据（加 bbox 之前入库）没有坐标：退回整图缩略图，用户至少能看到照片
        return reply.redirect(
          `/api/v1/files/thumb?path=${encodeURIComponent(row.rel_path)}&size=${size}`,
          302,
        );
      }

      let abs: string;
      try {
        abs = resolveAnyPath(filesRoot(), row.rel_path);
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
      }

      const hash = crypto
        .createHash('sha1')
        .update(`${faceId}:${row.box_left}:${row.box_top}:${row.box_width}:${row.box_height}:${size}`)
        .digest('hex')
        .slice(0, 32);
      const out = path.join(k.paths.dataDir, 'faces', `${hash}.jpg`);
      if (!fs.existsSync(out)) {
        const ff = ffmpegPath();
        if (!ff) return reply.code(503).send({ error: Err.mediaUnavailable, message: 'ffmpeg missing' });
        const iw = Number(row.img_width) || 0;
        const ih = Number(row.img_height) || 0;
        if (!iw || !ih) {
          return reply.redirect(
            `/api/v1/files/thumb?path=${encodeURIComponent(row.rel_path)}&size=${size}`,
            302,
          );
        }
        const bw = Number(row.box_width);
        const bh = Number(row.box_height);
        const extend = 0.3;
        const topExtra = 0.1;
        const cx = Number(row.box_left) + bw / 2;
        const cy = Number(row.box_top) + bh / 2;
        const base = Math.max(bw, bh);
        let cropSize = Math.round(base * (1 + extend * 2));
        cropSize = Math.min(cropSize, Math.max(2, Math.min(iw, ih)));
        const left = Math.max(0, Math.min(iw - cropSize, Math.round(cx - cropSize / 2)));
        const top = Math.max(0, Math.min(ih - cropSize, Math.round(cy - cropSize / 2 - base * topExtra)));
        const vf =
          `crop=${cropSize}:${cropSize}:${left}:${top},` +
          `scale=${size}:${size}:force_original_aspect_ratio=increase,crop=${size}:${size}`;
        try {
          fs.mkdirSync(path.dirname(out), { recursive: true });
          const ok = await new Promise<boolean>((resolve) => {
            const child = spawn(ff, ['-hide_banner', '-loglevel', 'error', '-y', '-i', abs, '-vf', vf, '-frames:v', '1', out], {
              windowsHide: true,
            });
            child.on('error', () => resolve(false));
            child.on('close', (code) => resolve(code === 0 && fs.existsSync(out)));
          });
          if (!ok) {
            return reply.redirect(
              `/api/v1/files/thumb?path=${encodeURIComponent(row.rel_path)}&size=${size}`,
              302,
            );
          }
        } catch {
          return reply.code(500).send({ error: Err.internal, message: 'crop failed' });
        }
      }
      reply.header('content-type', 'image/jpeg');
      reply.header('cache-control', 'private, max-age=604800');
      return reply.send(fs.createReadStream(out));
    },
  );

  /**
   * 解散一个簇：把里面的脸放回未分组（**不删人脸数据**）。
   *
   * 为什么需要它：合并错了 / 一个簇明显混了两个人 / 这就是一堆路人 ——
   * 以前只能整库 `purge` 或者逐个移出，代价太大。解散后这些脸会重新参与归属投票。
   */
  /**
   * 只补人脸框（bbox backfill）。
   *
   * 为什么单独一个接口而不是 `analyze?force=1`：
   *   - `force` 会把 CLIP 嵌入 / 场景 / OCR **全部重算**，1 万张要跑几小时；
   *   - 这里只做人脸检测（不做场景、不算嵌入），同一批照片快 3~5 倍；
   *   - 并且**保留已有簇归属**：新脸照旧走投票归属，簇名字不会丢。
   *
   * 适用场景：加 bbox 之前入库的人脸没有坐标（头像墙画不出来）。
   */
  app.post(
    '/api/v1/photo/faces/backfill',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceBackfill',
        tags: ['photo'],
        summary: '只补人脸框（不重算场景/嵌入，保留簇归属）',
        body: ref('PhotoFaceBackfillBody'),
        response: { 200: ref('PhotoFaceBackfillResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { limit?: number; photoIds?: string[] };
      const limit = Math.max(1, Math.min(Number(body.limit) || 500, 5000));
      const ids = (body.photoIds || []).filter((v) => typeof v === 'string' && v.trim());

      const whereIds = ids.length
        ? sql`and i.id in (${sql.join(ids.map((v) => sql`${v}`), sql`, `)})`
        : sql``;

      // 缺坐标 = 有脸行但 box_left 为空；没有脸行的照片不在这里处理（可能本来就没脸）
      const rows = (
        await sql<{ id: string; rel_path: string }>`
          select distinct i.id, i.rel_path
            from photo_faces f join photo_items i on i.id = f.photo_id
           where i.in_trash = 0 and f.box_left is null
             ${whereIds}
           order by i.taken_at desc
           limit ${limit}
        `.execute(k.db)
      ).rows;

      const s = await ensureSidecar(k);
      const root = filesRoot();
      let photos = 0;
      let faces = 0;
      let tooSmall = 0;
      let skipped = 0;

      for (const row of rows) {
        let abs: string;
        try {
          abs = resolveAnyPath(root, row.rel_path);
        } catch {
          skipped += 1;
          continue;
        }
        if (!fs.existsSync(abs)) {
          skipped += 1;
          continue;
        }
        try {
          const out = await s.request<{
            faces: Array<{
              score: number;
              emb: number[];
              box?: { left: number; top: number; width: number; height: number } | null;
              imgWidth?: number;
              imgHeight?: number;
            }>;
          }>('analyze', { src: abs, faces: true, scenes: false, embed: false }, 600_000);

          // 同一个人在这张照片里的人脸行整体替换（旧行没有坐标，留着只会重复计数）
          await sql`delete from photo_faces where photo_id = ${row.id}`.execute(k.db);
          for (const face of out.faces) {
            const iw = face.imgWidth ?? 0;
            if (face.box && iw > 0 && face.box.width / iw < FACE_MIN_WIDTH_RATIO) {
              tooSmall += 1;
              continue;
            }
            await assignCluster(
              k,
              Float32Array.from(face.emb),
              row.id,
              face.box
                ? {
                    left: face.box.left,
                    top: face.box.top,
                    width: face.box.width,
                    height: face.box.height,
                    imgWidth: face.imgWidth,
                    imgHeight: face.imgHeight,
                  }
                : null,
              Number(face.score) || 1,
            );
            faces += 1;
          }
          photos += 1;
        } catch (err) {
          k.log.warn(
            { photo: row.id, err: String((err as Error)?.message || err) },
            'face bbox backfill failed',
          );
          skipped += 1;
        }
      }

      const remaining = (
        await sql<{ n: number }>`
          select count(distinct i.id) as n
            from photo_faces f join photo_items i on i.id = f.photo_id
           where i.in_trash = 0 and f.box_left is null
        `.execute(k.db)
      ).rows[0];

      return {
        photos,
        faces,
        facesTooSmall: tooSmall,
        remaining: Number(remaining?.n ?? 0),
        skipped,
      };
    },
  );

  app.post(
    '/api/v1/photo/faces/dissolve',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceDissolve',
        tags: ['photo'],
        summary: '解散人脸簇（脸放回未分组，不删数据）',
        body: ref('PhotoFaceDissolveBody'),
        response: { 200: ref('PhotoFaceOk'), 404: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { clusterId?: string };
      const id = String(body.clusterId || '').trim();
      if (!id) return reply.code(400).send({ error: Err.badRequest, message: 'clusterId required' });
      const exists = (
        await sql<{ n: number }>`select count(*) as n from photo_face_clusters where id = ${id}`.execute(
          k.db,
        )
      ).rows[0];
      if (!Number(exists?.n)) {
        return reply.code(404).send({ error: Err.notFound, message: 'cluster not found' });
      }
      await db_transaction(k, async (trx: any) => {
        await sql`update photo_faces set cluster_id = null where cluster_id = ${id}`.execute(trx);
        await sql`delete from photo_face_clusters where id = ${id}`.execute(trx);
      });
      // 索引里还留着旧分组会污染后续归属，直接重置让它下次查询重建
      faceIndex.reset();
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/photo/faces/name',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceName',
        tags: ['photo'],
        summary: '给人脸簇命名（空串 = 取消命名）',
        body: ref('PhotoFaceNameBody'),
        response: { 200: ref('PhotoFaceOk'), 404: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { clusterId?: string; name?: string };
      const id = String(body.clusterId || '');
      const name = String(body.name || '')
        .trim()
        .slice(0, 64);
      const row = (
        await sql<{ id: string }>`select id from photo_face_clusters where id = ${id}`.execute(k.db)
      ).rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'cluster not found' });
      await sql`
        update photo_face_clusters set name = ${name || null}, updated_at = ${now()} where id = ${id}
      `.execute(k.db);
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/photo/faces/merge',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceMerge',
        tags: ['photo'],
        summary: '把一个人脸簇并入另一个（from → to）',
        body: ref('PhotoFaceMergeBody'),
        response: { 200: ref('PhotoFaceMergeResponse'), 400: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { fromId?: string; toId?: string };
      const fromId = String(body.fromId || '');
      const toId = String(body.toId || '');
      if (!fromId || !toId || fromId === toId) {
        return reply.code(400).send({ error: Err.badRequest, message: 'fromId and toId required' });
      }
      const target = (
        await sql<{ id: string; cover_photo_id: string | null }>`
          select id, cover_photo_id from photo_face_clusters where id = ${toId}
        `.execute(k.db)
      ).rows[0];
      const source = (
        await sql<{ id: string }>`select id from photo_face_clusters where id = ${fromId}`.execute(
          k.db,
        )
      ).rows[0];
      if (!target || !source) {
        return reply.code(400).send({ error: Err.badRequest, message: 'cluster not found' });
      }

      await faceIndex.load(k.db);
      const res = await mergeClusterPair(k, fromId, toId, String(req.user?.sub || ''));
      return { moved: res.moved, clusterId: toId };
    },
  );

  // 单张人脸移动 / 移出簇。整簇合并解决不了「这张脸其实认错了」——
  // 那是单张的归属问题，只能一张一张搬。
  app.post(
    '/api/v1/photo/faces/move',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceMove',
        tags: ['photo'],
        summary: '把单张人脸移到另一个簇（toClusterId=null 表示移出成未分组）',
        body: ref('PhotoFaceMoveBody'),
        response: { 200: ref('PhotoFaceMoveResponse'), 400: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { faceId?: string; toClusterId?: string | null };
      const faceId = String(body.faceId || '');
      if (!faceId) return reply.code(400).send({ error: Err.badRequest, message: 'faceId required' });
      const face = (
        await sql<{ id: string; cluster_id: string | null }>`
          select id, cluster_id from photo_faces where id = ${faceId}
        `.execute(k.db)
      ).rows[0];
      if (!face) return reply.code(400).send({ error: Err.badRequest, message: 'face not found' });

      const toClusterId =
        body.toClusterId == null || body.toClusterId === '' ? null : String(body.toClusterId);
      if (toClusterId) {
        const exists = (
          await sql<{ n: number }>`
            select count(*) as n from photo_face_clusters where id = ${toClusterId}
          `.execute(k.db)
        ).rows[0];
        if (Number(exists?.n) === 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'target cluster not found' });
        }
      }
      const fromClusterId = face.cluster_id ?? null;
      if (fromClusterId === toClusterId) return { ok: true, clusterId: toClusterId };

      await sql`update photo_faces set cluster_id = ${toClusterId} where id = ${faceId}`.execute(k.db);
      await refreshClusterStats(k.db, fromClusterId);
      await refreshClusterStats(k.db, toClusterId);
      await faceIndex.load(k.db);
      return { ok: true, clusterId: toClusterId };
    },
  );

  // 跨照片二次合并：先给候选（不改数据），用户逐对确认后再打 /faces/merge。
  // 候选不是 O(n²)：用每张脸的 KNN 跨簇投票攒「证据」，只对攒够证据的簇对算质心余弦，
  // 因此簇数上千也不会退化成百万次点积。
  app.post(
    '/api/v1/photo/faces/merge-candidates',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceMergeCandidates',
        tags: ['photo'],
        summary: '跨照片二次合并的候选簇对（只读，逐对确认后调 /faces/merge）',
        body: ref('PhotoFaceMergeCandidateBody'),
        response: { 200: ref('PhotoFaceMergeCandidateList') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { minSim?: number; minEvidence?: number; limit?: number };
      const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(v, hi));
      // 阈值缺省跟随聚类参数，而不是另外拍一个数：
      // rebuild 用 mergeClusterSim（0.76）合并簇，候选审阅却用 0.62 的话，
      // 用户看到的候选与自动合并的口径不是一套，越看越糊涂。
      const defaultSim = clamp(
        Number(process.env.COLANAS_FACE_MERGE_SIM) || paramsFromEnv().mergeClusterSim,
        0.3,
        0.99,
      );
      const minSim = clamp(Number(body.minSim) || defaultSim, 0.3, 0.99);
      const minEvidence = clamp(Number(body.minEvidence) || 2, 1, 50);
      const limit = clamp(Number(body.limit) || 30, 1, 200);

      await faceIndex.load(k.db);
      const clusterRows = (
        await sql<{
          id: string;
          name: string | null;
          size: number;
          centroid: Buffer | null;
          cover_face_id: string | null;
        }>`
          select id, name, size, centroid, cover_face_id
            from photo_face_clusters
           order by size desc
           limit 2000
        `.execute(k.db)
      ).rows;
      const clusters = new Map(
        clusterRows.map((r) => [
          r.id,
          { ...r, vec: r.centroid ? fromBuffer(r.centroid) : null },
        ]),
      );
      if (clusters.size < 2) return { items: [], scanned: clusters.size, pairs: 0 };

      const faceRows = (
        await sql<{ id: string; cluster_id: string | null; emb: Buffer }>`
          select id, cluster_id, emb from photo_faces where cluster_id is not null
        `.execute(k.db)
      ).rows;

      // 1) 跨簇近邻投票：同一个人被拆成两簇时，两簇的成员天生互为近邻
      const votes = new Map<string, number>();
      for (const f of faceRows) {
        const own = f.cluster_id;
        if (!own) continue;
        const nb = faceIndex.neighbors(fromBuffer(f.emb), 24);
        for (const n of nb) {
          if (!n.clusterId || n.clusterId === own) continue;
          if (!clusters.has(n.clusterId) || !clusters.has(own)) continue;
          const key = own < n.clusterId ? `${own}|${n.clusterId}` : `${n.clusterId}|${own}`;
          votes.set(key, (votes.get(key) || 0) + 1);
        }
      }

      // 2) 只对攒够证据的簇对算质心余弦（顺带得到可解释的 sim）
      const scored: Array<{
        fromId: string;
        toId: string;
        fromName: string | null;
        toName: string | null;
        fromSize: number;
        toSize: number;
        fromCoverFaceId: string | null;
        toCoverFaceId: string | null;
        sim: number;
        evidence: number;
      }> = [];
      for (const [key, evidence] of votes) {
        if (evidence < minEvidence) continue;
        const [aId, bId] = key.split('|');
        const a = clusters.get(aId);
        const b = clusters.get(bId);
        if (!a || !b || !a.vec || !b.vec) continue;
        let dot = 0;
        const len = Math.min(a.vec.length, b.vec.length);
        for (let d = 0; d < len; d += 1) dot += a.vec[d] * b.vec[d];
        if (dot < minSim) continue;
        const bigger = Number(a.size) >= Number(b.size) ? a : b;
        const smaller = bigger === a ? b : a;
        scored.push({
          fromId: smaller.id,
          toId: bigger.id,
          fromName: smaller.name,
          toName: bigger.name,
          fromSize: Number(smaller.size) || 0,
          toSize: Number(bigger.size) || 0,
          fromCoverFaceId: smaller.cover_face_id,
          toCoverFaceId: bigger.cover_face_id,
          sim: Math.round(dot * 1000) / 1000,
          evidence,
        });
      }
      scored.sort((x, y) => y.sim - x.sim || y.evidence - x.evidence);

      // 3) 同框冲突过滤：同一张照片里两张脸若分属两簇，合了就会出现"一张照片里两个自己"
      const items: typeof scored = [];
      for (const p of scored) {
        if (items.length >= limit) break;
        const conflict = (
          await sql<{ n: number }>`
            select count(*) as n from photo_faces fa
              join photo_faces fb on fb.photo_id = fa.photo_id
             where fa.cluster_id = ${p.fromId} and fb.cluster_id = ${p.toId}
          `.execute(k.db)
        ).rows[0];
        if (Number(conflict?.n) > 0) continue;
        items.push(p);
      }
      return { items, scanned: clusters.size, pairs: scored.length };
    },
  );

  // 撤消合并（按审计表回滚）。rebuild 的回滚是"整库回到上一次"，
  // 这里补的是"点错了某一对，把它单独退回来"。
  app.post(
    '/api/v1/photo/faces/merge-undo',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceMergeUndo',
        tags: ['photo'],
        summary: '撤消人脸合并（按审计记录还原被并掉的簇与成员）',
        body: ref('PhotoFaceMergeUndoBody'),
        response: { 200: ref('PhotoFaceMergeUndoResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { ids?: string[]; limit?: number };
      const owner = String(req.user?.sub || '');
      const limit = Math.max(1, Math.min(Number(body.limit) || 20, 100));
      const ids = (body.ids || []).slice(0, 100);
      const where =
        ids.length > 0
          ? sql`and id in (${sql.join(
              ids.map((id) => sql`${id}`),
              sql`, `,
            )})`
          : sql``;
      const logs = (
        await sql<{
          id: string;
          from_id: string;
          to_id: string;
          from_name: string | null;
          from_cover_face_id: string | null;
          from_centroid: Buffer | null;
          face_ids: string | null;
        }>`
          select id, from_id, to_id, from_name, from_cover_face_id, from_centroid, face_ids
            from photo_face_merge_log
           where undone_at is null and (owner_id = ${owner} or owner_id = '')
             ${where}
           order by created_at desc
           limit ${limit}
        `.execute(k.db)
      ).rows;

      let restored = 0;
      let movedFaces = 0;
      for (const log of logs) {
        let faceIds: string[] = [];
        try {
          faceIds = JSON.parse(log.face_ids || '[]') as string[];
        } catch {
          faceIds = [];
        }
        if (faceIds.length === 0) continue;
        const stillThere = (
          await sql<{ n: number }>`
            select count(*) as n from photo_face_clusters where id = ${log.to_id}
          `.execute(k.db)
        ).rows[0];
        if (Number(stillThere?.n) === 0) continue;

        await k.db.transaction().execute(async (trx: any) => {
          // 只有还留在目标簇里的成员才搬回（期间可能被用户又挪走了，不抢回来）
          const moved = await sql`
            update photo_faces set cluster_id = ${log.from_id}
             where cluster_id = ${log.to_id}
               and id in (${sql.join(
                 faceIds.map((id) => sql`${id}`),
                 sql`, `,
               )})
          `.execute(trx);
          await sql`
            insert or ignore into photo_face_clusters
              (id, name, size, cover_photo_id, centroid, created_at, cover_face_id)
            values (${log.from_id}, ${log.from_name}, 0, null, ${log.from_centroid}, ${now()},
                    ${log.from_cover_face_id})
          `.execute(trx);
          await refreshClusterStats(trx, log.from_id);
          await refreshClusterStats(trx, log.to_id);
          await sql`update photo_face_merge_log set undone_at = ${now()} where id = ${log.id}`.execute(
            trx,
          );
          movedFaces += Number(moved.numAffectedRows || 0);
        });
        restored += 1;
      }
      if (restored > 0) await faceIndex.load(k.db);
      return { restored, faces: movedFaces };
    },
  );

  app.post(
    '/api/v1/photo/faces/rebuild',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceRebuild',
        tags: ['photo'],
        summary: '全库重算人脸簇（先快照，可用 rollback 还原）',
        body: ref('PhotoFaceRebuildBody'),
        response: { 200: ref('PhotoFaceRebuildResponse'), 409: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { limit?: number };
      const limit = Math.max(1, Math.min(Number(body.limit) || 200000, 200000));

      const running = (
        await sql<{ id: string }>`
          select id from photo_face_rebuild_runs where finished_at is null limit 1
        `.execute(k.db)
      ).rows[0];
      if (running) {
        return reply.code(409).send({ error: Err.conflict, message: '已有重建任务在进行' });
      }

      const runId = `fr_${crypto.randomBytes(8).toString('hex')}`;
      const started = Date.now();
      await sql`
        insert into photo_face_rebuild_runs (id, owner_id, created_at)
        values (${runId}, ${req.user?.sub || ''}, ${now()})
      `.execute(k.db);

      await k.db.transaction().execute(async (trx: any) => {
        await sql`
          insert into photo_face_clusters_prev (run_id, id, name, size, cover_photo_id, centroid, created_at)
          select ${runId}, id, name, size, cover_photo_id, centroid, created_at from photo_face_clusters
        `.execute(trx);
        await sql`
          insert into photo_face_prev_map (run_id, face_id, cluster_id)
          select ${runId}, id, cluster_id from photo_faces
        `.execute(trx);
        await sql`delete from photo_face_clusters`.execute(trx);
        await sql`update photo_faces set cluster_id = null`.execute(trx);
      });

      faceIndex.reset();
      const rows = (
        await sql<{
          id: string;
          photo_id: string;
          emb: Buffer;
          score: number;
          cluster_id: string | null;
        }>`
          select f.id, f.photo_id, f.emb, f.score, f.cluster_id
            from photo_faces f
            join photo_items i on i.id = f.photo_id
           order by i.taken_at asc, f.id asc
           limit ${limit}
        `.execute(k.db)
      ).rows;

      // v2：从完整特征库重算全局分组（Mutual KNN + 多 seed Chinese Whispers + 质量分层 + must-link）。
      // 质量分：检测分数映射到 60..100，保证低分脸仍进入「待认领层」而不是被丢弃。
      const samples: ClusterSample[] = rows.map((r) => ({
        id: r.id,
        photoId: r.photo_id,
        photoKey: r.photo_id,
        vec: fromBuffer(r.emb),
        quality: Math.round(60 + Math.min(1, Math.max(0, Number(r.score) || 0)) * 40),
        oldClusterId: r.cluster_id,
      }));
      const params = paramsFromEnv();
      const report = clusterSamples(samples, params);

      const bySample = new Map(samples.map((s) => [s.id, s]));
      const idByKey = new Map<string, string>();
      const usedIds = new Set<string>();
      const nowTs = now();

      await k.db.transaction().execute(async (trx: any) => {
        for (const cluster of report.clusters) {
          // 新簇 id 尽量继承「成员最多的旧簇」：人工命名 / 封面得以保留
          const oldVotes = new Map<string, number>();
          for (const sampleId of cluster.members) {
            const old = bySample.get(sampleId)?.oldClusterId;
            if (old) oldVotes.set(old, (oldVotes.get(old) ?? 0) + 1);
          }
          const inherited = [...oldVotes.entries()]
            .sort((a, b) => b[1] - a[1])
            .find(([id, cnt]) => !usedIds.has(id) && cnt / cluster.members.length >= 0.5);
          const clusterId = inherited ? inherited[0] : crypto.randomUUID();
          usedIds.add(clusterId);
          idByKey.set(cluster.key, clusterId);

          const memberSql = sql.join(
            cluster.members.map((x) => sql`${x}`),
            sql`, `,
          );
          const dim = samples[0].vec.length;
          const centroid = new Float32Array(dim);
          for (const sampleId of cluster.members) {
            const v = bySample.get(sampleId)!.vec;
            for (let d = 0; d < dim; d += 1) centroid[d] += v[d] / cluster.members.length;
          }
          let norm = 0;
          for (let d = 0; d < dim; d += 1) norm += centroid[d] * centroid[d];
          norm = Math.sqrt(norm) || 1;
          for (let d = 0; d < dim; d += 1) centroid[d] /= norm;

          await sql`
            insert into photo_face_clusters (id, name, size, cover_photo_id, centroid, created_at, updated_at)
            values (${clusterId}, ${null},
                    (select count(distinct photo_id) from photo_faces where id in (${memberSql})),
                    (select photo_id from photo_faces where id in (${memberSql}) limit 1),
                    ${toBuffer(Array.from(centroid))}, ${nowTs}, ${nowTs})
          `.execute(trx);

          for (const sampleId of cluster.members) {
            await sql`update photo_faces set cluster_id = ${clusterId} where id = ${sampleId}`.execute(
              trx,
            );
          }
        }
      });

      // 内存索引按新分配重建（下一次增量识别用）
      for (const cluster of report.clusters) {
        const clusterId = idByKey.get(cluster.key)!;
        for (const sampleId of cluster.members) {
          faceIndex.add(sampleId, clusterId, new Float32Array(bySample.get(sampleId)!.vec));
        }
      }

      await sql`
        update photo_face_rebuild_runs
           set finished_at = ${nowTs}, faces = ${report.usedCount}, clusters = ${report.clusterCount},
               algo_version = ${report.algoVersion}, embedding_model = ${report.embeddingModel},
               preprocess_version = ${report.preprocessVersion}, params_json = ${JSON.stringify(report.params)},
               sample_count = ${report.sampleCount}, singleton_count = ${report.singletonCount},
               coverage = ${report.coverage}, elapsed_ms = ${report.elapsedMs}
         where id = ${runId}
      `.execute(k.db);

      return {
        runId,
        faces: report.usedCount,
        clusters: report.clusterCount,
        ms: Date.now() - started,
        coverage: report.coverage,
        elapsedMs: report.elapsedMs,
        algoVersion: ALGO_VERSION,
      };
    },
  );

  app.post(
    '/api/v1/photo/faces/rollback',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceRollback',
        tags: ['photo'],
        summary: '回滚一次全库重建',
        body: ref('PhotoFaceRollbackBody'),
        response: { 200: ref('PhotoFaceOk'), 404: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { runId?: string };
      const runId = String(body.runId || '');
      const run = (
        await sql<{ id: string; rolled_back_at: number | null }>`
          select id, rolled_back_at from photo_face_rebuild_runs where id = ${runId}
        `.execute(k.db)
      ).rows[0];
      if (!run) return reply.code(404).send({ error: Err.notFound, message: 'run not found' });
      if (run.rolled_back_at) return { ok: true };

      await k.db.transaction().execute(async (trx: any) => {
        await sql`delete from photo_face_clusters`.execute(trx);
        await sql`
          insert into photo_face_clusters (id, name, size, cover_photo_id, centroid, created_at, updated_at)
          select id, name, size, cover_photo_id, centroid, created_at, created_at
            from photo_face_clusters_prev where run_id = ${runId}
        `.execute(trx);
        await sql`
          update photo_faces
             set cluster_id = (select m.cluster_id from photo_face_prev_map m
                                where m.run_id = ${runId} and m.face_id = photo_faces.id)
           where id in (select face_id from photo_face_prev_map where run_id = ${runId})
        `.execute(trx);
        await sql`
          update photo_face_rebuild_runs set rolled_back_at = ${now()} where id = ${runId}
        `.execute(trx);
      });

      faceIndex.reset();
      return { ok: true };
    },
  );
}
