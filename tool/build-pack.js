#!/usr/bin/env node
/**
 * 打包统一入口（`npm run pack` / `dist` / `dist:lite`）。
 *
 * 为什么不用 electron-builder 的自动 rebuild：
 *   - `better-sqlite3` 必须按 Electron ABI 重建，但开发中的内核会占用
 *     `better_sqlite3.node`（Windows 上 unlink 报 EPERM），每次打包都重建既慢又容易失败；
 *   - `node-pty` 1.1 是 N-API（node-addon-api），**不需要**重建；它的源码编译还要求
 *     VS 的 Spectre 缓解库（缺失即 MSB8040，整包失败）。
 *
 * 这里先做一次 ABI 探测：Electron 能 `require('better-sqlite3')` 就直接打包，
 * 否则才跑 `npm run rebuild`。electron-builder 侧已 `npmRebuild: false`。
 *
 * 用法：
 *   node tool/build-pack.js --dir      # 免安装目录（npm run pack）
 *   node tool/build-pack.js            # 安装器（npm run dist）
 *   node tool/build-pack.js --lite     # 不含本地模型（npm run dist:lite）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const args = process.argv.slice(2);
const lite = args.includes('--lite');
const dir = args.includes('--dir');

const electron = path.join(
  root,
  'node_modules',
  'electron',
  'dist',
  process.platform === 'win32' ? 'electron.exe' : 'electron',
);

function betterSqliteAbiOk() {
  if (!fs.existsSync(electron)) return false;
  const probe = spawnSync(electron, ['-e', "require('better-sqlite3');"], {
    cwd: root,
    stdio: 'ignore',
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  });
  return probe.status === 0;
}

if (!betterSqliteAbiOk()) {
  console.log('[build-pack] better-sqlite3 与 Electron ABI 不匹配，执行 npm run rebuild ...');
  const rebuild = spawnSync('npm', ['run', 'rebuild'], {
    cwd: root,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (rebuild.status !== 0) {
    console.error(
      '[build-pack] 重建失败：通常是开发中的内核 / Electron 进程占用了 better_sqlite3.node。',
    );
    console.error('             先停掉 dev.bat / start.bat 起的进程，再重跑打包。');
    process.exit(1);
  }
} else {
  console.log('[build-pack] better-sqlite3 ABI 已匹配，跳过 rebuild');
}

// 随包地名库转成 DELETE journal 模式：WAL 库只读打开时首次查询会 SQLITE_CANTOPEN，
// 装机版的「相册回忆」整页 500（详见 tool/geo-journal.js）。转换失败不阻断打包，
// 内核侧已降级为空地名。
const geoFix = spawnSync(electron, [path.join(__dirname, 'geo-journal.js')], {
  cwd: root,
  stdio: 'inherit',
  env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
});
if (geoFix.status !== 0) {
  console.warn('[build-pack] [!] 地名库 journal 模式转换失败：装机版相册回忆会没有地名（不会 500）');
}

// 便携 python 运行时（AI 新闻播客的本地语音合成）：缺了就现做一份。
// 失败不阻断打包：只影响语音合成，其余功能照常。
if (!lite) {
  const pyExe = path.join(
    root,
    'vendor',
    'python-runtime',
    process.platform === 'win32' ? 'python.exe' : path.join('bin', 'python3'),
  );
  if (fs.existsSync(pyExe)) {
    console.log('[build-pack] 便携 python 运行时已就绪');
  } else {
    const bundler = path.join(__dirname, 'bundle-python.js');
    if (!fs.existsSync(bundler)) {
      console.warn('[build-pack] [!] 未生成 python 运行时（本机没有 vendor/python-runtime，也没有打包脚本）：');
      console.warn('            装机版的 AI 语音合成不可用，其余功能照常。');
      console.warn('            需要时手动放一份便携 python 到 vendor/python-runtime 后重跑打包。');
    } else {
      console.log('[build-pack] 缺少便携 python 运行时，尝试生成 …');
      const r = spawnSync(process.execPath, [bundler], {
        cwd: root,
        stdio: 'inherit',
      });
      if (r.status !== 0) {
        console.warn('[build-pack] [!] 未生成 python 运行时：装机版的 AI 语音合成会不可用。');
      }
    }
  }
}

const cliArgs = [
  path.join(root, 'node_modules', 'electron-builder', 'cli.js'),
  '--publish',
  'never',
];
if (dir) cliArgs.push('--dir');

const result = spawnSync(process.execPath, cliArgs, {
  cwd: root,
  stdio: 'inherit',
  env: { ...process.env, ...(lite ? { COLANAS_LITE: '1' } : {}) },
});
process.exit(result.status ?? 1);