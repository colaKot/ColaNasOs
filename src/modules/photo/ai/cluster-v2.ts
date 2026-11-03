/**
 * 人脸全库重建 v2：从完整特征库重算全局分组（不是「在旧分组上再跑一遍贪心」）。
 *
 * 流水线：
 *   特征校验/归一化 → 质量分层 → Mutual KNN 图 → 多 seed Chinese Whispers
 *   → 垃圾簇溶解 → 簇级合并 → must-link（旧组锚定）→ 产出分配
 *
 * 为什么不用「单阈值贪心 + 质心」：
 *   同一人跨 15 年、亲戚长得像的数据上，纯视觉单阈值在数学上不可分；
 *   在旧分组上再跑一遍会把人工整理成果清零、结果不可复现、也无法回滚。
 *
 * 参数全部来自参考实现的扫参结论（548 对人工标注），且**可被环境变量覆盖**；
 * 非法值直接抛错（不做静默降级），并把最终参数落库以便复现。
 */
export const ALGO_VERSION = 'face-cluster-v2.1.0';
export const EMBEDDING_MODEL = 'edgeface-512';
export const PREPROCESS_VERSION = 'align112-lumaMean-v1';

export interface ClusterParams {
  /** Mutual KNN 的 K */
  topK: number;
  /** 相似度下限（同图不同脸负样本 p99 = 0.56；0.42 是更保守的 floor） */
  simFloor: number;
  /** 强边阈值（只用于统计/审计） */
  strongSim: number;
  /** 边权 gamma */
  gamma: number;
  rankPenalty: number;
  /** 质量分层 */
  coreQuality: number;
  lowQuality: number;
  minQuality: number;
  /** Chinese Whispers */
  cwMaxIter: number;
  cwSeeds: number[];
  cwMinEdgeWeight: number;
  cwConvergeRatio: number;
  maxClusterSize: number;
  /** 多 seed 共识 */
  consensusMinVotes: number;
  consensusMinSupport: number;
  consensusMinShare: number;
  /** 簇级审计 */
  clusterMinCohesion: number;
  /** 簇级合并 */
  mergeClusterSim: number;
  /** must-link */
  mustLinkShare: number;
  /** 中心化 */
  centerEmbeddings: boolean;
}

export const DEFAULT_PARAMS: ClusterParams = {
  topK: 32,
  simFloor: 0.42,
  strongSim: 0.55,
  gamma: 2.0,
  rankPenalty: 0.12,
  coreQuality: 70,
  lowQuality: 55,
  minQuality: 55,
  cwMaxIter: 40,
  cwSeeds: [1, 7, 13],
  cwMinEdgeWeight: 0.012,
  cwConvergeRatio: 0.002,
  maxClusterSize: 4000,
  consensusMinVotes: 2,
  consensusMinSupport: 5,
  consensusMinShare: 0.15,
  clusterMinCohesion: 0.58,
  mergeClusterSim: 0.76,
  mustLinkShare: 0.6,
  centerEmbeddings: true,
};

/** 参数边界：越界直接抛错，避免「静默降级」出一个没人能解释结果 */
export const NUMERIC_BOUNDS: Record<keyof ClusterParams, [number, number] | null> = {
  topK: [4, 128],
  simFloor: [0.2, 0.95],
  strongSim: [0.2, 0.99],
  gamma: [0.5, 4],
  rankPenalty: [0, 1],
  coreQuality: [0, 100],
  lowQuality: [0, 100],
  minQuality: [0, 100],
  cwMaxIter: [1, 200],
  cwSeeds: null,
  cwMinEdgeWeight: [0, 1],
  cwConvergeRatio: [0, 0.5],
  maxClusterSize: [10, 100000],
  consensusMinVotes: [1, 10],
  consensusMinSupport: [1, 1000],
  consensusMinShare: [0, 1],
  clusterMinCohesion: [0, 1],
  mergeClusterSim: [0, 1],
  mustLinkShare: [0, 1],
  centerEmbeddings: null,
};

export interface ClusterSample {
  id: string;
  photoId: string;
  vec: Float32Array | number[];
  /** 质量分 0..100（检测分数 × 尺寸等推导） */
  quality: number;
  /** 旧组（must-link 锚定）；空表示新样本 */
  oldClusterId?: string | null;
  /** 同一张照片里的脸：禁止同簇（cannot-link） */
  photoKey?: string;
}

