#!/usr/bin/env node
/**
 * photo-ai sidecar：人脸检测 / 场景分类 / 图像 embedding。
 *
 * 模型与做法如下，代码按本项目零依赖风格实现：
 *   faces/faceLandMark  端到端检测 + 106 点 + 224² 对齐图（输入 HWC uint8，动态尺寸）
 *   faces/edgeface      112² RGB、(x-127.5)/127.5 → 512 维人脸特征
 *   places365           resnet50，ImageNet 归一化 + 224 中心裁剪 → 365 类
 *   clip/vision_model   pixel_values 1×3×224×224（CLIP 预处理）→ 512 维图像特征
 *
 * 预处理全部用 ffmpeg 出 raw RGB（不引 sharp / canvas），推理用 onnxruntime-node。
 *
 * 协议：
 *   invoke('analyze', { src, faces?, scenes?, embed? }) ->
 *     { faces: [{ emb, score, quality, pose, box }], scenes: [{ label, score }], embedding: number[] }
 *     quality = score * 100；pose = { yaw, roll, iod }（kpss 缺失时 yaw/roll 为 null）
 *   invoke('stats') -> 计数器
 */
'use strict';

const fs = require('node:fs');
const nodePath = require('node:path');
const { spawn } = require('node:child_process');
const ort = require('onnxruntime-node');
const ocr = require('./ocr');
const activity = require('./activity');
const semantic = require('./semantic');
const sceneBlend = require('./scene-blend');

const ROOT = nodePath.join(__dirname, '..', '..');
const MODEL_ROOT = process.env.COLANAS_MODEL_DIR || nodePath.join(ROOT, 'vendor', 'models');

/** 与 ai-infer 一致：显式排除 webgpu（1.30 的 dml/webgpu 互斥会废掉全部会话） */
const EP_ALLOW = ['dml', 'cuda', 'cpu'];

const stats = { images: 0, faces: 0, scenes: 0, embeds: 0, ocr: 0, activities: 0, fails: 0 };

process.stdin.setEncoding('utf8');
process.stdout.on('error', () => {});
let buf = '';
const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

function findFfmpeg() {
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const env = process.env.COLANAS_FFMPEG;
  if (env && fs.existsSync(env)) return env;
  for (const c of [
    nodePath.join(ROOT, 'vendor', 'ffmpeg', exe),
    nodePath.join(ROOT, 'vendor', 'ffmpeg', 'bin', exe),
  ]) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}
const FFMPEG = findFfmpeg();

function findFfprobe() {
  const exe = process.platform === 'win32' ? 'ffprobe.exe' : 'ffprobe';
  if (FFMPEG) {
    const sibling = nodePath.join(nodePath.dirname(FFMPEG), exe);
    if (fs.existsSync(sibling)) return sibling;
  }
  for (const c of [
    nodePath.join(ROOT, 'vendor', 'ffmpeg', exe),
    nodePath.join(ROOT, 'vendor', 'ffmpeg', 'bin', exe),
  ]) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}
const FFPROBE = findFfprobe();

function bestEps() {
  if (process.env.COLANAS_PHOTO_AI_FORCE_CPU === '1') return ['cpu'];
  try {
    const backing = ort.listSupportedBackends().map((b) => b.name);
    const allowed = EP_ALLOW.filter((e) => backing.includes(e));
    return allowed.length > 0 ? allowed : ['cpu'];
  } catch {
    return ['cpu'];
  }
}

const SESSION_OPTS = { executionProviders: bestEps(), graphOptimizationLevel: 'all' };

const sessions = new Map();
function session(path, key) {
  const cached = sessions.get(key);
  if (cached) return cached;
  const p = (async () => {
    const s = await ort.InferenceSession.create(path, SESSION_OPTS);
    return s;
  })();
  sessions.set(key, p);
  return p;
}

