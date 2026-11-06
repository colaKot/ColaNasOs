import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import { EMB_DIM, now, ref } from './schemas';
import {
  ALGO_VERSION,
  EMBEDDING_MODEL,
  PREPROCESS_VERSION,
  clusterSamples,
  paramsFromEnv,
  type ClusterSample,
} from './cluster-v2';
import {
  aiConfig,
  faceTuning,
  FACE_MIN_WIDTH_RATIO,
  FACE_MIN_QUALITY,
  FACE_CLAIM_MIN_QUALITY,
  FACE_CLAIM_MAX_ABS_YAW,
  FACE_MAX_GROUP_FACES,
} from './config';
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

/**
 * 认领参数。增量识别从 aiConfig.tuning 读，离线重建用同一套缺省值，
 * 保证「重建出来的分组」和「以后新照片会进的分组」是同一口径。
 */
export interface ClaimParams {
  matchSim: number;
  minVotes: number;
  coldSim: number;
  consistencySim: number;
}

export function claimParams(k?: KernelApi): ClaimParams {
  const t = k ? faceTuning(k) : { matchSim: FACE_MATCH_SIM, minVotes: FACE_MIN_VOTES };
  return {
    matchSim: t.matchSim,
    minVotes: t.minVotes,
    coldSim: FACE_COLD_SIM,
    consistencySim: FACE_CONSISTENCY_SIM,
  };
}

export interface NeighborHit {
  clusterId: string;
  sim: number;
  quality: number;
  slot: number;
}

export interface SearchOptions {
  k?: number;
  minSim?: number;
  /** 邻居质量下限：低于它的样本不投票（对齐 findBestByVotes 的 quals 过滤） */
  minQuality?: number;
  /** 同一张照片里已经出现过的组，禁止再认领（同图必是两个人） */
  excludeClusters?: Set<string>;
  /** >0 时先按簇中心挑 topN 个候选簇，再在成员里做精确 KNN；离线重建用，避免 O(n²) */
  shortlist?: number;
}

export interface ClaimOptions {
  quality: number;
  poseYaw?: number | null;
  usedClusterIds?: Set<string>;
  shortlist?: number;
  params: ClaimParams;
}

export interface ClaimDecision {
  /** null = 质量太差，整张脸不入库分组 */
  clusterId: string | null;
  isNew: boolean;
  reason: 'claimed' | 'new' | 'low_quality_hold' | 'pose_hold' | 'dropped' | 'rejected' | 'frozen';
}

interface ClaimGroup {
  members: number[];
  sum: Float64Array;
  count: number;
  centroid: Float32Array | null;
}

/**
 * 人脸向量索引 + 认领决策。
 *
 * 除了 512 维特征，还要记住每个样本的 **质量分** 和 **所属组**：
 *   - 低质量样本可以给别人当参考吗？不行 —— 它们互相之间反而更像，会把大杂烩组的票数垫高；
 *   - 组中心一致性门需要组质心，不能每次都回表查；
 *   - 同图互斥需要「这张照片已经用过哪些组」，由调用方按照片维护。
 *
 * 增量识别用全量暴力 KNN（一次只来几张脸）；离线重建用 `shortlist` 先按簇中心
 * 筛候选簇，把 3.7 万 × 3.7 万降到 3.7 万 × 簇数，几十秒能跑完。
 */
export class FaceVectorIndex {
  ids: string[] = [];
  clusters: string[] = [];
  quals: number[] = [];
  photoIds: string[] = [];
  private data = new Float32Array(0);
  /** 去掉全局平均脸分量后的特征：所有相似度都在这一空间算 */
  private cdata = new Float32Array(0);
  private mean: Float32Array | null = null;
  count = 0;
  private loaded = false;
  private loading: Promise<void> | null = null;
  private groups = new Map<string, ClaimGroup>();
  private groupDirty = false;

  reset(): void {
    this.ids = [];
    this.clusters = [];
    this.quals = [];
    this.photoIds = [];
    this.data = new Float32Array(0);
    this.cdata = new Float32Array(0);
    this.mean = null;
    this.count = 0;
    this.groups.clear();
    this.groupDirty = false;
    this.loaded = true;
  }

  /**
   * 去掉「全局平均脸」分量。
   *
   * 实测本库任一人脸与全体均值方向的余弦平均 0.32 —— 不减掉它，一个混了上千人的大组
   * 质心会趋近全局均值，于是对**任何**新脸都有 ~0.32 的相似度：短名单永远排它第一，
   * 它再靠人数凑票数，最终把全库吸成一个黑洞（2026-11-06 首次重建实测 2324 张/组）。
   * 减掉公共分量后，混合组的质心趋近 0，短名单与一致性门同时恢复正常。
   */
  setMean(mean: Float32Array): void {
    this.mean = mean;
    this.rebuildCentered();
  }

  centerVec(vec: Float32Array): Float32Array {
    const m = this.mean;
    if (!m) return vec;
    let dot = 0;
    for (let d = 0; d < EMB_DIM; d += 1) dot += vec[d] * m[d];
    const out = new Float32Array(EMB_DIM);
    let norm = 0;
    for (let d = 0; d < EMB_DIM; d += 1) {
      out[d] = vec[d] - dot * m[d];
      norm += out[d] * out[d];
    }
    norm = Math.sqrt(norm) || 1;
    for (let d = 0; d < EMB_DIM; d += 1) out[d] /= norm;
    return out;
  }

  private rebuildCentered(): void {
    const out = new Float32Array(this.count * EMB_DIM);
    for (let i = 0; i < this.count; i += 1) {
      const b = i * EMB_DIM;
      out.set(this.centerVec(this.data.subarray(b, b + EMB_DIM)), b);
    }
    this.cdata = out;
    this.groupDirty = true;
  }

