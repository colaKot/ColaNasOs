#!/usr/bin/env node
/**
 * 菜单契约 ↔ 页面实现 的对账。
 *
 * 为什么要有：把菜单写进 `contracts/apps.json#nav` 之后，新增一个菜单项只是改 JSON +
 * 跑生成 —— 但**页面可能没接**。那种情况运行时表现是"点了没反应"，很难发现。
 * **双向**检查：
 *   1. 契约里的每个静态菜单项 id 必须在 `_content()` 里有分支（否则点了没反应）；
 *   2. `_content()` 里的每个 `case` 必须在契约里有对应项（否则是删不掉的死代码）。
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
  // 兼容适配实现是当前生效的壳（旧 `music_shell.dart` 保留做回退）
  music: 'apps/colanas_os/lib/features/music/shell/music_shell_view.dart',
  blog: 'apps/colanas_os/lib/features/blog/blog_shell.dart',
  discover: 'apps/colanas_os/lib/features/discover/discover_shell.dart',
  // 同步没有单独的 shell 文件：菜单与内容都在 sync_page.dart 里
  sync: 'apps/colanas_os/lib/features/sync/sync_page.dart',
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

  // `// nav-orphan: a, b` 声明「页面有分支、契约没有入口」的孤儿页面（附理由），
  // 避免它被当成死代码误删，也避免长期无人过问。
  const orphans = new Set(
    [...body.matchAll(/nav-orphan:\s*([^\n]+)/g)]
      .flatMap((m) => m[1].split(','))
      .map((v) => v.trim())
      .filter(Boolean),
  );

  const ids = new Set();
  const missing = [];
  for (const section of app.nav.sections || []) {
    for (const item of section.items || []) {
      if (item.dynamic) continue;
      ids.add(item.id);
      if (defaults.has(item.id)) continue;
      // 允许 `case 'x':` 或 `if (key == 'x')` 两种写法
      const quoted = `'${item.id}'`;
      if (!body.includes(quoted)) missing.push(`${section.id}.${item.id}`);
    }
  }

  // 反向：`case 'x':` 里的 id 必须在契约里（或声明为 default / orphan）。
  // 只查一个方向的话，菜单项被删掉后页面分支会一直静默留在代码里。
  const cases = [...body.matchAll(/case '([^']+)':/g)].map((m) => m[1]);
  const extra = [...new Set(cases)].filter(
    (id) => !ids.has(id) && !defaults.has(id) && !orphans.has(id),
  );

  const total = ids.size;
  if (missing.length) {
    rows.push(`[FAIL] ${app.id}: ${missing.length}/${total} 个菜单项没在 _content() 里接页面 → ${missing.join(', ')}`);
    failed += 1;
  } else if (extra.length) {
    rows.push(`[FAIL] ${app.id}: _content() 里有契约没有的分支（死代码）→ ${extra.join(', ')}`);
    failed += 1;
  } else {
    const orphanNote = orphans.size ? `（另 ${orphans.size} 个孤儿页面已声明）` : '';
    rows.push(`[OK]   ${app.id}: ${total} 个静态菜单项全部已接页面${orphanNote}`);
  }
}

console.log(rows.join('\n'));
if (failed > 0) {
  console.error(`\n[app-nav] ${failed} 个模块存在「菜单有项、页面没接」`);
  process.exit(1);
}
console.log(`\n[app-nav] ${rows.filter((r) => r.startsWith('[OK]')).length} 个模块对账通过`);
