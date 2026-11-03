#!/usr/bin/env node
/**
 * 生成外壳托盘图标（无第三方依赖，手写 PNG 编码）。
 * 输出：resources/tray.png（32x32 RGBA）
 *
 * 用法：node tool/gen-tray.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const W = 32;
const H = 32;
const R = 7; // 圆角半径
const BRAND = [109, 91, 208, 255]; // #6D5BD0
const WHITE = [255, 255, 255, 255];

const crcTable = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function insideRoundRect(x, y) {
  const inX = x >= R && x < W - R;
  const inY = y >= R && y < H - R;
  if (inX || inY) return x >= 0 && x < W && y >= 0 && y < H;
  const dx = x < R ? R - 0.5 - x : x - (W - R - 0.5);
  const dy = y < R ? R - 0.5 - y : y - (H - R - 0.5);
  return dx * dx + dy * dy <= R * R;
}

const raw = Buffer.alloc((W * 4 + 1) * H);
for (let y = 0; y < H; y++) {
  raw[y * (W * 4 + 1)] = 0; // filter: none
  for (let x = 0; x < W; x++) {
    const o = y * (W * 4 + 1) + 1 + x * 4;
    const d = Math.hypot(x + 0.5 - W / 2, y + 0.5 - H / 2);
    let px = [0, 0, 0, 0];
    if (d >= 7 && d <= 10) px = WHITE;
    else if (insideRoundRect(x, y)) px = BRAND;
    raw[o] = px[0];
    raw[o + 1] = px[1];
    raw[o + 2] = px[2];
    raw[o + 3] = px[3];
  }
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0);
ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 6; // RGBA
ihdr[10] = 0;
ihdr[11] = 0;
ihdr[12] = 0;

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

const out = path.join(__dirname, '..', 'resources', 'tray.png');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, png);
console.log(`[assets] wrote ${out} (${png.length} bytes, ${W}x${H})`);