  /** 独立实例（离线重建）不需要从库里 load，直接标记为已加载 */
  markLoaded(): void {
    this.loaded = true;
  }

  /**
   * 让索引下次从库里重建。
   * `reset()` 会留下 `loaded=true` 的空索引 —— 组被解散 / 整库重建后如果只调 reset，
   * 后续 `load()` 直接返回，增量识别就再也看不到任何已有的人脸了。
   */
  invalidate(): void {
    this.reset();
    this.loaded = false;
    this.loading = null;
  }

  async load(db: any): Promise<void> {
    if (this.loaded) return;
    if (this.loading) return this.loading;
    this.loading = (async () => {
      const rows = (
        await sql<{
          id: string;
          cluster_id: string | null;
          emb: Buffer;
          score: number;
          quality: number | null;
          photo_id: string;
        }>`
          select id, cluster_id, emb, score, quality, photo_id
            from photo_faces where cluster_id is not null
        `.execute(db)
      ).rows;
      const n = rows.length;
      const data = new Float32Array(n * EMB_DIM);
      const ids: string[] = [];
      const clusters: string[] = [];
      const quals: number[] = [];
      const photoIds: string[] = [];
      for (let i = 0; i < n; i += 1) {
        const vec = fromBuffer(rows[i].emb);
        data.set(vec.subarray(0, EMB_DIM), i * EMB_DIM);
        ids.push(rows[i].id);
        clusters.push(String(rows[i].cluster_id));
        quals.push(faceQuality(rows[i].quality, rows[i].score));
        photoIds.push(rows[i].photo_id);
      }
      this.ids = ids;
      this.clusters = clusters;
      this.quals = quals;
      this.photoIds = photoIds;
      this.data = data;
      this.count = n;
      // 全局平均脸：增量与离线重建用同一套定义（各自从当前库全体人脸向量算）
      const mean = new Float32Array(EMB_DIM);
      for (let i = 0; i < n; i += 1) {
        const b = i * EMB_DIM;
        for (let d = 0; d < EMB_DIM; d += 1) mean[d] += data[b + d] / Math.max(1, n);
      }
      let mn = 0;
      for (let d = 0; d < EMB_DIM; d += 1) mn += mean[d] * mean[d];
      mn = Math.sqrt(mn) || 1;
      for (let d = 0; d < EMB_DIM; d += 1) mean[d] /= mn;
      this.mean = mean;
      this.rebuildCentered();
      this.loaded = true;
    })().finally(() => {
      this.loading = null;
    });
    return this.loading;
  }

  private ensureGroups(): void {
    if (!this.groupDirty) return;
    this.groups.clear();
    for (let slot = 0; slot < this.count; slot += 1) {
      const cid = this.clusters[slot];
      if (!cid) continue;
      let g = this.groups.get(cid);
      if (!g) {
        g = { members: [], sum: new Float64Array(EMB_DIM), count: 0, centroid: null };
        this.groups.set(cid, g);
      }
      g.members.push(slot);
      const base = slot * EMB_DIM;
      for (let d = 0; d < EMB_DIM; d += 1) g.sum[d] += this.cdata[base + d];
      g.count += 1;
    }
    this.groupDirty = false;
  }

  add(
    id: string,
    clusterId: string,
    vec: Float32Array,
    quality = 100,
    photoId = '',
  ): void {
    const need = (this.count + 1) * EMB_DIM;
    if (this.data.length < need) {
      const cap = Math.max(need, this.data.length * 2, 1024 * EMB_DIM);
      const next = new Float32Array(cap);
      next.set(this.data);
      this.data = next;
      const cnext = new Float32Array(cap);
      cnext.set(this.cdata);
      this.cdata = cnext;
    }
    const slot = this.count;
    this.data.set(vec.subarray(0, EMB_DIM), slot * EMB_DIM);
    const cv = this.centerVec(vec);
    this.cdata.set(cv.subarray(0, EMB_DIM), slot * EMB_DIM);
    this.ids.push(id);
    this.clusters.push(clusterId);
    this.quals.push(quality);
    this.photoIds.push(photoId);
    this.count += 1;

    this.ensureGroups();
    let g = this.groups.get(clusterId);
    if (!g) {
      g = { members: [], sum: new Float64Array(EMB_DIM), count: 0, centroid: null };
      this.groups.set(clusterId, g);
    }
    g.members.push(slot);
    for (let d = 0; d < EMB_DIM; d += 1) g.sum[d] += cv[d] || 0;
    g.count += 1;
    g.centroid = null;
  }

  /** 只在簇迁移时改归属，向量不动（组统计下次用到时重建） */
  setCluster(faceId: string, clusterId: string): void {
    const idx = this.ids.indexOf(faceId);
    if (idx >= 0) {
      this.clusters[idx] = clusterId;
      this.groupDirty = true;
    }
  }

  groupSize(clusterId: string): number {
    this.ensureGroups();
    return this.groups.get(clusterId)?.count || 0;
  }

  /** 组中心（成员均值 + L2 归一化）；缓存到下次成员变动 */
  centroidOf(clusterId: string): Float32Array | null {
    this.ensureGroups();
    const g = this.groups.get(clusterId);
    if (!g || g.count === 0) return null;
    if (!g.centroid) {
      const c = new Float32Array(EMB_DIM);
      let norm = 0;
      for (let d = 0; d < EMB_DIM; d += 1) {
        c[d] = g.sum[d] / g.count;
        norm += c[d] * c[d];
      }
      norm = Math.sqrt(norm) || 1;
      for (let d = 0; d < EMB_DIM; d += 1) c[d] /= norm;
      g.centroid = c;
    }
    return g.centroid;
  }

