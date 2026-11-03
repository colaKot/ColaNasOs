#!/usr/bin/env node
/**
 * 语义搜索的「查询解析」：中文 → 场景标签。
 *
 * 口径：
 *   ① 词表 512 条短语（query_lexicon.json）配 512 维预计算嵌入（query_embeds.bin），
 *      中文输入按「最长短语优先」做最大匹配，未被覆盖的字符单独报给前端；
 *   ② **权威绑定优先**：短语声明了 binding 且该标签在场景标签空间里 ⇒ 直接命中，
 *      绝不走最近邻（实测「猫」的最近邻是「地下墓穴 0.97」这类噪声）；
 *   ③ 没声明 binding 的氛围词/抽象词才用嵌入找最近邻，且只保留「与最近邻差距 ≤0.03」的候选，
 *      **不用绝对阈值**（CLIP 文本相似度绝对值普遍很高、不具分辨力）；
 *   ④ 多个短语命中同一标签时按 `1 + 0.35×(hits-1)` 加权（「A 的 B」的 AND 语义）。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const MODEL_ROOT = process.env.COLANAS_MODEL_DIR || path.join(ROOT, 'vendor', 'models');
const CLIP_DIR = () => path.join(MODEL_ROOT, 'clip');

const FALLBACK_SIM_GAP = 0.03;
const FALLBACK_MAX_TAGS = 4;
const MULTI_HIT_BONUS = 0.35;
const LEADING_NOISE = /^(?:帮我|请|麻烦|我要|我想|想找|找一下|找找|查找|搜索|搜一下|搜索一下|搜|看看|来点|给我|找)+/;
const TRAILING_NOISE = /(?:的照片|的图片|的相片|照片|图片|相片|图片集|的图)+$/;

let ready = null;
let entries = [];
let embeds = null;
let dim = 0;
let byLen = [];
let labels = [];
let labelEmbeds = null;

function available() {
  return (
    fs.existsSync(path.join(CLIP_DIR(), 'query_lexicon.json')) &&
    fs.existsSync(path.join(CLIP_DIR(), 'query_embeds.bin')) &&
    fs.existsSync(path.join(CLIP_DIR(), 'text_embeds.json')) &&
    fs.existsSync(path.join(CLIP_DIR(), 'text_embeds.bin'))
  );
}

function ensure() {
  if (ready) return ready;
  ready = (async () => {
    if (!available()) throw new Error('semantic lexicon not available');
    const meta = JSON.parse(fs.readFileSync(path.join(CLIP_DIR(), 'query_lexicon.json'), 'utf8'));
    const bin = fs.readFileSync(path.join(CLIP_DIR(), 'query_embeds.bin'));
    entries = (Array.isArray(meta.entries) ? meta.entries : [])
      .map((e) => ({
        key: String(e.key || '').trim(),
        prompt: String(e.prompt || '').trim(),
        binding: String(e.binding || '').trim(),
      }))
      .filter((e) => e.key && e.prompt);
    dim = Number(meta.dim) || 512;
    embeds = new Float32Array(bin.buffer.slice(bin.byteOffset, bin.byteOffset + bin.byteLength));
    if (embeds.length !== entries.length * dim) throw new Error('query embeds size mismatch');

    const tagMeta = JSON.parse(fs.readFileSync(path.join(CLIP_DIR(), 'text_embeds.json'), 'utf8'));
    const tagBin = fs.readFileSync(path.join(CLIP_DIR(), 'text_embeds.bin'));
    labels = (Array.isArray(tagMeta.labels) ? tagMeta.labels : []).map((s) => String(s || ''));
    labelEmbeds = new Float32Array(tagBin.buffer.slice(tagBin.byteOffset, tagBin.byteOffset + tagBin.byteLength));
    const tagDim = Number(tagMeta.dim) || dim;
    if (labelEmbeds.length !== labels.length * tagDim) throw new Error('tag embeds size mismatch');

    byLen = entries
      .map((e, i) => ({ key: e.key, i }))
      .filter((x) => x.key)
      .sort((a, b) => b.key.length - a.key.length);
    return true;
  })().catch((err) => {
    ready = null;
    throw err;
  });
  return ready;
}

function normalize(text) {
  let s = String(text == null ? '' : text).trim();
  if (!s) return '';
  s = s
    .replace(/[\uFF01-\uFF5E]/g, (ch) => String.fromCharCode(ch.charCodeAt(0) - 0xfee0))
    .replace(/\u3000/g, ' ')
    .toLowerCase();
  return s.replace(LEADING_NOISE, '').replace(TRAILING_NOISE, '').trim();
}

/** 最大匹配：从当前位置取能匹配上的最长短语 */
function segment(q) {
  const components = [];
  const unmatched = [];
  const seen = new Set();
  let i = 0;
  let gap = '';
  const SEP = /[\s,，、。.!！?？/|+&;；:：\-_（）()[\]【】"'“”‘’]/;
  while (i < q.length) {
    const ch = q[i];
    if (SEP.test(ch)) {
      i += 1;
      continue;
    }
    let hit = null;
    for (const cand of byLen) {
      if (cand.key.length > q.length - i) continue;
      if (q.startsWith(cand.key, i)) {
        hit = cand;
        break;
      }
    }
    if (hit) {
      if (!seen.has(hit.key)) {
        seen.add(hit.key);
        components.push({ key: hit.key, index: hit.i });
      }
      if (gap) {
        unmatched.push(gap);
        gap = '';
      }
      i += hit.key.length;
    } else {
      gap += ch;
      i += 1;
    }
  }
  if (gap) unmatched.push(gap);
  return { components, unmatched };
}

function weightOf(key) {
  return 1 + Math.min(0.6, Math.max(0, key.length - 1) * 0.2);
}

function embedAt(idx) {
  return embeds.subarray(idx * dim, (idx + 1) * dim);
}

/**
 * @returns {{ok:boolean, normalized:string, components:Array, unmatched:string[],
 *            tags:Array<{label:string,score:number,hits:number,from:string[]}>, reason?:string}}
 */
async function analyze(text, opts = {}) {
  await ensure();
  const normalized = normalize(text);
  if (!normalized) return { ok: false, normalized, components: [], unmatched: [], tags: [], reason: 'empty' };
  if (!labels.length || !labelEmbeds) {
    return { ok: false, normalized, components: [], unmatched: [], tags: [], reason: 'tag_table_missing' };
  }

  const labelIndex = new Map();
  for (let i = 0; i < labels.length; i += 1) if (labels[i]) labelIndex.set(labels[i], i);

  const { components, unmatched } = segment(normalized);
  if (!components.length) {
    return { ok: false, normalized, components: [], unmatched, tags: [], reason: 'no_component' };
  }

  const acc = new Map();
  const add = (label, value, fromKey, weight) => {
    if (!label) return;
    let rec = acc.get(label);
    if (!rec) {
      rec = { label, score: 0, hits: 0, weight: 0, from: new Set() };
      acc.set(label, rec);
    }
    rec.score += value * weight;
    rec.weight += weight;
    rec.hits += 1;
    rec.from.add(fromKey);
  };

  const resolved = [];
  for (const c of components) {
    const entry = entries[c.index];
    const weight = weightOf(entry.key);
    const bindings = String(entry.binding || '')
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    const hitBinding = bindings.find((b) => labelIndex.has(b));
    if (hitBinding) {
      add(hitBinding, 1, entry.key, weight);
      resolved.push({ key: entry.key, binding: entry.binding, tag: hitBinding, via: 'binding' });
      continue;
    }
    if (bindings.length) {
      // 声明了绑定但目标不在标签空间：宁可不给，也不给错的
      resolved.push({ key: entry.key, binding: entry.binding, tag: '', via: 'binding_unavailable' });
      continue;
    }

    const qv = embedAt(c.index);
    const scored = [];
    for (let t = 0; t < labels.length; t += 1) {
      if (!labels[t]) continue;
      const base = t * dim;
      let s = 0;
      for (let d = 0; d < dim; d += 1) s += qv[d] * labelEmbeds[base + d];
      scored.push({ label: labels[t], sim: s });
    }
    scored.sort((a, b) => b.sim - a.sim);
    const best = scored.length ? scored[0].sim : 0;
    let picked = 0;
    for (const s of scored) {
      if (picked >= FALLBACK_MAX_TAGS) break;
      if (best - s.sim > FALLBACK_SIM_GAP) break;
      add(s.label, s.sim, entry.key, weight);
      picked += 1;
    }
    resolved.push({ key: entry.key, binding: entry.binding || '', tag: picked ? scored[0].label : '', via: 'embedding' });
  }

  const limit = Math.max(1, Number(opts.topTags) || 8);
  const tags = [...acc.values()]
    .map((rec) => ({
      label: rec.label,
      score: (rec.weight > 0 ? rec.score / rec.weight : 0) * (1 + MULTI_HIT_BONUS * Math.max(0, rec.hits - 1)),
      hits: rec.hits,
      from: [...rec.from],
    }))
    .sort((a, b) => b.hits - a.hits || b.score - a.score)
    .slice(0, limit);

  return { ok: tags.length > 0, normalized, components: resolved, unmatched, tags };
}

module.exports = { available, analyze };