let labelsPromise = null;
function placesLabels() {
  if (labelsPromise) return labelsPromise;
  labelsPromise = (async () => {
    const zh = nodePath.join(MODEL_ROOT, 'places365', 'categories_places365.zh.txt');
    const raw = fs.readFileSync(zh, 'utf8').split(/\r?\n/).filter(Boolean);
    // 行格式：zh 版是 `/a/alcove\t凹室`，英文版是 `/a/alcove`
    return raw.map((line) => {
      const [category, zhLabel] = line.split('\t');
      if (zhLabel && zhLabel.trim()) return zhLabel.trim();
      return category.replace(/^\//, '');
    });
  })();
  return labelsPromise;
}

/**
 * CLIP 场景词表资产：
 * - `scene_tags.txt`：`中文标签 <TAB> 英文提示词`，同一标签多行 = 提示词集成；
 * - `text_embeds.bin`：按提示词顺序存放的 float32 嵌入（构建期算好，运行时不用文本塔）；
 * - `scene_scorable_head.json`：可判性二分类 head（w/b/threshold）。
 *
 * 加载时按标签聚合（平均 + 重新归一化），行数与嵌入数不一致直接抛错——静默错位比报错更难查。
 */
let sceneAssetsPromise = null;
function sceneAssets() {
  if (sceneAssetsPromise) return sceneAssetsPromise;
  sceneAssetsPromise = (async () => {
    const meta = JSON.parse(
      fs.readFileSync(nodePath.join(MODEL_ROOT, 'clip', 'text_embeds.json'), 'utf8'),
    );
    const dim = Number(meta.dim) || 512;
    // 嵌入是**按标签**存放的（构建期已做提示词集成平均），数量 = meta.labels.length；
    // scene_tags.txt 的行数是提示词数（含同一标签多行），不能拿来对齐。
    const labelList = Array.isArray(meta.labels) ? meta.labels : [];
    const bin = fs.readFileSync(nodePath.join(MODEL_ROOT, 'clip', 'text_embeds.bin'));
    const n = Math.floor(bin.length / (dim * 4));
    if (n !== labelList.length) {
      throw new Error(`scene assets mismatch: labels=${labelList.length} embeds=${n}`);
    }

    const labels = labelList.map((label, i) => {
      const vec = new Float32Array(dim);
      for (let d = 0; d < dim; d += 1) vec[d] = bin.readFloatLE((i * dim + d) * 4);
      return { label, vec: sceneBlend.l2normalize(Array.from(vec)) };
    });

    let head = null;
    try {
      head = JSON.parse(
        fs.readFileSync(nodePath.join(MODEL_ROOT, 'clip', 'scene_scorable_head.json'), 'utf8'),
      );
    } catch {
      /* head 缺失：退化为「100% 出标签」的老行为 */
    }

    return { labels, head };
  })();
  return sceneAssetsPromise;
}

/** ffmpeg 出 RGB24 raw：等比缩放到最长边 maxSize，再 pad 成 size×size（黑边不影响分类/检测） */
function rawRgb(src, size) {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      src,
      // HEIC 解码时 ffmpeg 内部会自建 complex filtergraph（网格 / 透明通道），
      // 这时再给 `-vf` 会直接报「Simple and complex filtering cannot be used
      // together」，HEIC 一张都识别不了。统一走 `-filter_complex` + map。
      '-filter_complex',
      `[0:v]scale=${size}:${size}:force_original_aspect_ratio=decrease,pad=${size}:${size}:(ow-iw)/2:(oh-ih)/2,format=rgb24[out]`,
      '-map',
      '[out]',
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgb24',
      '-',
    ];
    const child = spawn(FFMPEG, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
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
      const expected = size * size * 3;
      if (code !== 0 || data.length < expected) {
        reject(new Error(`ffmpeg raw failed (${code}): ${err.slice(-200)}`));
        return;
      }
      resolve(data.subarray(0, expected));
    });
  });
}

/** ffmpeg 出灰度 raw（w×h），用于 9×8 dHash */
function rawGray(src, w, h) {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      src,
      // 同上：HEIC 只能用 complex filtergraph
      '-filter_complex',
      `[0:v]scale=${w}:${h}:flags=area,format=gray[out]`,
      '-map',
      '[out]',
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'gray',
      '-',
    ];
    const child = spawn(FFMPEG, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
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
      if (code !== 0 || data.length < w * h) {
        reject(new Error(`ffmpeg gray failed (${code}): ${err.slice(-200)}`));
        return;
      }
      resolve(data.subarray(0, w * h));
    });
  });
}