export interface ClusterAssignment {
  sampleId: string;
  clusterKey: string | null;
  quality: number;
}

export interface ClusterReport {
  algoVersion: string;
  embeddingModel: string;
  preprocessVersion: string;
  params: ClusterParams;
  seeds: number[];
  sampleCount: number;
  usedCount: number;
  clusterCount: number;
  singletonCount: number;
  coverage: number;
  elapsedMs: number;
  /** 每个簇的成员 sampleId（便于上层落库） */
  clusters: Array<{ key: string; size: number; cohesion: number; members: string[] }>;
  assignments: ClusterAssignment[];
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function l2(vec: number[]): number[] {
  let n = 0;
  for (const v of vec) n += v * v;
  n = Math.sqrt(n) || 1;
  return vec.map((v) => v / n);
}

function dot(a: number[], b: number[]): number {
  let s = 0;
  for (let i = 0; i < a.length; i += 1) s += a[i] * b[i];
  return s;
}

export function validateParams(input: Partial<ClusterParams> = {}): ClusterParams {
  const merged = { ...DEFAULT_PARAMS, ...input };
  for (const [key, bounds] of Object.entries(NUMERIC_BOUNDS)) {
    if (!bounds) continue;
    const value = (merged as unknown as Record<string, number>)[key];
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      throw new Error(`invalid cluster param ${key}: ${String(value)}`);
    }
    if (value < bounds[0] || value > bounds[1]) {
      throw new Error(`cluster param out of bounds ${key}=${value} (${bounds[0]}..${bounds[1]})`);
    }
  }
  if (!Array.isArray(merged.cwSeeds) || merged.cwSeeds.length === 0) {
    throw new Error('cluster param cwSeeds must be a non-empty array');
  }
  return merged;
}

/** 环境变量覆盖（COLANAS_CLUSTER_*），便于真机扫参 */
export function paramsFromEnv(): ClusterParams {
  const p: Partial<ClusterParams> = {};
  const num = (name: string) => {
    const v = Number(process.env[name]);
    return Number.isFinite(v) ? v : undefined;
  };
  const map: Array<[keyof ClusterParams, string]> = [
    ['topK', 'COLANAS_CLUSTER_TOPK'],
    ['simFloor', 'COLANAS_CLUSTER_SIM_FLOOR'],
    ['mergeClusterSim', 'COLANAS_CLUSTER_MERGE_SIM'],
    ['clusterMinCohesion', 'COLANAS_CLUSTER_MIN_COHESION'],
    ['coreQuality', 'COLANAS_CLUSTER_CORE_QUALITY'],
    ['minQuality', 'COLANAS_CLUSTER_MIN_QUALITY'],
  ];
  for (const [key, env] of map) {
    const v = num(env);
    if (v !== undefined) (p as any)[key] = v;
  }
  return validateParams(p);
}

/**
 * 主入口：纯计算，不触碰数据库。
 * `samples` 建议已按 taken_at 升序传入（结果的可复现性依赖输入顺序）。
 */
