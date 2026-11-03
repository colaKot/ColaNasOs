#!/usr/bin/env node
/**
 * 首次安装引导 + 开发令牌关闭 的验收（安全回归）：
 *   1. 空库里 `/auth/bootstrap` 报 `needsSetup: true`
 *   2. **未设 `COLANAS_DEV_TOKEN` 时 `/auth/dev-token` 必须 404**（旧实现默认就开放 `*` scope 令牌）
 *   3. 弱密码被拒；正常密码创建出 `*` scope 管理员
 *   4. 初始化后再次 bootstrap → 409（不会出现第二个管理员）
 *   5. 新管理员能登录、能建子账号
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

// 关键：显式清掉开发令牌开关，并保持「非 production」—— 复现旧实现会误开的环境
delete process.env.COLANAS_DEV_TOKEN;
process.env.NODE_ENV = 'development';
process.env.COLANAS_LOG_FILE = '0';

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

process.chdir(root);

let passed = 0;
let failed = 0;
const ok = (n, d) => {
  passed += 1;
  console.log('[OK]  ', n.padEnd(28), d === undefined ? '' : d);
};
const bad = (n, d) => {
  failed += 1;
  console.log('[FAIL]', n.padEnd(28), d);
};
const check = (n, c, d) => (c ? ok(n) : bad(n, d));

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-boot-'));
  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;

  // 1. 空库
  let r = await app.inject({ method: 'GET', url: '/api/v1/auth/bootstrap' });
  const status = r.json();
  check('needs_setup_on_empty', r.statusCode === 200 && status.needsSetup === true, JSON.stringify(status));

  // 2. dev-token 默认关闭（安全回归的核心断言）
  r = await app.inject({ method: 'POST', url: '/api/v1/auth/dev-token', payload: {} });
  check('dev_token_disabled_by_default', r.statusCode === 404, 'status=' + r.statusCode);

  // 3. 弱密码
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/bootstrap',
    payload: { username: 'admin', password: 'short' },
  });
  check('weak_password_rejected', r.statusCode === 400, 'status=' + r.statusCode);

  // 4. 创建管理员
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/bootstrap',
    payload: { username: 'admin', password: 'colanas123' },
  });
  const admin = r.json();
  check(
    'bootstrap_creates_admin',
    r.statusCode === 200 && Array.isArray(admin.scopes) && admin.scopes.includes('*'),
    JSON.stringify(admin).slice(0, 120),
  );

  // 5. 初始化后 bootstrap 关闭
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/bootstrap',
    payload: { username: 'evil', password: 'evilpass123' },
  });
  check('bootstrap_closed_after_init', r.statusCode === 409, 'status=' + r.statusCode);

  // 6. 状态翻转
  r = await app.inject({ method: 'GET', url: '/api/v1/auth/bootstrap' });
  check(
    'status_after_init',
    r.json().needsSetup === false && r.json().users === 1,
    JSON.stringify(r.json()),
  );

  // 7. 登录
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/login',
    payload: { username: 'admin', password: 'colanas123' },
  });
  check('login_after_bootstrap', r.statusCode === 200 && Boolean(r.json().token), 'status=' + r.statusCode);

  // 8. 管理员能建子账号（证明 `*` scope 真的生效）
  const bearer = { authorization: 'Bearer ' + r.json().token };
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/accounts/users/create',
    headers: bearer,
    payload: { username: 'bob', password: 'bobpass123', scopes: ['files:read'] },
  });
  check('admin_can_create_user', r.statusCode === 200, 'status=' + r.statusCode);

  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 日志句柄释放有延迟 */
  }

  console.log(`[summary] ${passed}/${passed + failed} passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});