/** 9×8 差值与 dHash：64 位 → 16 位十六进制 */
async function phashOnly(params) {
  if (!FFMPEG) throw Object.assign(new Error('ffmpeg not found'), { code: 'E_NO_FFMPEG' });
  const src = String(params.src || '');
  if (!src) throw Object.assign(new Error('src required'), { code: 'E_BAD_PARAM' });
  const gray = await rawGray(src, 9, 8);
  let bits = '';
  for (let y = 0; y < 8; y += 1) {
    for (let x = 0; x < 8; x += 1) {
      bits += gray[y * 9 + x] > gray[y * 9 + x + 1] ? '1' : '0';
    }
  }
  stats.phashes = (stats.phashes || 0) + 1;
  return { hash: BigInt(`0b${bits}`).toString(16).padStart(16, '0'), bits: 64 };
}

/** 原图显示尺寸（ffprobe；ffmpeg 解码时已按 EXIF 自动旋转，坐标空间一致） */
function probeSize(src) {
  return new Promise((resolve) => {
    if (!FFPROBE) {
      resolve(null);
      return;
    }
    const args = [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height',
      '-of', 'csv=p=0',
      src,
    ];
    const child = spawn(FFPROBE, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (c) => {
      out += String(c);
      if (out.length > 512) out = out.slice(0, 512);
    });
    child.on('error', () => resolve(null));
    child.on('close', (code) => {
      if (code !== 0) return resolve(null);
      const [w, h] = out.trim().split(',').map((v) => Number(v));
      if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return resolve(null);
      resolve({ w, h });
    });
  });
}

/**
 * 检测输入边长：**跟随原图**而不是固定 640。
 *
 * 固定 640 的代价是实测出来的：4000px 原图缩到 640，占画面 1/10 宽的脸只剩 64px，
 * 合影后排直接漏检。这里按最长边向上取 32 的倍数，上限 960（与参考实现同口径）。
 */
function detectSize(ow, oh) {
  const maxSide = Math.max(ow, oh);
  return Math.max(256, Math.min(960, Math.ceil(maxSide / 32) * 32));
}

/** 等比缩放 + 居中 pad 后的 affine（与 rawRgb 的 ffmpeg 滤镜参数一致） */
function affineOf(ow, oh, targetSize) {
  const scale = Math.min(1, targetSize / ow, targetSize / oh);
  const newW = Math.max(1, Math.round(ow * scale));
  const newH = Math.max(1, Math.round(oh * scale));
  return {
    scale,
    padX: Math.floor((targetSize - newW) / 2),
    padY: Math.floor((targetSize - newH) / 2),
  };
}

/** HWC uint8 → 张量 [H,W,3]（faceLandMark 要 HWC 且不带 batch 维） */
function hwcTensor(buf, size) {
  return new ort.Tensor('uint8', new Uint8Array(buf), [size, size, 3]);
}

/** CHW float32（RGB，按 mean/std 归一化） */
function chwTensor(rgb, size, mean, std) {
  const hw = size * size;
  const out = new Float32Array(3 * hw);
  for (let i = 0; i < hw; i += 1) {
    // rgb 是 0~255 uint8，mean/std 是 0~1 归一化参数：必须先 /255（2026-11-04 修）
    const r = rgb[i * 3] / 255;
    const g = rgb[i * 3 + 1] / 255;
    const b = rgb[i * 3 + 2] / 255;
    out[i] = (r - mean[0]) / std[0];
    out[hw + i] = (g - mean[1]) / std[1];
    out[2 * hw + i] = (b - mean[2]) / std[2];
  }
  return new ort.Tensor('float32', out, [1, 3, size, size]);
}

/** 224² uint8 RGB → 112² float32 CHW（(x-127.5)/127.5，EdgeFace 预处理） */
function alignTo112(rgb224) {
  const src = 224;
  const dst = 112;
  const rgb112 = new Uint8Array(dst * dst * 3);
  for (let y = 0; y < dst; y += 1) {
    for (let x = 0; x < dst; x += 1) {
      const si = (y * 2 * src + x * 2) * 3;
      const di = (y * dst + x) * 3;
      rgb112[di] = rgb224[si];
      rgb112[di + 1] = rgb224[si + 1];
      rgb112[di + 2] = rgb224[si + 2];
    }
  }
  if (FACE_LUMA_NORM) lumaNormalizeRgbInplace(rgb112);
  const out = new Float32Array(3 * dst * dst);
  for (let i = 0; i < dst * dst; i += 1) {
    out[i] = (rgb112[i * 3] - 127.5) / 127.5;
    out[dst * dst + i] = (rgb112[i * 3 + 1] - 127.5) / 127.5;
    out[2 * dst * dst + i] = (rgb112[i * 3 + 2] - 127.5) / 127.5;
  }
  return new ort.Tensor('float32', out, [1, 3, dst, dst]);
}

