/**
 * 照片 CLIP 向量的内存常驻索引（以图搜图 / 相似检索用）。
 *
 * 为什么不写成 SQL：相似检索的本质是「拿一条向量和全库逐条比余弦」，纯内存计算活。
 * 让 SQLite 参与反而更慢 —— 同一份数据（20,203 条 × 512 维 = 39.5 MB）实测：
 *
 *   · `join photo_items ... limit 5000`  → 44.6ms 读 + 6.2ms 算 = 50.8ms，且只覆盖 24.7%
 *   · 全量逐行 join                       → 162.5ms 读 + 21.5ms 算 = 184ms
 *   · 本模块：一次性载入 + 拍平          → 预热 168ms（一次性），每查 14ms 且覆盖 100%
 *
 * 三个关键设计：
 *   1. **拍平成一整块连续 Float32Array**，而不是两万个小 Float32Array。
 *      逐条数组每个都是独立对象、内存不连续，CPU 缓存命中率差；实测拍平后快一倍以上。
 *   2. **范数预存**：余弦里的两次开方只在载入时算一次，查询时只剩点积 + 一次除法。
 *   3. **重载判据用「行数 + TTL」**：不逐次 count。30 秒最多数一次行数，
 *      10 分钟强制全量重载一次兜底（覆盖「照片重扫导致向量被替换但行数不变」的情况）。
 *
 * 内存占用：索引常驻约 40 MB（20,203 × 512 × 4 字节）；重建瞬间峰值约 80 MB
 * （查询结果的 Buffer 与拍平矩阵同时存在），重建耗时 168ms，属于可接受的一次性开销。
 */
import { sql } from 'kysely';

/** 这段时间内不重复数行数 */
const CHECK_INTERVAL_MS = 30_000;
/** 强制重载周期：兜底「向量原地更新、行数没变」的情况 */
const FORCE_RELOAD_MS = 10 * 60_000;

interface IndexState {
  ids: string[];
  /** 长度 = ids.length * dim，行优先拍平 */
  mat: Float32Array;
  /** 每条向量的 L2 范数，避免查询时重复开方 */
  norms: Float32Array;
  dim: number;
  count: number;
  loadedAt: number;
  checkedAt: number;
}

/**
 * 按库隔离的索引状态。
 *
 * 为什么用 WeakMap 而不是模块级单例：迁移脚本、冒烟脚本会在**同一个进程里**先后
 * 启动多个内核（各自一个临时库）。单例会让第二个库复用第一个库的向量矩阵 ——
 * 行数碰巧相同时连重建都不会触发，检索结果直接串库。生产环境一个进程一个库，
 * WeakMap 的行为与单例完全一致，但测试态不会再互相污染。
 */
const stores = new WeakMap<object, IndexState>();
const loadings = new WeakMap<object, Promise<IndexState>>();

function buildFromRows(rows: Array<{ photo_id: string; vec: Buffer }>): IndexState {
  const count = rows.length;
  const dim = count > 0 ? (rows[0].vec as Buffer).byteLength / 4 : 0;
  const ids: string[] = new Array(count);
  const mat = new Float32Array(count * dim);
  const norms = new Float32Array(count);

  for (let i = 0; i < count; i++) {
    const r = rows[i];
    ids[i] = String(r.photo_id);
    const b = r.vec as Buffer;
    // 维度不一致的脏数据留在原地（全零），评分算出来是 0，不会污染排序
    if (b.byteLength !== dim * 4) {
      norms[i] = 1;
      continue;
    }
    const v = new Float32Array(b.buffer, b.byteOffset, dim);
    mat.set(v, i * dim);
    let s = 0;
    for (let j = 0; j < dim; j++) s += v[j] * v[j];
    norms[i] = Math.sqrt(s) || 1;
  }

  const now = Date.now();
  return { ids, mat, norms, dim, count, loadedAt: now, checkedAt: now };
}

async function rebuild(db: any): Promise<IndexState> {
  const res = await sql<{ photo_id: string; vec: Buffer }>`
    select photo_id, vec from photo_embeddings
  `.execute(db);
  const built = buildFromRows(res.rows as Array<{ photo_id: string; vec: Buffer }>);
  stores.set(db, built);
  return built;
}

