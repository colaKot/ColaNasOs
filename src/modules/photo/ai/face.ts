import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import type { KernelApi } from '../../../../kernel/types';
import { EMB_DIM, now, ref } from './schemas';
import {
  aiConfig,
  faceTuning,
  FACE_MIN_WIDTH_RATIO,
  FACE_MIN_QUALITY,
  FACE_CLAIM_MIN_QUALITY,
  FACE_CLAIM_MAX_ABS_YAW,
  FACE_MAX_GROUP_FACES_HARD,
  FACE_AMBIGUITY_MARGIN,
  FACE_SWEEP_SIM,
  FACE_SWEEP_MARGIN,
  FACE_SWEEP_THIRD_SIM,
  FACE_SWEEP_ONLY_NAMED,
  FACE_SWEEP_FRAGMENT_MAX,
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
/** 簇级合并相似度下限（原 cluster-v2 的 mergeClusterSim 默认值，rebuild 删除后内联到这里） */
export const CLUSTER_MERGE_SIM = Number(process.env.COLANAS_CLUSTER_MERGE_SIM) || 0.76;

export const FACE_MIN_SHOW_COUNT = Number(process.env.COLANAS_FACE_MIN_SHOW_COUNT) || 3;

/**
 * 人脸相关列表的分页：默认每页 500，单页最多 5000。
 * 没有「总量上限」——客户端拿 nextCursor 一直翻到底就行（照片有几百万张也一样）。
 */
export const FACES_PAGE_DEFAULT = 500;
export const FACES_PAGE_MAX = 5000;

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

/** 某个簇对新脸的匹配情况 */
export interface ClusterMatch {
  /** 簇内最像的那张脸 */
  best: number;
  /** 命中 matchSim 的成员数（只作同分兜底，不参与主排序） */
  count: number;
  /**
   * 簇内前 3 名相似度的均值 —— 选簇与歧义判定用它。
   *
   * 为什么不用 best：best 是 max 统计，成员越多越容易撞出一张高分脸，
   * 大簇在「两个簇同样像」时仍会靠人多赢（歧义脸被硬塞进大簇）。
   * 前 3 名均值对单张偶然高分不敏感，也接近两个簇真实的可比性。
   */
  score: number;
  /** 前 3 名相似度（降序，内部用） */
  top: number[];
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

  /**
   * 过滤式扫描：一次遍历同时产出两种视图。
   *  - hits：全局 top-K 邻居（跨簇合并候选等场景用）
   *  - perCluster：每个簇「最佳成员相似度 + 命中数」
   *
   * 认领决策必须用 perCluster，不能拿 hits 数票：大簇成员多，top-K 名额会被它占满，
   * 于是任何新脸都能在大簇凑出票（黑洞），真正属于小簇的脸反而抢不到票（丢人）。
   * 「簇内最佳成员相似度」与簇大小无关，这是拆掉冻结之后还能既准又全的关键。
   */
  private scan(
    vec: Float32Array,
    opts: SearchOptions = {},
  ): { hits: NeighborHit[]; perCluster: Map<string, ClusterMatch> } {
    const n = this.count;
    const perCluster = new Map<string, ClusterMatch>();
    if (n === 0) return { hits: [], perCluster };
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
      const rec = perCluster.get(cid);
      if (!rec) {
        perCluster.set(cid, { best: sim, count: 1, score: sim, top: [sim] });
      } else {
        rec.count += 1;
        if (sim > rec.best) rec.best = sim;
        const top = rec.top;
        if (top.length < 3) {
          top.push(sim);
          top.sort((a, b) => b - a);
        } else if (sim > top[2]) {
          top[2] = sim;
          top.sort((a, b) => b - a);
        }
        let s = 0;
        for (const v of top) s += v;
        rec.score = s / top.length;
      }
      if (best.length < limit) {
        best.push({ clusterId: cid, sim, quality: this.quals[i], slot: i });
        best.sort((a, b) => a.sim - b.sim);
      } else if (sim > best[0].sim) {
        best[0] = { clusterId: cid, sim, quality: this.quals[i], slot: i };
        best.sort((a, b) => a.sim - b.sim);
      }
    }
    return { hits: best.reverse(), perCluster };
  }

  /** 过滤式 KNN：minSim / 邻居质量 / 同图互斥 / 候选簇短名单 */
  search(vec: Float32Array, opts: SearchOptions = {}): NeighborHit[] {
    return this.scan(vec, opts).hits;
  }

  /** 每个簇的「最佳成员相似度」，与簇成员数无关（选簇用它） */
  matchClusters(vec: Float32Array, opts: SearchOptions = {}): Map<string, ClusterMatch> {
    return this.scan(vec, opts).perCluster;
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
   * 对齐既有实现的四道门：
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
    // 质量不够 / 极端侧脸：**不建簇**、也不参与投票，先挂起（cluster_id = null）。
    // 旧实现这里直接 randomUUID 建簇 —— 名字叫 hold，行为却是「独立成组」，
    // 于是每张糊脸、每张侧脸都变成一个人物，碎片簇越滚越多
    //（用户「儿子 900 多张」之外的几十张就是这么散掉的）。挂起后由 sweep 用
    // 成型簇的成员级证据回捞，既不丢也不污染。
    if (!canClaim) {
      return {
        clusterId: null,
        isNew: false,
        reason: poseOk ? 'low_quality_hold' : 'pose_hold',
      };
    }

    const perCluster = this.matchClusters(vec, {
      minSim: P.matchSim,
      minQuality: FACE_CLAIM_MIN_QUALITY,
      excludeClusters: opts.usedClusterIds,
      shortlist: opts.shortlist ?? 0,
    });

    // 选簇：按「簇内最佳成员相似度」，票数只作同分兜底。
    // 按票数选簇会天然偏袒大簇：大簇人多，近邻名额被它占满，任何新脸都能凑票（黑洞），
    // 而真人小簇永远抢不到票（丢人）。best 主导后，簇大小不再决定谁赢。
    let picked: { id: string; best: number; score: number; count: number } | null = null;
    let runnerUp = 0;
    for (const [id, m] of perCluster) {
      if (
        !picked ||
        m.score > picked.score ||
        (m.score === picked.score && m.count > picked.count)
      ) {
        if (picked) runnerUp = Math.max(runnerUp, picked.score);
        picked = { id, best: m.best, score: m.score, count: m.count };
      } else if (m.score > runnerUp) {
        runnerUp = m.score;
      }
    }
    // 没有任何簇够得上 matchSim ⇒ 库里的新人，正常建组
    if (!picked) return { clusterId: crypto.randomUUID(), isNew: true, reason: 'new' };

    const size = this.groupSize(picked.id);
    // 纯保险丝，默认 0 = 不限制。正常吸纳没有上限，也不会因为「组太大」被拒。
    if (FACE_MAX_GROUP_FACES_HARD > 0 && size >= FACE_MAX_GROUP_FACES_HARD) {
      return { clusterId: null, isNew: false, reason: 'rejected' };
    }
    // 组还没成型（1~2 张）：够像就跟着走。这里不能要求多票 ——
    // 库里第一批脸永远凑不出票，否则新人一律退化成碎片簇。
    if (size < P.minVotes) {
      return picked.best >= P.matchSim
        ? { clusterId: picked.id, isNew: false, reason: 'claimed' }
        : { clusterId: crypto.randomUUID(), isNew: true, reason: 'new' };
    }
    // 成型组：中心一致性门，挡「只是组里人多」的误认（保准）
    const center = this.centroidOf(picked.id);
    if (center && this.dotVec(this.centerVec(vec), center) < P.consistencySim) {
      // 偏离组中心不代表不是这个人：侧脸、换发型、不同年龄、化妆都会偏。
      // 不丢、也不硬塞，挂起交给 sweep 用「和组里某几张脸很像」的成员级证据裁决。
      return { clusterId: null, isNew: false, reason: 'rejected' };
    }
    // 歧义门：两个组同样像（亲子、双胞胎、同款路人脸）。硬塞必错，挂起等更多证据。
    if (runnerUp > 0 && runnerUp >= picked.score - FACE_AMBIGUITY_MARGIN) {
      return { clusterId: null, isNew: false, reason: 'rejected' };
    }
    if (opts.usedClusterIds?.has(picked.id)) {
      return { clusterId: null, isNew: false, reason: 'rejected' };
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

/** 只做认领决策，不写库：挂起态（clusterId = null）也需要知道 reason 才能决定要不要保留脸 */
export async function claimFaceDecision(
  k: KernelApi,
  emb: Float32Array,
  opts: AssignClusterIdOptions,
): Promise<ClaimDecision> {
  await faceIndex.load(k.db);
  return faceIndex.claim(emb, {
    quality: opts.quality,
    poseYaw: opts.poseYaw,
    usedClusterIds: opts.usedClusterIds,
    shortlist: opts.shortlist ?? 0,
    params: claimParams(k),
  });
}

/** 把决策落库（建新簇 / 推进老簇中心），返回最终归属（null = 挂起，脸仍然入库） */
async function applyClaimDecision(
  k: KernelApi,
  decision: ClaimDecision,
  emb: Float32Array,
): Promise<string | null> {
  if (!decision.clusterId) return null;
  if (decision.isNew) {
    await sql`
      insert into photo_face_clusters (id, name, size, cover_photo_id, centroid, created_at, updated_at)
      values (${decision.clusterId}, ${null}, 1, ${null}, ${toBuffer(Array.from(emb))}, ${now()}, ${now()})
    `.execute(k.db);
    return decision.clusterId;
  }

  // 只有够格的样本才推动组中心：低分 / 极端侧脸根本进不了这里（它们先挂起，等 sweep）
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

/** 按护栏给一张脸定归属，并同步 photo_face_clusters 的 centroid / size */
export async function assignClusterId(
  k: KernelApi,
  emb: Float32Array,
  opts: AssignClusterIdOptions,
): Promise<string | null> {
  const decision = await claimFaceDecision(k, emb, opts);
  return applyClaimDecision(k, decision, emb);
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

/**
 * 分析流程用：护栏认领 + 插入人脸（含 bbox / quality / pose）+ 更新索引 + 补封面。
 *
 * 关键变化（2026-11-06）：挂起脸（低质量 / 极端侧脸 / 一时判不准）**也要写进 photo_faces**，
 * 只是 cluster_id 为 null。以前这里直接 return null 就丢了，等于「宁可丢脸也不冒险」；
 * 现在脸留在库里，等 sweep 用成型簇的成员级证据回捞 —— 这才是既准又全。
 */
export async function assignCluster(
  k: KernelApi,
  emb: Float32Array,
  photoId: string,
  input: AssignClusterInput,
): Promise<{ clusterId: string | null; faceId: string } | null> {
  const quality = faceQuality(input.quality, input.score ?? input.quality / 100);
  const decision = await claimFaceDecision(k, emb, {
    quality,
    poseYaw: input.poseYaw,
    usedClusterIds: input.usedClusterIds,
  });
  // 只有质量分低于 MIN_QUALITY 的真·垃圾脸才丢弃（检测都不可信，留着只会拖慢 sweep）
  if (decision.reason === 'dropped') return null;

  const clusterId = await applyClaimDecision(k, decision, emb);
  // 已入簇的脸要占住本图名额，否则同框第二张脸可能并进同一个人
  if (clusterId) input.usedClusterIds?.add(clusterId);

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
  if (clusterId) {
    await sql`
      update photo_face_clusters set cover_photo_id = ${photoId}
       where id = ${clusterId} and (cover_photo_id is null or cover_photo_id = '')
    `.execute(k.db);
    faceIndex.add(faceId, clusterId, emb, quality, photoId);
  }
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

export interface SweepOptions {
  /** 碎片簇上限：成员数 ≤ n 且未命名的簇先解绑再重认（0 = 不动碎片簇） */
  fragmentMax?: number;
  /** 最多处理多少张（0 = 全部） */
  limit?: number;
  /** 只往已命名人物里收（默认跟 config 的 FACE_SWEEP_ONLY_NAMED 一致） */
  onlyNamed?: boolean;
  dryRun?: boolean;
}

export interface SweepReport {
  /** 本轮扫描的未归属脸 */
  candidates: number;
  /** 命中的碎片簇数 */
  fragments: number;
  /** 从碎片簇解绑回未归属的脸数 */
  unbound: number;
  /** 重新归位成功的脸数 */
  assigned: number;
  /** 仍留在未归属（等下次再有证据） */
  left: number;
  elapsedMs: number;
}

/**
 * 二轮收割：把「首轮挂起」和「历史碎片簇」的脸重新归位。
 *
 * 为什么必须有这一轮：「准」和「全」在单轮里是矛盾的。首轮为了不认错，会把侧脸、
 * 糊脸、跟主力簇不那么像的脸全拒掉；旧实现给它们各建一个簇（碎片爆炸），
 * 现在改成挂起 —— 挂起就必须有人来捞，否则等于换了个方式丢人。
 *
 * 这一轮只看「这个组里有没有一张脸和你足够像」，**不看组中心**：
 * 中心是平均脸，侧脸/换发型/不同年龄都会明显偏离，但总能和组里某几张很像。
 *
 * 三道门（2026-11-06 定案）：
 *   1) 只要具名人物的证据 —— 未命名簇不参与选簇，也不参与歧义否决。
 *      拿一个陌生人簇去否决「这张脸更像你老婆」在逻辑上站不住，实测会白丢 440 张家人脸。
 *   2) 簇内多成员支持：至少有 3 张成员都在 FACE_SWEEP_THIRD_SIM(0.50) 以上。
 *      单张高相似容易撞脸（父子、路人），多张同时像才算实锤。
 *   3) 歧义门：两个人物一样像就继续挂起，宁可等下次也不硬塞。
 */
export async function sweepUnassignedFaces(
  k: KernelApi,
  opts: SweepOptions = {},
): Promise<SweepReport> {
  const t0 = Date.now();
  const fragmentMax = Math.max(0, opts.fragmentMax ?? FACE_SWEEP_FRAGMENT_MAX);
  const limit = Math.max(0, opts.limit ?? 0);
  let fragments = 0;
  let unbound = 0;

  // 1) 碎片簇解绑：未命名 + 成员数很少的簇先打散回未归属，
  //    再由成员级匹配决定它们到底是谁；解不开的保持未归属，不再各占一个人物。
  if (fragmentMax > 0) {
    const frag = (
      await sql<{ id: string; n: number }>`
        select c.id as id,
               (select count(*) from photo_faces f where f.cluster_id = c.id) as n
          from photo_face_clusters c
         where (c.name is null or c.name = '')
      `.execute(k.db)
    ).rows.filter((r) => Number(r.n) <= fragmentMax);
    fragments = frag.length;
    if (frag.length && !opts.dryRun) {
      for (const r of frag) {
        unbound += Number(r.n);
        await sql`update photo_faces set cluster_id = null where cluster_id = ${r.id}`.execute(k.db);
        await sql`delete from photo_face_clusters where id = ${r.id}`.execute(k.db);
      }
    }
  }

  // 2) 索引只装「成型簇」：解绑后必须重载，否则旧成员还在索引里当投票者
  faceIndex.invalidate();
  await faceIndex.load(k.db);

  const shortlist = Math.max(
    16,
    Math.min(128, Number(process.env.COLANAS_FACE_SWEEP_SHORTLIST) || 48),
  );
  const batch = Math.max(200, Math.min(5000, Number(process.env.COLANAS_FACE_SWEEP_BATCH) || 2000));
  const onlyNamed = opts.onlyNamed ?? FACE_SWEEP_ONLY_NAMED;

  // 具名人物白名单：歧义只在「人」之间比，未命名簇不参与
  const namedIds = new Set(
    (
      await sql<{ id: string }>`
        select id from photo_face_clusters where name is not null and name <> ''
      `.execute(k.db)
    ).rows.map((r) => String(r.id)),
  );

  const byCluster = new Map<string, string[]>();
  let scanned = 0;
  let lastId = '';

  // 3) 分批扫未归属脸（按 id 游标翻页，避免几十万张一次读进内存）
  for (;;) {
    const rows = (
      await sql<{ id: string; emb: Buffer }>`
        select id, emb from photo_faces
         where cluster_id is null and emb is not null and id > ${lastId}
         order by id asc limit ${batch}
      `.execute(k.db)
    ).rows;
    if (!rows.length) break;
    for (const r of rows) {
      lastId = r.id;
      scanned += 1;
      // minSim 取两者较小值：多成员支持门要看 top3 里第三张的分数，
      // 如果直接按 FACE_SWEEP_SIM 截断，第三张永远是 0，门就永远过不了。
      const per = faceIndex.matchClusters(fromBuffer(r.emb), {
        minSim: Math.min(FACE_SWEEP_SIM, FACE_SWEEP_THIRD_SIM),
        shortlist,
      });
      let best: { id: string; best: number; score: number; top: number[] } | null = null;
      let runnerUp = 0;
      for (const [id, m] of per) {
        if (onlyNamed && !namedIds.has(id)) continue;
        if (!best || m.score > best.score) {
          if (best) runnerUp = Math.max(runnerUp, best.score);
          best = { id, best: m.best, score: m.score, top: m.top };
        } else if (m.score > runnerUp) {
          runnerUp = m.score;
        }
      }
      if (!best || best.best < FACE_SWEEP_SIM) continue;
      // 簇内多成员支持：至少有 3 张成员都够像（单张高相似容易撞脸）
      if (best.top.length < 3 || best.top[2] < FACE_SWEEP_THIRD_SIM) continue;
      // 歧义门：两个人物一样像就不猜（亲子脸、双胞胎最容易卡这里）
      if (runnerUp > 0 && runnerUp >= best.score - FACE_SWEEP_MARGIN) continue;
      let list = byCluster.get(best.id);
      if (!list) {
        list = [];
        byCluster.set(best.id, list);
      }
      list.push(r.id);
    }
    if (limit > 0 && scanned >= limit) break;
  }

  let assigned = 0;
  for (const list of byCluster.values()) assigned += list.length;

  if (!opts.dryRun && assigned > 0) {
    await k.db.transaction().execute(async (trx: any) => {
      for (const [cid, ids] of byCluster) {
        for (const id of ids) {
          await sql`update photo_faces set cluster_id = ${cid} where id = ${id}`.execute(trx);
        }
        await refreshClusterStats(trx, cid);
      }
    });
    // 索引里的分组与 size 都变了，交给下次 load 回表重建
    faceIndex.invalidate();
  }

  return {
    candidates: scanned,
    fragments,
    unbound,
    assigned,
    left: scanned - assigned,
    elapsedMs: Date.now() - t0,
  };
}

export async function registerPhotoFaces(app: any, k: KernelApi): Promise<void> {
  app.get(
    '/api/v1/photo/faces/clusters',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaceClusters',
        tags: ['photo'],
        summary: '人脸聚类列表（按人数倒序，分页；少于 minCount 的碎片组不显示，具名组豁免）',
        querystring: ref('PhotoFaceClusterFilter'),
        response: { 200: ref('PhotoFaceClusterList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { minCount?: number; limit?: number; cursor?: number };
      const minCount = Math.max(
        1,
        Math.min(Number(q.minCount) || aiConfig(k).faceMinShowCount, 1000),
      );
      // 分页而不是写死上限：簇可能上万个，一次全吐出去客户端也扛不住，
      // 但翻页必须能翻到底（客户端自己循环拉全量）。
      const limit = Math.max(1, Math.min(Number(q.limit) || FACES_PAGE_DEFAULT, FACES_PAGE_MAX));
      const offset = Math.max(0, Number(q.cursor) || 0);
      const where = sql`where size >= ${minCount} or (name is not null and name <> '')`;

      const totalRow = (
        await sql<{ n: number }>`select count(*) as n from photo_face_clusters ${where}`.execute(k.db)
      ).rows[0];

      // 头像兜底放在 SQL 里挑（相关子查询），不再逐行发一条 —— 老写法是 N+1，
      // 500 行就要 500 次往返，翻页后更糟。
      const rows = (
        await sql<{
          id: string;
          name: string | null;
          size: number;
          cover_photo_id: string | null;
          cover_face_id: string | null;
        }>`
          select id, name, size, cover_photo_id,
                 coalesce(cover_face_id, (
                   select f.id from photo_faces f
                    where f.cluster_id = photo_face_clusters.id
                    order by coalesce(f.box_width * f.box_height, 0) desc, f.created_at asc
                    limit 1
                 )) as cover_face_id
            from photo_face_clusters
            ${where}
           order by size desc, id asc
           limit ${limit} offset ${offset}
        `.execute(k.db)
      ).rows;

      const items = rows.map((r) => ({
        id: r.id,
        name: r.name,
        size: Number(r.size),
        coverPhotoId: r.cover_photo_id,
        coverFaceId: r.cover_face_id,
      }));
      return {
        total: Number(totalRow?.n) || 0,
        items,
        nextCursor: items.length === limit ? String(offset + limit) : null,
      };
    },
  );

  app.get(
    '/api/v1/photo/faces',
    secured('photo:read', {
      schema: {
        operationId: 'photoFaces',
        tags: ['photo'],
        summary: '某个人脸簇下的照片（分页，按拍摄时间倒序）',
        querystring: ref('PhotoFaceClusterQuery'),
        response: { 200: ref('PhotoFaceList') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { id?: string; limit?: number; cursor?: number };
      const clusterId = q.id ?? '';
      const limit = Math.max(1, Math.min(Number(q.limit) || FACES_PAGE_DEFAULT, FACES_PAGE_MAX));
      const offset = Math.max(0, Number(q.cursor) || 0);
      // 老写法 `limit 500` 直接把一千张的簇截成 500 张，用户看到的就是「照片少了」。
      // 改成真分页：total 给客户端算进度，nextCursor 翻到底。
      const totalRow = (
        await sql<{ n: number }>`
          select count(*) as n
            from photo_faces f join photo_items i on i.id = f.photo_id
           where f.cluster_id = ${clusterId} and i.in_trash = 0
        `.execute(k.db)
      ).rows[0];
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
          where f.cluster_id = ${clusterId} and i.in_trash = 0
          order by i.taken_at desc, f.id asc limit ${limit} offset ${offset}
        `.execute(k.db)
      ).rows;
      return {
        total: Number(totalRow?.n) || 0,
        nextCursor: rows.length === limit ? String(offset + limit) : null,
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
   * 构图照既有实现：以人脸框中心为基准，按最长边外扩 `FACE_IMAGE_EXTEND`（默认 20%），
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
        // 构图对齐既有实现：最长边外扩 20%、再向上偏移 12%。
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
    '/api/v1/photo/faces/sweep',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceSweep',
        tags: ['photo'],
        summary: '二轮收割：把挂起脸与历史碎片簇按成员级相似度重新归位',
        body: ref('PhotoFaceSweepBody'),
        response: { 200: ref('PhotoFaceSweepResult') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        fragmentMax?: number;
        limit?: number;
        onlyNamed?: boolean;
        dryRun?: boolean;
      };
      return sweepUnassignedFaces(k, {
        fragmentMax: body.fragmentMax,
        limit: body.limit,
        onlyNamed: body.onlyNamed,
        dryRun: body.dryRun,
      });
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

  // 手动指定人脸封面。聚类时只在 cover_photo_id 为空的情况下自动挑一张，
  // 挑到闭眼 / 侧脸就没法纠正；这里给一个「就用这张」的覆盖入口。
  // 只接受确实属于该簇的照片，避免把无关照片设成别人的封面。
  app.post(
    '/api/v1/photo/faces/cover',
    secured('photo:write', {
      schema: {
        operationId: 'photoFaceCover',
        tags: ['photo'],
        summary: '把簇内某张照片设为人脸封面',
        body: ref('PhotoFaceCoverBody'),
        response: { 200: ref('PhotoFaceCoverResponse'), 400: ref('PhotoAiError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as { clusterId?: string; photoId?: string };
      const clusterId = String(body.clusterId || '');
      const photoId = String(body.photoId || '');
      if (!clusterId || !photoId) {
        return reply.code(400).send({ error: Err.badRequest, message: 'clusterId/photoId required' });
      }
      const face = (
        await sql<{ id: string }>`
          select id from photo_faces
           where cluster_id = ${clusterId} and photo_id = ${photoId}
           order by coalesce(box_width * box_height, 0) desc, created_at asc
           limit 1
        `.execute(k.db)
      ).rows[0];
      if (!face) {
        return reply.code(400).send({ error: Err.badRequest, message: 'photo not in cluster' });
      }
      await sql`
        update photo_face_clusters
           set cover_photo_id = ${photoId}, cover_face_id = ${face.id}, updated_at = ${now()}
         where id = ${clusterId}
      `.execute(k.db);
      return { ok: true, coverPhotoId: photoId, coverFaceId: face.id };
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
        Number(process.env.COLANAS_FACE_MERGE_SIM) || CLUSTER_MERGE_SIM,
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

}
