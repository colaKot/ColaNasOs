#!/usr/bin/env node
/**
 * Web 产物自检：确认 `apps/colanas_os/build/web` 能在外网不可用、无缓存的内网环境里
 * 直接被内核（`http://127.0.0.1:7788/`）托管起来，而不是一片空白。
 *
 * 只查静态事实，不启动内核，因此可以进 CI：
 *   1. `index.html` 只引用 `flutter_bootstrap.js`，且没有劫持 `window._flutter`
 *      （劫持后 bootstrap 会复用假 loader，真 loader 永不创建 → 白屏）；
 *   2. `flutter_bootstrap.js` 把 `canvasKitBaseUrl` 指到本地 `canvaskit/`
 *      （默认会去 gstatic CDN，取不到引擎 → 白屏）；
 *   3. `fontFallbackBaseUrl` 指到本地 `fonts_fallback/s/`（汉字不出方块）；
 *   4. canvaskit / 字体镜像 / 入口脚本确实在产物里，且体积非零。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const web = path.join(root, 'apps', 'colanas_os', 'build', 'web');

let passed = 0;
let failed = 0;
const ok = (n, d) => {
  passed += 1;
  console.log('[OK]  ', n.padEnd(32), d === undefined ? '' : d);
};
const bad = (n, d) => {
  failed += 1;
  console.log('[FAIL]', n.padEnd(32), d);
};
const check = (n, c, d) => (c ? ok(n, d) : bad(n, d));

function readText(rel) {
  const p = path.join(web, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf-8') : null;
}

function fileSize(rel) {
  const p = path.join(web, rel);
  return fs.existsSync(p) ? fs.statSync(p).size : 0;
}

function main() {
  const index = readText('index.html');
  const boot = readText('flutter_bootstrap.js');

  check('bundle_present', index !== null && boot !== null, web);
  if (index === null || boot === null) return;

  check('index_links_bootstrap', index.includes('flutter_bootstrap.js'));
  check(
    'index_no_flutter_hijack',
    !/Object\.defineProperty\(\s*window\s*,\s*['"]_flutter['"]/.test(index),
    '不要在 index.html 里改写 window._flutter',
  );
  check(
    'bootstrap_local_canvaskit',
    /canvasKitBaseUrl\s*:\s*['"]canvaskit\/['"]/.test(boot),
    'canvasKitBaseUrl 必须指到本地 canvaskit/',
  );
  check(
    'bootstrap_local_fonts',
    /fontFallbackBaseUrl\s*:\s*['"]fonts_fallback\/s\/['"]/.test(boot),
    'fontFallbackBaseUrl 必须指到本地 fonts_fallback/s/',
  );
  check('bootstrap_placeholders_filled', !boot.includes('{{'), '仍存在未替换的模板占位符');

  check('main_dart_js', fileSize('main.dart.js') > 100_000, `${fileSize('main.dart.js')} bytes`);
  check(
    'canvaskit_js',
    fileSize('canvaskit/canvaskit.js') > 10_000,
    `${fileSize('canvaskit/canvaskit.js')} bytes`,
  );
  check(
    'canvaskit_wasm',
    fileSize('canvaskit/canvaskit.wasm') > 100_000,
    `${fileSize('canvaskit/canvaskit.wasm')} bytes`,
  );

  const fontsManifest = readText('fonts_fallback/manifest.json');
  check('fonts_manifest', fontsManifest !== null, '先跑 npm run fonts:fetch');
  if (fontsManifest !== null) {
    let count;
    try {
      const parsed = JSON.parse(fontsManifest);
      if (typeof parsed.count === 'number') count = parsed.count;
      else if (Array.isArray(parsed.items)) count = parsed.items.length;
      else if (Array.isArray(parsed)) count = parsed.length;
      else count = Object.keys(parsed).length;
    } catch {
      count = -1;
    }
    check('fonts_manifest_parse', count > 0, `entries=${count}`);
  }

  console.log(`[summary] ${passed}/${passed + failed} passed`);
  process.exit(failed === 0 ? 0 : 1);
}

main();
