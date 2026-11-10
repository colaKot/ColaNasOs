import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import type { KernelApi } from '../../../../kernel/types';
import { fromBuffer } from './face';
import { modelRoot } from './sidecar';

/**
 * 照片级向量检索（CLIP 图文同空间）。
 *
 * 已有的语义检索走的是「短语 → 场景标签 → 标签召回」，粒度是**标签**：
 * 词表里没有的概念、或者标签没打上的照片，就永远搜不到。
 * 这里补的是**照片级**召回：把查询短语的文本向量求和成查询方向，
 * 直接对 `photo_embeddings`（CLIP 视觉塔产出的 512 维）做余弦扫描。
 *
 * 关键前提：`photo_embeddings.vec`（视觉塔）与 `clip/query_embeds.bin`
 * （文本塔，按 query_lexicon.json 的顺序）**是同一个 512 维空间**，
 * 所以不需要运行时文本塔 —— 这是构建期就把提示词向量算好带来的能力。
 *
 * 命中只作为**召回补充**（给一个低于精确标签命中的分），不重排既有结果：
 * 标签命中是确定性的，向量命中是概率的，不能让它把确定性结果顶下去。
 */

interface LexiconEntry {
  key: string;
  prompt: string;
  binding: string;
}

interface VectorAssets {
  dim: number;
  entries: LexiconEntry[];
  /** 词表短语的文本向量（entries 顺序） */
  entryEmbeds: Float32Array;
  labels: string[];
  /** 场景标签的文本向量，词表兜底时用 */
  labelEmbeds: Float32Array | null;
  labelIndex: Map<string, number>;
}

let assets: VectorAssets | null = null;
let loadFailed = false;

function clipDir(): string {
  return path.join(modelRoot(), 'clip');
}

/** 只读三个小文件（1MB 上下），缺任何一个就整体降级，不影响搜索本身 */
function ensureAssets(): VectorAssets | null {
  if (assets) return assets;
  if (loadFailed) return null;
  try {
    const dir = clipDir();
    const metaPath = path.join(dir, 'query_lexicon.json');
    const binPath = path.join(dir, 'query_embeds.bin');
    if (!fs.existsSync(metaPath) || !fs.existsSync(binPath)) throw new Error('lexicon missing');

    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as {
      dim?: number;
      entries?: Array<Partial<LexiconEntry>>;
    };
    const dim = Number(meta.dim) || 512;
    const entries = (Array.isArray(meta.entries) ? meta.entries : [])
      .map((e) => ({
        key: String(e?.key || '').trim(),
        prompt: String(e?.prompt || '').trim(),
        binding: String(e?.binding || '').trim(),
      }))
      .filter((e) => e.key && e.prompt);

    const buf = fs.readFileSync(binPath);
    const entryEmbeds = new Float32Array(
      buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength),
    );
    if (entries.length === 0 || entryEmbeds.length !== entries.length * dim) {
      throw new Error('query embeds size mismatch');
    }

    let labels: string[] = [];
    let labelEmbeds: Float32Array | null = null;
    const tagMetaPath = path.join(dir, 'text_embeds.json');
    const tagBinPath = path.join(dir, 'text_embeds.bin');
    if (fs.existsSync(tagMetaPath) && fs.existsSync(tagBinPath)) {
      const tagMeta = JSON.parse(fs.readFileSync(tagMetaPath, 'utf8')) as {
        dim?: number;
        labels?: string[];
      };
      const tagDim = Number(tagMeta.dim) || dim;
      const tagBuf = fs.readFileSync(tagBinPath);
      labels = (Array.isArray(tagMeta.labels) ? tagMeta.labels : []).map((s) => String(s || ''));
      const arr = new Float32Array(
        tagBuf.buffer.slice(tagBuf.byteOffset, tagBuf.byteOffset + tagBuf.byteLength),
      );
      if (labels.length > 0 && arr.length === labels.length * tagDim && tagDim === dim) {
        labelEmbeds = arr;
      }
    }

    const labelIndex = new Map<string, number>();
    labels.forEach((l, i) => {
      if (l) labelIndex.set(l, i);
    });

    assets = { dim, entries, entryEmbeds, labels, labelEmbeds, labelIndex };
    return assets;
  } catch {
    loadFailed = true;
    return null;
  }
}

export function vectorAvailable(): boolean {
  return ensureAssets() !== null;
}

/** 词表短语 → 下标（资产只加载一次，索引跟着资产缓存） */
let idxCache: { owner: VectorAssets; map: Map<string, number> } | null = null;