export function clusterSamples(input: ClusterSample[], params: ClusterParams): ClusterReport {
  const started = Date.now();
  const P = params;

  const usable = input.filter((s) => Number.isFinite(s.quality) && s.quality >= P.minQuality);
  const skipped = input.length - usable.length;
  const vecs = usable.map((s) => l2(Array.from(s.vec, Number)));
  const indexOfSample = new Map<string, number>();
  usable.forEach((s, i) => indexOfSample.set(s.id, i));
  const n = vecs.length;

  if (n === 0) {
    return {
      algoVersion: ALGO_VERSION,
      embeddingModel: EMBEDDING_MODEL,
      preprocessVersion: PREPROCESS_VERSION,
      params: P,
      seeds: P.cwSeeds,
      sampleCount: input.length,
      usedCount: 0,
      clusterCount: 0,
      singletonCount: 0,
      coverage: 0,
      elapsedMs: 0,
      clusters: [],
      assignments: input.map((s) => ({ sampleId: s.id, clusterKey: null, quality: s.quality })),
    };
  }

  // ---- 均值中心化（可选）：去掉「所有人脸都相似」的公共分量
  if (P.centerEmbeddings) {
    const dim = vecs[0].length;
    const mean = new Array(dim).fill(0);
    for (const v of vecs) for (let d = 0; d < dim; d += 1) mean[d] += v[d] / n;
    for (let i = 0; i < n; i += 1) {
      for (let d = 0; d < dim; d += 1) vecs[i][d] -= mean[d];
      vecs[i] = l2(vecs[i]);
    }
  }

  // ---- KNN（内存暴力，按块计算；n 上限由调用方控制）
  const k = Math.min(P.topK, Math.max(1, n - 1));
  const knn: Array<Array<{ j: number; sim: number }>> = [];
  for (let i = 0; i < n; i += 1) {
    const heap: Array<{ j: number; sim: number }> = [];
    for (let j = 0; j < n; j += 1) {
      if (i === j) continue;
      const sim = dot(vecs[i], vecs[j]);
      if (sim < P.simFloor) continue;
      if (heap.length < k) {
        heap.push({ j, sim });
        heap.sort((a, b) => a.sim - b.sim);
      } else if (sim > heap[0].sim) {
        heap[0] = { j, sim };
        heap.sort((a, b) => a.sim - b.sim);
      }
    }
    knn.push(heap);
  }

  // ---- Mutual KNN：只在 i→j 与 j→i 同时成立时连边（抑制 hub 与单向误连）
  const adj: Array<Map<number, number>> = Array.from({ length: n }, () => new Map());
  for (let i = 0; i < n; i += 1) {
    for (let rank = 0; rank < knn[i].length; rank += 1) {
      const { j, sim } = knn[i][rank];
      if (!knn[j].some((x) => x.j === i)) continue;
      const w =
        Math.pow(Math.max(0, (sim - P.simFloor) / (1 - P.simFloor)), P.gamma) /
        (1 + P.rankPenalty * rank);
      if (w < P.cwMinEdgeWeight) continue;
      adj[i].set(j, w);
      adj[j].set(i, w);
    }
  }

  // ---- can-not-link：同一张照片里的不同脸不能同簇
  const photoGroups = new Map<string, number[]>();
  usable.forEach((s, i) => {
    const key = s.photoKey ?? s.photoId;
    const list = photoGroups.get(key) ?? [];
    list.push(i);
    photoGroups.set(key, list);
  });
  const cannot = new Map<number, Set<number>>();
  for (const group of photoGroups.values()) {
    if (group.length < 2) continue;
    for (const a of group) {
      for (const b of group) {
        if (a === b) continue;
        if (!cannot.has(a)) cannot.set(a, new Set());
        cannot.get(a)!.add(b);
      }
    }
  }

  // ---- 多 seed Chinese Whispers + 共识投票
  // 基准 = 第一个 seed 的划分；其余 seed 的簇按「与基准簇最大重叠」映射后再投票，
  // 这样不同 seed 的数值标签才可比（它们的标签编号本来没有共同含义）。
  const baseLabels = chineseWhispers(adj, usable, P, P.cwSeeds[0], cannot);
  const support = new Array<number>(n).fill(1);
  for (const seed of P.cwSeeds.slice(1)) {
    const other = chineseWhispers(adj, usable, P, seed, cannot);
    const mapped = mapLabelsToBase(other, baseLabels);
    for (let i = 0; i < n; i += 1) {
      if (mapped.get(other[i]) === baseLabels[i]) support[i] += 1;
    }
  }

  const minVotes = Math.min(P.consensusMinVotes, P.cwSeeds.length);
  const labelOf = new Array<number>(n).fill(-1);
  for (let i = 0; i < n; i += 1) {
    if (support[i] >= minVotes) labelOf[i] = baseLabels[i];
  }

  // 簇级最小支持：被 ≥ consensusMinSupport 个样本稳定支持的簇才保留
  const stableCounts = new Map<number, number>();
  for (let i = 0; i < n; i += 1) {
    if (labelOf[i] >= 0) stableCounts.set(labelOf[i], (stableCounts.get(labelOf[i]) ?? 0) + 1);
  }
  for (let i = 0; i < n; i += 1) {
    const l = labelOf[i];
    if (l >= 0 && (stableCounts.get(l) ?? 0) < P.consensusMinSupport) labelOf[i] = -1;
  }

  // ---- 溶解垃圾簇（内聚度不足）
  const byLabel = new Map<number, number[]>();
  for (let i = 0; i < n; i += 1) {
    if (labelOf[i] < 0) continue;
    const list = byLabel.get(labelOf[i]) ?? [];
    list.push(i);
    byLabel.set(labelOf[i], list);
  }
  for (const [label, members] of [...byLabel]) {
    if (members.length < 2) continue;
    const cohesion = clusterCohesion(members, vecs, P.topK);
    if (cohesion < P.clusterMinCohesion) {
      for (const i of members) labelOf[i] = -1;
      byLabel.delete(label);
    }
  }

  // ---- 簇级合并（簇中心相似度 ≥ mergeClusterSim，且不违反 cannot-link）
  const centroids = new Map<number, number[]>();
  for (const [label, members] of byLabel) centroids.set(label, centroidOf(members, vecs));

  let merged = true;
  while (merged) {
    merged = false;
    const entries = [...centroids.entries()];
    outer: for (let a = 0; a < entries.length; a += 1) {
      for (let b = a + 1; b < entries.length; b += 1) {
        const [la, ca] = entries[a];
        const [lb, cb] = entries[b];
        if (dot(ca, cb) < P.mergeClusterSim) continue;
        const ma = byLabel.get(la) ?? [];
        const mb = byLabel.get(lb) ?? [];
        if (ma.some((x) => [...(cannot.get(x) ?? new Set<number>())].some((y) => mb.includes(y))))
          continue;

        // 大簇吸收小簇，保证结果稳定
        const [keep, drop] = ma.length >= mb.length ? [la, lb] : [lb, la];
        const keepMembers = byLabel.get(keep) ?? [];
        const dropMembers = byLabel.get(drop) ?? [];
        for (const i of dropMembers) labelOf[i] = keep;
        byLabel.set(keep, [...keepMembers, ...dropMembers]);
        byLabel.delete(drop);
        centroids.set(keep, centroidOf(byLabel.get(keep)!, vecs));
        centroids.delete(drop);
        merged = true;
        break outer;
      }
    }
  }

  // ---- must-link：旧组占比 ≥ mustLinkShare 的簇并入同一新簇
  const oldGroups = new Map<string, number[]>();
  usable.forEach((s, i) => {
    if (!s.oldClusterId) return;
    const list = oldGroups.get(s.oldClusterId) ?? [];
    list.push(i);
    oldGroups.set(s.oldClusterId, list);
  });

  for (const [oldId, members] of oldGroups) {
    const distinct = new Set<number>();
    for (const i of members) if (labelOf[i] >= 0) distinct.add(labelOf[i]);
    if (distinct.size <= 1) continue;

    // 每个新簇在该旧组里的占比
    const share = new Map<number, number>();
    for (const i of members) {
      const l = labelOf[i];
      if (l < 0) continue;
      share.set(l, (share.get(l) ?? 0) + 1);
    }
    const keep = [...share.entries()].sort((a, b) => b[1] - a[1])[0];
    if (!keep || keep[1] / members.length < P.mustLinkShare) continue;
    const targetLabel = keep[0];

    for (const i of members) {
      if (labelOf[i] !== targetLabel && labelOf[i] >= 0) {
        // cannot-link 硬检查：冲突则不合并
        const conflicts = cannot.get(i) ?? new Set<number>();
        if ([...conflicts].some((j) => labelOf[j] === targetLabel && !members.includes(j)))
          continue;
        labelOf[i] = targetLabel;
      }
    }
    void oldId;
  }

  // ---- 输出：把标签映射成稳定 key（成员最小 sampleId）
  const labelMembers = new Map<number, number[]>();
  for (let i = 0; i < n; i += 1) {
    if (labelOf[i] < 0) continue;
    const list = labelMembers.get(labelOf[i]) ?? [];
    list.push(i);
    labelMembers.set(labelOf[i], list);
  }

  const clusters: ClusterReport['clusters'] = [];
  const keyOf = new Map<number, string>();
  for (const [label, members] of labelMembers) {
    const key = members.map((i) => usable[i].id).sort()[0];
    keyOf.set(label, key);
    clusters.push({
      key,
      size: members.length,
      cohesion: Number(clusterCohesion(members, vecs, P.topK).toFixed(4)),
      members: members.map((i) => usable[i].id),
    });
  }

  const assignments: ClusterAssignment[] = input.map((s) => {
    const idx = indexOfSample.get(s.id) ?? -1;
    if (idx < 0) return { sampleId: s.id, clusterKey: null, quality: s.quality };
    const label = labelOf[idx];
    return {
      sampleId: s.id,
      clusterKey: label >= 0 ? (keyOf.get(label) ?? null) : null,
      quality: s.quality,
    };
  });

  const assigned = assignments.filter((a) => a.clusterKey).length;
  const singletonCount = clusters.filter((c) => c.size === 1).length;

  return {
    algoVersion: ALGO_VERSION,
    embeddingModel: EMBEDDING_MODEL,
    preprocessVersion: PREPROCESS_VERSION,
    params: P,
    seeds: P.cwSeeds,
    sampleCount: input.length,
    usedCount: n,
    clusterCount: clusters.length,
    singletonCount,
    coverage: n === 0 ? 0 : Number(((assigned / n) * 100).toFixed(2)),
    elapsedMs: Date.now() - started,
    clusters,
    assignments,
    ...(skipped > 0 ? { skippedLowQuality: skipped } : {}),
  } as ClusterReport;
}

