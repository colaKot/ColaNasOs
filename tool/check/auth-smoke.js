#!/usr/bin/env node
/**
 * SP3-01 验收：登录 / TOTP 2FA / 子账号 / IP 黑名单规则。
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/auth-smoke.js
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
const { sql } = require('kysely');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';
const { b32decode, totpAt, isBlocked } = require(path.join(root, 'dist', 'src', 'modules', 'auth', 'index.js'));

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-auth-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  // ---- 纯函数：IP 规则 ----
  check('ip_exact', isBlocked('1.2.3.4', ['1.2.3.4']) === true && isBlocked('1.2.3.5', ['1.2.3.4']) === false, 'exact');
  check(
    'ip_cidr',
    isBlocked('10.1.2.3', ['10.0.0.0/8']) === true && isBlocked('11.1.2.3', ['10.0.0.0/8']) === false,
    'cidr 10/8',
  );
  check('ip_invalid', isBlocked('not-an-ip', ['10.0.0.0/8']) === false, 'invalid input');

  const dev = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'admin', scopes: ['*'] },
  });
  const admin = { authorization: 'Bearer ' + (dev.json().token || '') };

  // ---- 子账号 ----
  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/create',
    headers: admin,
    payload: { username: 'alice', password: 'alice-pass', scopes: ['files:read'] },
  });
  const alice = r.json();
  check('user_create', r.statusCode === 200 && alice.id && alice.username === 'alice', JSON.stringify(alice).slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/create',
    headers: admin,
    payload: { username: 'alice', password: 'x123456' },
  });
  check('user_duplicate_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/accounts/users', headers: admin });
  check('user_list', r.statusCode === 200 && r.json().items.length === 1, 'items=' + r.json().items.length);

  // ---- 登录 ----
  r = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 'alice', password: 'alice-pass' } });
  const login = r.json();
  check('login_ok', r.statusCode === 200 && login.token && login.scopes.includes('files:read'), 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 'alice', password: 'wrong' } });
  check('login_bad_password', r.statusCode === 401, 'status=' + r.statusCode);

  // ---- 2FA ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/2fa/setup',
    headers: admin,
    payload: { id: alice.id },
  });
  const setup = r.json();
  check(
    'totp_setup',
    r.statusCode === 200 && setup.secret && setup.uri.startsWith('otpauth://totp/'),
    (setup.uri || '').slice(0, 40),
  );

  const nowSec = Date.now() / 1000;
  const goodCode = totpAt(b32decode(setup.secret), nowSec);
  const badCode = goodCode === '000000' ? '111111' : '000000';

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/2fa/enable',
    headers: admin,
    payload: { id: alice.id, code: badCode },
  });
  check('totp_enable_rejects_bad', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/2fa/enable',
    headers: admin,
    payload: { id: alice.id, code: goodCode },
  });
  check('totp_enable_ok', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 'alice', password: 'alice-pass' } });
  check('login_requires_totp', r.statusCode === 401 && r.json().error === 'totp_required', 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    payload: { username: 'alice', password: 'alice-pass', totp: badCode },
  });
  check('login_bad_totp', r.statusCode === 401 && r.json().error === 'totp_invalid', 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    payload: { username: 'alice', password: 'alice-pass', totp: totpAt(b32decode(setup.secret), Date.now() / 1000) },
  });
  check('login_with_totp', r.statusCode === 200 && r.json().token, 'status=' + r.statusCode);

  // ---- 2FA secret 落库形态 ----
  const readTotpSecret = async () =>
    (await sql`select totp_secret from auth_users where id = ${alice.id}`.execute(k.db)).rows[0].totp_secret;

  let storedSecret = await readTotpSecret();
  check(
    'totp_secret_sealed',
    typeof storedSecret === 'string' && storedSecret.startsWith('v1:') && !storedSecret.includes(setup.secret),
    String(storedSecret || '').slice(0, 24),
  );

  // 旧版本数据（明文 secret）仍能登录；启用接口会把明文回写成密文
  await sql`update auth_users set totp_secret = ${setup.secret} where id = ${alice.id}`.execute(k.db);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    payload: { username: 'alice', password: 'alice-pass', totp: totpAt(b32decode(setup.secret), Date.now() / 1000) },
  });
  check('totp_legacy_plaintext_login', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/2fa/enable',
    headers: admin,
    payload: { id: alice.id, code: totpAt(b32decode(setup.secret), Date.now() / 1000) },
  });
  storedSecret = await readTotpSecret();
  check(
    'totp_legacy_migrated',
    r.statusCode === 200 && String(storedSecret).startsWith('v1:') && !String(storedSecret).includes(setup.secret),
    'status=' + r.statusCode,
  );

  // ---- 禁用 ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/disable',
    headers: admin,
    payload: { id: alice.id, disabled: true },
  });
  const afterDisable = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    payload: { username: 'alice', password: 'alice-pass', totp: totpAt(b32decode(setup.secret), Date.now() / 1000) },
  });
  check('disabled_login_401', r.statusCode === 200 && afterDisable.statusCode === 401, 'login=' + afterDisable.statusCode);

  // ---- IP 规则 API ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/security/ip/add',
    headers: admin,
    payload: { rule: '10.0.0.0/8' },
  });
  const addOk = r.statusCode === 200;
  r = await app.inject({ method: 'GET', url: '/api/v1/security/ip/list', headers: admin });
  const list = r.json();
  check('ip_api_add_list', addOk && list.items.some((x) => x.rule === '10.0.0.0/8'), 'items=' + list.items.length);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/security/ip/add',
    headers: admin,
    payload: { rule: 'not a rule' },
  });
  check('ip_api_invalid_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/security/ip/remove',
    headers: admin,
    payload: { rule: '10.0.0.0/8' },
  });
  const afterRemove = await app.inject({ method: 'GET', url: '/api/v1/security/ip/list', headers: admin });
  check('ip_api_remove', r.statusCode === 200 && afterRemove.json().items.length === 0, 'items=' + afterRemove.json().items.length);

  // ---- 子账号双层授权：应用白名单 + 路径 ACL ----
  const dev2 = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: alice.id, scopes: ['files:read', 'files:write', 'photo:read'] },
  });
  const aliceToken = { authorization: 'Bearer ' + (dev2.json().token || '') };

  r = await app.inject({ method: 'GET', url: '/api/v1/files/list?path=/', headers: aliceToken });
  check('policy_unset_allows', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/policy',
    headers: admin,
    payload: { uid: alice.id, allowedApps: ['photo'], paths: [] },
  });
  check('policy_set_apps', r.statusCode === 200 && r.json().allowedApps.join() === 'photo', 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/files/list?path=/', headers: aliceToken });
  check('policy_app_blocks_403', r.statusCode === 403 && r.json().error === 'appForbidden', 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/timeline', headers: aliceToken });
  check('policy_app_allows', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/policy',
    headers: admin,
    payload: {
      uid: alice.id,
      allowedApps: null,
      paths: [{ path: '/pub', access: 'ro' }],
    },
  });
  check('policy_set_paths', r.statusCode === 200 && r.json().paths.length === 1, 'status=' + r.statusCode);

  // 路径 ACL 用的是真实目录，先建出来（否则 404 会掩盖「读被放行」的判定）
  const { filesRoot } = require(path.join(root, 'dist', 'src', 'modules', 'files', 'fs-root'));
  fs.mkdirSync(path.join(filesRoot(), 'pub'), { recursive: true });

  r = await app.inject({ method: 'GET', url: '/api/v1/files/list?path=/pub', headers: aliceToken });
  check('policy_path_ro_read', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/files/list?path=/secret', headers: aliceToken });
  check('policy_path_denied_403', r.statusCode === 403 && r.json().error === 'pathForbidden', 'status=' + r.statusCode);

  // 错误响应形态（docs/03 §9.2）：结构化上下文收进 details，并带 traceId
  const deniedBody = r.json();
  check(
    'error_details_structured',
    Boolean(deniedBody.details) && deniedBody.details.need === 'read' && deniedBody.details.path === '/secret',
    'details=' + JSON.stringify(deniedBody.details),
  );
  check(
    'error_trace_id',
    typeof deniedBody.traceId === 'string' && deniedBody.traceId.length > 0,
    'traceId=' + deniedBody.traceId,
  );
  check(
    'error_code_alias',
    deniedBody.code === 'pathForbidden' && deniedBody.error === 'pathForbidden',
    'code=' + deniedBody.code,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/policy',
    headers: admin,
    payload: { uid: alice.id, paths: [{ path: '/a/../../etc', access: 'rw' }] },
  });
  check('policy_path_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/accounts/users/policy?uid=' + alice.id, headers: admin });
  check('policy_get', r.statusCode === 200 && r.json().uid === alice.id, 'status=' + r.statusCode);

  // ---- U-C：编辑 / 删除用户 ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/create',
    headers: admin,
    payload: {
      username: 'bob',
      password: 'bob-pass',
      scopes: ['files:read'],
      phone: '13800000000',
      remark: 'backup account',
    },
  });
  const bob = r.json();
  check(
    'user_create_profile',
    r.statusCode === 200 && bob.phone === '13800000000' && bob.remark === 'backup account',
    JSON.stringify({ phone: bob.phone, remark: bob.remark }),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/update',
    headers: admin,
    payload: { id: bob.id, username: 'bob2', phone: '13900000000', remark: 'renamed' },
  });
  check(
    'user_update_profile',
    r.statusCode === 200 &&
      r.json().username === 'bob2' &&
      r.json().phone === '13900000000' &&
      r.json().remark === 'renamed',
    JSON.stringify({ u: r.json().username, p: r.json().phone }),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/update',
    headers: admin,
    payload: { id: bob.id, password: 'bob-new-pass' },
  });
  check('user_update_password', r.statusCode === 200, 'status=' + r.statusCode);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    payload: { username: 'bob2', password: 'bob-new-pass' },
  });
  check('user_update_password_login', r.statusCode === 200 && r.json().token, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/update',
    headers: admin,
    payload: { id: bob.id, username: 'alice' },
  });
  check('user_update_duplicate_400', r.statusCode === 400, 'status=' + r.statusCode);

  // ---- U-F：登录记录 / 操作日志 ----
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/accounts/users/login-records?uid=' + alice.id + '&limit=100',
    headers: admin,
  });
  const loginEvents = r.json().items || [];
  check(
    'login_records',
    r.statusCode === 200 &&
      loginEvents.length >= 3 &&
      loginEvents.some((e) => e.type === 'login') &&
      loginEvents.some((e) => e.type === 'login_failed'),
    'items=' + loginEvents.length,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/accounts/users/audit-logs?uid=' + alice.id + '&limit=100',
    headers: admin,
  });
  const aliceAudit = r.json().items || [];
  check(
    'audit_logs_alice',
    r.statusCode === 200 &&
      aliceAudit.some((e) => e.type === 'user_create') &&
      aliceAudit.some((e) => e.type === '2fa_enable'),
    'items=' + aliceAudit.length,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/accounts/users/audit-logs?uid=' + bob.id + '&limit=100',
    headers: admin,
  });
  check(
    'audit_logs_bob_update',
    r.statusCode === 200 && (r.json().items || []).some((e) => e.type === 'user_update'),
    'items=' + (r.json().items || []).length,
  );

  // ---- 删除用户 ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/delete',
    headers: admin,
    payload: { id: bob.id },
  });
  check('user_delete', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);
  r = await app.inject({ method: 'GET', url: '/api/v1/accounts/users', headers: admin });
  check(
    'user_delete_gone',
    !(r.json().items || []).some((u) => u.id === bob.id),
    'items=' + (r.json().items || []).length,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/create',
    headers: admin,
    payload: { username: 'admin2', password: 'admin2-pass', scopes: ['*'] },
  });
  const admin2 = r.json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/delete',
    headers: admin,
    payload: { id: admin2.id },
  });
  check('user_delete_last_admin_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/delete',
    headers: admin,
    payload: { id: 'nope' },
  });
  check('user_delete_missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  // ---- U-H：长期访问令牌（Scoped Token） ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: admin2.id, scopes: ['user:read', 'user:write', 'files:read'] },
  });
  const admin2Bearer = { authorization: 'Bearer ' + (r.json().token || '') };

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/tokens',
    headers: admin2Bearer,
    payload: { name: 'cli', scopes: ['files:read'], expiresInDays: 30 },
  });
  const createdToken = r.json();
  check(
    'api_token_create',
    r.statusCode === 200 &&
      String(createdToken.token || '').startsWith('cnt_') &&
      createdToken.item?.scopes?.includes('files:read'),
    'status=' + r.statusCode,
  );

  const tokenHeaders = { authorization: 'Bearer ' + (createdToken.token || '') };
  r = await app.inject({ method: 'GET', url: '/api/v1/files/list?path=/', headers: tokenHeaders });
  check('api_token_works', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/create',
    headers: tokenHeaders,
    payload: { username: 'scoped', password: 'scoped-pass', scopes: ['files:read'] },
  });
  check('api_token_scope_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/accounts/tokens', headers: admin2Bearer });
  const tokenList = r.json().items || [];
  check(
    'api_token_list_no_secret',
    r.statusCode === 200 &&
      tokenList.some((x) => x.id === createdToken.item.id) &&
      !JSON.stringify(tokenList).includes(createdToken.token),
    'items=' + tokenList.length,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/tokens/revoke',
    headers: admin2Bearer,
    payload: { id: createdToken.item.id },
  });
  check('api_token_revoke', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/files/list?path=/', headers: tokenHeaders });
  check('api_token_revoked_401', r.statusCode === 401, 'status=' + r.statusCode);

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