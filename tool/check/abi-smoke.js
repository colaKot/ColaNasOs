#!/usr/bin/env node
/**
 * ABI 冒烟：验证 Electron 运行时下的原生模块是否可用。
 *
 * 用法（跨平台，自动自举到 Electron 运行时）：
 *   node tool/check/abi-smoke.js
 *   # 或（在 electron_server 下）
 *   npm run smoke:abi
 *
 * 退出码：0 全部通过 / 1 有失败 / 2 环境问题（找不到 electron 或 node_modules）
 *
 * 背景（2026-10-27 实测基线）：
 *   Electron 44.9.0 / Node 24.22.0 / ABI(modules) 149
 *   better-sqlite3 12.11.1 可用。
 *   README 里「better-sqlite3 最高支持 Electron 37」是过时结论。
 */

'use strict';

const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

function exeName() {
  return process.platform === 'win32' ? 'electron.exe' : 'electron';
}

function resolveElectronExe() {
  const candidates = [
    path.join(process.cwd(), 'node_modules', 'electron', 'dist', exeName()),
    path.join(__dirname, '..', '..', 'node_modules', 'electron', 'dist', exeName()),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

// ---- 自举：不在 Electron 运行时则重新以 ELECTRON_RUN_AS_NODE=1 启动自己 ----
if (!process.versions.electron) {
  const exe = resolveElectronExe();
  if (!exe) {
    console.error(
      '[FATAL] 找不到 electron 可执行文件。请先在 electron_server 下执行 npm install。',
    );
    process.exit(2);
  }
  console.log(`[boot] 以 Electron 运行时重启：${exe}`);
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  if (r.error) {
    console.error('[FATAL] 启动 electron 失败：' + r.error.message);
    process.exit(2);
  }
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

// ---- 定位 node_modules 所在目录（脚本可能在仓库根或 tool/ 下运行）----
function resolveProjectRoot() {
  const candidates = [process.cwd(), path.join(__dirname, '..', '..')];
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, 'node_modules', 'better-sqlite3'))) return c;
  }
  return null;
}

const PROJECT_ROOT = resolveProjectRoot();
if (!PROJECT_ROOT) {
  console.error('[FATAL] 找不到 electron_server/node_modules，请先在该目录执行 npm install。');
  process.exit(2);
}

/** 以绝对路径加载原生模块，避免脚本位置影响模块解析 */
function load(name) {
  return require(path.join(PROJECT_ROOT, 'node_modules', name));
}

const v = process.versions;
console.log(
  `[env] electron=${v.electron} node=${v.node} abi=${v.modules} ` +
    `platform=${process.platform}/${process.arch}`,
);
console.log(`[env] projectRoot=${PROJECT_ROOT}`);

const results = [];
function check(name, fn) {
  // 未安装的模块跳过（按需引入）
  if (!fs.existsSync(path.join(PROJECT_ROOT, 'node_modules', name))) {
    results.push({ name: name, ok: true, skipped: true, detail: 'not installed (skip)' });
    return;
  }
  try {
    const detail = fn();
    results.push({ name: name, ok: true, detail: detail || 'ok' });
  } catch (e) {
    results.push({ name: name, ok: false, detail: e && e.message ? e.message : String(e) });
  }
}

// 1) better-sqlite3：加载 + 建表 + 写入 + 查询
check('better-sqlite3', function () {
  const Database = load('better-sqlite3');
  const db = new Database(':memory:');
  try {
    db.exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
    db.prepare('INSERT INTO t(v) VALUES (?)').run('ok');
    const row = db.prepare('SELECT v FROM t WHERE id = 1').get();
    if (!row || row.v !== 'ok') throw new Error('query mismatch');
    const sqliteVersion = db.prepare('select sqlite_version() as v').get().v;
    return 'create/insert/select ok (sqlite ' + sqliteVersion + ')';
  } finally {
    db.close();
  }
});

// 2) node-pty：只验证加载与导出（真实 spawn 需要终端，不适合冒烟）
check('node-pty', function () {
  const pty = load('node-pty');
  if (typeof pty.spawn !== 'function') throw new Error('spawn not exported');
  return 'loaded';
});

// 3) node-datachannel：只验证加载与导出
check('node-datachannel', function () {
  const ndc = load('node-datachannel');
  if (!ndc || typeof ndc.PeerConnection !== 'function')
    throw new Error('PeerConnection not exported');
  return 'loaded';
});

// 4) sharp：验证当前平台二进制可加载（libvips）
check('sharp', function () {
  const sharp = load('sharp');
  const meta = sharp.versions || {};
  if (!meta.vips) throw new Error('libvips version missing (binary not loaded)');
  return 'libvips ' + meta.vips;
});

let failed = 0;
for (const r of results) {
  const tag = r.skipped ? '[SKIP]' : r.ok ? '[OK]  ' : '[FAIL]';
  console.log(`${tag} ${r.name.padEnd(16)} ${r.detail}`);
  if (!r.ok) failed++;
}
console.log(`[summary] ${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
