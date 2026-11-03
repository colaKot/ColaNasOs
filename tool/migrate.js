#!/usr/bin/env node
/**
 * 迁移运维工具（schema-as-code）。
 *
 * 用法：
 *   node tool/migrate.js verify              校验「模块提供的迁移」与「顺序清单」一致（不需要数据库）
 *   node tool/migrate.js status              查看已应用 / 待应用 / 未登记（需要数据库）
 *   node tool/migrate.js up --dry-run        列出将要执行的迁移（不写库）
 *   node tool/migrate.js up                  执行待应用迁移
 *
 * 顺序清单真源：`kernel/migrations/manifest.ts`（只允许末尾追加）。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

function exeName() {
  return process.platform === 'win32' ? 'electron.exe' : 'electron';
}

function resolveElectronExe() {
  const candidates = [
    path.join(process.cwd(), 'node_modules', 'electron', 'dist', exeName()),
    path.join(__dirname, '..', 'node_modules', 'electron', 'dist', exeName()),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

if (!process.versions.electron) {
  const exe = resolveElectronExe();
  if (!exe) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename, ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..');
const { moduleList } = require(path.join(root, 'dist', 'kernel', 'modules'));
const { BASE_MIGRATIONS } = require(path.join(root, 'dist', 'kernel', 'migrations', 'base'));
const { MIGRATION_ORDER, checkMigrationOrder } = require(path.join(
  root,
  'dist',
  'kernel',
  'migrations',
  'manifest',
));

function collect() {
  return [...BASE_MIGRATIONS, ...moduleList().flatMap((m) => m.migrations || [])];
}

function dataDir() {
  const base = process.env.APPDATA || path.join(os.homedir(), '.config');
  return process.env.COLANAS_DATA_DIR || path.join(base, 'colanas_os_server');
}

async function main() {
  const cmd = process.argv[2] || 'verify';
  const argv = process.argv.slice(3);
  const migrations = collect();
  const check = checkMigrationOrder(
    migrations.map((m) => m.id),
    MIGRATION_ORDER,
  );

  if (cmd === 'verify') {
    console.log(`migrations provided : ${migrations.length}`);
    console.log(`manifest entries    : ${MIGRATION_ORDER.length}`);
    if (check.unregistered.length) {
      console.error(`[FAIL] 未登记迁移（请追加到 manifest 末尾）: ${check.unregistered.join(', ')}`);
      process.exit(1);
    }
    if (check.duplicated.length) {
      console.error(`[FAIL] 清单内重复: ${check.duplicated.join(', ')}`);
      process.exit(1);
    }
    if (check.missing.length) {
      console.warn(`[warn] 清单已登记但模块未提供（允许裁剪）: ${check.missing.join(', ')}`);
    }
    console.log('[OK] 迁移清单与模块一致');
    return;
  }

  if (check.unregistered.length) {
    console.error(`[FAIL] 未登记迁移: ${check.unregistered.join(', ')}`);
    process.exit(1);
  }

  const { createDb, closeDb } = require(path.join(root, 'dist', 'kernel', 'db'));
  const { Migrator } = require(path.join(root, 'dist', 'kernel', 'migrator'));

  const dir = dataDir();
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'colanas.sqlite');
  if (!fs.existsSync(file) && cmd !== 'up') {
    console.error(`[FATAL] 数据库不存在: ${file}（先启动一次内核，或执行 migrate up）`);
    process.exit(3);
  }

  const handle = createDb(file);
  const migrator = new Migrator(handle.db);

  if (cmd === 'status') {
    const plan = await migrator.plan(migrations, MIGRATION_ORDER);
    console.log(`database            : ${file}`);
    console.log(`applied             : ${plan.applied.length}`);
    console.log(`pending             : ${plan.pending.length}`);
    if (plan.pending.length) console.log(`  ${plan.pending.join(', ')}`);
    if (check.missing.length) console.log(`manifest-missing    : ${check.missing.join(', ')}`);
    await closeDb(handle);
    if (plan.pending.length) process.exit(1);
    return;
  }

  if (cmd === 'up') {
    const dryRun = argv.includes('--dry-run');
    const plan = await migrator.plan(migrations, MIGRATION_ORDER);
    if (plan.pending.length === 0) {
      console.log('[OK] 无待应用迁移');
      await closeDb(handle);
      return;
    }
    console.log(`${dryRun ? '[dry-run] 将执行' : '执行'} ${plan.pending.length} 条迁移:`);
    for (const id of plan.pending) console.log(`  - ${id}`);
    if (!dryRun) {
      const applied = await migrator.run(migrations, MIGRATION_ORDER);
      console.log(`[OK] 已应用 ${applied.length} 条`);
    }
    await closeDb(handle);
    return;
  }

  console.error(`未知命令: ${cmd}（可用：verify / status / up [--dry-run]）`);
  process.exit(2);
}

main().catch((err) => {
  console.error('[FATAL]', err && err.stack ? err.stack : err);
  process.exit(1);
});