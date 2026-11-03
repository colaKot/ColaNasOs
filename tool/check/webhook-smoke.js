#!/usr/bin/env node
/**
 * SP3-14 验收：Webhook 创建 / 签名 / 重试 / 事件分发 / 删除。
 *
 * 本地起一个 HTTP 接收端：第一次返回 500，验证重试后成功并校验 HMAC。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/webhook-smoke.js
 */
'use strict';

const http = require('node:http');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(process.cwd(), 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
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
const { signature } = require(path.join(root, 'dist', 'src', 'modules', 'integrations', 'index.js'));

process.chdir(root);

(async () => {
  const received = [];
  let hit = 0;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      hit += 1;
      received.push({ sig: req.headers['x-colanas-signature'], event: req.headers['x-colanas-event'], body });
      if (hit === 1) {
        res.statusCode = 500;
        res.end('first-fail');
      } else {
        res.statusCode = 200;
        res.end('ok');
      }
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-hook-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['integration:read', 'integration:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };

  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/integration/webhooks',
    headers: bearer,
    payload: { url: `http://127.0.0.1:${port}/hook`, events: ['file.changed', 'test'] },
  });
  const hook = r.json();
  check('hook_create', r.statusCode === 200 && hook.id && hook.secret.length >= 16, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/integration/webhooks', headers: bearer, payload: { url: 'ftp://x', events: ['a'] } });
  check('hook_bad_url_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/integration/webhooks/test',
    headers: bearer,
    payload: { id: hook.id },
  });
  const testRes = r.json();
  check('test_delivered_after_retry', r.statusCode === 200 && testRes.delivered === 1, JSON.stringify(testRes));

  r = await app.inject({ method: 'GET', url: '/api/v1/integration/deliveries?hookId=' + encodeURIComponent(hook.id), headers: bearer });
  const deliv = r.json();
  check(
    'delivery_attempts_2',
    r.statusCode === 200 && deliv.items.length === 1 && deliv.items[0].attempts === 2 && deliv.items[0].status === 'delivered',
    JSON.stringify(deliv.items[0]),
  );

  const last = received[received.length - 1];
  check(
    'signature_valid',
    last && last.sig === signature(hook.secret, last.body) && last.event === 'test',
    `sig=${(last && last.sig || '').slice(0, 20)}`,
  );

  // 事件分发
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/integration/emit',
    headers: bearer,
    payload: { event: 'file.changed', payload: { path: '/media/a.jpg' } },
  });
  const emit = r.json();
  check('event_dispatch', r.statusCode === 200 && emit.hooks === 1 && emit.delivered === 1, JSON.stringify(emit));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/integration/emit',
    headers: bearer,
    payload: { event: 'unknown.event' },
  });
  check('event_no_match', r.json().hooks === 0, JSON.stringify(r.json()));

  // 列表不回传 secret
  r = await app.inject({ method: 'GET', url: '/api/v1/integration/webhooks', headers: bearer });
  const list = r.json();
  check(
    'list_hides_secret',
    r.statusCode === 200 && list.items.length === 1 && list.items[0].secret === undefined,
    JSON.stringify(list.items[0]),
  );

  // 删除
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/integration/webhooks/remove',
    headers: bearer,
    payload: { id: hook.id },
  });
  const afterRemove = await app.inject({
    method: 'POST',
    url: '/api/v1/integration/webhooks/test',
    headers: bearer,
    payload: { id: hook.id },
  });
  check('remove_404', r.json().ok === true && afterRemove.statusCode === 404, 'test=' + afterRemove.statusCode);

  await app.close();
  await new Promise((r2) => server.close(r2));
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(26)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});