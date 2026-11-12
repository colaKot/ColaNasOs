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

function render(img, size) {
  const canvas = createCanvas(size, size);
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.clearRect(0, 0, size, size);
  ctx.drawImage(img, 0, 0, size, size);
  return canvas;
}

async function main() {
  if (!fs.existsSync(source)) {
    throw new Error(`缺少图标源文件：${source}`);
  }
  const img = await loadImage(source);

  const small = render(img, 16);
  const large = render(img, 32);
  const png16 = await small.encode('png');
  const png32 = await large.encode('png');
  fs.writeFileSync(path.join(resources, 'tray16.png'), png16);
  fs.writeFileSync(path.join(resources, 'tray.png'), png32);

  console.log(`[assets] tray16.png ${png16.length}B (16x16) / tray.png ${png32.length}B (32x32)`);
}

main().catch((err) => {
  console.error('[assets] 生成托盘图标失败：', err.message);
  process.exit(1);
});
