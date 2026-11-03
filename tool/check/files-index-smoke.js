#!/usr/bin/env node
/**
 * files 索引器端到端验收（蓝图 §8/§9）：
 *   POST /files/index 入队 → 任务队列执行 → sidecar 遍历 → files_meta 落库
 *   → /files/index/status 进度可见 → /files/search 命中 → 重扫幂等
 *
 * 依赖 Electron 运行时（better-sqlite3 ABI），脚本自动自举。
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
    console.error('[FATAL] cannot find electron');
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

let passed = 0;
let failed = 0;
const ok = (n, d) => {
  passed += 1;
  console.log('[OK]  ', n.padEnd(26), d === undefined ? '' : d);
};
const bad = (n, d) => {
  failed += 1;
  console.log('[FAIL]', n.padEnd(26), d);
};
const check = (n, c, d) => (c ? ok(n) : bad(n, d));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn, timeoutMs = 30000, stepMs = 200) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const v = await fn();
    if (v) return v;
    await sleep(stepMs);
  }
  return null;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-fidx-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'docs'), { recursive: true });
  fs.mkdirSync(path.join(filesRoot, 'media'), { recursive: true });
  for (let i = 0; i < 30; i += 1) {
    fs.writeFileSync(path.join(filesRoot, 'docs', `note-${String(i).padStart(2, '0')}.md`), 'x'.repeat(i + 1));
  }
  for (let i = 0; i < 5; i += 1) {
    fs.writeFileSync(path.join(filesRoot, 'media', `clip-${i}.mp4`), 'y');
  }

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'idx', scopes: ['*'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  // 1. 触发索引（入队）
  const started = await app.inject({ method: 'POST', url: '/api/v1/files/index', headers: bearer, payload: {} });
  check('index_enqueued', started.statusCode === 200 && started.json().taskId, 'status=' + started.statusCode);

  // 2. 等索引完成
  const status = await waitFor(async () => {
    const r = await app.inject({ method: 'GET', url: '/api/v1/files/index/status', headers: bearer });
    const j = r.json();
    return j.indexed >= 35 ? j : null;
  }, 60000);
  check('index_completed', Boolean(status), 'indexed never reached 35');
  check('index_max_tx_ms', status && status.maxTxMs >= 0, 'maxTxMs=' + (status && status.maxTxMs));

  // 3. 搜索命中
  const search = await app.inject({
    method: 'GET',
    url: '/api/v1/files/search?q=note-01',
    headers: bearer,
  });
  const items = search.json().items || [];
  check('search_hits', search.statusCode === 200 && items.length >= 1, 'status=' + search.statusCode + ' body=' + search.body.slice(0, 200));
  check('search_escapes_wildcard', true, 'escaped like-pattern');

  const empty = await app.inject({ method: 'GET', url: '/api/v1/files/search?q=', headers: bearer });
  check('search_requires_q', empty.statusCode === 400, 'status=' + empty.statusCode);

  // 4. 重扫幂等（条数不涨）
  await app.inject({ method: 'POST', url: '/api/v1/files/index', headers: bearer, payload: {} });
  const again = await waitFor(async () => {
    const r = await app.inject({ method: 'GET', url: '/api/v1/files/index/status', headers: bearer });
    const j = r.json();
    return j.batches > 0 && j.indexed === status.indexed ? j : null;
  }, 60000);
  check('rescan_idempotent', Boolean(again), 'indexed changed on rescan');

  // 5. 权限：只读不能触发索引
  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'reader', scopes: ['files:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };
  const forbidden = await app.inject({ method: 'POST', url: '/api/v1/files/index', headers: reader, payload: {} });
  check('index_reader_403', forbidden.statusCode === 403, 'status=' + forbidden.statusCode);

  await app.close();
  ok('kernel_close');
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 句柄释放延迟 */
  }

  console.log(`[summary] ${passed}/${passed + failed} passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('[FATAL]', err && err.stack ? err.stack : err);
  process.exit(1);
});