function chineseWhispers(
  adj: Array<Map<number, number>>,
  samples: ClusterSample[],
  P: ClusterParams,
  seed: number,
  cannot: Map<number, Set<number>>,
): number[] {
  const n = adj.length;
  const labels = Array.from({ length: n }, (_, i) => i);
  const rnd = mulberry32(seed);
  const order = Array.from({ length: n }, (_, i) => i);
  for (let i = order.length - 1; i > 0; i -= 1) {
    const j = Math.floor(rnd() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }

  for (let iter = 0; iter < P.cwMaxIter; iter += 1) {
    let changed = 0;
    for (const i of order) {
      const weights = new Map<number, number>();
      for (const [j, w] of adj[i]) weights.set(labels[j], (weights.get(labels[j]) ?? 0) + w);
      // 自身当前标签加权，避免来回抖动
      weights.set(labels[i], (weights.get(labels[i]) ?? 0) + 1e-6);
      if (weights.size === 0) continue;

      let best = labels[i];
      let bestW = -1;
      for (const [label, w] of weights) {
        if (w > bestW || (w === bestW && label < best)) {
          best = label;
          bestW = w;
        }
      }
      if (best !== labels[i]) {
        const conflicts = cannot.get(i);
        if (conflicts && [...conflicts].some((j) => labels[j] === best)) continue;
        labels[i] = best;
        changed += 1;
      }
    }
    if (changed / Math.max(1, n) < P.cwConvergeRatio) break;

    // 防止超大簇（会把全库连成一坨）
    const counts = new Map<number, number>();
    for (const l of labels) counts.set(l, (counts.get(l) ?? 0) + 1);
    for (const [label, count] of counts) {
      if (count <= P.maxClusterSize) continue;
      const members = labels.map((l, i) => (l === label ? i : -1)).filter((i) => i >= 0);
      // 超出部分拆成自己的标签（按输入顺序切分，保证可复现）
      for (const i of members.slice(P.maxClusterSize)) labels[i] = i;
    }
  }
  void samples;
  return labels;
}

/** 把 another seed 的簇标签映射到基准划分（按最大重叠） */
function mapLabelsToBase(other: number[], base: number[]): Map<number, number> {
  const overlap = new Map<number, Map<number, number>>();
  for (let i = 0; i < other.length; i += 1) {
    if (!overlap.has(other[i])) overlap.set(other[i], new Map());
    const m = overlap.get(other[i])!;
    m.set(base[i], (m.get(base[i]) ?? 0) + 1);
  }
  const out = new Map<number, number>();
  for (const [label, counts] of overlap) {
    let best = base[0] ?? -1;
    let bestCount = -1;
    for (const [b, c] of counts) {
      if (c > bestCount) {
        best = b;
        bestCount = c;
      }
    }
    out.set(label, best);
  }
  return out;
}

function centroidOf(members: number[], vecs: number[][]): number[] {
  const dim = vecs[members[0]].length;
  const c = new Array(dim).fill(0);
  for (const i of members) for (let d = 0; d < dim; d += 1) c[d] += vecs[i][d] / members.length;
  return l2(c);
}

function clusterCohesion(members: number[], vecs: number[][], topK: number): number {
  if (members.length <= 1) return 1;
  let sum = 0;
  let count = 0;
  for (const i of members) {
    const sims: number[] = [];
    for (const j of members) {
      if (i === j) continue;
      sims.push(dot(vecs[i], vecs[j]));
    }
    sims.sort((a, b) => b - a);
    for (const s of sims.slice(0, Math.max(1, Math.min(topK, sims.length)))) sum += s;
    count += Math.max(1, Math.min(topK, sims.length));
  }
  return count === 0 ? 0 : sum / count;
}
