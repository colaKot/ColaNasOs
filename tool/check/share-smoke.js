#!/usr/bin/env node
/**
 * SP3-08 fileServer / quickShare 验收：
 *   创建 → 公开 info/下载 → 密码保护（403）→ 撤销（404）→ 路径越界（400）
 *   → Range（206）→ 过期（410，直接改库）
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/share-smoke.js
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
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-share-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'media'), { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'media', 'a.txt'), 'hello-share');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['share:read', 'share:write', 'files:read'] },
  });
  const token = tokenRes.json().token || '';
  const bearer = { authorization: 'Bearer ' + token };

  // 1. 无 token 不能创建
  let r = await app.inject({ method: 'POST', url: '/api/v1/share/create', payload: { path: '/media/a.txt' } });
  check('create_requires_auth', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 创建（无密码）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/share/create',
    headers: bearer,
    payload: { path: '/media/a.txt' },
  });
  const created = r.json();
  check('create_ok', r.statusCode === 200 && created.id && created.url, JSON.stringify(created).slice(0, 80));

  // 3. 公开 info
  r = await app.inject({ method: 'GET', url: '/api/v1/share/info?id=' + encodeURIComponent(created.id) });
  const info = r.json();
  check('public_info', r.statusCode === 200 && info.fileName === 'a.txt', 'status=' + r.statusCode);

  // 4. 公开下载
  r = await app.inject({ method: 'GET', url: '/api/v1/share/download?id=' + encodeURIComponent(created.id) });
  check('public_download', r.statusCode === 200 && r.body === 'hello-share', 'status=' + r.statusCode);

  // 5. Range
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/share/download?id=' + encodeURIComponent(created.id),
    headers: { range: 'bytes=0-4' },
  });
  check('range_206', r.statusCode === 206 && r.body === 'hello', 'status=' + r.statusCode + ' body=' + r.body);

  // 6. 密码保护
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/share/create',
    headers: bearer,
    payload: { path: '/media/a.txt', password: 's3cret' },
  });
  const withPw = r.json();
  const noPw = await app.inject({ method: 'GET', url: '/api/v1/share/download?id=' + encodeURIComponent(withPw.id) });
  const badPw = await app.inject({
    method: 'GET',
    url: '/api/v1/share/download?id=' + encodeURIComponent(withPw.id) + '&password=wrong',
  });
  const okPw = await app.inject({
    method: 'GET',
    url: '/api/v1/share/download?id=' + encodeURIComponent(withPw.id) + '&password=s3cret',
  });
  check(
    'password_guard',
    noPw.statusCode === 403 && badPw.statusCode === 403 && okPw.statusCode === 200,
    `none=${noPw.statusCode} bad=${badPw.statusCode} ok=${okPw.statusCode}`,
  );

  // 7. 路径越界
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/share/create',
    headers: bearer,
    payload: { path: '../../../../etc/passwd' },
  });
  check('path_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 8. 撤销
  r = await app.inject({ method: 'POST', url: '/api/v1/share/revoke', headers: bearer, payload: { id: created.id } });
  const afterRevoke = await app.inject({ method: 'GET', url: '/api/v1/share/info?id=' + encodeURIComponent(created.id) });
  check('revoke_404', r.statusCode === 200 && afterRevoke.statusCode === 404, 'revoke=' + r.statusCode + ' info=' + afterRevoke.statusCode);

  // 9. 列表
  r = await app.inject({ method: 'GET', url: '/api/v1/share/list', headers: bearer });
  const list = r.json();
  check(
    'list_has_password_flag',
    r.statusCode === 200 && list.items.some((x) => x.id === withPw.id && x.hasPassword === true),
    'items=' + (list.items || []).length,
  );

  // 10. 过期 → 410（直接改库，避免等待）
  const { sql } = require(path.join(root, 'node_modules', 'kysely'));
  await sql`update share_links set expires_at = 1 where id = ${withPw.id}`.execute(k.db);
  const expiredInfo = await app.inject({
    method: 'GET',
    url: '/api/v1/share/info?id=' + encodeURIComponent(withPw.id),
  });
  const expiredDl = await app.inject({
    method: 'GET',
    url: '/api/v1/share/download?id=' + encodeURIComponent(withPw.id) + '&password=s3cret',
  });
  check(
    'expired_410',
    expiredInfo.statusCode === 410 && expiredDl.statusCode === 410,
    `info=${expiredInfo.statusCode} dl=${expiredDl.statusCode}`,
  );

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(24)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});