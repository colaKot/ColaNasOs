#!/usr/bin/env node
/**
 * 两项补充能力验收：discover 离线刮削 / 受限命令执行。
 *
 * 用法：node tool/check/extras-smoke.js（Electron 自举）
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(
    process.cwd(),
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
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

function findFfmpeg() {
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const env = process.env.COLANAS_FFMPEG;
  if (env && fs.existsSync(env)) return env;
  for (const c of [
    path.join(root, 'vendor', 'ffmpeg', exe),
    path.join(root, 'vendor', 'ffmpeg', 'bin', exe),
  ]) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-extras-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'media'), { recursive: true });

  const ffmpeg = findFfmpeg();
  if (ffmpeg) {
    process.env.COLANAS_FFMPEG = ffmpeg;
    spawnSync(ffmpeg, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=160x120:rate=24',
      '-t',
      '1',
      '-pix_fmt',
      'yuv420p',
      path.join(filesRoot, 'media', 'a.mp4'),
    ]);
  } else {
    fs.writeFileSync(path.join(filesRoot, 'media', 'a.mp4'), Buffer.alloc(1024));
  }
  fs.writeFileSync(
    path.join(filesRoot, 'media', 'a.nfo'),
    `<movie><title>Demo Movie</title><plot>一把钥匙引发的故事。</plot><year>2021</year><genre>科幻</genre><rating>7.8</rating></movie>`,
  );

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;
  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const inject = (method, url, token, payload) =>
    app.inject({
      method,
      url,
      headers: token ? { authorization: 'Bearer ' + token } : undefined,
      payload,
    });
  const devToken = async (scopes, sub = 'admin') =>
    (await inject('POST', '/api/v1/auth/dev-token', '', { sub, scopes })).json().token;

  const all = [
    'discover:read',
    'discover:write',
    'system:read',
    'system:write',
    'video:read',
    'video:write',
    'files:read',
    'files:write',
  ];
  const admin = await devToken(all, 'admin');
  const reader = await devToken(['discover:read', 'system:read'], 'reader');

  // ---- discover：NFO 离线刮削 ----
  let r = await inject('POST', '/api/v1/discover/scrape', '', {});
  check('scrape_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/discover/scrape', reader, {});
  check('scrape_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  await inject('POST', '/api/v1/video/libraries', admin, { name: 'media', path: 'media' });
  const scan = await inject('POST', '/api/v1/video/scan', admin, {});
  check(
    'video_scan',
    scan.statusCode === 200 && (scan.json().added || 0) >= 1,
    'added=' + (scan.json().added || 0),
  );

  r = await inject('POST', '/api/v1/discover/scrape', admin, {});
  check(
    'scrape_nfo',
    r.statusCode === 200 && r.json().scraped >= 1,
    `scanned=${r.statusCode === 200 ? r.json().scanned : '?'} scraped=${r.statusCode === 200 ? r.json().scraped : '?'}`,
  );

  r = await inject('GET', '/api/v1/discover/meta', admin);
  const metas = r.statusCode === 200 ? r.json().items : [];
  check(
    'meta_fields',
    metas.length >= 1 &&
      metas[0].year === 2021 &&
      metas[0].genre === '科幻' &&
      Math.abs((metas[0].rating || 0) - 7.8) < 0.01 &&
      (metas[0].plot || '').includes('钥匙'),
    JSON.stringify(metas[0] || {}).slice(0, 120),
  );

  // ---- 受限命令执行 ----
  r = await inject('POST', '/api/v1/system/exec', '', { command: 'pwd' });
  check('exec_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/system/exec', reader, { command: 'pwd' });
  check('exec_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/system/exec', admin, { command: 'rm' });
  check('exec_not_allowed_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/system/exec', admin, { command: 'pwd', args: ['../etc'] });
  check('exec_args_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/system/exec', admin, { command: 'whoami' });
  check(
    'exec_ok',
    r.statusCode === 200 && r.json().code === 0 && typeof r.json().stdout === 'string',
    `code=${r.statusCode === 200 ? r.json().code : '?'} out=${String(r.statusCode === 200 ? r.json().stdout : '').slice(0, 40)}`,
  );

  await app.close();
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
