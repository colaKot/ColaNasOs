'use strict';

/**
 * 生成全部应用图标（2026-11-04 重写）。
 *
 * 唯一真源：`resources/icon-source.png`（1024×1024，白底插画）。
 * 之前这里是「纯 Node 画一个紫蓝渐变圆」的品牌图形，现在改成从这张图派生，
 * 保证任务栏 / 开始菜单 / 托盘 / 浏览器标签 / PWA / 各端安装包只有一套图标。
 *
 *   node tool/gen-icons.js            # 生成全部目标
 *   node tool/gen-icons.js --check    # 只校验尺寸 / 透明度是否符合预期
 *
 * 依赖 ImageMagick 7（`magick` 在 PATH 上）。生成结果是二进制资源，随仓库提交，
 * 因此 CI / 门禁不需要装 ImageMagick；只有换图的人才跑这个脚本。
 *
 * 两种形态：
 *   round —— 22% 圆角 + 四角透明（Windows / macOS / Web / 托盘）
 *   full  —— 满幅不透明（iOS / Android / 鸿蒙 / maskable，形状由系统自己裁）
 */

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'resources/icon-source.png');
const RADIUS = 0.22;

/** Windows 应用壳 / 托盘 / 浏览器 */
const RESOURCES = [
  ['resources/icon.png', 512, 'round'],
  ['resources/tray.png', 32, 'round'],
  // electron-builder 的 win/mac/linux 图标入口，多帧 ICO
  ['resources/icon.ico', 0, 'round'],
];

const WEB = [
  ['apps/colanas_os/web/favicon.png', 32, 'round'],
  ['apps/colanas_os/web/icons/Icon-192.png', 192, 'round'],
  ['apps/colanas_os/web/icons/Icon-512.png', 512, 'round'],
  ['apps/colanas_os/web/icons/Icon-maskable-192.png', 192, 'full'],
  ['apps/colanas_os/web/icons/Icon-maskable-512.png', 512, 'full'],
  // 应用内品牌位（侧栏 logo）用的同一张图
  ['apps/colanas_os/assets/branding/app_icon.png', 512, 'round'],
];

/** 四个客户端共用一套图标 */
const APPS = ['colanas_os', 'music_client', 'photo_client', 'sync_client'];
const MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024];
const ANDROID_SIZES = {
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

/** iOS 图标文件名 → 像素尺寸（`Icon-App-83.5x83.5@2x` → 167） */
function iosSize(name) {
  const m = /^Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$/.exec(name);
  if (!m) return null;
  return Math.round(Number(m[1]) * Number(m[2]));
}

function magick(args) {
  execFileSync('magick', args, { stdio: ['ignore', 'ignore', 'pipe'] });
}

function main() {
  const check = process.argv.includes('--check');
  if (!fs.existsSync(SRC)) {
    console.error(`[gen-icons] 缺少母版 ${path.relative(ROOT, SRC)}`);
    process.exit(1);
  }

  const tmp = path.join(ROOT, '.tmp/gen-icons');
  fs.mkdirSync(tmp, { recursive: true });

  // 圆角版：先做蒙版，再 CopyOpacity；母版本身无 alpha，拷贝前要 -alpha off
  const roundPng = path.join(tmp, 'round-1024.png');
  const fullPng = path.join(tmp, 'full-1024.png');
  if (!check) {
    const mask = path.join(tmp, 'mask-1024.png');
    const r = Math.round(1024 * RADIUS);
    magick([
      '-size',
      '1024x1024',
      'xc:none',
      '-fill',
      'white',
      '-draw',
      `roundrectangle 0,0 1023,1023 ${r},${r}`,
      mask,
    ]);
    magick([SRC, mask, '-alpha', 'off', '-compose', 'CopyOpacity', '-composite',
      '-type', 'TrueColorAlpha', roundPng]);
    // 满底版：显式去掉 alpha（iOS 图标带透明会被 App Store 拒）
    magick([SRC, '-background', 'white', '-alpha', 'remove', '-alpha', 'off', fullPng]);
  }

  /** @type {Array<[string, number, 'round'|'full']>} */
  const targets = [];
  targets.push(...RESOURCES, ...WEB);

  for (const app of APPS) {
    const base = `apps/${app}`;
    targets.push([`${base}/windows/runner/resources/app_icon.ico`, 0, 'round']);
    for (const s of MAC_SIZES) {
      targets.push([`${base}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${s}.png`, s, 'round']);
    }
    const iosDir = path.join(ROOT, base, 'ios/Runner/Assets.xcassets/AppIcon.appiconset');
    if (fs.existsSync(iosDir)) {
      for (const name of fs.readdirSync(iosDir)) {
        const size = iosSize(name);
        if (size) targets.push([`${base}/ios/Runner/Assets.xcassets/AppIcon.appiconset/${name}`, size, 'full']);
      }
    }
    for (const [dir, size] of Object.entries(ANDROID_SIZES)) {
      targets.push([`${base}/android/app/src/main/res/${dir}/ic_launcher.png`, size, 'full']);
    }
  }

  // 鸿蒙（只有主客户端）
  for (const rel of [
    'AppScope/resources/base/media/app_icon.png',
    'entry/src/main/resources/base/media/app_icon.png',
  ]) {
    targets.push([`apps/colanas_os/ohos/${rel}`, 192, 'full']);
  }

  let bad = 0;
  let written = 0;
  for (const [rel, size, kind] of targets) {
    const abs = path.join(ROOT, rel);
    if (check) {
      if (!fs.existsSync(abs)) {
        console.log(`[gen-icons] 缺失: ${rel}`);
        bad += 1;
        continue;
      }
      const info = execFileSync('magick', ['identify', '-format', '%w %h %[channels]', abs], {
        encoding: 'utf8',
      });
      const [w, h, channels] = info.split(' ');
      const wantSquare = rel.endsWith('.ico') ? null : size;
      const hasAlpha = channels.includes('a');
      if (wantSquare && (Number(w) !== wantSquare || Number(h) !== wantSquare)) {
        console.log(`[gen-icons] 尺寸不符: ${rel}（${w}×${h}，期望 ${wantSquare}）`);
        bad += 1;
      } else if (!rel.endsWith('.ico') && hasAlpha !== (kind === 'round')) {
        console.log(`[gen-icons] 透明度不符: ${rel}（${kind}）`);
        bad += 1;
      }
      continue;
    }

    fs.mkdirSync(path.dirname(abs), { recursive: true });
    if (rel.endsWith('.ico')) {
      magick([roundPng, '-define', 'icon:auto-resize=256,128,64,48,32,16', abs]);
    } else if (kind === 'round') {
      magick([roundPng, '-resize', `${size}x${size}`, abs]);
    } else {
      magick([fullPng, '-resize', `${size}x${size}`, abs]);
    }
    written += 1;
  }

  if (check) {
    if (bad > 0) {
      console.error(`[gen-icons] ${bad} 个图标不合规，跑 node tool/gen-icons.js 重新生成`);
      process.exit(1);
    }
    console.log(`[gen-icons.check] ok（${targets.length} 个）`);
    return;
  }
  console.log(`[gen-icons] 已生成 ${written} 个图标（母版 ${path.relative(ROOT, SRC)}）`);
}

main();