function entryIndex(a: VectorAssets): Map<string, number> {
  if (idxCache && idxCache.owner === a) return idxCache.map;
  const map = new Map<string, number>();
  a.entries.forEach((e, i) => map.set(e.key, i));
  idxCache = { owner: a, map };
  return map;
}

export interface VectorQueryInput {
  /** 词表命中的短语（权重高的在前），`from` 来自 sidecar 的解析结果 */
  keys: string[];
  /** 标签名，词表兜底时用标签向量 */
  labels: string[];
}

/**
 * 查询方向 = 命中的短语向量按长度加权求和。
 *
 * 多条短语（「海边的日落」= 海边 + 日落）求和得到的是两者的**方向中位**，
 * 这正是 AND 语义想要的效果；余弦只看方向，所以不用担心中位向量的模变小。
 * 一条短语都对不上时退回标签向量，保证「词表没覆盖但标签命中了」也能扫。
 */
export function queryVector(input: VectorQueryInput): Float32Array | null {
  const a = ensureAssets();
  if (!a) return null;
  const out = new Float32Array(a.dim);
  let total = 0;
  const idx = entryIndex(a);
  for (const key of input.keys) {
    const i = idx.get(key);
    if (i == null) continue;
    // 长短语更具体（「日落」比「日」有信息量），权重随长度温和增长
    const w = 1 + Math.min(0.6, Math.max(0, key.length - 1) * 0.2);
    const base = i * a.dim;
    for (let d = 0; d < a.dim; d += 1) out[d] += a.entryEmbeds[base + d] * w;
    total += w;
  }
  if (total === 0 && a.labelEmbeds) {
    for (const label of input.labels) {
      const i = a.labelIndex.get(label);
      if (i == null) continue;
      const base = i * a.dim;
      for (let d = 0; d < a.dim; d += 1) out[d] += a.labelEmbeds[base + d];
      total += 1;
    }
  }
  if (total === 0) return null;
  // 归一成方向即可（余弦对模长不敏感，这里归一只是为了后面的阈值有直观含义）
  let norm = 0;
  for (let d = 0; d < a.dim; d += 1) norm += out[d] * out[d];
  norm = Math.sqrt(norm) || 1;
  for (let d = 0; d < a.dim; d += 1) out[d] /= norm;
  return out;
}

function cosine(a: Float32Array, b: Float32Array): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}

export interface VectorHit {
  id: string;
  score: number;
}

/**
 * 照片级余弦扫描。
 *
 * `minScore` 默认 0.18：CLIP 图文余弦的有效区间本来就窄（0.2 附近已算同义），
 * 用 0.5 这种「像句子相似度」的阈值会一条都抓不到。
 */
export async function scorePhotoVector(
  k: KernelApi,
  input: VectorQueryInput,
  opts: { uid: string; limit?: number; minScore?: number },
): Promise<{ hits: VectorHit[]; truncated: boolean; degraded: boolean }> {
  const qv = queryVector(input);
  if (!qv) return { hits: [], truncated: false, degraded: true };

  const limit = Math.max(1, Math.min(Number(opts.limit) || 300, 500));
  const minScore = opts.minScore == null ? 0.18 : Number(opts.minScore);
  // 线性扫描：默认最近 5000 条，可同上限环境变量调大；到顶只告警不报错
  const scanLimit = Math.max(
    100,
    Math.min(Number(process.env.COLANAS_VECTOR_SCAN_LIMIT) || 5000, 50_000),
  );

  const rows = (
    await sql<{ photo_id: string; vec: Buffer }>`
      select e.photo_id, e.vec from photo_embeddings e
        join photo_items i on i.id = e.photo_id
       where e.dim = ${qv.length} and i.in_trash = 0
         and i.library_id in (select id from photo_libraries where owner_id = ${opts.uid})
       limit ${scanLimit}
    `.execute(k.db)
  ).rows;
  const truncated = rows.length >= scanLimit;
  if (truncated) {
    k.log.warn({ scanLimit }, 'photo.semantic.vector: scan limit reached, recall may be incomplete');
  }

  const hits = rows
    .map((r) => ({ id: r.photo_id, score: cosine(qv, fromBuffer(r.vec)) }))
    .filter((h) => h.score >= minScore)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map((h) => ({ id: h.id, score: Number(h.score.toFixed(3)) }));

  return { hits, truncated, degraded: false };
}
