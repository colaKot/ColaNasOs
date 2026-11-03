#!/usr/bin/env node
/**
 * 接口验收（SP0-05 / SP0-06 / SP0-08）：
 * 认证 401 / 越权 403 / 正常 200、根目录逃逸、token 篡改、队列 claim+recover。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：node tool/check/api-smoke.js
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
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-api-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(filesRoot, { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'a.txt'), 'x');
  fs.mkdirSync(path.join(filesRoot, 'sub'));

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  // 1. 无 token → 401
  let r = await app.inject({ method: 'GET', url: '/api/v1/files/list' });
  check('auth_required', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 签发只读 token
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['files:read'] },
  });
  const token = r.json().token || '';
  check('dev_token', r.statusCode === 200 && token.length > 20, 'status=' + r.statusCode);

  const bearer = { authorization: 'Bearer ' + token };

  // 3. 有 files:read → 200
  r = await app.inject({ method: 'GET', url: '/api/v1/files/list', headers: bearer });
  const body = r.json();
  check(
    'scope_allow',
    r.statusCode === 200 && Array.isArray(body.items) && body.items.length === 2,
    'status=' + r.statusCode + ' items=' + (body.items || []).length,
  );

  // 4. 只有 files:read，访问 tasks:read → 403
  r = await app.inject({ method: 'GET', url: '/api/v1/tasks', headers: bearer });
  check('scope_deny', r.statusCode === 403, 'status=' + r.statusCode);

  // 5. tasks:read token → 200
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { scopes: ['tasks:read'] },
  });
  const taskToken = r.json().token;
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/tasks',
    headers: { authorization: 'Bearer ' + taskToken },
  });
  check('scope_tasks', r.statusCode === 200 && !!r.json().stats, 'status=' + r.statusCode);

  // 6. 根目录逃逸 → 403
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/files/list?path=../../../etc',
    headers: bearer,
  });
  check('path_escape', r.statusCode === 403, 'status=' + r.statusCode);

  // 7. 篡改 token → 401
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/files/list',
    headers: { authorization: 'Bearer ' + token.slice(0, -2) + 'xx' },
  });
  check('token_tamper', r.statusCode === 401, 'status=' + r.statusCode);

  // 8. 公开路由免认证 → 200
  r = await app.inject({ method: 'GET', url: '/health' });
  check('public_health', r.statusCode === 200, 'status=' + r.statusCode);

  // 9. 队列：enqueue → claim → recover（模拟崩溃）
  const id = await k.queue.enqueue('noop', { a: 1 });
  const claimed = await k.queue.claim(1);
  const wasRunning =
    claimed.length === 1 && claimed[0].state === 'running' && claimed[0].attempts === 1;
  const recovered = await k.queue.recover();
  const after = await k.queue.get(id);
  check(
    'queue_claim_recover',
    wasRunning && recovered === 1 && after.state === 'pending' && after.attempts === 1,
    `claimed=${claimed.length} recovered=${recovered} state=${after && after.state} attempts=${after && after.attempts}`,
  );

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(20)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