  /** 落库用的原始空间质心（展示 / 合并候选仍在原始空间比对） */
  rawCentroidOf(clusterId: string): Float32Array | null {
    this.ensureGroups();
    const g = this.groups.get(clusterId);
    if (!g || g.count === 0) return null;
    const c = new Float32Array(EMB_DIM);
    let norm = 0;
    for (const slot of g.members) {
      const base = slot * EMB_DIM;
      for (let d = 0; d < EMB_DIM; d += 1) c[d] += this.data[base + d] / g.count;
    }
    for (let d = 0; d < EMB_DIM; d += 1) norm += c[d] * c[d];
    norm = Math.sqrt(norm) || 1;
    for (let d = 0; d < EMB_DIM; d += 1) c[d] /= norm;
    return c;
  }

  private dotAt(slot: number, vec: Float32Array): number {
    const base = slot * EMB_DIM;
    let dot = 0;
    for (let d = 0; d < EMB_DIM; d += 1) dot += this.cdata[base + d] * vec[d];
    return dot;
  }

  /** 过滤式 KNN：minSim / 邻居质量 / 同图互斥 / 候选簇短名单 */
  search(vec: Float32Array, opts: SearchOptions = {}): NeighborHit[] {
    const n = this.count;
    if (n === 0) return [];
    const qv = this.centerVec(vec);
    const limit = Math.max(1, Math.min(opts.k ?? FACE_NEIGHBOR_K, n));
    const minSim = opts.minSim ?? -1;
    const minQuality = opts.minQuality ?? 0;
    const exclude = opts.excludeClusters;

    let slots: number[] | null = null;
    const shortlist = opts.shortlist ?? 0;
    if (shortlist > 0) {
      this.ensureGroups();
      // 只维护 size=shortlist 的最小堆，不要每查一次就把上千个组全排序
      const top: Array<{ cid: string; sim: number }> = [];
      for (const cid of this.groups.keys()) {
        const c = this.centroidOf(cid);
        if (!c) continue;
        const sim = this.dotVec(c, qv);
        if (top.length < shortlist) {
          top.push({ cid, sim });
          if (top.length === shortlist) top.sort((a, b) => a.sim - b.sim);
        } else if (sim > top[0].sim) {
          top[0] = { cid, sim };
          let i = 0;
          while (i + 1 < shortlist && top[i].sim > top[i + 1].sim) {
            const t = top[i];
            top[i] = top[i + 1];
            top[i + 1] = t;
            i += 1;
          }
        }
      }
      const picked = new Set(top.map((x) => x.cid));
      slots = [];
      for (const [cid, g] of this.groups) {
        if (!picked.has(cid)) continue;
        for (let m = 0; m < g.members.length; m += 1) slots.push(g.members[m]);
      }
    }

    const total = slots ? slots.length : n;
    const best: NeighborHit[] = [];
    for (let s = 0; s < total; s += 1) {
      const i = slots ? slots[s] : s;
      const cid = this.clusters[i];
      if (!cid || (exclude && exclude.has(cid))) continue;
      if (minQuality > 0 && this.quals[i] < minQuality) continue;
      const sim = this.dotAt(i, qv);
      if (sim < minSim) continue;
      if (best.length < limit) {
        best.push({ clusterId: cid, sim, quality: this.quals[i], slot: i });
        best.sort((a, b) => a.sim - b.sim);
      } else if (sim > best[0].sim) {
        best[0] = { clusterId: cid, sim, quality: this.quals[i], slot: i };
        best.sort((a, b) => a.sim - b.sim);
      }
    }
    return best.reverse();
  }

  /** 两个「已中心化」向量的余弦（点积即可） */
  dotVec(a: Float32Array, b: Float32Array): number {
    let dot = 0;
    for (let d = 0; d < EMB_DIM; d += 1) dot += a[d] * b[d];
    return dot;
  }

  /** 兼容旧的跨簇合并候选查询 */
  neighbors(vec: Float32Array, k = FACE_NEIGHBOR_K): Array<{ clusterId: string; sim: number }> {
    return this.search(vec, { k }).map((h) => ({ clusterId: h.clusterId, sim: h.sim }));
  }

