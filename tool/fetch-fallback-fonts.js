#!/usr/bin/env node
/**
 * 镜像 Flutter Web 的 Noto 字体分片到本地，内网/无外网时不再出现「方块里一个 X」。
 *
 * 清单真源 = Flutter SDK 的 `font_fallback_data.dart`（升级 SDK 后必须 `--clean` 重跑：
 * 分片路径里带版本与内容哈希，旧文件不会自动失效）。
 *
 * 用法：
 *   node tool/fetch-fallback-fonts.js            # 下载缺失分片
 *   node tool/fetch-fallback-fonts.js --check    # 只统计清单与本地文件
 *   node tool/fetch-fallback-fonts.js --clean    # 先删本地镜像再下载
 *   node tool/fetch-fallback-fonts.js --limit 5  # 只取前 N 个（冒烟/验证脚本用）
 *
 * 产物：`apps/colanas_os/web/fonts_fallback/s/<相对路径>` + `manifest.json`
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const OUT = path.join(root, 'apps', 'colanas_os', 'web', 'fonts_fallback');

function findSdkData() {
  const candidates = [];
  if (process.env.FLUTTER_ROOT) {
    candidates.push(
      path.join(
        process.env.FLUTTER_ROOT,
        'bin',
        'cache',
        'flutter_web_sdk',
        'lib',
        'ui',
        'src',
        'engine',
        'font_fallback_data.dart',
      ),
    );
  }
  candidates.push(
    'C:/dev/flutter/bin/cache/flutter_web_sdk/lib/ui/src/engine/font_fallback_data.dart',
    '/opt/flutter/bin/cache/flutter_web_sdk/lib/ui/src/engine/font_fallback_data.dart',
  );
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function parseList(file) {
  const text = fs.readFileSync(file, 'utf-8');
  const re = /NotoFont\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,?\s*\)/g;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) out.push({ name: m[1], rel: m[2] });
  return out;
}

async function download(url, dest) {
  const controller = new globalThis.AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) return false;
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length < 256) return false;
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, buf);
    return true;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

// 引擎主字体 Roboto 不在 SDK 的 Noto 清单里，但引擎仍会从 `fontFallbackBaseUrl` 取它；
// 缺了会在控制台一直刷 "Failed to load font Roboto"（英文界面回退到系统字体）。
const ENGINE_FONTS = [{ name: 'Roboto', rel: 'roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2' }];

(async () => {
  const sdkFile = findSdkData();
  if (!sdkFile) {
    console.error('[FATAL] 找不到 Flutter SDK 的 font_fallback_data.dart（设置 FLUTTER_ROOT 或 --sdk <路径>）');
    process.exit(2);
  }
  // 引擎默认字体 Roboto 也会从 `fontFallbackBaseUrl` 拉取，缺了会刷 "Failed to load font" 警告
  const items = parseList(sdkFile).filter((x) =>
    /notosanssc|notosans\/|notocoloremoji|roboto/i.test(x.rel),
  );
  for (const extra of ENGINE_FONTS) {
    if (!items.some((x) => x.rel === extra.rel)) items.push(extra);
  }
  const args = process.argv.slice(2);
  const checkOnly = args.includes('--check');
  const clean = args.includes('--clean');
  const limitAt = args.indexOf('--limit');
  const limit = limitAt >= 0 ? Number(args[limitAt + 1]) || 0 : 0;
  const list = limit > 0 ? items.slice(0, limit) : items;

  if (clean) {
    fs.rmSync(OUT, { recursive: true, force: true });
  }

  console.log(`[fonts] sdk=${sdkFile}`);
  console.log(`[fonts] fonts=${items.length}（本次处理 ${list.length}）`);

  if (checkOnly) {
    const missing = list.filter((x) => !fs.existsSync(path.join(OUT, 's', x.rel)));
    console.log(`[fonts] 已镜像 ${list.length - missing.length}/${list.length}，缺失 ${missing.length}`);
    process.exit(missing.length ? 1 : 0);
  }

  let ok = 0;
  let failed = 0;
  for (const item of list) {
    const dest = path.join(OUT, 's', item.rel);
    if (fs.existsSync(dest) && fs.statSync(dest).size > 256) {
      ok += 1;
      continue;
    }
    const url = `https://fonts.gstatic.com/s/${item.rel}`;
    const done = await download(url, dest);
    if (done) ok += 1;
    else {
      failed += 1;
      if (failed <= 5) console.error(`[fonts] FAIL ${url}`);
    }
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    sdk: sdkFile,
    count: ok,
    items: list.map((x) => ({ name: x.name, path: `s/${x.rel}` })),
  };
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(manifest, null, 2));

  console.log(`[fonts] 完成：成功 ${ok}，失败 ${failed}`);
  process.exit(failed ? 1 : 0);
})().catch((err) => {
  console.error('[FATAL]', err);
  process.exit(1);
});