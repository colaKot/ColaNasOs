#!/usr/bin/env node
/**
 * 分片上传验收（SP0-09）：
 * check（秒传/断点）、chunk（落片）、merge（拼接/校验/幂等）、缺片 409、越界 403、hash 422。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：node tool/check/upload-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const crypto = require('node:crypto');
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

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-upload-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(filesRoot, { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'upload-smoke-secret-0123456789';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenFor = async (scopes) => {
    const r = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub: 'u1', scopes },
    });
    return { authorization: 'Bearer ' + r.json().token };
  };

  const readOnly = await tokenFor(['files:read']);
  // 路径 ACL 默认拒绝（用户 2026-11-11）：没授权目录的账号连文件根都列不出来。
  // 本用例验的不是授权，所以显式把文件根授给这个测试账号。
  await k.config.set('accessPolicy.u1', {
    apps: null,
    paths: [{ path: '/', actions: ['view', 'download', 'update', 'delete', 'upload'] }],
  });

  const full = await tokenFor(['files:read', 'files:write']);

  const content = Buffer.from('0123456789abcdef'.repeat(4096)); // 64 KiB
  const parts = [
    content.subarray(0, 20000),
    content.subarray(20000, 40000),
    content.subarray(40000),
  ];
  const hash = sha256(content);

  // 1. 只有 files:read 不能上传 → 403
  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: readOnly,
    payload: { path: 'up/data.bin' },
  });
  check('write_scope_denied', r.statusCode === 403, 'status=' + r.statusCode);

  // 2. 首次 check：不存在，无已传分片
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: full,
    payload: { path: 'up/data.bin', size: content.length },
  });
  const c0 = r.json();
  check(
    'check_new',
    r.statusCode === 200 && c0.exists === false && c0.uploaded.length === 0,
    JSON.stringify(c0),
  );

  // 3. 上传分片 0
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/chunk?path=up/data.bin&index=0&total=3',
    headers: Object.assign({ 'content-type': 'application/octet-stream' }, full),
    payload: parts[0],
  });
  check('chunk_0', r.statusCode === 200 && r.json().index === 0, 'status=' + r.statusCode);

  // 4. 断点续传：再 check 应看到 [0]
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: full,
    payload: { path: 'up/data.bin', size: content.length },
  });
  const c1 = r.json();
  check('resume_uploaded', JSON.stringify(c1.uploaded) === '[0]', JSON.stringify(c1.uploaded));

  // 5. 补齐剩余分片
  const rest = [];
  for (let i = 1; i <= 2; i++) {
    rest.push(
      await app.inject({
        method: 'POST',
        url: `/api/v1/files/chunk?path=up/data.bin&index=${i}&total=3`,
        headers: Object.assign({ 'content-type': 'application/octet-stream' }, full),
        payload: parts[i],
      }),
    );
  }
  check(
    'chunk_rest',
    rest.every((x) => x.statusCode === 200),
    rest.map((x) => x.statusCode).join(','),
  );

  // 6. 合并 → 内容与 hash 一致
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/data.bin', total: 3, size: content.length, hash },
  });
  const merged = r.statusCode === 200 ? r.json() : {};
  const absFile = path.join(filesRoot, 'up', 'data.bin');
  const onDisk = fs.existsSync(absFile) ? fs.readFileSync(absFile) : Buffer.alloc(0);
  check(
    'merge',
    r.statusCode === 200 && merged.skipped === false && Buffer.compare(onDisk, content) === 0,
    `status=${r.statusCode} size=${merged.size} match=${Buffer.compare(onDisk, content) === 0}`,
  );

  // 6b. 同步业务依赖「上传回写 mtime」：merge 带 mtimeMs 后，落盘文件时间必须对齐
  const wantMtime = 1_700_000_000_000;
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/data.bin', total: 3, size: content.length, hash, mtimeMs: wantMtime },
  });
  const gotMtime = fs.existsSync(absFile) ? Math.round(fs.statSync(absFile).mtimeMs) : 0;
  check(
    'merge_mtime_aligned',
    r.statusCode === 200 && Math.abs(gotMtime - wantMtime) <= 2000,
    `status=${r.statusCode} mtime=${gotMtime} want=${wantMtime}`,
  );

  // 6c. 0 字节文件：total=0 时直接落盘空文件（同步会带空文件）
  const emptyPath = path.join(filesRoot, 'up', 'empty.bin');
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/empty.bin', total: 0, size: 0 },
  });
  check(
    'empty_file_upload',
    r.statusCode === 200 && fs.existsSync(emptyPath) && fs.statSync(emptyPath).size === 0,
    `status=${r.statusCode}`,
  );
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/data.bin', total: 3, size: content.length, hash },
  });
  check(
    'merge_idempotent',
    r.statusCode === 200 && r.json().skipped === true,
    JSON.stringify(r.json()),
  );

  // 8. 缺片 → 409
  await app.inject({
    method: 'POST',
    url: '/api/v1/files/chunk?path=up/half.bin&index=0&total=2',
    headers: Object.assign({ 'content-type': 'application/octet-stream' }, full),
    payload: parts[0],
  });
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/half.bin', total: 2 },
  });
  check('missing_chunk', r.statusCode === 409, 'status=' + r.statusCode);

  // 9. 越界路径 → 403
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/check',
    headers: full,
    payload: { path: '../../etc/passwd' },
  });
  check('path_escape', r.statusCode === 403, 'status=' + r.statusCode);

  // 10. hash 不符 → 422，且不落盘
  for (let i = 0; i < 3; i++) {
    await app.inject({
      method: 'POST',
      url: `/api/v1/files/chunk?path=up/bad.bin&index=${i}&total=3`,
      headers: Object.assign({ 'content-type': 'application/octet-stream' }, full),
      payload: parts[i],
    });
  }
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/files/merge',
    headers: full,
    payload: { path: 'up/bad.bin', total: 3, hash: 'f'.repeat(64) },
  });
  check(
    'hash_mismatch',
    r.statusCode === 422 && !fs.existsSync(path.join(filesRoot, 'up', 'bad.bin')),
    'status=' + r.statusCode,
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
