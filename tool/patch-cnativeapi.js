#!/usr/bin/env node
/**
 * 给 cnativeapi 的 build hook 打补丁（幂等）。
 *
 * 背景：flutter_ohos 当前把 ohos 的 targetOS 映射成 linux，cnativeapi（被 tray_manager
 * 间接依赖）会去编译 Linux/GTK 的 C++ 实现，在 Windows 上因缺 GTK / 标准库失败。
 * cnativeapi 提供的是桌面托盘等能力，ohos 上不需要 —— 在「Windows + targetOS=linux」
 * 时直接跳过，不产出 code assets。真正的 Linux 桌面构建（Platform.isLinux）不受影响。
 *
 * 这是上游 bug（hooks API 没有 ohos 枚举），等 flutter_ohos / cnativeapi 修复后可删。
 *
 * 用法：node tool/patch-cnativeapi.js
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const pubCache =
  process.env.PUB_CACHE || path.join(os.homedir(), 'AppData', 'Local', 'Pub', 'Cache');
const hostedDir = path.join(pubCache, 'hosted');

const MARKER = 'if (Platform.isWindows && targetOS == OS.linux)';
const ANCHOR = 'final targetOS = input.config.code.targetOS;';

function findHooks() {
  const hooks = [];
  if (!fs.existsSync(hostedDir)) return hooks;
  for (const mirror of fs.readdirSync(hostedDir)) {
    const mdir = path.join(hostedDir, mirror);
    let isDir;
    try {
      isDir = fs.statSync(mdir).isDirectory();
    } catch {
      continue;
    }
    if (!isDir) continue;
    for (const pkg of fs.readdirSync(mdir)) {
      if (!pkg.startsWith('cnativeapi-')) continue;
      const hook = path.join(mdir, pkg, 'hook', 'build.dart');
      if (fs.existsSync(hook)) hooks.push(hook);
    }
  }
  return hooks;
}

const hooks = findHooks();
if (hooks.length === 0) {
  console.log(`[patch-cnativeapi] 在 ${hostedDir} 下没找到 cnativeapi-*/hook/build.dart`);
  process.exit(0);
}

let patched = 0;
let skipped = 0;
for (const file of hooks) {
  let src = fs.readFileSync(file, 'utf8');
  if (src.includes(MARKER)) {
    skipped += 1;
    continue;
  }
  const idx = src.indexOf(ANCHOR);
  if (idx < 0) {
    console.log(`[patch-cnativeapi] 跳过（找不到锚点）：${file}`);
    continue;
  }
  const insertion =
    `${ANCHOR}\n` +
    '    // Windows 上构建 ohos（flutter_ohos 把 targetOS 映射成 linux）时跳过，\n' +
    '    // 避免去编译 Linux/GTK 的 C++ 实现；桌面托盘在 ohos 上没有意义。\n' +
    `    ${MARKER} {\n` +
    '      return;\n' +
    '    }';
  src = src.slice(0, idx) + insertion + src.slice(idx + ANCHOR.length);
  fs.writeFileSync(file, src);
  patched += 1;
  console.log(`[patch-cnativeapi] patched: ${file}`);
}

console.log(`[patch-cnativeapi] 完成：patched=${patched}, skipped=${skipped}, total=${hooks.length}`);
