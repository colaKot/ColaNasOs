#!/usr/bin/env node
/**
 * PP-OCRv6 文字识别（纯 Node + ffmpeg raw，不引 sharp / opencv）。
 *
 * 流程：det（DB 文本检测）→ 二值化 + 连通域 → 框扩展 → rec（CTC 识别）。
 *
 * 口径（OCR 升级后，代码按本项目重写）：
 *   - 检测输入：最长边 ≤ 960、宽高取 32 的倍数；mean/std 用 ImageNet 值；**BGR** 通道序；
 *   - 二值化阈值 v6 0.20；框最小 6px；按面积/周长做 DB unclip 扩展；
 *   - 识别输入高 48、宽按比例（8..960）；mean/std 0.5；
 *   - CTC 解码：argmax → 合并重复 → 去 blank(0)，字典下标 = idx-1；
 *   - ⛔ 换模型必须连字典一起换（v5 18385 / v6 18710 项），否则 argmax 下标越界会静默出空串。
 *
 * 方向分类（cls）暂不启用：相册里的票据/截图绝大多数是正向，省掉一次推理；
 * 需要时可按 48×192 输入补上，标签 180 时旋转 180°。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ort = require('onnxruntime-node');

const ROOT = path.join(__dirname, '..', '..');
const MODEL_ROOT = process.env.COLANAS_MODEL_DIR || path.join(ROOT, 'vendor', 'models');

const DET_LIMIT_SIDE = Number(process.env.COLANAS_OCR_LIMIT_SIDE || 960);
const DET_BIN_THRESH = Number(process.env.COLANAS_OCR_DET_THRESH || 0.2);
const DET_BOX_THRESH = Number(process.env.COLANAS_OCR_BOX_THRESH || 0.3);
const DET_MIN_SIZE = Number(process.env.COLANAS_OCR_MIN_SIZE || 6);
const DET_UNCLIP = Number(process.env.COLANAS_OCR_UNCLIP || 1.5);
const REC_H = 48;
const REC_MAX_W = 960;

const EP_ALLOW = ['dml', 'cuda', 'cpu'];

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
function session(file, key) {
  const hit = sessions.get(key);
  if (hit) return hit;
  const p = ort.InferenceSession.create(file, SESSION_OPTS);
  sessions.set(key, p);
  return p;
}

function dictPath() {
  return path.join(MODEL_ROOT, 'ppocrv6', 'ppocrv6_dict.txt');
}

function modelPath(part) {
  return path.join(MODEL_ROOT, 'ppocrv6', part, `${part}.onnx`);
}

function available() {
  return (
    fs.existsSync(modelPath('det')) &&
    fs.existsSync(modelPath('rec')) &&
    fs.existsSync(dictPath())
  );
}

let dictCache = null;
function dict() {
  if (dictCache) return dictCache;
  const lines = fs.readFileSync(dictPath(), 'utf8').split(/\r?\n/);
  // 最后一行常是空串：字典项 = 行内容（含空格字符），末尾空行不计
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  dictCache = lines;
  return dictCache;
}

/** 用 ffprobe 拿原始尺寸；失败返回 null */
function probeSize(src, ffprobe) {
  return new Promise((resolve) => {
    const child = spawn(ffprobe, [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height',
      '-of',
      'csv=s=x:p=0',
      src,
    ]);
    let out = '';
    child.stdout.on('data', (c) => {
      out += String(c);
    });
    child.on('error', () => resolve(null));
    child.on('close', () => {
      const m = /(\d+)x(\d+)/.exec(out.trim());
      if (!m) return resolve(null);
      resolve({ width: Number(m[1]), height: Number(m[2]) });
    });
  });
}

/** ffmpeg 出整图 RGB24（直接缩放到指定尺寸，避免再反推实际宽高） */
function rawRgb(src, ffmpeg, width, height) {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      src,
      '-vf',
      `scale=${width}:${height}`,
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
      if (code !== 0) {
        reject(new Error(`ffmpeg raw failed (${code}): ${err.slice(-200)}`));
        return;
      }
      resolve(Buffer.concat(chunks));
    });
  });
}

