#!/usr/bin/env node
/**
 * 下载验收（SP0-10）：Range / ETag / If-None-Match / If-Range / 416 / 流式 200。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：node tool/check/download-smoke.js
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
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-dl-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'sub'), { recursive: true });

  const SIZE = 1024 * 1024;
  const content = Buffer.alloc(SIZE);
  for (let i = 0; i < SIZE; i++) content[i] = i % 251;
  fs.writeFileSync(path.join(filesRoot, 'big.bin'), content);

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'download-smoke-secret-0123456789';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['files:read'] },
  });
  const auth = { authorization: 'Bearer ' + tokenRes.json().token };
  // 路径 ACL 默认拒绝（用户 2026-11-11）：没授权目录的账号连文件根都列不出来。
  // 本用例验的不是授权，所以显式把文件根授给这个测试账号。
  await k.config.set('accessPolicy.u1', {
    apps: null,
    paths: [{ path: '/', actions: ['view', 'download', 'update', 'delete', 'upload'] }],
  });


  const url = (p) => '/api/v1/files/download?path=' + encodeURIComponent(p);

  // 1. 无 token → 401
  let r = await app.inject({ method: 'GET', url: url('big.bin') });
  check('no_token', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 全量 200 + 头齐全 + 内容一致
  r = await app.inject({ method: 'GET', url: url('big.bin'), headers: auth });
  const etag = r.headers.etag;
  check(
    'full_200',
    r.statusCode === 200 &&
      Number(r.headers['content-length']) === SIZE &&
      r.headers['accept-ranges'] === 'bytes' &&
      !!etag &&
      Buffer.compare(r.rawPayload, content) === 0,
    `status=${r.statusCode} len=${r.headers['content-length']} etag=${etag}`,
  );

  // 3. If-None-Match → 304
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ 'if-none-match': etag }, auth),
  });
  check('etag_304', r.statusCode === 304 && r.rawPayload.length === 0, 'status=' + r.statusCode);

  // 4. Range 首段
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ range: 'bytes=0-99' }, auth),
  });
  check(
    'range_head',
    r.statusCode === 206 &&
      r.headers['content-range'] === `bytes 0-99/${SIZE}` &&
      Buffer.compare(r.rawPayload, content.subarray(0, 100)) === 0,
    `status=${r.statusCode} cr=${r.headers['content-range']}`,
  );

  // 5. Range 开放尾段
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ range: `bytes=${SIZE - 100}-` }, auth),
  });
  check(
    'range_open',
    r.statusCode === 206 && Buffer.compare(r.rawPayload, content.subarray(SIZE - 100)) === 0,
    `status=${r.statusCode} len=${r.rawPayload.length}`,
  );

  // 6. Range 后缀
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ range: 'bytes=-100' }, auth),
  });
  check(
    'range_suffix',
    r.statusCode === 206 && Buffer.compare(r.rawPayload, content.subarray(SIZE - 100)) === 0,
    `status=${r.statusCode} len=${r.rawPayload.length}`,
  );

  // 7. 越界 → 416
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ range: `bytes=${SIZE}-` }, auth),
  });
  check(
    'range_416',
    r.statusCode === 416 && r.headers['content-range'] === `bytes */${SIZE}`,
    `status=${r.statusCode} cr=${r.headers['content-range']}`,
  );

  // 8. 多段 Range 语法 → 忽略，200 全量
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ range: 'bytes=0-1,5-6' }, auth),
  });
  check(
    'range_multi_ignored',
    r.statusCode === 200 && r.rawPayload.length === SIZE,
    'status=' + r.statusCode,
  );

  // 9. If-Range 不匹配 → 忽略 Range，200 全量
  r = await app.inject({
    method: 'GET',
    url: url('big.bin'),
    headers: Object.assign({ range: 'bytes=0-99', 'if-range': '"stale-etag"' }, auth),
  });
  check(
    'if_range_mismatch',
    r.statusCode === 200 && r.rawPayload.length === SIZE,
    'status=' + r.statusCode,
  );

  // 10. 目录 → 400
  r = await app.inject({ method: 'GET', url: url('sub'), headers: auth });
  check('dir_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 11. 越界 → 403
  r = await app.inject({ method: 'GET', url: url('../../etc/passwd'), headers: auth });
  check('escape_403', r.statusCode === 403, 'status=' + r.statusCode);

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
