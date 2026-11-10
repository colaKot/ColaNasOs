#!/usr/bin/env node
/**
 * 活动识别（SigLIP2 零样本，只走英文 prompts）。
 *
 * 口径（评测结论）：
 *   - 预处理：整图 224×224 cover、mean/std = 0.5（SigLIP 与 CLIP 不同，别抄 CLIP 的 0.48/0.26）；
 *   - 文本塔离线：`act_text_embeds.bin` 是 27×768 预计算嵌入，运行时只跑视觉塔；
 *   - 相似度 = 归一化图像嵌入 · 归一化文本嵌入；阈值 τ = 0.078，1.3τ 以上直接判有活动；
 *   - 不做「unrelated 锚点」：它会把 Top-1 抢走三分之一；
 *   - 中文 labels 只用于展示，判定只用英文 key/prompt。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ort = require('onnxruntime-node');

const ROOT = path.join(__dirname, '..', '..');
const MODEL_ROOT = process.env.COLANAS_MODEL_DIR || path.join(ROOT, 'vendor', 'models');
const DIR = () => path.join(MODEL_ROOT, 'activity');

const INPUT_SIZE = 224;
const MEAN = 0.5;
const STD = 0.5;
const ACT_THRESHOLD = Number(process.env.COLANAS_ACTIVITY_THRESHOLD || 0.078);

const EP_ALLOW = ['dml', 'cuda', 'cpu'];

function bestEps() {
  // 与 main.js / ocr.js 保持一致：默认 CPU，只有 COLANAS_PHOTO_AI_GPU=1 才试 DirectML。
  if (process.env.COLANAS_PHOTO_AI_FORCE_CPU === '1') return ['cpu'];
  if (process.env.COLANAS_PHOTO_AI_GPU !== '1') return ['cpu'];
  try {
    const backing = ort.listSupportedBackends().map((b) => b.name);
    const allowed = EP_ALLOW.filter((e) => backing.includes(e));
    return allowed.length > 0 ? allowed : ['cpu'];
  } catch {
    return ['cpu'];
  }
}

let ready = null;
let session = null;
let inputName = '';
let outputName = '';
let textEmbeds = null;
let meta = null;

function visionFile() {
  for (const name of ['siglip2_vision_q4f16.onnx', 'siglip2_vision_int8.onnx', 'siglip2_vision_fp16.onnx']) {
    const p = path.join(DIR(), name);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function available() {
  return Boolean(
    visionFile() &&
      fs.existsSync(path.join(DIR(), 'act_text_embeds.bin')) &&
      fs.existsSync(path.join(DIR(), 'act_candidates.json')),
  );
}

function ensure() {
  if (ready) return ready;
  ready = (async () => {
    if (!available()) throw new Error('activity model not available');
    meta = JSON.parse(fs.readFileSync(path.join(DIR(), 'act_candidates.json'), 'utf8'));
    const bin = fs.readFileSync(path.join(DIR(), 'act_text_embeds.bin'));
    textEmbeds = new Float32Array(bin.buffer.slice(bin.byteOffset, bin.byteOffset + bin.byteLength));
    const dim = Number(meta.dim) || 0;
    const count = Number(meta.count) || 0;
    if (!dim || !count || textEmbeds.length !== dim * count) {
      throw new Error('activity text embeddings size mismatch');
    }

    session = await ort.InferenceSession.create(visionFile(), {
      executionProviders: bestEps(),
      graphOptimizationLevel: 'all',
    });
    inputName = session.inputNames[0];
    outputName =
      (session.outputNames || []).find((n) => /pooler|image_embeds|embeds/i.test(n)) ||
      session.outputNames[session.outputNames.length - 1];
    return true;
  })().catch((err) => {
    ready = null;
    throw err;
  });
  return ready;
}

/** ffmpeg 出 224×224 cover 的 RGB24（cover = 等比放大后居中裁剪） */
function rgb224(src, ffmpeg) {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      src,
      '-vf',
      `scale=${INPUT_SIZE}:${INPUT_SIZE}:force_original_aspect_ratio=increase,crop=${INPUT_SIZE}:${INPUT_SIZE}`,
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgb24',
      '-',
    ];
    const child = spawn(ffmpeg, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    let err = '';
    child.stdout.on('data', (c) => chunks.push(c));
    child.stderr.on('data', (c) => {
      err += String(c);
      if (err.length > 4096) err = err.slice(-2048);
    });
    child.on('error', reject);
    child.on('close', (code) => {
      const data = Buffer.concat(chunks);
      if (code !== 0 || data.length < INPUT_SIZE * INPUT_SIZE * 3) {
        reject(new Error(`ffmpeg raw failed (${code}): ${err.slice(-200)}`));
        return;
      }
      resolve(data.subarray(0, INPUT_SIZE * INPUT_SIZE * 3));
    });
  });
}

function chw(rgb) {
  const hw = INPUT_SIZE * INPUT_SIZE;
  const out = new Float32Array(3 * hw);
  for (let i = 0; i < hw; i += 1) {
    const base = i * 3;
    out[i] = (rgb[base] / 255 - MEAN) / STD;
    out[hw + i] = (rgb[base + 1] / 255 - MEAN) / STD;
    out[2 * hw + i] = (rgb[base + 2] / 255 - MEAN) / STD;
  }
  return out;
}

function l2(vec) {
  let sum = 0;
  for (let i = 0; i < vec.length; i += 1) sum += vec[i] * vec[i];
  const n = Math.sqrt(sum) || 1;
  const out = new Float32Array(vec.length);
  for (let i = 0; i < vec.length; i += 1) out[i] = vec[i] / n;
  return out;
}

/**
 * 对单张图做活动打分。
 * @returns {Promise<{labels: Array<{key:string,label:string,score:number}>, topScore:number, hasActivity:boolean}>}
 */
async function score(src, ffmpeg, opts = {}) {
  await ensure();
  // 主进程多路解码时已经把 224×224 cover 这一路一起出好了，直接用，省一次 spawn
  const rgb =
    opts.rgb && opts.rgb.length >= INPUT_SIZE * INPUT_SIZE * 3
      ? opts.rgb.subarray(0, INPUT_SIZE * INPUT_SIZE * 3)
      : await rgb224(src, ffmpeg);
  const out = await session.run({
    [inputName]: new ort.Tensor('float32', chw(rgb), [1, 3, INPUT_SIZE, INPUT_SIZE]),
  });
  const emb = l2(Float32Array.from(out[outputName].data));

  const dim = Number(meta.dim);
  const count = Number(meta.count);
  const sims = [];
  for (let i = 0; i < count; i += 1) {
    let dot = 0;
    const base = i * dim;
    for (let d = 0; d < dim; d += 1) dot += emb[d] * textEmbeds[base + d];
    sims.push({ i, sim: dot });
  }
  sims.sort((a, b) => b.sim - a.sim);

  const keyList = Array.isArray(meta.keys) ? meta.keys : [];
  const labelList = Array.isArray(meta.labels) ? meta.labels : [];
  const threshold = Number(opts.threshold) || ACT_THRESHOLD;
  const topK = Math.max(1, Math.min(Number(opts.topK) || 3, count));
  const labels = sims.slice(0, topK).map((s) => ({
    key: String(keyList[s.i] || ''),
    label: String(labelList[s.i] || keyList[s.i] || ''),
    score: Number(s.sim.toFixed(4)),
  }));

  const topScore = labels.length ? labels[0].score : 0;
  return { labels, topScore, hasActivity: topScore >= threshold };
}

module.exports = { available, score, threshold: ACT_THRESHOLD };