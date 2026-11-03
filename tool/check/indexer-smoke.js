#!/usr/bin/env node
/**
 * indexer + 批量写协议验收（SP2-04）：
 *  1. 分片批大小 ≤ 500，批次序号连续
 *  2. 事务耗时 ≤ 50 ms / 批
 *  3. 全量入库行数正确（幂等 upsert）
 *  4. 崩溃后可续：kill 中途 → 重启 → 按 checkpoint 续传，最终行数正确且无重复
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：node tool/check/indexer-smoke.js
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
    path.join(__dirname, '..', '..', 'node_modules', 'electron', 'dist', exeName()),
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
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { createDb, closeDb } = require(path.join(root, 'dist', 'kernel', 'db'));
const { Migrator } = require(path.join(root, 'dist', 'kernel', 'migrator'));
const { SidecarSupervisor } = require(path.join(root, 'dist', 'kernel', 'sidecar', 'supervisor'));
const { IndexerBridge } = require(path.join(root, 'dist', 'kernel', 'sidecar', 'indexer-bridge'));
const { files } = require(path.join(root, 'dist', 'src', 'modules', 'files', 'index.js'));

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

function makeTree(base, count, subdirs = 4, prefix = '') {
  for (let i = 0; i < count; i++) {
    const dir = path.join(base, `d${i % subdirs}`);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, `${prefix}f${String(i).padStart(5, '0')}.txt`), 'x'.repeat(i % 97));
  }
  return count;
}

function countRows(db) {
  return db.prepare('select count(*) as n from files_meta').get().n;
}

function startIndexer() {
  return new SidecarSupervisor({
    name: 'indexer',
    command: process.env.COLANAS_SIDECAR_NODE || process.execPath,
    args: [process.env.COLANAS_SIDECAR_SCRIPT || path.join(root, 'sidecars', 'indexer', 'main.js')],
    requestTimeoutMs: 5_000,
    heartbeatMs: 2_000,
    maxRestarts: 3,
    startTimeoutMs: 8_000,
    stopGraceMs: 3_000,
    log: (lvl, msg) => console.log('[idx:' + lvl + '] ' + msg),
  });
}

function waitFor(sup, event, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting ${event}`)), timeoutMs);
    sup.once('event', function onEvent(name, data) {
      if (name !== event) {
        sup.once('event', onEvent);
        return;
      }
      clearTimeout(timer);
      resolve(data);
    });
  });
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-index-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(filesRoot, { recursive: true });

  const TOTAL = 1200;
  makeTree(filesRoot, TOTAL);
  const SMALL = 3000;
  const smallRoot = path.join(dataDir, 'small');
  fs.mkdirSync(smallRoot, { recursive: true });
  // 前缀区分：files_meta 按 path 唯一，两棵树必须不同名，否则 upsert 会互相覆盖
  makeTree(smallRoot, SMALL, 4, 's');

  const handle = createDb(path.join(dataDir, 'index.sqlite'));
  const migrator = new Migrator(handle.db);
  await migrator.run(files.migrations || []);

  // ---------- 1. 全量扫描 ----------
  const sup = startIndexer();
  console.log(
    '[diag] cmd=',
    process.env.COLANAS_SIDECAR_NODE || process.execPath,
    'script=',
    path.join(root, 'sidecars', 'indexer', 'main.js'),
    'rows=',
    countRows(handle.raw),
  );
  await sup.start();

  const bridge = new IndexerBridge(handle.raw, sup);
  const since = bridge.loadCheckpoint(filesRoot);
  check('checkpoint_initial', since === 0, 'sinceSeq=' + since);

  const batchSizes = [];
  sup.on('event', (name, data) => {
    if (name === 'batch') batchSizes.push(data.entries.length);
  });

  const donePromise = waitFor(sup, 'scan_done');
  const accepted = await sup.request('scan', { root: filesRoot, batchSize: 500, flushMs: 5000 });
  const done = await donePromise;

  const rows = countRows(handle.raw);
  const stats = bridge.getStats();

  check('scan_accepted', accepted && accepted.accepted === true, JSON.stringify(accepted));
  check('batch_size_le_500', batchSizes.length > 0 && batchSizes.every((n) => n <= 500), batchSizes.join(','));
  check(
    'rows_complete',
    rows === TOTAL && done.total === TOTAL,
    `rows=${rows} total=${done.total} batches=${done.batches}`,
  );
  check('tx_under_50ms', stats.maxTxMs < 50, `maxTxMs=${stats.maxTxMs.toFixed(2)}`);

  // ---------- 2. 幂等：重复扫描不叠加 ----------
  const again = waitFor(sup, 'scan_done');
  await sup.request('scan', { root: filesRoot, batchSize: 500, flushMs: 5000 });
  await again;
  const rowsAfterRepeat = countRows(handle.raw);
  check('idempotent_rescan', rowsAfterRepeat === TOTAL, `rows=${rowsAfterRepeat}`);

  // ---------- 3. 崩溃续传 ----------
  const smallBridge = new IndexerBridge(handle.raw, sup);
  const smallSince = smallBridge.loadCheckpoint(smallRoot);
  check('checkpoint_second_root', smallSince === 0, 'sinceSeq=' + smallSince);

  const rowsBefore = countRows(handle.raw);
  let killed = false;
  const willKill = new Promise((resolve) => {
    sup.on('event', (name, data) => {
      if (name === 'batch' && data && data.seq === 1 && !killed) {
        killed = true;
        // 等 scan 的 accepted 响应先回到主线程再杀，避免把「已被 kill」误判成请求失败
        setTimeout(() => {
          try {
            process.kill(sup.pid, 'SIGKILL');
          } catch {
            /* 已退出 */
          }
          resolve();
        }, 0);
      }
    });
  });

  const pidBefore = sup.pid;
  await sup.request('scan', { root: smallRoot, batchSize: 500, flushMs: 5000 });
  await willKill;

  // 等自动重启完成（以「ready 且 pid 已更换」为准，避免状态窗口期误判）
  await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('restart timeout')), 15_000);
    const done = () => {
      if (sup.state === 'ready' && sup.pid !== pidBefore) {
        clearTimeout(t);
        resolve();
      }
    };
    sup.on('ready', done);
    setTimeout(done, 600);
  });

  const rowsAfterCrash = countRows(handle.raw);
  const checkpoint = smallBridge.loadCheckpoint(smallRoot);

  // 从 checkpoint 续传剩余批次
  const resume = waitFor(sup, 'scan_done');
  await sup.request('scan', { root: smallRoot, batchSize: 500, flushMs: 5000, sinceSeq: checkpoint });
  await resume;

  const rowsFinal = countRows(handle.raw);
  check('crash_partial', rowsAfterCrash > rowsBefore && rowsAfterCrash < rowsBefore + SMALL, `rows=${rowsAfterCrash}`);
  check(
    'resume_complete',
    checkpoint > 0 && rowsFinal === TOTAL + SMALL,
    `checkpoint=${checkpoint} rows=${rowsFinal} expect=${TOTAL + SMALL}`,
  );

  await sup.stop();
  await closeDb(handle);
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(22)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});