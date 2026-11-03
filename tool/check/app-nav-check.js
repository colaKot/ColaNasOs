#!/usr/bin/env node
/**
 * 菜单契约 ↔ 页面实现 的对账。
 *
 * 为什么要有：把菜单写进 `contracts/apps.json#nav` 之后，新增一个菜单项只是改 JSON +
 * 跑生成 —— 但**页面可能没接**。那种情况运行时表现是"点了没反应"，很难发现。
 * 这里检查契约里的每个静态菜单项 id 是否在该模块的 `_content()` 里出现过。
 *
 * 动态项（如影视的 `lib:`）不检查：它们的页面由前缀分支处理。
 *
 * 用法：node tool/check/app-nav-check.js
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const spec = JSON.parse(fs.readFileSync(path.join(root, 'contracts', 'apps.json'), 'utf-8'));

/** app id → 承载 `_content()` 的 shell 文件 */
const SHELL_OF = {
  photo: 'apps/colanas_os/lib/features/photo/photo_shell.dart',
  video: 'apps/colanas_os/lib/features/video/video_shell.dart',
  music: 'apps/colanas_os/lib/features/music/music_shell.dart',
  discover: 'apps/colanas_os/lib/features/discover/discover_shell.dart',
};

/** 取出 `_content(...)` 方法体（到下一个同类方法或类结束） */
function contentBody(src) {
  const start = src.indexOf('Widget _content(');
  if (start < 0) return null;
  const rest = src.slice(start + 10);
  // 到下一个 "  Widget " / "  String " / "  Future " / 类结束为止
  const stop = rest.search(/\n {2}(?:Widget|String|Future|void|int|double|bool|List|Map)\s/);
  return stop < 0 ? rest : rest.slice(0, stop);
}

let failed = 0;
const rows = [];

for (const app of spec.apps) {
  if (!app.nav) continue;
  const rel = SHELL_OF[app.id];
  if (!rel) {
    rows.push(`[SKIP] ${app.id}: 未登记 shell 文件（新模块请在 SHELL_OF 里补一行）`);
    continue;
  }
  const file = path.join(root, rel);
  if (!fs.existsSync(file)) {
    rows.push(`[FAIL] ${app.id}: shell 文件不存在 ${rel}`);
    failed += 1;
    continue;
  }
  const body = contentBody(fs.readFileSync(file, 'utf-8'));
  if (body == null) {
    rows.push(`[FAIL] ${app.id}: 找不到 _content()（约定：菜单分发写在这个方法里）`);
    failed += 1;
    continue;
  }

  // `// nav-default: a, b` 声明走默认分支的菜单项（省掉一个 `case 'x': return 同一个页面`）
  const defaults = new Set(
    [...body.matchAll(/nav-default:\s*([^\n]+)/g)]
      .flatMap((m) => m[1].split(','))
      .map((v) => v.trim())
      .filter(Boolean),
  );

  const missing = [];
  for (const section of app.nav.sections || []) {
    for (const item of section.items || []) {
      if (item.dynamic) continue;
      if (defaults.has(item.id)) continue;
      // 允许 `case 'x':` 或 `if (key == 'x')` 两种写法
      const quoted = `'${item.id}'`;
      if (!body.includes(quoted)) missing.push(`${section.id}.${item.id}`);
    }
  }
  const total = (app.nav.sections || []).reduce(
    (a, s) => a + (s.items || []).filter((i) => !i.dynamic).length,
    0,
  );
  if (missing.length) {
    rows.push(`[FAIL] ${app.id}: ${missing.length}/${total} 个菜单项没在 _content() 里接页面 → ${missing.join(', ')}`);
    failed += 1;
  } else {
    rows.push(`[OK]   ${app.id}: ${total} 个静态菜单项全部已接页面`);
  }
}

console.log(rows.join('\n'));
if (failed > 0) {
  console.error(`\n[app-nav] ${failed} 个模块存在「菜单有项、页面没接」`);
  process.exit(1);
}
console.log(`\n[app-nav] ${rows.filter((r) => r.startsWith('[OK]')).length} 个模块对账通过`);
