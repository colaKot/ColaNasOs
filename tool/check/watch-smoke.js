#!/usr/bin/env node
/**
 * 文件监控与增量扫描（蓝图 §56）验收：
 *   建库 → **不手动扫描** → 往库目录丢图片 → 自动入库 →
 *   子目录新增 → 自动入库 → 非图片文件被忽略 → 删除文件不误删索引 → 内核可正常关闭
 *
 * 依赖 Electron 运行时（better-sqlite3 的 ABI），脚本自动自举。
 * 用法：node tool/check/watch-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(
    process.cwd(),
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
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
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

/** 1x1 PNG；photo/exif 只校验 IHDR 合法性 */
const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

let passed = 0;
let failed = 0;

function ok(name, extra) {
  passed += 1;
  console.log('[OK]  ', name.padEnd(26), extra === undefined ? '' : extra);
}

function fail(name, detail) {
  failed += 1;
  console.log('[FAIL]', name.padEnd(26), detail);
}

function check(name, cond, detail) {
  if (cond) ok(name);
  else fail(name, detail);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 6000, stepMs = 100) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const v = await fn();
    if (v) return v;
    await sleep(stepMs);
  }
  return null;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-watch-'));
  const filesRoot = path.join(dataDir, 'files');
  const album = path.join(filesRoot, 'album');
  fs.mkdirSync(path.join(album, 'sub'), { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_WATCH_DEBOUNCE_MS = '100';
  process.env.LOG_LEVEL = 'warn';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'watcher', scopes: ['*'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const timeline = async () => {
    const r = await app.inject({ method: 'GET', url: '/api/v1/photo/timeline', headers: bearer });
    return r.statusCode === 200 ? r.json().items.length : -1;
  };

  // 1. 建库（不扫描）
  const created = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/libraries',
    headers: bearer,
    payload: { name: 'album', path: 'album' },
  });
  check('library_create', created.statusCode === 200, `status=${created.statusCode}`);
  check('timeline_empty_before', (await timeline()) === 0, 'timeline should start empty');

  // 2. 丢一张图片 → 自动入库
  fs.writeFileSync(path.join(album, 'a.png'), PNG_1PX);
  const got1 = await waitFor(async () => (await timeline()) === 1);
  check('auto_index_new_file', Boolean(got1), 'file was not indexed automatically');

  // 3. 子目录新增 → 只重扫该目录，同样入库
  fs.writeFileSync(path.join(album, 'sub', 'b.png'), PNG_1PX);
  const got2 = await waitFor(async () => (await timeline()) === 2);
  check('auto_index_subdir', Boolean(got2), 'sub-directory file was not indexed');

  // 4. 非图片文件不触发索引
  fs.writeFileSync(path.join(album, 'notes.txt'), 'hello');
  await sleep(700);
  const n4 = await timeline();
  check('ignore_non_media', n4 === 2, 'timeline=' + n4);

  // 5. 忽略规则：系统垃圾文件
  fs.writeFileSync(path.join(album, '.DS_Store'), 'x');
  fs.mkdirSync(path.join(album, '@eaDir'), { recursive: true });
  fs.writeFileSync(path.join(album, '@eaDir', 'c.png'), PNG_1PX);
  await sleep(700);
  const n5 = await timeline();
  check('ignore_junk_paths', n5 === 2, 'timeline=' + n5);

  // 6. 删除文件不误删索引（全量扫描负责「正确」，监控不删元数据）
  fs.unlinkSync(path.join(album, 'a.png'));
  await sleep(700);
  const n6 = await timeline();
  check('keep_index_on_delete', n6 === 2, 'timeline=' + n6);

  // 7. 显式 prune：清理「索引有、磁盘无」的行（默认扫描不删，见上一步）
  const pruneRes = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/scan',
    headers: bearer,
    payload: { prune: true },
  });
  const pruned = pruneRes.json();
  check('scan_reports_missing', pruned.missing >= 1, 'missing=' + pruned.missing);
  check('scan_prune_removed', pruned.pruned >= 1, 'pruned=' + pruned.pruned);
  const afterPrune = await timeline();
  check('timeline_after_prune', afterPrune === 1, 'timeline=' + afterPrune);

  // 8. 事件流：客户端可增量拉取扫描事件做局部刷新
  const evRes = await app.inject({
    method: 'GET',
    url: '/api/v1/events/recent?since=0&limit=100',
    headers: bearer,
  });
  const ev = evRes.json();
  const items = Array.isArray(ev.items) ? ev.items : [];
  check(
    'events_scan_done',
    items.some((i) => i.topic === 'scan.done' && i.data && i.data.domain === 'photo'),
    'items=' + items.length,
  );
  check('events_next_seq', typeof ev.nextSeq === 'number' && ev.nextSeq > 0, 'next=' + ev.nextSeq);

  // 9. 关闭内核：watcher 不应阻止退出
  await app.close();
  ok('kernel_close');

  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  console.log(`[summary] ${passed}/${passed + failed} passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('[FATAL]', err && err.stack ? err.stack : err);
  process.exit(1);
});