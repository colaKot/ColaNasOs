#!/usr/bin/env node
/**
 * 音乐收藏 / 播放历史 / 自动歌单 验收。
 *
 * - 音乐：收藏幂等、取消、播放历史倒序、跨用户隔离、自动歌单口径
 * - 书籍模块已整体移除：`/api/v1/book/*` 必须全部 404（防止路由被误加回来）
 *
 * 用法：node tool/check/state-smoke.js（Electron 自举）
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
const { sql } = require('kysely');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-state-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(filesRoot, { recursive: true });

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

  const admin = await devToken(['music:read', 'music:write'], 'admin');
  const other = await devToken(['music:read', 'music:write'], 'u2');

  // ---- 书籍模块已移除：相关路由必须不存在（而不是 401/403/500） ----
  let r = await inject('POST', '/api/v1/book/libraries', admin, { name: 'books', path: 'books' });
  check('book_libraries_route_removed', r.statusCode === 404, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/book/search/reindex', admin, {});
  check('book_reindex_route_removed', r.statusCode === 404, 'status=' + r.statusCode);

  r = await inject('GET', '/api/v1/book/search?q=' + encodeURIComponent('三体'), admin);
  check('book_search_route_removed', r.statusCode === 404, 'status=' + r.statusCode);

  // ---- 音乐收藏 / 历史 / 自动歌单（直接插曲目，避免依赖 ffmpeg 探测） ----
  const baseSec = Math.floor(Date.now() / 1000);
  const trackIds = ['t1', 't2', 't3'];
  for (const [i, id] of trackIds.entries()) {
    await sql`
      insert into music_tracks (id, library_id, rel_path, title, artist, album, duration, size, mtime, created_at)
      values (${id}, 'lib', ${'a' + i + '.mp3'}, ${'歌曲' + (i + 1)}, ${'歌手' + (i + 1)},
              '专辑', ${180 + i}, 1024, 1, ${baseSec - (trackIds.length - i)})
    `.execute(k.db);
  }

  r = await inject('POST', '/api/v1/music/favorite', admin, { id: 't1', favorite: true });
  check('favorite_add', r.statusCode === 200 && r.json().ok, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/music/favorite', admin, { id: 't1', favorite: true });
  check('favorite_idempotent', r.statusCode === 200, 'status=' + r.statusCode);

  r = await inject('GET', '/api/v1/music/favorites', admin);
  check(
    'favorites_list',
    r.statusCode === 200 && r.json().items.length === 1 && r.json().items[0].id === 't1',
    'items=' + r.json().items.length,
  );

  r = await inject('GET', '/api/v1/music/favorites', other);
  check(
    'favorites_cross_user_isolated',
    r.statusCode === 200 && r.json().items.length === 0,
    'items=' + r.json().items.length,
  );

  await inject('POST', '/api/v1/music/favorite', admin, { id: 't1', favorite: false });
  r = await inject('GET', '/api/v1/music/favorites', admin);
  check(
    'favorite_remove',
    r.statusCode === 200 && r.json().items.length === 0,
    'items=' + r.json().items.length,
  );

  // 历史：先 t1 再 t2，最近播放应排在最前
  await inject('POST', '/api/v1/music/play', admin, { id: 't1' });
  await new Promise((res) => setTimeout(res, 5));
  await inject('POST', '/api/v1/music/play', admin, { id: 't2' });

  r = await inject('GET', '/api/v1/music/history?limit=10', admin);
  const history = r.statusCode === 200 ? r.json().items : [];
  check(
    'history_order',
    history.length === 2 && history[0].id === 't2' && history[1].id === 't1',
    history.map((x) => x.id).join(','),
  );

  r = await inject('GET', '/api/v1/music/history?limit=10', other);
  check(
    'history_cross_user_isolated',
    r.statusCode === 200 && r.json().items.length === 0,
    'items=' + r.json().items.length,
  );

  // 自动歌单：t1 共 3 次、t2 共 2 次（最后播 t2），t3 从未播放
  // → 最常播放看次数（t1 在前），最近播放看时间（t2 在前）
  await inject('POST', '/api/v1/music/play', admin, { id: 't1' });
  await inject('POST', '/api/v1/music/play', admin, { id: 't1' });
  await new Promise((res) => setTimeout(res, 5));
  await inject('POST', '/api/v1/music/play', admin, { id: 't2' });

  r = await inject('GET', '/api/v1/music/auto-playlists', admin);
  const overview = r.statusCode === 200 ? r.json().items : [];
  const counts = Object.fromEntries(overview.map((x) => [x.kind, x.count]));
  check(
    'auto_overview',
    r.statusCode === 200 &&
      overview.length === 4 &&
      counts.recent_added === 3 &&
      counts.recently_played === 2 &&
      counts.most_played === 2 &&
      counts.never_played === 1,
    `status=${r.statusCode} counts=${JSON.stringify(counts)}`,
  );

  r = await inject('GET', '/api/v1/music/auto-playlist?kind=most_played&limit=10', admin);
  const most = r.statusCode === 200 ? r.json().items : [];
  check(
    'auto_most_played_order',
    most.map((x) => x.id).join(',') === 't1,t2',
    most.map((x) => x.id).join(','),
  );

  r = await inject('GET', '/api/v1/music/auto-playlist?kind=recently_played&limit=10', admin);
  const recent = r.statusCode === 200 ? r.json().items : [];
  check(
    'auto_recently_played_order',
    recent.map((x) => x.id).join(',') === 't2,t1',
    recent.map((x) => x.id).join(','),
  );

  r = await inject('GET', '/api/v1/music/auto-playlist?kind=recent_added&limit=10', admin);
  const added = r.statusCode === 200 ? r.json().items : [];
  check(
    'auto_recent_added_order',
    added.map((x) => x.id).join(',') === 't3,t2,t1',
    added.map((x) => x.id).join(','),
  );

  r = await inject('GET', '/api/v1/music/auto-playlist?kind=never_played&limit=10', admin);
  const never = r.statusCode === 200 ? r.json().items : [];
  check(
    'auto_never_played_user',
    never.map((x) => x.id).join(',') === 't3',
    never.map((x) => x.id).join(','),
  );

  r = await inject('GET', '/api/v1/music/auto-playlist?kind=never_played&limit=10', other);
  const neverOther = r.statusCode === 200 ? r.json().items : [];
  check(
    'auto_never_played_other_user',
    neverOther.length === 3,
    'items=' + neverOther.map((x) => x.id).join(','),
  );

  r = await inject('GET', '/api/v1/music/auto-playlist?kind=nope', admin);
  check('auto_unknown_kind_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await inject('POST', '/api/v1/music/play', '', { id: 't1' });
  check('play_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(28)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});