/**
 * 亮度归一化：把对齐人脸的 Y 均值拉到 127.5（std 64）。
 *
 * 逆光 / 夜间照片的特征会整体偏暗，跨照片相似度被压低，表现为同一个人裂成多组。
 */
function lumaNormalizeRgbInplace(rgb) {
  const pixels = rgb.length / 3;
  if (!pixels) return;
  let sum = 0;
  let sum2 = 0;
  for (let i = 0; i < rgb.length; i += 3) {
    const y = 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
    sum += y;
    sum2 += y * y;
  }
  const mean = sum / pixels;
  const variance = Math.max(0, sum2 / pixels - mean * mean);
  const std = Math.sqrt(variance);
  if (!(std > 1e-6)) return;
  const scale = 64.0 / std;
  const offset = 127.5 - scale * mean;
  for (let i = 0; i < rgb.length; i += 1) {
    const v = Math.round(rgb[i] * scale + offset);
    rgb[i] = v <= 0 ? 0 : v >= 255 ? 255 : v;
  }
}

function l2normalize(vec) {
  let sum = 0;
  for (const v of vec) sum += v * v;
  const norm = Math.sqrt(sum) || 1;
  return Array.from(vec, (v) => v / norm);
}

/** int64 张量在 onnxruntime-node 里是 BigInt64Array，统一转 number */
function numOf(v) {
  return typeof v === 'bigint' ? Number(v) : Number(v) || 0;
}

/** 亮度归一化开关（对齐参考实现的 EdgeFace 预处理） */
const FACE_LUMA_NORM = String(process.env.COLANAS_FACE_LUMA_NORM ?? '1') !== '0';

/**
 * 之前本 sidecar 把模型输出的**所有**框都收进库，低分纹理误检也会变成「人脸碎片」，
 * 于是头像墙里大量莫名其妙的半张脸 / 背景光斑。这组阈值把这类框挡在识别之前。
 *
 * - score < 0.55：直接丢弃（孩子侧脸、夜间虚影真人脸通常还在 0.55~0.8）
 * - 框短边 < 80px：特征不稳定，丢弃
 * - 框宽 < 图宽 1.5%：极小伪脸；低分框（<0.8）还要求 ≥3%
 * - 单图超过 20 张脸：基本是图案误检，整张丢弃
 */
const FACE_DET_SCORE_THRESH = Number(process.env.COLANAS_FACE_DET_SCORE ?? 0.55);
const FACE_DET_SCORE_STRICT = Number(process.env.COLANAS_FACE_DET_STRICT ?? 0.8);
const FACE_MIN_BOX_SIZE_PX = Number(process.env.COLANAS_FACE_MIN_BOX_PX ?? 80);
const FACE_MIN_BOX_WIDTH_RATIO = Number(process.env.COLANAS_FACE_MIN_BOX_RATIO ?? 0.015);
const FACE_MIN_BOX_WIDTH_RATIO_LOOSE = Number(
  process.env.COLANAS_FACE_MIN_BOX_RATIO_LOOSE ?? 0.03,
);
const FACE_MAX_FACES_PER_IMAGE = Number(process.env.COLANAS_FACE_MAX_PER_IMAGE ?? 20);

/**
 * 从 faceLandMark 的 5 点关键点算姿态代理量（对齐参考实现 _computePoseFromKps）。
 *
 * 为什么需要：极端侧脸的**检测置信度往往很高**（模型很确定"这是一张脸"），
 * 只靠 quality 拦不住；而这些脸的 embedding 互相之间反而更像，是"侧脸槽"大杂烩组的原料。
 * yaw = (鼻尖 x - 双眼中点 x) / 瞳距，无量纲；|yaw| > 0.4 视为极端侧脸。
 *
 * kpss 与 bboxes 同处 letterbox 后的输入张量空间，用同一套 (v - pad) / scale 还原。
 */