  /**
   * 认领一张脸。只做决策 + 返回组 id，**不写库、不往索引里加脸**；
   * 调用方落库后必须再 `add()`，否则后续邻居看不到这张脸。
   *
   * 对齐参考实现的四道门：
   *   MIN_QUALITY 丢弃 / 低质量与极端侧脸只独立成组 / 邻居质量过滤 /
   *   组中心一致性（只对成型组）/ 冷启动只允许目标组本身还没成型。
   */
  claim(vec: Float32Array, opts: ClaimOptions): ClaimDecision {
    const P = opts.params;
    const q = Number(opts.quality) || 0;
    if (q < FACE_MIN_QUALITY) return { clusterId: null, isNew: false, reason: 'dropped' };

    const yaw = opts.poseYaw == null ? null : Math.abs(Number(opts.poseYaw));
    const poseOk =
      FACE_CLAIM_MAX_ABS_YAW <= 0 ||
      yaw === null ||
      !Number.isFinite(yaw) ||
      yaw <= FACE_CLAIM_MAX_ABS_YAW;
    const canClaim = q >= FACE_CLAIM_MIN_QUALITY && poseOk;
    if (!canClaim) {
      return {
        clusterId: crypto.randomUUID(),
        isNew: true,
        reason: poseOk ? 'low_quality_hold' : 'pose_hold',
      };
    }

    const hits = this.search(vec, {
      k: FACE_NEIGHBOR_K,
      minSim: P.matchSim,
      minQuality: FACE_CLAIM_MIN_QUALITY,
      excludeClusters: opts.usedClusterIds,
      shortlist: opts.shortlist ?? 0,
    });

    // 按组投票：票数优先，票数相同看最高相似度
    const votes = new Map<string, { count: number; best: number }>();
    for (const h of hits) {
      const rec = votes.get(h.clusterId) || { count: 0, best: 0 };
      rec.count += 1;
      if (h.sim > rec.best) rec.best = h.sim;
      votes.set(h.clusterId, rec);
    }
    let picked: { id: string; count: number; best: number } | null = null;
    for (const [id, rec] of votes) {
      if (
        !picked ||
        rec.count > picked.count ||
        (rec.count === picked.count && rec.best > picked.best)
      ) {
        picked = { id, count: rec.count, best: rec.best };
      }
    }
    if (!picked) return { clusterId: crypto.randomUUID(), isNew: true, reason: 'new' };

    const size = this.groupSize(picked.id);
    // 冻结门：一个组滚到上千张后成员覆盖了各种长相，任何新脸都能凑出票数。
    // 到阈值就停止吸纳，宁可同一个人被拆成两个干净组。
    if (FACE_MAX_GROUP_FACES > 0 && size >= FACE_MAX_GROUP_FACES) {
      return { clusterId: crypto.randomUUID(), isNew: true, reason: 'frozen' };
    }
    // 冷启动兜底：只有「目标组本身凑不出 minVotes 票」时才允许单票认领。
    // 大组只命中 1 张说明是碰巧近，绝不能放行（旧实现这里没判断 size，是假组扩张的主因之一）。
    const enough =
      picked.count >= P.minVotes ||
      (picked.count >= 1 && picked.best >= P.coldSim && size > 0 && size < P.minVotes);
    if (!enough) return { clusterId: crypto.randomUUID(), isNew: true, reason: 'new' };

    // 组中心一致性门：只对成型组生效，否则 0.58 > 0.52 会把冷启动全挡死。
    if (size >= P.minVotes) {
      const center = this.centroidOf(picked.id);
      if (center && this.dotVec(this.centerVec(vec), center) < P.consistencySim) {
        return { clusterId: crypto.randomUUID(), isNew: true, reason: 'rejected' };
      }
      // 第二道：与「最好的那张邻居」也不够像 ⇒ 只是靠组里人多凑票，判为误认领
      if (picked.best < P.consistencySim) {
        return { clusterId: crypto.randomUUID(), isNew: true, reason: 'rejected' };
      }
    }
    if (opts.usedClusterIds?.has(picked.id)) {
      return { clusterId: crypto.randomUUID(), isNew: true, reason: 'new' };
    }
    return { clusterId: picked.id, isNew: false, reason: 'claimed' };
  }
}

/** 0..100 质量分：优先用迁移回填的 quality，老行按 score × 100 推 */
export function faceQuality(quality: number | null | undefined, score: number): number {
  const q = Number(quality);
  if (Number.isFinite(q) && q > 0) return Math.max(0, Math.min(100, q));
  return Math.round(Math.max(0, Math.min(1, Number(score) || 0)) * 100);
}

export const faceIndex = new FaceVectorIndex();

export interface AssignClusterIdOptions {
  quality: number;
  poseYaw?: number | null;
  usedClusterIds?: Set<string>;
  shortlist?: number;
}

/** 按护栏给一张脸定归属，并同步 photo_face_clusters 的 centroid / size */
export async function assignClusterId(
  k: KernelApi,
  emb: Float32Array,
  opts: AssignClusterIdOptions,
): Promise<string | null> {
  await faceIndex.load(k.db);
  const decision = faceIndex.claim(emb, {
    quality: opts.quality,
    poseYaw: opts.poseYaw,
    usedClusterIds: opts.usedClusterIds,
    shortlist: opts.shortlist ?? 0,
    params: claimParams(k),
  });
  if (!decision.clusterId) return null;

  if (decision.isNew) {
    await sql`
      insert into photo_face_clusters (id, name, size, cover_photo_id, centroid, created_at, updated_at)
      values (${decision.clusterId}, ${null}, 1, ${null}, ${toBuffer(Array.from(emb))}, ${now()}, ${now()})
    `.execute(k.db);
    return decision.clusterId;
  }

  // 只有够格的样本才推动组中心：低分 / 极端侧脸根本进不了这里（它们各自独立成组）。
  const w = faceIndex.groupSize(decision.clusterId);
  const centroid = faceIndex.rawCentroidOf(decision.clusterId);
  const merged = new Float32Array(EMB_DIM);
  let norm = 0;
  for (let i = 0; i < EMB_DIM; i += 1) {
    merged[i] = ((centroid?.[i] ?? 0) * w + emb[i]) / (w + 1);
    norm += merged[i] * merged[i];
  }
  norm = Math.sqrt(norm) || 1;
  for (let i = 0; i < EMB_DIM; i += 1) merged[i] /= norm;
  await sql`
    update photo_face_clusters
       set centroid = ${toBuffer(Array.from(merged))}, size = ${w + 1}, updated_at = ${now()}
     where id = ${decision.clusterId}
  `.execute(k.db);
  return decision.clusterId;
}

export interface FaceBox {
  left: number;
  top: number;
  width: number;
  height: number;
  imgWidth?: number;
  imgHeight?: number;
}

