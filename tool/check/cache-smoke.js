#!/usr/bin/env node
/**
 * 缓存命中统计验收（**只测量，不改策略**）：
 *   GET /api/v1/system/cache/stats 可读 → 初始为空 → 请求缩略图两次
 *   → files.thumb 计数器出现且总量 >= 2 → 命中率在 0~1 → 无 system:read 时 403
 *
 * 说明：缩略图依赖 ffmpeg / media sidecar。缺依赖时第一次请求返回 503，
 * 但计数器照样记录一次 miss —— 这正是「观测不依赖生成成功」的意义。
 * 依赖可用时会额外断言「第二次请求命中缓存」。
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

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

let passed = 0;
let failed = 0;
const ok = (n, d) => {
  passed += 1;
  console.log('[OK]  ', n.padEnd(26), d === undefined ? '' : d);
};
const bad = (n, d) => {
  failed += 1;
  console.log('[FAIL]', n.padEnd(26), d);
};
const check = (n, c, d) => (c ? ok(n) : bad(n, d));

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-cache-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(filesRoot, { recursive: true });
  // 1×1 PNG：能过扩展名白名单，内容是否可解码由 sidecar 决定（不可用时会 503）
  fs.writeFileSync(
    path.join(filesRoot, 'dot.png'),
    Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
      'base64',
    ),
  );

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'cache', scopes: ['*'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  // 1. 初始为空
  let r = await app.inject({ method: 'GET', url: '/api/v1/system/cache/stats', headers: bearer });
  check('stats_readable', r.statusCode === 200 && Array.isArray(r.json().items), 'status=' + r.statusCode);
  check('stats_empty_initially', (r.json().items || []).length === 0, JSON.stringify(r.json().items));

  // 2. 预置缩略图缓存文件 → 两次请求都应命中（不依赖 ffmpeg / media sidecar）
  const crypto = require('node:crypto');
  const fsRootMod = require(path.join(root, 'dist', 'src', 'modules', 'files', 'fs-root'));
  const { rel } = fsRootMod.relativeInRoot(fsRootMod.filesRoot(), '/dot.png');
  const srcStat = fs.statSync(path.join(filesRoot, 'dot.png'));
  const thumbSize = 64;
  const key = crypto
    .createHash('sha1')
    // 缓存 key 末位是抽帧位置 atSec：图片恒为 0，视频才是 posterSeekOf() 给的秒数。
    // 少了这一段，预置的缓存文件永远命中不了，用例会退化成「真的去跑 ffmpeg」。
    .update(`${rel}|${thumbSize}|${srcStat.size}|${Math.floor(srcStat.mtimeMs)}|0`)
    .digest('hex');
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
  fs.mkdirSync(path.join(dataDir, 'thumbs'), { recursive: true });
  fs.writeFileSync(path.join(dataDir, 'thumbs', `${key}.jpg`), jpeg);

  const thumbUrl = `/api/v1/files/thumb?path=/dot.png&size=${thumbSize}`;
  const first = await app.inject({ method: 'GET', url: thumbUrl, headers: bearer });
  const second = await app.inject({ method: 'GET', url: thumbUrl, headers: bearer });
  check('cached_thumb_served', first.statusCode === 200 && first.rawPayload.length === jpeg.length, 'status=' + first.statusCode);

  // 3. 计数器出现
  r = await app.inject({ method: 'GET', url: '/api/v1/system/cache/stats', headers: bearer });
  const items = r.json().items || [];
  const thumb = items.find((x) => x.name === 'files.thumb');
  check('counter_recorded', Boolean(thumb) && thumb.hits + thumb.misses >= 2, JSON.stringify(thumb));
  check(
    'hit_rate_in_range',
    Boolean(thumb) && thumb.hitRate >= 0 && thumb.hitRate <= 1,
    thumb && 'hitRate=' + thumb.hitRate,
  );
  check('both_requests_hit', Boolean(thumb) && thumb.hits === 2 && thumb.misses === 0, JSON.stringify(thumb));
  check('second_request_200', second.statusCode === 200, 'status=' + second.statusCode);

  // 4. 权限：没有 system:read 的 token 拿不到统计
  const limitedRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'nosys', scopes: ['files:read'] },
  });
  const limited = await app.inject({
    method: 'GET',
    url: '/api/v1/system/cache/stats',
    headers: { authorization: 'Bearer ' + limitedRes.json().token },
  });
  check('requires_system_read', limited.statusCode === 403, 'status=' + limited.statusCode);

  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 日志句柄释放有延迟，交给系统清理 */
  }

  console.log(`[summary] ${passed}/${passed + failed} passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});