#!/usr/bin/env node
/**
 * 新增应用的脚手架。
 *
 * 为什么要有：以前新增一个应用要动 4 个地方（契约、一级菜单分组 switch、二级菜单常量表、
 * 路由注册），漏一处就是"菜单里点不到"或"菜单有项没页面"。现在：
 *
 *   1. 契约（`contracts/apps.json`）写 app + nav
 *   2. i18n 写键（这里自动占位，文案后面再改）
 *   3. 生成 `lib/features/<id>/<id>_shell.dart` 骨架（已接好侧栏与分发）
 *   4. 路由注册一行（**故意不自动改**：生成器动构建配置的坑远比省这两行多）
 *
 * 用法：
 *   node tool/new-app.js --id=nvr --name=监控 --icon=camera --group=service \
 *        --sections="cameras:摄像头,recordings:录像"
 *   node tool/new-app.js ... --dry-run     # 只打印要做什么，不落盘
 *
 * --sections 每项是 `id:标题`，逗号分隔；第一项会作为默认页。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.join(__dirname, '..');

function parseArgs(argv) {
  const out = {};
  for (const a of argv.slice(2)) {
    const m = /^--([^=]+)=(.*)$/.exec(a);
    if (m) out[m[1]] = m[2];
    else if (a.startsWith('--')) out[a.slice(2)] = true;
  }
  return out;
}

const args = parseArgs(process.argv);
const dryRun = args['dry-run'] === true;
const id = String(args.id || '').trim();
const name = String(args.name || '').trim();
const icon = String(args.icon || 'apps').trim();
const group = String(args.group || 'system').trim();
const GROUPS = ['media', 'data', 'service', 'system'];

function die(msg) {
  console.error('[new-app] ' + msg);
  process.exit(1);
}

if (!id) die('缺 --id（英文小写，会作为目录名与契约键）');
if (!/^[a-z][a-z0-9_]*$/.test(id)) die(`--id 只能是小写字母/数字/下划线，收到 ${id}`);
if (!name) die('缺 --name（中文显示名，写进 i18n）');
if (!GROUPS.includes(group)) die(`--group 必须是 ${GROUPS.join(' / ')}，收到 ${group}`);

const sections = String(args.sections || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .map((s) => {
    const [sid, title] = s.split(':');
    return { id: String(sid || '').trim(), title: String(title || sid || '').trim() };
  });
if (sections.length === 0) die('缺 --sections（形如 cameras:摄像头,recordings:录像）');
for (const s of sections) {
  if (!/^[a-z][a-zA-Z0-9_]*$/.test(s.id)) die(`section id 不合法：${s.id}`);
}

const appsPath = path.join(root, 'contracts', 'apps.json');
const i18nPath = path.join(root, 'contracts', 'i18n.json');
const shellDir = path.join(root, 'apps', 'colanas_os', 'lib', 'features', id);
const shellPath = path.join(shellDir, `${id}_shell.dart`);

const spec = JSON.parse(fs.readFileSync(appsPath, 'utf-8'));
if (spec.apps.some((a) => a.id === id)) die(`契约里已存在 app: ${id}`);
if (fs.existsSync(shellPath)) die(`shell 文件已存在：${shellPath}`);

// ---------------------------------------------------------------- 契约
const acc = ['#6366F1', '#8B5CF6'];
const app = {
  id,
  nameKey: `app.${id}`,
  route: `/${id}`,
  icon,
  group,
  accent: acc,
  endpoints: ['desktop', 'tablet', 'mobile', 'tv', 'web', 'appleTv'],
  available: true,
  nav: {
    style: 'side',
    sections: sections.map((s) => ({
      id: s.id,
      titleKey: `${id}.nav.${s.id}`,
      icon,
      items: [{ id: s.id, labelKey: `${id}.nav.${s.id}`, icon }],
    })),
  },
};

// ---------------------------------------------------------------- i18n
const I18N = [
  { key: `app.${id}`, zh: name, en: name },
  ...sections.map((s) => ({ key: `${id}.nav.${s.id}`, zh: s.title, en: s.title })),
];

// ---------------------------------------------------------------- shell 骨架
const cls = id
  .split('_')
  .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
  .join('');
const firstItem = sections[0].id;

const shell = `import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../shell/app_nav_shell.dart';

/// ${name}（脚手架生成于 tool/new-app.js）。
///
/// 菜单结构**不在这里写**：改 \`contracts/apps.json#nav\` 后跑 \`npm run gen:apps\`。
/// 折叠状态、标题、竖分隔都由 [AppNavShell] 提供（四个模块共用一份实现），
/// 这里只负责「菜单项 id → 内容」。
class ${cls}Shell extends StatelessWidget {
  const ${cls}Shell({super.key});

  Widget _content(String key) {
    switch (key) {
      // TODO: 每个菜单项接上真正的页面，然后把下面的 _PendingPane 删掉。
      // 没接的项会被 \`npm run app-nav.check\` 报出来（它在 _content 里找不到对应 id）。
      // 未列出的菜单项落到这个默认页
      // nav-default: ${firstItem}
      default:
        return const _PendingPane();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(
      appId: '${id}',
      defaultKey: '${firstItem}',
      content: _content,
    );
  }
}

/// 占位页：脚手架刚生成时所有菜单项都落在这里。
/// 接完真实页面就删掉它，\`app-nav.check\` 会因此开始要求每个 id 都有 case。
class _PendingPane extends StatelessWidget {
  const _PendingPane();

  @override
  Widget build(BuildContext context) {
    return NasEmptyState(
      title: tr('common.pending'),
      message: tr('common.pendingHint'),
      icon: Icons.construction_outlined,
    );
  }
}
`;

// ---------------------------------------------------------------- 执行
const summary = [
  `[new-app] ${dryRun ? '（演练，不落盘）' : ''}`,
  `  契约      contracts/apps.json  += app ${id}（${sections.length} 个菜单项）`,
  `  i18n      contracts/i18n.json + messages/{zh-CN,en-US}.json  += ${I18N.filter((x) => !x.skip).length} 个键`,
  `  骨架      ${path.relative(root, shellPath)}`,
  '',
  '  之后还要手工做两件事：',
  `    1. 在 apps/colanas_os/lib/shell/app_shell.dart 的 _pageById 里加一行：`,
  `         case '${id}': return const ${cls}Shell();`,
  `    2. 跑 npm run gen（生成 AppNavSpec）、npm run gen:i18n`,
];
console.log(summary.join('\n'));
if (dryRun) process.exit(0);

// 1) 契约
spec.apps.push(app);
fs.writeFileSync(appsPath, JSON.stringify(spec, null, 2) + '\n', 'utf-8');

// 2) i18n（键 + 中英占位）
const i18n = JSON.parse(fs.readFileSync(i18nPath, 'utf-8'));
for (const row of I18N) if (!i18n.keys[row.key]) i18n.keys[row.key] = {};
fs.writeFileSync(i18nPath, JSON.stringify(i18n, null, 2) + '\n', 'utf-8');

for (const [locale, field] of [['zh-CN', 'zh'], ['en-US', 'en']]) {
  const p = path.join(root, 'contracts', 'messages', `${locale}.json`);
  const m = JSON.parse(fs.readFileSync(p, 'utf-8'));
  for (const row of I18N) if (!m.messages[row.key]) m.messages[row.key] = row[field];
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + '\n', 'utf-8');
}

// 3) 骨架
fs.mkdirSync(shellDir, { recursive: true });
fs.writeFileSync(shellPath, shell, 'utf-8');

// 4) 生成（失败不阻断，提示手动跑）
try {
  execFileSync(process.execPath, [path.join(root, 'tool', 'gen-apps.js')], { stdio: 'inherit' });
  execFileSync(process.execPath, [path.join(root, 'tool', 'gen-i18n.js')], { stdio: 'inherit' });
} catch {
  console.error('[new-app] 自动生成失败，请手动跑 npm run gen:apps && npm run gen:i18n');
}

console.log(`\n[new-app] 完成。别忘了上面那两行手工程序。`);