/** 双线性缩放（RGB24） */
function resizeRgb(src, sw, sh, dw, dh) {
  const out = Buffer.alloc(dw * dh * 3);
  const xRatio = sw / dw;
  const yRatio = sh / dh;
  for (let y = 0; y < dh; y += 1) {
    const sy = Math.min(sh - 1, Math.max(0, (y + 0.5) * yRatio - 0.5));
    const y0 = Math.floor(sy);
    const y1 = Math.min(sh - 1, y0 + 1);
    const wy = sy - y0;
    for (let x = 0; x < dw; x += 1) {
      const sx = Math.min(sw - 1, Math.max(0, (x + 0.5) * xRatio - 0.5));
      const x0 = Math.floor(sx);
      const x1 = Math.min(sw - 1, x0 + 1);
      const wx = sx - x0;
      const i00 = (y0 * sw + x0) * 3;
      const i10 = (y0 * sw + x1) * 3;
      const i01 = (y1 * sw + x0) * 3;
      const i11 = (y1 * sw + x1) * 3;
      const o = (y * dw + x) * 3;
      for (let c = 0; c < 3; c += 1) {
        const top = src[i00 + c] * (1 - wx) + src[i10 + c] * wx;
        const bottom = src[i01 + c] * (1 - wx) + src[i11 + c] * wx;
        out[o + c] = Math.round(top * (1 - wy) + bottom * wy);
      }
    }
  }
  return out;
}

/** RGB24 → CHW float32（PP-OCR 用 BGR 序） */
function chwBgr(rgb, w, h, mean, std) {
  const hw = w * h;
  const out = new Float32Array(3 * hw);
  for (let i = 0; i < hw; i += 1) {
    const base = i * 3;
    // B,G,R 落到通道 0,1,2
    out[i] = (rgb[base + 2] / 255 - mean[0]) / std[0];
    out[hw + i] = (rgb[base + 1] / 255 - mean[1]) / std[1];
    out[2 * hw + i] = (rgb[base] / 255 - mean[2]) / std[2];
  }
  return out;
}

function align32(v) {
  return Math.max(32, Math.round(v / 32) * 32);
}

/** 概率图 → 二值图 → 连通域 → 框（坐标为检测输入尺寸） */
function detectBoxes(prob, w, h) {
  const mask = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i += 1) mask[i] = prob[i] >= DET_BIN_THRESH ? 1 : 0;

  const visited = new Uint8Array(w * h);
  const stack = [];
  const boxes = [];
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const idx = y * w + x;
      if (!mask[idx] || visited[idx]) continue;
      stack.length = 0;
      stack.push(idx);
      visited[idx] = 1;
      let minX = x;
      let maxX = x;
      let minY = y;
      let maxY = y;
      let count = 0;
      let scoreSum = 0;
      while (stack.length) {
        const cur = stack.pop();
        const cy = (cur / w) | 0;
        const cx = cur - cy * w;
        count += 1;
        scoreSum += prob[cur];
        if (cx < minX) minX = cx;
        if (cx > maxX) maxX = cx;
        if (cy < minY) minY = cy;
        if (cy > maxY) maxY = cy;
        const neighbors = [
          [cx - 1, cy],
          [cx + 1, cy],
          [cx, cy - 1],
          [cx, cy + 1],
        ];
        for (const [nx, ny] of neighbors) {
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          const ni = ny * w + nx;
          if (mask[ni] && !visited[ni]) {
            visited[ni] = 1;
            stack.push(ni);
          }
        }
      }
      const bw = maxX - minX + 1;
      const bh = maxY - minY + 1;
      if (bw < DET_MIN_SIZE || bh < DET_MIN_SIZE) continue;
      if (count < 8) continue;
      const score = scoreSum / count;
      if (score < DET_BOX_THRESH) continue;
      boxes.push({ minX, minY, maxX, maxY, score, count });
    }
  }
  return boxes;
}

/** DB unclip：按面积/周长估算向外扩张量，再夹到图内 */
function unclip(box, w, h) {
  const bw = box.maxX - box.minX + 1;
  const bh = box.maxY - box.minY + 1;
  const area = bw * bh;
  const perimeter = 2 * (bw + bh);
  const delta = perimeter > 0 ? (area * DET_UNCLIP) / perimeter : 0;
  return {
    minX: Math.max(0, Math.floor(box.minX - delta)),
    minY: Math.max(0, Math.floor(box.minY - delta)),
    maxX: Math.min(w - 1, Math.ceil(box.maxX + delta)),
    maxY: Math.min(h - 1, Math.ceil(box.maxY + delta)),
  };
}

/** 按行分组排序：先按 y 中心分行，行内按 x */
function sortBoxes(boxes) {
  if (boxes.length <= 1) return boxes;
  const items = boxes
    .map((b) => ({ b, cy: (b.minY + b.maxY) / 2, cx: (b.minX + b.maxX) / 2 }))
    .sort((a, b) => a.cy - b.cy);
  const lines = [];
  for (const item of items) {
    const line = lines.find((l) => Math.abs(l.cy - item.cy) < Math.max(8, (item.b.maxY - item.b.minY) * 0.6));
    if (line) {
      line.items.push(item);
      line.cy = (line.cy * (line.items.length - 1) + item.cy) / line.items.length;
    } else {
      lines.push({ cy: item.cy, items: [item] });
    }
  }
  lines.sort((a, b) => a.cy - b.cy);
  return lines.flatMap((l) => l.items.sort((a, b) => a.cx - b.cx).map((i) => i.b));
}

