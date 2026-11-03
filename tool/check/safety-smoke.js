#!/usr/bin/env node
/**
 * SP3-09 备份 / 加密空间验收：
 *   备份 → 清单校验 → 恢复一致 → 篡改检测
 *   加密空间 → 建库 → 写入 → 读回一致 → 错误密码 403 → 列表 → 删除
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/safety-smoke.js
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
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-safety-'));
  const filesRoot = path.join(dataDir, 'files');
  const src = path.join(filesRoot, 'src');
  fs.mkdirSync(path.join(src, 'sub'), { recursive: true });
  fs.writeFileSync(path.join(src, 'a.txt'), 'alpha');
  fs.writeFileSync(path.join(src, 'b.txt'), 'beta');
  fs.writeFileSync(path.join(src, 'sub', 'c.txt'), 'gamma');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['backup:read', 'backup:write', 'vault:read', 'vault:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };

  // ---------- 备份 ----------
  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/backup/run',
    headers: bearer,
    payload: { source: '/src', name: 'snap1' },
  });
  const backup = r.json();
  check('backup_run', r.statusCode === 200 && backup.files === 3 && backup.bytes === 14, JSON.stringify({ files: backup.files, bytes: backup.bytes }));

  r = await app.inject({ method: 'GET', url: '/api/v1/backup/list', headers: bearer });
  const list = r.json();
  check('backup_list', r.statusCode === 200 && list.items.some((x) => x.id === 'snap1'), 'items=' + (list.items || []).length);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/backup/restore',
    headers: bearer,
    payload: { id: 'snap1', target: '/restored' },
  });
  const restored = r.json();
  const restoredOk =
    r.statusCode === 200 &&
    restored.restored === 3 &&
    fs.readFileSync(path.join(filesRoot, 'restored', 'sub', 'c.txt'), 'utf8') === 'gamma';
  check('backup_restore', restoredOk, JSON.stringify(restored));

  // 重复同名备份被拒绝
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/backup/run',
    headers: bearer,
    payload: { source: '/src', name: 'snap1' },
  });
  check('backup_no_overwrite', r.statusCode === 400, 'status=' + r.statusCode);

  // 篡改后再恢复 → 摘要不符
  fs.writeFileSync(path.join(backup.dir, 'data', 'a.txt'), 'tampered', 'utf8');
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/backup/restore',
    headers: bearer,
    payload: { id: 'snap1', target: '/restored2' },
  });
  check('backup_tamper_detected', r.statusCode === 400 && r.json().error === 'corrupted', 'status=' + r.statusCode);

  // ---------- 加密空间 ----------
  const PWD = 's3cret123';
  const plain = 'hello-vault-内容';
  const b64 = Buffer.from(plain, 'utf8').toString('base64');

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/create',
    headers: bearer,
    payload: { id: 'vault1', password: PWD },
  });
  check('vault_create', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/put',
    headers: bearer,
    payload: { id: 'vault1', path: '/docs/note.txt', data: b64, password: PWD },
  });
  const putOk = r.statusCode === 200;

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/get',
    headers: bearer,
    payload: { id: 'vault1', path: '/docs/note.txt', password: PWD },
  });
  const got = r.json();
  check(
    'vault_roundtrip',
    putOk && r.statusCode === 200 && Buffer.from(got.data, 'base64').toString('utf8') === plain,
    'status=' + r.statusCode + ' size=' + got.size,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/get',
    headers: bearer,
    payload: { id: 'vault1', path: '/docs/note.txt', password: 'wrong-password' },
  });
  check('vault_wrong_password', r.statusCode === 403, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/list',
    headers: bearer,
    payload: { id: 'vault1', password: PWD },
  });
  const vlist = r.json();
  check('vault_list', r.statusCode === 200 && vlist.items.length === 1 && vlist.items[0].path === '/docs/note.txt', JSON.stringify(vlist));

  // 密文不含明文
  const cipherFile = fs.readdirSync(path.join(dataDir, 'vaults', 'vault1'))[0];
  const cipher = fs.readFileSync(path.join(dataDir, 'vaults', 'vault1', cipherFile));
  check('vault_ciphertext', !cipher.includes(Buffer.from(plain, 'utf8')), 'bytes=' + cipher.length);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/delete',
    headers: bearer,
    payload: { id: 'vault1', path: '/docs/note.txt', password: PWD },
  });
  const del = r.json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/get',
    headers: bearer,
    payload: { id: 'vault1', path: '/docs/note.txt', password: PWD },
  });
  check('vault_delete', del.ok === true && r.statusCode === 404, 'get=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/vault/list',
    headers: bearer,
    payload: { id: 'nope', password: PWD },
  });
  check('vault_missing', r.statusCode === 403, 'status=' + r.statusCode);

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