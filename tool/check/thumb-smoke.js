#!/usr/bin/env node
/**
 * files/thumb 验收（缩略图接口）：
 *   鉴权（匿名 401 / 缺 scope 403）→ 生成 200 且宽度符合 → 文件缓存命中与 ETag 304
 *   → size 钳制（32..2048）→ 源文件变更后 ETag 变 → 越界 403 / 缺失 404 / 非图片 400 / 目录 400
 *
 * 走真实 media sidecar（内核按需拉起），因此需要 ffmpeg；找不到时打印 SKIP 并以 0 退出。
 * 用法：node tool/check/thumb-smoke.js
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
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

process.chdir(root);

const FFMPEG_EXE = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';

function probeFfmpeg() {
  const vendor = path.join(root, 'vendor', 'ffmpeg');
  const cands = [
    process.env.COLANAS_FFMPEG,
    path.join(vendor, FFMPEG_EXE),
    path.join(vendor, 'bin', FFMPEG_EXE),
    FFMPEG_EXE,
  ];
  for (const c of cands) {
    if (!c) continue;
    const r = spawnSync(c, ['-version'], { encoding: 'utf8', windowsHide: true });
    if (r.status === 0 && /ffmpeg version/i.test(r.stdout || '')) return c;
  }
  return null;
}

const ffmpeg = probeFfmpeg();
if (!ffmpeg) {
  console.log('[SKIP] 缩略图验收需要 ffmpeg（设置 COLANAS_FFMPEG 或 npm run ffmpeg:fetch）');
  process.exit(0);
}

function ff(args) {
  const r = spawnSync(ffmpeg, args, { encoding: 'utf8', windowsHide: true });
  if (r.status !== 0) throw new Error('ffmpeg 执行失败: ' + String(r.stderr || '').slice(-300));
}

/** 从 JPEG 读实际宽度：ffmpeg -i 的 stderr 里取 `WxH` */
function widthOf(file) {
  const r = spawnSync(ffmpeg, ['-hide_banner', '-i', file], {
    encoding: 'utf8',
    windowsHide: true,
  });
  const m = /(\d{2,5})x(\d{2,5})/.exec(r.stderr || '');
  return m ? Number(m[1]) : 0;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-thumb-'));
  const filesRoot = path.join(dataDir, 'files');
  const photos = path.join(filesRoot, 'photos');
  fs.mkdirSync(photos, { recursive: true });

  const src = path.join(photos, 'wide.jpg');
  ff([
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=1920x1080:rate=1',
    '-frames:v',
    '1',
    '-q:v',
    '2',
    src,
  ]);
  fs.writeFileSync(path.join(photos, 'notes.txt'), 'not an image');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  process.env.COLANAS_FFMPEG = ffmpeg;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const mkToken = async (sub, scopes) => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/v1/auth/dev-token',
      payload: { sub, scopes },
    });
    return { authorization: 'Bearer ' + res.json().token };
  };

  const reader = await mkToken('u1', ['files:read']);
  const outsider = await mkToken('u2', ['photo:read']);

  const get = (query, headers, extra) =>
    app.inject({
      method: 'GET',
      url: `/api/v1/files/thumb?${query}`,
      headers: headers || reader,
      ...(extra || {}),
    });

  // 1. 鉴权
  let r = await get('path=%2Fphotos%2Fwide.jpg&size=256', {});
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await get('path=%2Fphotos%2Fwide.jpg&size=256', outsider);
  check('missing_scope_403', r.statusCode === 403, 'status=' + r.statusCode);

  // 2. 生成
  r = await get('path=%2Fphotos%2Fwide.jpg&size=256');
  const etag1 = r.headers.etag;
  const raw = r.rawPayload || Buffer.from([]);
  fs.writeFileSync(path.join(dataDir, 'out256.jpg'), raw);
  check(
    'thumb_256_ok',
    r.statusCode === 200 &&
      /image\/jpeg/.test(String(r.headers['content-type'])) &&
      widthOf(path.join(dataDir, 'out256.jpg')) === 256,
    `status=${r.statusCode} type=${r.headers['content-type']} w=${widthOf(path.join(dataDir, 'out256.jpg'))} bytes=${raw.length}`,
  );

  // 3. 缓存：同一 key 只落一个文件，第二次带 If-None-Match 走 304
  const thumbsDir = path.join(dataDir, 'thumbs');
  const cached = fs.existsSync(thumbsDir) ? fs.readdirSync(thumbsDir) : [];
  check('cache_single_file', cached.length === 1, 'files=' + JSON.stringify(cached));

  r = await get('path=%2Fphotos%2Fwide.jpg&size=256', {
    ...reader,
    'if-none-match': String(etag1),
  });
  check('etag_304', r.statusCode === 304, 'status=' + r.statusCode + ' etag=' + etag1);

  // 4. 自定义尺寸：128 → 独立缓存条目；越界尺寸按契约 400（32..2048）
  r = await get('path=%2Fphotos%2Fwide.jpg&size=128');
  fs.writeFileSync(path.join(dataDir, 'out128.jpg'), r.rawPayload);
  const mid = widthOf(path.join(dataDir, 'out128.jpg'));
  const keys = fs.readdirSync(thumbsDir);
  check(
    'thumb_128_ok',
    r.statusCode === 200 && mid === 128 && keys.length === 2,
    `status=${r.statusCode} w=${mid} cached=${keys.length}`,
  );

  r = await get('path=%2Fphotos%2Fwide.jpg&size=4096');
  check('size_too_large_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await get('path=%2Fphotos%2Fwide.jpg&size=10');
  check('size_too_small_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 5. 默认尺寸（不带 size）= 256，复用同一缓存条目
  r = await get('path=%2Fphotos%2Fwide.jpg');
  check(
    'default_size_256',
    r.statusCode === 200 && String(r.headers.etag) === String(etag1),
    `status=${r.statusCode} etag=${r.headers.etag}`,
  );

  // 6. 源文件变更 → ETag 变，重新生成
  ff([
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=800x600:rate=1',
    '-frames:v',
    '1',
    '-q:v',
    '2',
    src,
  ]);
  r = await get('path=%2Fphotos%2Fwide.jpg&size=256');
  check(
    'etag_changes_on_update',
    r.statusCode === 200 && String(r.headers.etag) !== String(etag1),
    `old=${etag1} new=${r.headers.etag}`,
  );

  // 7. 异常路径
  r = await get('path=..%2Fsecret.jpg');
  check('outside_root_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await get('path=%2Fphotos%2Fmissing.jpg');
  check('missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await get('path=%2Fphotos%2Fnotes.txt');
  check('non_image_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await get('path=%2Fphotos');
  check('directory_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await get('path=%2Fphotos%2Fwide.jpg&size=abc');
  check('bad_size_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 8. 关闭内核必须收掉 sidecar 子进程
  const pid = k.media ? k.media.pid : undefined;
  await app.close();
  let pidAlive = false;
  if (pid) {
    try {
      process.kill(pid, 0);
      pidAlive = true;
    } catch {
      pidAlive = false;
    }
  }
  check('sidecar_stopped_on_close', pid ? !pidAlive : true, `pid=${pid} alive=${pidAlive}`);

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(28)} ${x.detail}`);
  }
  console.log(`\n[thumb] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();
