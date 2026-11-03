#!/usr/bin/env node
/**
 * SP3-13（message 子集）验收：发送 / 用户隔离 / 未读数 / 已读 / 全部已读 / 删除。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/message-smoke.js
 */
'use strict';

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

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-msg-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenFor = async (sub) => {
    const r = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub, scopes: ['message:read', 'message:write'] },
    });
    return { authorization: 'Bearer ' + (r.json().token || '') };
  };

  const alice = await tokenFor('alice');
  const bob = await tokenFor('bob');

  // 发送给 alice
  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/messages/send',
    headers: alice,
    payload: { userId: 'alice', title: '备份完成', body: 'snap1 ok', level: 'info' },
  });
  const sent = r.json();
  check('send_ok', r.statusCode === 200 && sent.ownerId === 'alice', JSON.stringify(sent).slice(0, 80));

  r = await app.inject({ method: 'GET', url: '/api/v1/messages', headers: alice });
  check('alice_sees_it', r.statusCode === 200 && r.json().items.length === 1, 'items=' + r.json().items.length);

  r = await app.inject({ method: 'GET', url: '/api/v1/messages', headers: bob });
  check('bob_isolated', r.statusCode === 200 && r.json().items.length === 0, 'items=' + r.json().items.length);

  r = await app.inject({ method: 'GET', url: '/api/v1/messages/unread-count', headers: alice });
  check('unread_1', r.json().unread === 1, 'unread=' + r.json().unread);

  // bob 试图把 alice 的消息标记已读 → 不应生效
  r = await app.inject({ method: 'POST', url: '/api/v1/messages/read', headers: bob, payload: { id: sent.id } });
  const afterBobRead = await app.inject({ method: 'GET', url: '/api/v1/messages/unread-count', headers: alice });
  check(
    'cross_user_read_blocked',
    r.statusCode === 200 && afterBobRead.json().unread === 1,
    'unread=' + afterBobRead.json().unread,
  );

  r = await app.inject({ method: 'POST', url: '/api/v1/messages/read', headers: alice, payload: { id: sent.id } });
  const afterAliceRead = await app.inject({ method: 'GET', url: '/api/v1/messages/unread-count', headers: alice });
  check('mark_read', r.json().ok === true && afterAliceRead.json().unread === 0, 'unread=' + afterAliceRead.json().unread);

  // 未读过滤
  await app.inject({ method: 'POST', url: '/api/v1/messages/send', headers: alice, payload: { title: 'n1', body: '' } });
  await app.inject({ method: 'POST', url: '/api/v1/messages/send', headers: alice, payload: { title: 'n2', body: '' } });
  r = await app.inject({ method: 'GET', url: '/api/v1/messages?unreadOnly=true', headers: alice });
  check('unread_filter', r.json().items.length === 2, 'items=' + r.json().items.length);

  check(
    'self_send_owner',
    (await app.inject({ method: 'GET', url: '/api/v1/messages', headers: alice })).json().items.every((x) => x.ownerId === 'alice'),
    'owner ok',
  );

  r = await app.inject({ method: 'POST', url: '/api/v1/messages/read-all', headers: alice });
  const afterAll = await app.inject({ method: 'GET', url: '/api/v1/messages/unread-count', headers: alice });
  check('read_all', r.json().ok === true && afterAll.json().unread === 0, 'unread=' + afterAll.json().unread);

  r = await app.inject({ method: 'POST', url: '/api/v1/messages/remove', headers: alice, payload: { id: sent.id } });
  const afterRemove = await app.inject({ method: 'GET', url: '/api/v1/messages', headers: alice });
  check('remove_own', r.json().ok === true && afterRemove.json().total === 2, 'total=' + afterRemove.json().total);

  r = await app.inject({ method: 'GET', url: '/api/v1/messages' });
  check('requires_auth', r.statusCode === 401, 'status=' + r.statusCode);

  const token = (await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 'x', password: 'y' } })).statusCode;
  check('login_public_still_401_for_bad_user', token === 401, 'status=' + token);

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(30)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});