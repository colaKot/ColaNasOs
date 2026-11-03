#!/usr/bin/env node
/**
 * SP3-06（notes 子集）验收：创建 / 更新存版 / 搜索 / 标签 / 版本恢复 / 用户隔离 / 软删。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/notes-smoke.js
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
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-notes-'));
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
      payload: { sub, scopes: ['notes:read', 'notes:write'] },
    });
    return { authorization: 'Bearer ' + (r.json().token || '') };
  };

  const alice = await tokenFor('alice');
  const bob = await tokenFor('bob');

  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/notes/create',
    headers: alice,
    payload: { title: '会议纪要', body: 'v1 内容', tags: ['work'] },
  });
  const note = r.json();
  check('create_ok', r.statusCode === 200 && note.id && note.tags.includes('work'), JSON.stringify(note).slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/notes/update',
    headers: alice,
    payload: { id: note.id, body: 'v2 内容' },
  });
  check('update_1', r.statusCode === 200 && r.json().body === 'v2 内容', 'body=' + r.json().body);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/notes/update',
    headers: alice,
    payload: { id: note.id, body: 'v3 内容', pinned: true },
  });
  check('update_2_pinned', r.statusCode === 200 && r.json().pinned === true, 'pinned=' + r.json().pinned);

  r = await app.inject({ method: 'GET', url: '/api/v1/notes/versions?id=' + encodeURIComponent(note.id), headers: alice });
  const versions = r.json();
  check(
    'versions_two',
    r.statusCode === 200 && versions.items.length === 2 && versions.items.some((v) => v.body === 'v1 内容'),
    'count=' + versions.items.length,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/notes?q=' + encodeURIComponent('v2'), headers: alice });
  const search = r.json();
  check('search_body', r.statusCode === 200 && search.items.length === 0, '命中旧版本正文应为 0（正文已是 v3）');

  r = await app.inject({ method: 'GET', url: '/api/v1/notes?q=' + encodeURIComponent('会议'), headers: alice });
  check('search_title', r.json().items.length === 1, 'items=' + r.json().items.length);

  r = await app.inject({ method: 'GET', url: '/api/v1/notes?tag=work', headers: alice });
  check('filter_tag', r.json().items.length === 1, 'items=' + r.json().items.length);

  const v1 = versions.items.find((v) => v.body === 'v1 内容');
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/notes/restore',
    headers: alice,
    payload: { id: note.id, versionId: v1.id },
  });
  const restored = r.json();
  const afterVersionCount = (await app.inject({ method: 'GET', url: '/api/v1/notes/versions?id=' + encodeURIComponent(note.id), headers: alice })).json();
  check(
    'restore_version',
    r.statusCode === 200 && restored.body === 'v1 内容' && afterVersionCount.items.length === 3,
    `body=${restored.body} versions=${afterVersionCount.items.length}`,
  );

  // 乐观锁：基于过期版本保存 → 409 + 最新内容；基于最新版本 → 成功
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/notes/update',
    headers: alice,
    payload: { id: note.id, body: 'stale 内容', baseVersion: 1 },
  });
  const conflict = r.json();
  check(
    'conflict_409',
    r.statusCode === 409 &&
      conflict.error === 'conflict' &&
      conflict.details &&
      conflict.details.version === 4 &&
      conflict.details.body === 'v1 内容',
    `status=${r.statusCode} version=${conflict.details && conflict.details.version}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/notes/update',
    headers: alice,
    payload: { id: note.id, body: 'v5 内容', baseVersion: 4 },
  });
  check(
    'conflict_resolved',
    r.statusCode === 200 && r.json().version === 5 && r.json().body === 'v5 内容',
    `status=${r.statusCode} version=${r.json().version}`,
  );

  // 隔离
  r = await app.inject({ method: 'GET', url: '/api/v1/notes', headers: bob });
  check('bob_list_empty', r.json().items.length === 0 && r.json().total === 0, 'total=' + r.json().total);
  r = await app.inject({ method: 'GET', url: '/api/v1/notes/get?id=' + encodeURIComponent(note.id), headers: bob });
  check('bob_get_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 软删
  r = await app.inject({ method: 'POST', url: '/api/v1/notes/remove', headers: alice, payload: { id: note.id } });
  const afterRemove = await app.inject({ method: 'GET', url: '/api/v1/notes', headers: alice });
  check('soft_delete', r.json().ok === true && afterRemove.json().total === 0, 'total=' + afterRemove.json().total);

  r = await app.inject({ method: 'GET', url: '/api/v1/notes' });
  check('requires_auth', r.statusCode === 401, 'status=' + r.statusCode);

  await app.close();
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