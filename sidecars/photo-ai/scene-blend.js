'use strict';

/**
 * 场景识别 v2：CLIP 开放词表 + Places365 闭集「双路融合 + 类先验校正 + 开放集门控」。
 *
 * 背景（实测结论，来自既有实现的真机数据）：
 * - 单跑 Places365 的 top-1 会形成 hub 标签（病房/荒漠/美容院…），且把「两人餐桌」判成「美容院」；
 * - 因此两路分数先归一到同一量纲再融合，并对 CLIP 做 z-score、对 Places365 做 logit adjustment；
 * - 「模型没看懂」必须有出口：confident / ambiguous / unknown 三态。
 *
 * 参数默认值来自既有实现的扫参结论（clipWeight 0.55 由 95 张人工标注扫出），
 * 全部可用环境变量覆盖，便于在真机上做 A/B。
 */

const DEFAULTS = {
  clipWeight: num('SCENE_CLIP_WEIGHT', 0.55),
  clipTemp: num('SCENE_CLIP_TEMP', 2.0),
  placesTemp: num('SCENE_PLACES_TEMP', 1.0),
  placesPriorBeta: num('SCENE_PLACES_PRIOR_BETA', 1.0),
  highThreshold: num('SCENE_HIGH', 0.2),
  lowThreshold: num('SCENE_LOW', 0.1),
  marginThreshold: num('SCENE_MARGIN', 0.015),
  topK: num('SCENE_TOPK', 3),
  altRatio: num('SCENE_ALT_RATIO', 0.3),
};

function num(name, fallback) {
  const v = Number(process.env[name]);
  return Number.isFinite(v) ? v : fallback;
}

function l2normalize(vec) {
  let n = 0;
  for (const v of vec) n += v * v;
  n = Math.sqrt(n) || 1;
  return vec.map((v) => v / n);
}

/** z-score：减均值除标准差（治 hub 标签） */
function zscore(values) {
  const n = values.length || 1;
  const mean = values.reduce((a, b) => a + b, 0) / n;
  const variance = values.reduce((a, b) => a + (b - mean) * (b - mean), 0) / n;
  const std = Math.sqrt(variance) || 1e-6;
  return values.map((v) => (v - mean) / std);
}

function softmax(values, temp = 1) {
  const t = temp > 0 ? temp : 1;
  const max = Math.max(...values);
  const exps = values.map((v) => Math.exp((v - max) / t));
  const sum = exps.reduce((a, b) => a + b, 0) || 1;
  return exps.map((v) => v / sum);
}

/** CLIP 侧：相似度 → z-score → 温度 softmax */
function clipDistribution(clipScores, temp) {
  const scores = clipScores.map((x) => Number(x.score) || 0);
  if (scores.length === 0) return [];
  const z = zscore(scores);
  const probs = softmax(z, temp);
  return clipScores.map((x, i) => ({ label: x.label, score: probs[i] }));
}

/** Places 侧：logit adjustment（减平均 logit）→ 温度 softmax */
function placesDistribution(placesLogits, temp, priorBeta) {
  const logits = placesLogits.map((x) => Number(x.logit) || 0);
  if (logits.length === 0) return [];
  const mean = logits.reduce((a, b) => a + b, 0) / logits.length;
  const adjusted = logits.map((v) => v - priorBeta * mean);
  const probs = softmax(adjusted, temp);
  return placesLogits.map((x, i) => ({ label: x.label, score: probs[i] }));
}

/**
 * 融合两路到统一标签空间，并按门控给出出口。
 * @param {object} input
 * @param {Array<{label:string,score:number}>} input.clipScores  CLIP 原始余弦
 * @param {Array<{label:string,logit:number}>} input.placesLogits Places365 原始 logits
 * @param {number|null} input.scorable 可判性 head 输出（score = w·x）
 * @param {number|null} input.scorableThreshold head 的阈值
 * @param {object} [input.params]
 */
function blendScene(input) {
  const params = Object.assign({}, DEFAULTS, input.params || {});
  const clip = clipDistribution(input.clipScores || [], params.clipTemp);
  const places = placesDistribution(input.placesLogits || [], params.placesTemp, params.placesPriorBeta);

  // 两路各自先取候选集：全标签 softmax 会被 700+ 类稀释（top 概率只有 0.0x），
  // 阈值就失去意义。候选集合并后再重归一化，分数尺度才与 high/low 阈值一致。
  const CANDIDATES = Math.max(20, params.topK * 4);
  const clipTop = clip.slice().sort((a, b) => b.score - a.score).slice(0, CANDIDATES);
  const placesTop = places.slice().sort((a, b) => b.score - a.score).slice(0, CANDIDATES);

  const clipMap = new Map(clipTop.map((x) => [x.label, x.score]));
  const placesMap = new Map(placesTop.map((x) => [x.label, x.score]));
  const labels = new Set([...clipMap.keys(), ...placesMap.keys()]);

  const w = params.clipWeight;
  const rawFused = [...labels].map((label) => ({
    label,
    raw: w * (clipMap.get(label) || 0) + (1 - w) * (placesMap.get(label) || 0),
  }));
  const total = rawFused.reduce((a, b) => a + b.raw, 0) || 1;
  const fused = rawFused
    .map((x) => ({ label: x.label, score: x.raw / total }))
    .sort((a, b) => b.score - a.score);

  if (fused.length === 0) {
    return { items: [], gate: { exit: 'unknown', score: 0, margin: 0, scorable: null, reason: 'no_signal' } };
  }

  const top = fused[0];
  const second = fused[1] || { score: 0 };
  const margin = top.score - second.score;

  let scorable = null;
  if (typeof input.scorable === 'number' && typeof input.scorableThreshold === 'number') {
    scorable = input.scorable >= input.scorableThreshold;
  }

  let exit = 'confident';
  let reason = 'ok';
  if (scorable === false) {
    exit = 'unknown';
    reason = 'scorable_gate';
  } else if (top.score < params.lowThreshold) {
    exit = 'unknown';
    reason = 'low_score';
  } else if (top.score < params.highThreshold || margin < params.marginThreshold) {
    exit = 'ambiguous';
    reason = margin < params.marginThreshold ? 'low_margin' : 'mid_score';
  }

  const items = fused
    .slice(0, Math.max(1, params.topK))
    .filter((x, i) => i === 0 || x.score >= top.score * params.altRatio)
    .map((x) => ({ label: x.label, score: Math.round(x.score * 1e6) / 1e6 }));

  return {
    items: exit === 'unknown' ? [] : items,
    gate: {
      exit,
      reason,
      score: Math.round(top.score * 1e6) / 1e6,
      margin: Math.round(margin * 1e6) / 1e6,
      scorable,
    },
  };
}

/** 余弦相似度（输入都已 L2 归一化时可退化为点积） */
function cosine(a, b) {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i += 1) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}

/** 可判性 head：score = w·x + b，x 为 L2 归一化的图像嵌入 */
function scorableScore(embedding, head) {
  if (!head || !Array.isArray(head.w) || head.w.length !== embedding.length) return null;
  let s = Number(head.b) || 0;
  for (let i = 0; i < embedding.length; i += 1) s += head.w[i] * embedding[i];
  return s;
}

module.exports = {
  DEFAULTS,
  blendScene,
  clipDistribution,
  placesDistribution,
  scorableScore,
  cosine,
  l2normalize,
  softmax,
  zscore,
};