/** 确保索引可用。并发调用共用同一次重建，避免启动瞬间建出多份。 */
async function ensure(db: any): Promise<IndexState> {
  const now = Date.now();
  const cur = stores.get(db);
  if (cur && now - cur.loadedAt < FORCE_RELOAD_MS) {
    if (now - cur.checkedAt < CHECK_INTERVAL_MS) return cur;
    // 数一次行数：增删照片会改变行数，是最便宜的有效信号
    const fresh = (await sql<{ c: number }>`select count(*) as c from photo_embeddings`.execute(db))
      .rows[0];
    if ((Number(fresh?.c) || 0) === cur.count) {
      cur.checkedAt = now;
      return cur;
    }
  }
  let pending = loadings.get(db);
  if (!pending) {
    pending = rebuild(db).finally(() => {
      loadings.delete(db);
    });
    loadings.set(db, pending);
  }
  return pending;
}

/**
 * 主动作废（向量刚写入 / 照片刚删除时调用，省掉最多 30 秒的滞后）。
 * 不阻塞：下一次检索会自动重建。
 */
export function invalidatePhotoVectorIndex(db?: any): void {
  if (db) stores.delete(db);
}

export interface VectorHit {
  photoId: string;
  score: number;
}

/**
 * 在全库向量里找和 `base` 余弦最相似的 `k` 条（跳过 `excludeId` 自己）。
 * 只做打分，不做权限过滤 —— 调用方拿 id 回表过滤，必要时扩大 `k` 重试。
 */
export async function searchPhotoVectors(
  db: any,
  base: Float32Array,
  k: number,
  excludeId: string,
): Promise<{ hits: VectorHit[]; scanned: number; dim: number }> {
  const idx = await ensure(db);
  const { ids, mat, norms, dim, count } = idx;
  if (count === 0 || dim === 0) return { hits: [], scanned: 0, dim };

  // 基准向量范数（只算一次）
  let bn = 0;
  for (let j = 0; j < dim; j++) bn += base[j] * base[j];
  bn = Math.sqrt(bn) || 1;

  const want = Math.max(1, Math.min(k, count));
  // 小顶堆：堆顶是当前第 want 名，新分数比它大才替换；避免对两万个分数做全排序
  const heapScore = new Float32Array(want);
  const heapIdx = new Int32Array(want);
  let filled = 0;

  const siftUp = (pos: number) => {
    while (pos > 0) {
      const parent = (pos - 1) >> 1;
      if (heapScore[parent] <= heapScore[pos]) break;
      const s = heapScore[parent];
      const i = heapIdx[parent];
      heapScore[parent] = heapScore[pos];
      heapIdx[parent] = heapIdx[pos];
      heapScore[pos] = s;
      heapIdx[pos] = i;
      pos = parent;
    }
  };
  const siftDown = (pos: number) => {
    for (;;) {
      const l = pos * 2 + 1;
      const r = l + 1;
      let min = pos;
      if (l < filled && heapScore[l] < heapScore[min]) min = l;
      if (r < filled && heapScore[r] < heapScore[min]) min = r;
      if (min === pos) break;
      const s = heapScore[min];
      const i = heapIdx[min];
      heapScore[min] = heapScore[pos];
      heapIdx[min] = heapIdx[pos];
      heapScore[pos] = s;
      heapIdx[pos] = i;
      pos = min;
    }
  };

  for (let i = 0; i < count; i++) {
    if (ids[i] === excludeId) continue;
    const off = i * dim;
    let dot = 0;
    for (let j = 0; j < dim; j++) dot += base[j] * mat[off + j];
    const score = dot / (bn * norms[i]);
    if (filled < want) {
      heapScore[filled] = score;
      heapIdx[filled] = i;
      siftUp(filled);
      filled++;
    } else if (score > heapScore[0]) {
      heapScore[0] = score;
      heapIdx[0] = i;
      siftDown(0);
    }
  }

  const hits: VectorHit[] = [];
  for (let i = 0; i < filled; i++) hits.push({ photoId: ids[heapIdx[i]], score: heapScore[i] });
  hits.sort((a, b) => b.score - a.score);
  return { hits, scanned: count, dim };
}

/** 诊断用：索引当前规模 */
export function photoVectorIndexInfo(db?: any): { count: number; dim: number; mb: number } | null {
  const s = db ? stores.get(db) : null;
  if (!s) return null;
  return {
    count: s.count,
    dim: s.dim,
    mb: Number(((s.count * s.dim * 4) / 1048576).toFixed(1)),
  };
}
