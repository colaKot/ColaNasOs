#!/usr/bin/env node
/**
 * 精简安装包（不含本地 AI 模型）：`npm run dist:lite`
 *
 * 与 `npm run dist` 同一份 `electron-builder.js`，只是设置 `COLANAS_LITE=1`。
 * 产物名带 `-lite`，可与完整包共存于 dist_installer。
 */
'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');

const root = path.join(__dirname, '..');

// 先按 Electron ABI 重建 better-sqlite3（electron-builder 已关掉自动 rebuild，见配置注释）；
// node-pty 是 N-API，不需要也不应该在这里编译。
const rebuild = spawnSync('npm', ['run', 'rebuild'], {
  cwd: root,
  stdio: 'inherit',
  shell: process.platform === 'win32',
});
if (rebuild.status !== 0) process.exit(rebuild.status ?? 1);

const r = spawnSync(
  process.execPath,
  [path.join(root, 'node_modules', 'electron-builder', 'cli.js'), '--publish', 'never'],
  {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env, COLANAS_LITE: '1' },
  },
);
process.exit(r.status ?? 1);