function computePoseFromKps(kpss, faceIndex, affine) {
  const empty = { yaw: null, roll: null, iod: 0 };
  if (!kpss || !kpss.data || !kpss.dims) return empty;
  const dims = kpss.dims;
  let base = 0;
  if (dims.length === 3 && dims[1] >= 5 && dims[2] === 2) {
    base = faceIndex * dims[1] * 2; // [N,5,2]
  } else if (dims.length === 4 && dims[2] >= 5 && dims[3] === 2) {
    base = faceIndex * dims[2] * 2; // [1,N,5,2]
  } else {
    return empty;
  }
  const scale = affine.scale > 0 ? affine.scale : 1;
  const at = (k) => {
    const x = numOf(kpss.data[base + k * 2]);
    const y = numOf(kpss.data[base + k * 2 + 1]);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
    return [(x - affine.padX) / scale, (y - affine.padY) / scale];
  };
  const le = at(0);
  const re = at(1);
  const nose = at(2);
  if (!le || !re || !nose) return empty;
  const iod = Math.hypot(re[0] - le[0], re[1] - le[1]);
  if (!(iod > 1e-3)) return empty;
  const yaw = (nose[0] - (le[0] + re[0]) / 2) / iod;
  const roll = (Math.atan2(re[1] - le[1], re[0] - le[0]) * 180) / Math.PI;
  // 关键点明显跑飞时宁可不判，也不要用一个离谱 yaw 把好脸误杀
  if (!Number.isFinite(yaw) || Math.abs(yaw) > 8) return empty;
  return {
    yaw: Number(yaw.toFixed(4)),
    roll: Number(roll.toFixed(2)),
    iod: Math.round(iod),
  };
}

/** 检测框是否可信（宽度占比用原图宽度，和参考实现同一口径） */
function faceBoxAcceptable(box, score, imgWidth) {
  if (score < FACE_DET_SCORE_THRESH) return false;
  if (!box) return true;
  const minSide = Math.min(box.width, box.height);
  if (FACE_MIN_BOX_SIZE_PX > 0 && minSide < FACE_MIN_BOX_SIZE_PX) return false;
  const ratio = Math.max(box.width, box.height) / Math.max(1, imgWidth);
  if (ratio < FACE_MIN_BOX_WIDTH_RATIO) return false;
  if (score < FACE_DET_SCORE_STRICT && ratio < FACE_MIN_BOX_WIDTH_RATIO_LOOSE) return false;
  return true;
}

/**
 * 人脸检测 + 特征。
 *
 * 返回的 `box` 是**原图坐标**（不是模型输入坐标）——上层要拿它裁剪头像。
 * `bboxes` 输出在 letterbox 后的输入张量空间，必须用 (v - pad) / scale 还原，
 * 否则裁出来的人脸会整体偏移（这是最容易踩的坑）。
 */
async function faces(src) {
  const size0 = await probeSize(src);
  const ow = size0 ? size0.w : 640;
  const oh = size0 ? size0.h : 640;
  const size = detectSize(ow, oh);
  const affine = affineOf(ow, oh, size);

  const s = await session(
    nodePath.join(MODEL_ROOT, 'faces', 'faceLandMark', 'faceLandMark.onnx'),
    'lmk',
  );
  const out = await s.run({ input: hwcTensor(await rawRgb(src, size), size) });
  const scores = Array.from(out.scores.data || []);
  const aligns = out.align_imgs;
  const bboxes = out.bboxes;
  const kpss = out.kpss;
  const n = aligns.dims[0];
  if (n === 0) return [];

  const ef = await session(
    nodePath.join(MODEL_ROOT, 'faces', 'edgeface', 'model.onnx'),
    'edgeface',
  );
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const result = [];
  // 上限 64：大合照也够；纯粹防病态输入把一次分析拖到分钟级
  for (let i = 0; i < Math.min(n, 64); i += 1) {
    const score = scores[i] ?? 0;

    // 先算框 / 过质量门，再提取特征：低分纹理误检白跑一次 EdgeFace 很浪费
    let box = null;
    if (bboxes && bboxes.data && bboxes.dims && bboxes.dims.length >= 2) {
      const b = bboxes.data;
      const x1 = (numOf(b[i * 4]) - affine.padX) / affine.scale;
      const y1 = (numOf(b[i * 4 + 1]) - affine.padY) / affine.scale;
      const x2 = (numOf(b[i * 4 + 2]) - affine.padX) / affine.scale;
      const y2 = (numOf(b[i * 4 + 3]) - affine.padY) / affine.scale;
      const left = clamp(Math.round(Math.min(x1, x2)), 0, ow);
      const top = clamp(Math.round(Math.min(y1, y2)), 0, oh);
      const right = clamp(Math.round(Math.max(x1, x2)), 0, ow);
      const bottom = clamp(Math.round(Math.max(y1, y2)), 0, oh);
      const w = Math.max(1, right - left);
      const h = Math.max(1, bottom - top);
      box = { left, top, width: w, height: h };
    }
    if (!faceBoxAcceptable(box, score, ow)) continue;

    // align_imgs: [N,224,224,3] uint8
    const start = i * 224 * 224 * 3;
    const aligned = aligns.data.subarray(start, start + 224 * 224 * 3);
    const emb = await ef.run({ input: alignTo112(aligned) });

    result.push({
      score,
      // 0..100 质量分：服务端护栏（<55 丢弃 / <70 不认领）与参考实现同一量纲
      quality: Math.round(score * 100),
      pose: computePoseFromKps(kpss, i, affine),
      emb: l2normalize(Array.from(emb.embedding.data)),
      box,
      imgWidth: ow,
      imgHeight: oh,
    });
  }
  // 整张都是图案 / 海报纹理时的候选爆炸：宁可这张不产出人脸，也不制造一堆碎片
  if (FACE_MAX_FACES_PER_IMAGE > 0 && result.length > FACE_MAX_FACES_PER_IMAGE) return [];
  return result;
}

