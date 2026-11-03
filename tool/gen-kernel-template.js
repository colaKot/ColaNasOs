#!/usr/bin/env node
/**
 * 生成「已跑完迁移」的内核空库模板，供门禁复用（见 kernel/index.ts 的 COLANAS_KERNEL_TEMPLATE）。
 *
 * 背景：每个 smoke / behavior 域都会 startKernel 一次，重复跑全量迁移是固定成本（单个约 2~3s）。
 * 模板按「迁移文件内容」派生 key：迁移改了就自动失效并重建，不会拿旧 schema 跑新代码。
 *
 * 用法：
 *   node tool/gen-kernel-template.js          # 命中缓存直接打印目录，否则生成
 *   node tool/gen-kernel-template.js --clear  # 清掉全部模板后重建
 * 输出：最后一行是模板目录绝对路径（tool/verify.js 用它设置环境变量）。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');

// better-sqlite3 是 Electron ABI，生成模板也要在 Electron 运行时里跑
if (!process.versions.electron) {
  const exe = path.join(
    root,
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename, ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

process.env.COLANAS_LOG_FILE = '0';
process.env.LOG_LEVEL = 'silent';
process.env.COLANAS_DEV_TOKEN = '1';

const cacheRoot = path.join(os.tmpdir(), 'colanas-kernel-template');

/** 收集所有会影响 schema 的迁移源文件 */
function migrationFiles() {
  const out = [];
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.ts') || e.name.endsWith('.js')) {
        if (p.includes('node_modules') || p.includes('dist')) continue;
        if (/migrations?\.(ts|js)$/.test(e.name) || p.includes(`${path.sep}migrations${path.sep}`)) out.push(p);
      }
    }
  };
  walk(path.join(root, 'kernel', 'migrations'));
  walk(path.join(root, 'src', 'modules'));
  return out.sort();
}

function templateKey() {
  const h = crypto.createHash('sha256');
  for (const f of migrationFiles()) {
    h.update(path.relative(root, f).replace(/\\/g, '/'));
    h.update(fs.readFileSync(f));
  }
  return h.digest('hex').slice(0, 16);
}

function copyDbFiles(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const name of fs.readdirSync(from)) {
    if (name.startsWith('colanas.sqlite')) fs.copyFileSync(path.join(from, name), path.join(to, name));
  }
}

(async () => {
  if (process.argv.includes('--clear')) {
    fs.rmSync(cacheRoot, { recursive: true, force: true });
  }

  const key = templateKey();
  const target = path.join(cacheRoot, key);
  if (fs.existsSync(path.join(target, 'colanas.sqlite'))) {
    console.log(target);
    return;
  }

  const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index.js'));
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-tpl-'));
  try {
    const k = await startKernel({ dataDir: work, port: 0, listen: false });
    await k.app.ready();
    await k.app.close();

    const staging = `${target}.${process.pid}`;
    fs.rmSync(staging, { recursive: true, force: true });
    copyDbFiles(work, staging);
    fs.mkdirSync(cacheRoot, { recursive: true });
    try {
      fs.renameSync(staging, target);
    } catch {
      // 并发生成时目标已存在：以先到者为准
      fs.rmSync(staging, { recursive: true, force: true });
    }
    if (!fs.existsSync(path.join(target, 'colanas.sqlite'))) {
      console.error('[template] 生成失败：目标库不存在');
      process.exit(1);
    }
    console.log(`[template] 已生成 ${key}`);
    console.log(target);
  } finally {
    fs.rmSync(work, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
})().catch((err) => {
  console.error('[template] FATAL', err);
  process.exit(1);
});