export interface AssignClusterInput {
  /** 0..100；低于 FACE_MIN_QUALITY 直接丢弃 */
  quality: number;
  /** 0..1 检测置信度（photo_faces.score 保留原量纲） */
  score?: number;
  poseYaw?: number | null;
  poseRoll?: number | null;
  poseIod?: number | null;
  /** 同一张照片共用同一个 Set：里面出现过的组不再被本图第二张脸认领 */
  usedClusterIds?: Set<string>;
  box?: FaceBox | null;
}

/** 分析流程用：护栏认领 + 插入人脸（含 bbox / quality / pose）+ 更新索引 + 补封面 */
export async function assignCluster(
  k: KernelApi,
  emb: Float32Array,
  photoId: string,
  input: AssignClusterInput,
): Promise<{ clusterId: string; faceId: string } | null> {
  const quality = faceQuality(input.quality, input.score ?? input.quality / 100);
  const clusterId = await assignClusterId(k, emb, {
    quality,
    poseYaw: input.poseYaw,
    usedClusterIds: input.usedClusterIds,
  });
  if (!clusterId) return null;
  // 独立成组的低质量 / 侧脸也要占住本图的名额，否则第二张脸可能又认领到它
  input.usedClusterIds?.add(clusterId);

  const box = input.box ?? null;
  const faceId = crypto.randomUUID();
  await sql`
    insert into photo_faces
      (id, photo_id, emb, cluster_id, score, quality, pose_yaw, pose_roll, pose_iod, created_at,
       box_left, box_top, box_width, box_height, img_width, img_height)
    values (${faceId}, ${photoId}, ${toBuffer(Array.from(emb))}, ${clusterId},
            ${input.score ?? quality / 100}, ${quality},
            ${input.poseYaw ?? null}, ${input.poseRoll ?? null}, ${input.poseIod ?? null}, ${now()},
            ${box ? Math.round(box.left) : null}, ${box ? Math.round(box.top) : null},
            ${box ? Math.round(box.width) : null}, ${box ? Math.round(box.height) : null},
            ${box?.imgWidth ?? null}, ${box?.imgHeight ?? null})
  `.execute(k.db);
  await sql`
    update photo_face_clusters set cover_photo_id = ${photoId}
     where id = ${clusterId} and (cover_photo_id is null or cover_photo_id = '')
  `.execute(k.db);
  faceIndex.add(faceId, clusterId, emb, quality, photoId);
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

export interface RegroupRow {
  id: string;
  photo_id: string;
  emb: Buffer;
  score: number;
  quality: number | null;
  pose_yaw: number | null;
  cluster_id: string | null;
}

export interface RegroupReport {
  faces: number;
  clusters: number;
  singletonCount: number;
  coverage: number;
  elapsedMs: number;
  dropped: number;
  held: number;
  claimed: number;
  created: number;
  /** 被体检判定为链式大组并拆开的数量 */
  splitClusters: number;
  algoVersion: string;
  params: ClaimParams;
}

export const CLAIM_ALGO_VERSION = 'face-claim-guard-v1';

interface RegroupPart {
  key: string;
  ids: string[];
}

/**
 * 大组体检 + 拆分（对应参考实现「组体检 / 溶解垃圾簇」的一次性离线版）。
 *
 * 顺序认领天然会「链式吸附」：A 像 B、B 像 C、C 像 D …… 每张新脸都只和当前质心
 * 差一点点，几百步后首尾两人已经完全不像，却还留在同一个组里。实测首次重建就出现
 * 4 个 1000 张的假人物组，组内平均相似度只有 0.47~0.58（干净小组是 0.62~0.70）。
 *
 * 处理办法：对 ≥60 张且抽样内聚度 <0.60 的组，按「种子代表」重新切分 —— 每张脸
 * 只和种子比（不是和最近的成员比），所以链式连接会被切断。切完每组都紧抱一个
 * 高质量种子，单张脸则退回独立组（被 minShowCount 隐藏，不污染人物墙）。
 */
function splitLooseParts(
  engine: FaceVectorIndex,
  membersOf: Map<string, string[]>,
  qualityOf: Map<string, number>,
  rawVecOf: (id: string) => Float32Array,
): { parts: RegroupPart[]; splitCount: number } {
  const minSize = Number(process.env.COLANAS_FACE_SPLIT_MIN) || 60;
  const cohesionGate = Number(process.env.COLANAS_FACE_SPLIT_COHESION) || 0.6;
  const leaderSim = Number(process.env.COLANAS_FACE_SPLIT_SIM) || 0.62;
  const maxLeaders = Number(process.env.COLANAS_FACE_SPLIT_LEADERS) || 64;
  const parts: RegroupPart[] = [];
  let splitCount = 0;

  for (const [key, ids] of membersOf) {
    if (ids.length < minSize) {
      parts.push({ key, ids });
      continue;
    }
    const centered = new Map<string, Float32Array>();
    const cv = (id: string): Float32Array => {
      let v = centered.get(id);
      if (!v) {
        v = engine.centerVec(rawVecOf(id));
        centered.set(id, v);
      }
      return v;
    };
    // 抽样算内聚度，干净的组直接放行（不必把正常人物拆开）
    const step = Math.max(1, Math.floor(ids.length / 120));
    const sample: Float32Array[] = [];
    for (let i = 0; i < ids.length; i += step) sample.push(cv(ids[i]));
    let sum = 0;
    let count = 0;
    for (let a = 0; a < sample.length; a += 1) {
      for (let b = a + 1; b < sample.length; b += 1) {
        sum += engine.dotVec(sample[a], sample[b]);
        count += 1;
      }
    }
    const cohesion = count ? sum / count : 1;
    if (cohesion >= cohesionGate) {
      parts.push({ key, ids });
      continue;
    }
    splitCount += 1;
    const ordered = [...ids].sort((a, b) => (qualityOf.get(b) ?? 0) - (qualityOf.get(a) ?? 0));
    const leaders: Array<{ seed: Float32Array; ids: string[] }> = [];
    const loose: string[] = [];
    for (const id of ordered) {
      const v = cv(id);
      let best: { seed: Float32Array; ids: string[] } | null = null;
      let bestSim = -1;
      for (const l of leaders) {
        const s = engine.dotVec(l.seed, v);
        if (s >= leaderSim && s > bestSim) {
          best = l;
          bestSim = s;
        }
      }
      if (best) best.ids.push(id);
      else if (leaders.length < maxLeaders) leaders.push({ seed: v, ids: [id] });
      else loose.push(id);
    }
    leaders.forEach((l, j) => parts.push({ key: `${key}#${j}`, ids: l.ids }));
    loose.forEach((id, j) => parts.push({ key: `${key}#x${j}`, ids: [id] }));
  }
  return { parts, splitCount };
}

/**
 * 离线重新分组：**不重跑模型推理**，只用 photo_faces 里已有的 512 维向量，
 * 按时间顺序「重放」一遍增量认领（同一套 ClaimEngine 护栏）。
 *
 * 为什么不沿用 v2 的全局图聚类：重建出来的分组必须和「以后新照片会被分到哪一组」
 * 口径一致，否则重建完立刻又会被增量逻辑滚回大杂烩。重放是唯一能保证一致的做法。
 *
 * 排序 = taken_at 升序（与增量识别新照片到来的顺序一致），同一张照片共用一份
 * usedClusterIds，所以同框两张脸绝不会并进同一个人。
 */
export async function regroupByClaim(
  k: KernelApi,
  rows: RegroupRow[],
  oldNames: Map<string, string> = new Map(),
): Promise<RegroupReport> {
  const t0 = Date.now();
  const engine = new FaceVectorIndex();
  engine.markLoaded();
  // 重建前先把全局平均脸算出来，整个过程用同一套中心化空间；
  // 增量路径在 load() 里按当前库自行计算，两者口径一致。
  const mean = new Float32Array(EMB_DIM);
  for (const r of rows) {
    const v = fromBuffer(r.emb);
    for (let d = 0; d < EMB_DIM; d += 1) mean[d] += v[d] / Math.max(1, rows.length);
  }
  let mn = 0;
  for (let d = 0; d < EMB_DIM; d += 1) mn += mean[d] * mean[d];
  mn = Math.sqrt(mn) || 1;
  for (let d = 0; d < EMB_DIM; d += 1) mean[d] /= mn;
  engine.setMean(mean);
  const params = claimParams(k);
  const shortlist = Math.max(
    8,
    Math.min(64, Number(process.env.COLANAS_FACE_REGROUP_SHORTLIST) || 32),
  );

  const assigned = new Map<string, string>();
  const membersOf = new Map<string, string[]>();
  const photoOf = new Map<string, string>();
  const oldOf = new Map<string, string | null>();
  const qualityOf = new Map<string, number>();
  let dropped = 0;
  let held = 0;
  let claimed = 0;
  let created = 0;
  // 按 photo_id 分组维护，不能靠「相邻行的 photo_id 变了」来换集合：
  // 大量连拍照片 taken_at 相同，faces 会按 id 交错，相邻两行往往来自不同照片，
  // 那样同图互斥几乎完全失效（首次重建实测同框冲突从 702 涨到 1607）。
  const usedByPhoto = new Map<string, Set<string>>();

  for (let i = 0; i < rows.length; i += 1) {
    const r = rows[i];
    let used = usedByPhoto.get(r.photo_id);
    if (!used) {
      used = new Set<string>();
      usedByPhoto.set(r.photo_id, used);
    }
    const quality = faceQuality(r.quality, r.score);
    qualityOf.set(r.id, quality);
    const vec = fromBuffer(r.emb);
    const d = engine.claim(vec, {
      quality,
      poseYaw: r.pose_yaw,
      usedClusterIds: used,
      shortlist,
      params,
    });
    if (!d.clusterId) {
      dropped += 1;
      continue;
    }
    if (d.isNew) created += 1;
    else claimed += 1;
    if (d.reason === 'low_quality_hold' || d.reason === 'pose_hold') held += 1;

    const cid = d.clusterId;
    engine.add(r.id, cid, vec, quality, r.photo_id);
    used.add(cid);
    assigned.set(r.id, cid);
    oldOf.set(r.id, r.cluster_id);
    photoOf.set(r.id, r.photo_id);
    let list = membersOf.get(cid);
    if (!list) {
      list = [];
      membersOf.set(cid, list);
    }
    list.push(r.id);

    if (i > 0 && i % 5000 === 0) {
      k.log.info(
        { at: i, total: rows.length, groups: membersOf.size, sec: Math.round((Date.now() - t0) / 1000) },
        'photo.faces regroup progress',
      );
    }
  }

  const rowById = new Map(rows.map((r) => [r.id, r]));
  const rawVecOf = (id: string): Float32Array => fromBuffer(rowById.get(id)!.emb);
  const { parts, splitCount } = splitLooseParts(engine, membersOf, qualityOf, rawVecOf);
  const partOfFace = new Map<string, string>();
  for (const p of parts) for (const id of p.ids) partOfFace.set(id, p.key);

  // 人工命名要跟着走：新簇里 ≥50% 成员来自同一个旧簇且旧簇有名字 ⇒ 继承旧簇 id + 名字。
  // 没名字的库（当前真机就是）全部换新 id，行为更干净。
  const idByPart = new Map<string, string>();
  const taken = new Set<string>();
  for (const p of parts) {
    const votes = new Map<string, number>();
    for (const id of p.ids) {
      const old = oldOf.get(id);
      if (old) votes.set(old, (votes.get(old) ?? 0) + 1);
    }
    const inheritable = [...votes.entries()]
      .filter(([old, cnt]) => oldNames.has(old) && !taken.has(old) && cnt / p.ids.length >= 0.5)
      .sort((a, b) => b[1] - a[1])[0];
    const finalId = inheritable ? inheritable[0] : crypto.randomUUID();
    taken.add(finalId);
    idByPart.set(p.key, finalId);
  }
  const nameOf = new Map<string, string | null>();
  for (const [key, finalId] of idByPart) nameOf.set(key, oldNames.get(finalId) ?? null);

  const nowTs = now();
  await k.db.transaction().execute(async (trx: any) => {
    for (const p of parts) {
      const cid = idByPart.get(p.key)!;
      const centroid = new Float32Array(EMB_DIM);
      const photos = new Set<string>();
      for (const id of p.ids) {
        const v = rawVecOf(id);
        for (let d = 0; d < EMB_DIM; d += 1) centroid[d] += v[d] / p.ids.length;
        const ph = photoOf.get(id);
        if (ph) photos.add(ph);
      }
      let nn = 0;
      for (let d = 0; d < EMB_DIM; d += 1) nn += centroid[d] * centroid[d];
      nn = Math.sqrt(nn) || 1;
      for (let d = 0; d < EMB_DIM; d += 1) centroid[d] /= nn;
      const coverPhoto = photoOf.get(p.ids[0]) ?? null;
      await sql`
        insert into photo_face_clusters
          (id, name, size, cover_photo_id, centroid, created_at, updated_at)
        values (${cid}, ${nameOf.get(p.key) ?? null}, ${photos.size},
                ${coverPhoto}, ${toBuffer(Array.from(centroid))}, ${nowTs}, ${nowTs})
      `.execute(trx);
    }
    for (const [faceId, nid] of assigned) {
      const key = partOfFace.get(faceId);
      if (!key) continue;
      await sql`update photo_faces set cluster_id = ${idByPart.get(key)!} where id = ${faceId}`.execute(
        trx,
      );
    }
  });

  // 让下一次增量识别从库里重新载入（reset 会留下 loaded=true 的空索引，是个老坑）
  faceIndex.invalidate();

  const singletonCount = parts.filter((p) => p.ids.length === 1).length;
  return {
    faces: assigned.size,
    clusters: parts.length,
    singletonCount,
    coverage: rows.length ? Number(((assigned.size / rows.length) * 100).toFixed(2)) : 0,
    elapsedMs: Date.now() - t0,
    dropped,
    held,
    claimed,
    created,
    splitClusters: splitCount,
    algoVersion: CLAIM_ALGO_VERSION,
    params,
  };
}

/** 从快照表还原一次重建（正常回滚和「重建中途失败自动兜底」共用） */
async function restoreFaceSnapshot(k: KernelApi, runId: string): Promise<void> {
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
    await sql`update photo_face_rebuild_runs set rolled_back_at = ${now()} where id = ${runId}`.execute(
      trx,
    );
  });
  faceIndex.invalidate();
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
   * 构图照参考实现：以人脸框中心为基准，按最长边外扩 `FACE_IMAGE_EXTEND`（默认 20%），
   * 再向上偏移 `FACE_IMAGE_TOP_EXTRA`（默认 12%）—— 人脸在头像里偏下一点才自然，
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
        // 构图对齐参考实现：最长边外扩 20%、再向上偏移 12%。
        // 之前写死 30% 会把肩膀/背景一起裁进来，头像墙看起来像「碎图」。
        const extend = Number(process.env.COLANAS_FACE_IMAGE_EXTEND ?? 0.2);
        const topExtra = Number(process.env.COLANAS_FACE_IMAGE_TOP_EXTRA ?? 0.12);
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
              quality?: number;
              pose?: { yaw: number | null; roll: number | null; iod?: number } | null;
              emb: number[];
              box?: { left: number; top: number; width: number; height: number } | null;
              imgWidth?: number;
              imgHeight?: number;
            }>;
          }>('analyze', { src: abs, faces: true, scenes: false, embed: false }, 600_000);

          // 同一个人在这张照片里的人脸行整体替换（旧行没有坐标，留着只会重复计数）
          await sql`delete from photo_faces where photo_id = ${row.id}`.execute(k.db);
          const usedClusterIds = new Set<string>();
          for (const face of out.faces) {
            const iw = face.imgWidth ?? 0;
            if (face.box && iw > 0 && face.box.width / iw < FACE_MIN_WIDTH_RATIO) {
              tooSmall += 1;
              continue;
            }
            const res = await assignCluster(k, Float32Array.from(face.emb), row.id, {
              quality: face.quality ?? Math.round((Number(face.score) || 0) * 100),
              score: Number(face.score) || 0,
              poseYaw: face.pose?.yaw ?? null,
              poseRoll: face.pose?.roll ?? null,
              poseIod: face.pose?.iod ?? null,
              usedClusterIds,
              box: face.box
                ? {
                    left: face.box.left,
                    top: face.box.top,
                    width: face.box.width,
                    height: face.box.height,
                    imgWidth: face.imgWidth,
                    imgHeight: face.imgHeight,
                  }
                : null,
            });
            if (res) faces += 1;
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
      // 索引里还留着旧分组会污染后续归属；invalidate 让下次 load 真正回表重建
      faceIndex.invalidate();
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
      faceIndex.invalidate();
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
      if (restored > 0) {
        faceIndex.invalidate();
        await faceIndex.load(k.db);
      }
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
        await sql<{ id: string; created_at: number }>`
          select id, created_at from photo_face_rebuild_runs where finished_at is null limit 1
        `.execute(k.db)
      ).rows[0];
      // 进程被杀 / 请求被断开时不会走到 finished_at，老记录会把重建永久锁死在 409。
      // 超过 30 分钟视为已废弃（重建本身远不到 30 分钟），收尾后放行。
      if (running) {
        const stale = Number(running.created_at) > 0 && now() - Number(running.created_at) > 1800;
        if (!stale) {
          return reply.code(409).send({ error: Err.conflict, message: '已有重建任务在进行' });
        }
        k.log.warn({ runId: running.id, createdAt: running.created_at }, 'photo.faces stale rebuild run closed');
        await sql`
          update photo_face_rebuild_runs set finished_at = ${now()} where id = ${running.id}
        `.execute(k.db);
      }

      const runId = `fr_${crypto.randomBytes(8).toString('hex')}`;
      const started = Date.now();
      await sql`
        insert into photo_face_rebuild_runs (id, owner_id, created_at)
        values (${runId}, ${req.user?.sub || ''}, ${now()})
      `.execute(k.db);

      // 旧分组要在清空之前读出来：清空后再 select f.cluster_id 全是 null，
      // 旧实现在这里把 must-link / 命名继承悄悄变成了空操作（2026-11-06 发现）。
      const rows = (
        await sql<RegroupRow>`
          select f.id, f.photo_id, f.emb, f.score, f.quality, f.pose_yaw, f.cluster_id
            from photo_faces f
            join photo_items i on i.id = f.photo_id
           where i.in_trash = 0
           order by i.taken_at asc, f.id asc
           limit ${limit}
        `.execute(k.db)
      ).rows;
      const oldNameRows = (
        await sql<{ id: string; name: string }>`
          select id, name from photo_face_clusters where name is not null and name <> ''
        `.execute(k.db)
      ).rows;
      const oldNames = new Map(oldNameRows.map((r) => [r.id, r.name]));

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
      faceIndex.invalidate();

      // 默认 = 护栏认领重放（与增量识别同一口径）；COLANAS_FACE_REBUILD_ALGO=v2 可回到全局图聚类。
      const algo = String(process.env.COLANAS_FACE_REBUILD_ALGO || 'claim').toLowerCase();
      if (algo === 'claim') {
        let report: RegroupReport;
        try {
          report = await regroupByClaim(k, rows, oldNames);
        } catch (err) {
          // 重建可能跑几分钟；中途异常（含请求被断开）必须自动还原，
          // 否则库停在「簇被清空」的半成品状态，而且 run 行没 finished_at 会一直 409 卡死。
          k.log.warn({ runId, err: String((err as Error)?.message || err) }, 'photo.faces regroup failed, restoring');
          await restoreFaceSnapshot(k, runId);
          throw err;
        }
        await sql`
          update photo_face_rebuild_runs
             set finished_at = ${now()}, faces = ${report.faces}, clusters = ${report.clusters},
                 algo_version = ${report.algoVersion}, embedding_model = ${EMBEDDING_MODEL},
                 preprocess_version = ${PREPROCESS_VERSION}, params_json = ${JSON.stringify({
                   ...report.params,
                   shortlist: Number(process.env.COLANAS_FACE_REGROUP_SHORTLIST) || 32,
                   minQuality: FACE_MIN_QUALITY,
                   claimMinQuality: FACE_CLAIM_MIN_QUALITY,
                   maxAbsYaw: FACE_CLAIM_MAX_ABS_YAW,
                   maxGroupFaces: FACE_MAX_GROUP_FACES,
                   centerEmbeddings: true,
                   splitClusters: report.splitClusters,
                   dropped: report.dropped,
                   held: report.held,
                 })},
                 sample_count = ${rows.length}, singleton_count = ${report.singletonCount},
                 coverage = ${report.coverage}, elapsed_ms = ${report.elapsedMs}
           where id = ${runId}
        `.execute(k.db);
        return {
          runId,
          faces: report.faces,
          clusters: report.clusters,
          ms: Date.now() - started,
          coverage: report.coverage,
          elapsedMs: report.elapsedMs,
          algoVersion: report.algoVersion,
        };
      }

      // v2：从完整特征库重算全局分组（Mutual KNN + 多 seed Chinese Whispers + 质量分层 + must-link）。
      // 质量分用真实 0..100（旧实现映射成 60..100，等于把所有低分脸都放进了可用层）。
      const samples: ClusterSample[] = rows.map((r) => ({
        id: r.id,
        photoId: r.photo_id,
        photoKey: r.photo_id,
        vec: fromBuffer(r.emb),
        quality: faceQuality(r.quality, r.score),
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

      // 内存索引按新分配重建（下一次增量识别用）；带质量分，否则这些样本永远不能给别人投票
      for (const cluster of report.clusters) {
        const clusterId = idByKey.get(cluster.key)!;
        for (const sampleId of cluster.members) {
          const s = bySample.get(sampleId)!;
          faceIndex.add(sampleId, clusterId, new Float32Array(s.vec), s.quality, s.photoId);
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

      await restoreFaceSnapshot(k, runId);
      return { ok: true };
    },
  );
}