async function scenes(rgb224, imgEmb) {
  const assets = await sceneAssets();
  const s = await session(
    nodePath.join(MODEL_ROOT, 'places365', 'resnet50_places365.onnx'),
    'places',
  );
  const labels = await placesLabels();
  const out = await s.run({
    input: chwTensor(rgb224, 224, [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
  });
  const logits = out.logits.data;
  const placesLogits = [];
  for (let i = 0; i < labels.length; i += 1) {
    placesLogits.push({ label: labels[i] || `#${i}`, logit: Number(logits[i]) || 0 });
  }

  const clipScores = assets.labels.map((x) => ({
    label: x.label,
    score: sceneBlend.cosine(imgEmb, x.vec),
  }));
  const scorable = sceneBlend.scorableScore(imgEmb, assets.head);
  if (process.env.PHOTO_AI_DEBUG === '1') {
    // 排障用：把两路 top5 打出来。场景判错时先看这里 ——
    // 若 clip top5 全是同一个标签或全是某个值，说明文本嵌入/视觉特征有问题。
    const ctop = clipScores.slice().sort((a, b) => b.score - a.score).slice(0, 5);
    const ptop = placesLogits.slice().sort((a, b) => b.logit - a.logit).slice(0, 5);
    console.error('[scene] embLen', imgEmb.length);
    console.error('[scene] outKeys', Object.keys(out).join(','), 'dims', JSON.stringify(out.logits && out.logits.dims), 'len', out.logits ? out.logits.data.length : -1);
    console.error('[scene] clip', JSON.stringify(ctop.map((x) => [x.label, Number(x.score.toFixed(4))])));
    console.error('[scene] places', JSON.stringify(ptop.map((x) => [x.label, Number(x.logit.toFixed(3))])));
  }
  const blended = sceneBlend.blendScene({
    clipScores,
    placesLogits,
    scorable,
    scorableThreshold: assets.head ? Number(assets.head.threshold) : null,
  });

  return { items: blended.items, gate: blended.gate };
}

async function embed(rgb224) {
  const s = await session(nodePath.join(MODEL_ROOT, 'clip', 'vision_model.onnx'), 'clip');
  const out = await s.run({
    pixel_values: chwTensor(
      rgb224,
      224,
      [0.48145466, 0.4578275, 0.40821073],
      [0.26862954, 0.26130258, 0.27577711],
    ),
  });
  return l2normalize(Array.from(out.image_embeds.data));
}

async function analyze(params) {
  const src = params && params.src;
  if (!src || !fs.existsSync(src))
    throw Object.assign(new Error('src not found'), { code: 'E_NO_SRC' });
  if (!FFMPEG) throw Object.assign(new Error('ffmpeg not found'), { code: 'E_NO_FFMPEG' });

  const wantFaces = params.faces !== false;
  const wantScenes = params.scenes !== false;
  const wantEmbed = params.embed !== false;
  const wantOcr = params.ocr === true;
  const wantActivity = params.activity === true;

  const result = { faces: [], scenes: [], sceneGate: null, embedding: [], ocr: null, activity: null };
  if (wantFaces) result.faces = await faces(src);
  const rgb224 = wantScenes || wantEmbed ? await rawRgb(src, 224) : null;

  // 场景与 embedding 共用同一份 CLIP 视觉特征：先算嵌入，再做双路融合
  const imgEmb = rgb224 ? await embed(rgb224) : [];
  if (wantEmbed) result.embedding = imgEmb;
  if (wantScenes) {
    try {
      const sc = await scenes(rgb224, imgEmb);
      result.scenes = sc.items;
      result.sceneGate = sc.gate;
    } catch (err) {
      // 词表/嵌入错位这类硬错误不静默：记到 stderr（父进程能看到），并给「unknown」出口
      console.error('[photo-ai] scene blend failed:', String((err && err.message) || err));
      result.scenes = [];
      result.sceneGate = { exit: 'unknown', reason: 'scene_error', score: 0, margin: 0, scorable: null };
    }
  }
  if (wantOcr) {
    result.ocr = await ocr.recognize(src, FFMPEG, FFPROBE);
    stats.ocr += 1;
  }
  if (wantActivity) {
    result.activity = await activity.score(src, FFMPEG);
    stats.activities += 1;
  }

  stats.images += 1;
  stats.faces += result.faces.length;
  if (result.scenes.length) stats.scenes += 1;
  if (result.embedding.length) stats.embeds += 1;
  return result;
}

async function ocrOnly(params) {
  const src = params && params.src;
  if (!src || !fs.existsSync(src))
    throw Object.assign(new Error('src not found'), { code: 'E_NO_SRC' });
  if (!FFMPEG || !FFPROBE) throw Object.assign(new Error('ffmpeg/ffprobe not found'), { code: 'E_NO_FFMPEG' });
  const out = await ocr.recognize(src, FFMPEG, FFPROBE);
  stats.ocr += 1;
  return out;
}

async function activityOnly(params) {
  const src = params && params.src;
  if (!src || !fs.existsSync(src))
    throw Object.assign(new Error('src not found'), { code: 'E_NO_SRC' });
  if (!FFMPEG) throw Object.assign(new Error('ffmpeg not found'), { code: 'E_NO_FFMPEG' });
  const out = await activity.score(src, FFMPEG, params || {});
  stats.activities += 1;
  return out;
}

async function semanticParse(params) {
  return semantic.analyze((params && params.query) || '', params || {});
}

async function handle(msg) {
  if (msg.type === 'ping') {
    send({ id: msg.id, ok: true, result: 'pong' });
    return;
  }
  if (msg.type === 'shutdown') {
    send({ id: msg.id, ok: true });
    setTimeout(() => process.exit(0), 5);
    return;
  }
  if (msg.type !== 'invoke') return;

  const handlers = {
    analyze,
    ocr: ocrOnly,
    activity: activityOnly,
    phash: phashOnly,
    semantic: semanticParse,
    stats: async () => ({
      ...stats,
      ffmpeg: FFMPEG,
      ffprobe: FFPROBE,
      eps: bestEps(),
      models: MODEL_ROOT,
      ocr: ocr.available(),
      activityModel: activity.available(),
      semantic: semantic.available(),
    }),
  };
  const fn = handlers[msg.method];
  if (!fn) {
    send({
      id: msg.id,
      ok: false,
      error: { code: 'E_METHOD', message: `unknown method: ${msg.method}` },
    });
    return;
  }
  try {
    send({ id: msg.id, ok: true, result: await fn(msg.params || {}) });
  } catch (err) {
    stats.fails += 1;
    send({
      id: msg.id,
      ok: false,
      error: { code: err.code || 'E_PHOTO_AI', message: String(err.message || err) },
    });
  }
}

process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx = buf.indexOf('\n');
  while (idx >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (line) {
      try {
        handle(JSON.parse(line));
      } catch {
        send({ type: 'log', level: 'warn', message: 'bad ndjson line' });
      }
    }
    idx = buf.indexOf('\n');
  }
});

process.stdin.on('end', () => process.exit(0));
send({
  type: 'log',
  level: 'info',
  message: `photo-ai ready (ffmpeg=${FFMPEG}, eps=${bestEps().join(',')})`,
});
