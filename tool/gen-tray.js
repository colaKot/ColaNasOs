#!/usr/bin/env node
/**
 * 生成托盘图标（与安装包 / 应用图标同一套视觉）。
 *
 * 输入：`resources/icon-source.png`（1024×1024 原始品牌图）
 * 输出：
 *   - `resources/tray16.png` 16×16（100% DPI 的托盘实际像素）
 *   - `resources/tray.png`   32×32（150% / 200% DPI）
 *
 * 为什么不直接给一张 32 或 1024：Windows 托盘在 100% 缩放下只用 16×16，
 * 拿大图让系统缩会糊。这里两档都从品牌图**单独渲染**，外壳再用
 * `nativeImage.addRepresentation({scaleFactor:1|2})` 交给系统按 DPI 挑。
 *
 * 以前托盘是脚本画的「紫底白圈」，和安装包图标完全不是一套；现在直接用品牌图。
 *
 * 用法：node tool/gen-tray.js（`npm run assets`）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createCanvas, loadImage } = require('@napi-rs/canvas');

const resources = path.join(__dirname, '..', 'resources');
const source = path.join(resources, 'icon-source.png');

/**
 * 从品牌图里抠出图案本体：**去掉白底**并裁掉四周留白。
 *
 * 为什么必须抠：`icon-source.png` 是白底不透明图，直接缩成 32×32 会得到
 * 「白色方块里一个杯子」—— 深色任务栏上就是用户说的「一个框里才有图标」。
 * 托盘图标必须是透明的、图案撑满画布。
 *
 * 做法：从四边向内做洪水填充，把连通的近白像素置透明；被图案包住的内部
 * 白色（云朵）不会被吃到，因为它在蓝色描边里面。然后按非透明像素的包围盒
 * 裁切（留 2% 边距），这样 16×16 下图案才够大。
 */
function keyoutWhite(img) {
  const WORK = 512;
  const canvas = createCanvas(WORK, WORK);
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(img, 0, 0, WORK, WORK);

  const data = ctx.getImageData(0, 0, WORK, WORK);
  const px = data.data;
  const nearWhite = (i) => px[i] > 236 && px[i + 1] > 236 && px[i + 2] > 236 && px[i + 3] > 0;

  const seen = new Uint8Array(WORK * WORK);
  const stack = [];
  const push = (x, y) => {
    if (x < 0 || y < 0 || x >= WORK || y >= WORK) return;
    const p = y * WORK + x;
    if (seen[p]) return;
    seen[p] = 1;
    if (!nearWhite(p * 4)) return;
    px[p * 4 + 3] = 0;
    stack.push(x, y);
  };
  for (let x = 0; x < WORK; x += 1) {
    push(x, 0);
    push(x, WORK - 1);
  }
  for (let y = 0; y < WORK; y += 1) {
    push(0, y);
    push(WORK - 1, y);
  }
  while (stack.length > 0) {
    const y = stack.pop();
    const x = stack.pop();
    push(x + 1, y);
    push(x - 1, y);
    push(x, y + 1);
    push(x, y - 1);
  }
  ctx.putImageData(data, 0, 0);

  // 包围盒：按不透明像素裁切，留 2% 呼吸位
  let minX = WORK;
  let minY = WORK;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < WORK; y += 1) {
    for (let x = 0; x < WORK; x += 1) {
      if (px[(y * WORK + x) * 4 + 3] > 8) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return { canvas, size: WORK, sx: 0, sy: 0, sw: WORK, sh: WORK };
  const pad = Math.round(WORK * 0.02);
  minX = Math.max(0, minX - pad);
  minY = Math.max(0, minY - pad);
  maxX = Math.min(WORK - 1, maxX + pad);
  maxY = Math.min(WORK - 1, maxY + pad);
  return {
    canvas,
    size: WORK,
    sx: minX,
    sy: minY,
    sw: maxX - minX + 1,
    sh: maxY - minY + 1,
  };
}

/** 把抠好的区域等比缩放进 size×size 的透明画布 */
function render(keyed, size) {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.clearRect(0, 0, size, size);
  // 正方形化：按长边等比缩放后居中，避免非正方形图案被拉扁
  const side = Math.max(keyed.sw, keyed.sh);
  const dw = (keyed.sw / side) * size;
  const dh = (keyed.sh / side) * size;
  ctx.drawImage(
    keyed.canvas,
    keyed.sx,
    keyed.sy,
    keyed.sw,
    keyed.sh,
    (size - dw) / 2,
    (size - dh) / 2,
    dw,
    dh,
  );
  return canvas;
}

async function main() {
  if (!fs.existsSync(source)) {
    throw new Error(`缺少图标源文件：${source}`);
  }
  const img = await loadImage(source);
  const keyed = keyoutWhite(img);

  const small = render(keyed, 16);
  const large = render(keyed, 32);
  const png16 = await small.encode('png');
  const png32 = await large.encode('png');
  fs.writeFileSync(path.join(resources, 'tray16.png'), png16);
  fs.writeFileSync(path.join(resources, 'tray.png'), png32);
  // 客户端（Flutter 桌面端托盘）读的是 assets 里这份，必须同步，
  // 否则服务端换了图、客户端托盘还是旧的。
  const appTray = path.join(__dirname, '..', 'apps', 'colanas_os', 'assets', 'icons', 'tray.png');
  if (fs.existsSync(path.dirname(appTray))) {
    fs.writeFileSync(appTray, png32);
  }

  console.log(`[assets] tray16.png ${png16.length}B (16x16) / tray.png ${png32.length}B (32x32)`);
}

main().catch((err) => {
  console.error('[assets] 生成托盘图标失败：', err.message);
  process.exit(1);
});