/** CTC argmax 解码 */
function decodeCtc(logits, timeSteps, classes) {
  const chars = dict();
  let out = '';
  let prev = -1;
  for (let t = 0; t < timeSteps; t += 1) {
    const base = t * classes;
    let best = 0;
    let bestVal = logits[base];
    for (let c = 1; c < classes; c += 1) {
      if (logits[base + c] > bestVal) {
        bestVal = logits[base + c];
        best = c;
      }
    }
    if (best === prev) continue;
    prev = best;
    if (best <= 0) continue;
    const ch = chars[best - 1];
    if (ch != null) out += ch;
  }
  return out;
}

/**
 * 识别一张图。
 * @returns {Promise<{text: string, lines: Array<{text:string,box:{x:number,y:number,w:number,h:number},score:number}>}>}
 */
async function recognize(src, ffmpeg, ffprobe) {
  if (!available()) throw new Error('ocr model not available');
  if (!ffmpeg) throw new Error('ffmpeg not found');

  const size = await probeSize(src, ffprobe);
  if (!size) throw new Error('probe failed');

  const scale = Math.min(1, DET_LIMIT_SIDE / Math.max(size.width, size.height));
  const baseW = Math.max(1, Math.round(size.width * scale));
  const baseH = Math.max(1, Math.round(size.height * scale));
  const detW = align32(baseW);
  const detH = align32(baseH);

  const raw = await rawRgb(src, ffmpeg, detW, detH);
  const rawW = detW;
  const rawH = detH;
  if (raw.length !== rawW * rawH * 3) {
    throw new Error(`ffmpeg raw size mismatch: ${raw.length}`);
  }

  const detRgb = raw;
  const det = await session(modelPath('det'), 'ocr-det');
  const detOut = await det.run({
    x: new ort.Tensor('float32', chwBgr(detRgb, detW, detH, [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]), [
      1,
      3,
      detH,
      detW,
    ]),
  });
  const probTensor = detOut[det.outputNames[0]];
  const dims = probTensor.dims;
  const ph = Number(dims[dims.length - 2]);
  const pw = Number(dims[dims.length - 1]);
  const prob = probTensor.data;

  const found = detectBoxes(prob, pw, ph);
  if (found.length === 0) return { text: '', lines: [] };

  const rec = await session(modelPath('rec'), 'ocr-rec');
  const lines = [];
  for (const box of sortBoxes(found).slice(0, 64)) {
    const b = unclip(box, pw, ph);
    const x1 = (b.minX / pw) * rawW;
    const x2 = ((b.maxX + 1) / pw) * rawW;
    const y1 = (b.minY / ph) * rawH;
    const y2 = ((b.maxY + 1) / ph) * rawH;
    const cw = Math.max(4, Math.round(x2 - x1));
    const chh = Math.max(4, Math.round(y2 - y1));
    const crop = Buffer.alloc(cw * chh * 3);
    for (let y = 0; y < chh; y += 1) {
      const sy = Math.min(rawH - 1, Math.round(y1) + y);
      for (let x = 0; x < cw; x += 1) {
        const sx = Math.min(rawW - 1, Math.round(x1) + x);
        const si = (sy * rawW + sx) * 3;
        const di = (y * cw + x) * 3;
        crop[di] = raw[si];
        crop[di + 1] = raw[si + 1];
        crop[di + 2] = raw[si + 2];
      }
    }

    const recW = Math.min(REC_MAX_W, Math.max(8, Math.round((cw / chh) * REC_H)));
    const recRgb = cw === recW && chh === REC_H ? crop : resizeRgb(crop, cw, chh, recW, REC_H);
    const input = chwBgr(recRgb, recW, REC_H, [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]);
    const out = await rec.run({ x: new ort.Tensor('float32', input, [1, 3, REC_H, recW]) });
    const tensor = out[rec.outputNames[0]];
    const [t, c] = tensor.dims.length === 3 ? [Number(tensor.dims[1]), Number(tensor.dims[2])] : [0, 0];
    if (!t || !c) continue;
    const text = decodeCtc(tensor.data, t, c);
    if (!text.trim()) continue;
    lines.push({
      text,
      score: Number(box.score.toFixed(3)),
      box: {
        x: Math.round(x1),
        y: Math.round(y1),
        w: cw,
        h: chh,
      },
    });
  }

  return { text: lines.map((l) => l.text).join('\n'), lines };
}

module.exports = { available, recognize, dictSize: () => dict().length };