#!/usr/bin/env node
/**
 * PT 冒烟：站点 CRUD（cookie 不回显）/ 搜索解析 / 订阅择种 / transmission 加种（409 重试）/ 留痕。
 *
 * 用本地假站点与假 transmission（覆盖 global.fetch），不依赖真实站点与下载器。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
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

process.chdir(root);

const PT_HTML =
  '<table>' +
  '<tr><td><a href="details.php?id=11&hit=1">Movie 2024 1080p HDR10 国语</a></td>' +
  '<td>1.5 GB</td><td>12</td><td>3</td><td>2026-01-01</td>' +
  '<td><a href="download.php?id=11">DL</a></td></tr>' +
  '<tr><td><a href="details.php?id=12&hit=1">Movie 2024 2160p HDR10 国语</a></td>' +
  '<td>8 GB</td><td>40</td><td>1</td><td>2026-01-02</td>' +
  '<td><a href="download.php?id=12">DL</a></td></tr>' +
  '</table>';

const realFetch = global.fetch;
let lastAdd = null;
let addCount = 0;
let lastMethod = '';
let lastArgs = {};
global.fetch = async (url, init) => {
  const u = String(url);
  if (u.startsWith('http://pt.local/torrents.php')) {
    return new globalThis.Response(PT_HTML, { status: 200, headers: { 'content-type': 'text/html' } });
  }
  if (u.startsWith('http://tr.local')) {
    const headers = (init && init.headers) || {};
    if (!headers['x-transmission-session-id']) {
      return new globalThis.Response('', { status: 409, headers: { 'x-transmission-session-id': 'abc' } });
    }
    try {
      lastAdd = init && init.body ? JSON.parse(String(init.body)) : null;
    } catch {
      lastAdd = null;
    }
    lastMethod = String(lastAdd?.method || '');
    lastArgs = (lastAdd && lastAdd.arguments) || {};
    addCount += 1;
    return new globalThis.Response(
      JSON.stringify({
        result: 'success',
        arguments: { 'torrent-added': { id: 7, name: 't', hashString: 'abc123' } },
      }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }
  return realFetch(url, init);
};

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-pt-'));
  fs.mkdirSync(path.join(dataDir, 'files', 'movies'), { recursive: true });
  process.env.COLANAS_FILES_ROOT = path.join(dataDir, 'files');
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['pt:read', 'pt:write', 'video:read', 'video:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };
  const post = (url, payload) => app.inject({ method: 'POST', url, headers: bearer, payload });
  const get = (url) => app.inject({ method: 'GET', url, headers: bearer });

  // 站点
  let r = await post('/api/v1/pt/sites/upsert', {
    name: 'fake-pt',
    baseUrl: 'http://pt.local',
    cookie: 'PHPSESSID=secret-value',
    priority: 10,
  });
  check('site_upsert', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);

  r = await get('/api/v1/pt/sites');
  const sites = r.json().items;
  check(
    'site_list_no_cookie',
    r.statusCode === 200 && sites.length === 1 && sites[0].hasCookie === true && !JSON.stringify(sites).includes('secret-value'),
    JSON.stringify(sites),
  );

  // 搜索
  r = await post('/api/v1/pt/search', { title: 'Movie', year: '2024' });
  const found = r.json().items;
  check(
    'search_parse',
    r.statusCode === 200 && found.length === 2 && found.some((x) => x.resolution === '2160p'),
    JSON.stringify(found.map((x) => x.title)),
  );

  // transmission 配置与探活
  r = await post('/api/v1/pt/settings', { url: 'http://tr.local', username: 'u', password: 'p' });
  check('settings_set', r.statusCode === 200, 'status=' + r.statusCode);
  r = await post('/api/v1/pt/transmission/test', {});
  check('transmission_test', r.statusCode === 200 && r.json().ok === true, JSON.stringify(r.json()));

  // ---- 下载目录 / 筛选（D5）：设置 → 订阅默认值 → transmission download-dir ----
  r = await post('/api/v1/video/libraries', { name: 'movies', path: '/movies' });
  const videoLib = r.json();
  check('video_library_create', r.statusCode === 200 && !!videoLib.id, JSON.stringify(videoLib).slice(0, 80));

  r = await get('/api/v1/pt/download/settings');
  const dlDefaults = r.json().settings || {};
  check(
    'download_settings_defaults',
    r.statusCode === 200 &&
      dlDefaults.quality === 'all' &&
      dlDefaults.autoDownload === true &&
      dlDefaults.scanIntervalMin === 360,
    JSON.stringify(dlDefaults),
  );

  r = await post('/api/v1/pt/download/settings', {
    movieLibraryId: videoLib.id || '',
    siteIds: sites.map((x) => x.id),
    quality: '1080p',
    hdr: 'hdr10',
    audioLangs: ['zh'],
    maxSizeBytes: 3 * 1024 * 1024 * 1024,
    minSeeders: 10,
    excludedKeywords: ['CAM'],
    scanIntervalMin: 30,
    autoDownload: true,
  });
  const dlSaved = r.json();
  check(
    'download_settings_save',
    r.statusCode === 200 &&
      dlSaved.settings.quality === '1080p' &&
      dlSaved.settings.minSeeders === 10 &&
      dlSaved.movieDir.length > 0,
    JSON.stringify({ q: dlSaved.settings?.quality, dir: dlSaved.movieDir }),
  );

  // 订阅 + 运行
  r = await post('/api/v1/pt/subscriptions/upsert', {
    mediaTitle: 'Movie',
    mediaYear: '2024',

  });
  check('subscription_upsert', r.statusCode === 200, 'status=' + r.statusCode);

  r = await get('/api/v1/pt/subscriptions');
  const sub = r.json().items[0];
  check('subscription_list', r.statusCode === 200 && sub && sub.enabled === true, JSON.stringify(sub));
  check(
    'subscription_defaults_applied',
    sub && sub.quality === '1080p' && sub.hdr === 'hdr10' && sub.minSeeders === 10,
    JSON.stringify({ q: sub?.quality, hdr: sub?.hdr, seeders: sub?.minSeeders }),
  );

  r = await post('/api/v1/pt/subscriptions/run', { id: sub.id });
  check(
    'subscription_run_added',
    r.statusCode === 200 && r.json().ok === true && r.json().message === 'added',
    JSON.stringify(r.json()),
  );

  r = await get('/api/v1/pt/downloads');
  const downloads = r.json().items;
  check(
    'download_trace',
    r.statusCode === 200 && downloads.length === 1 && downloads[0].status === 'added',
    JSON.stringify(downloads[0] || {}),
  );

  check(
    'download_dir_in_add',
    lastAdd?.arguments?.['download-dir'] === path.join(dataDir, 'files', 'movies'),
    JSON.stringify(lastAdd?.arguments || {}),
  );

  // ---- 下载台账：暂停 / 恢复 / 移除（不删本地数据） ----
  const dlItem = downloads[0];
  check(
    'download_hash',
    dlItem.infoHash === 'abc123' && dlItem.canControl === true,
    JSON.stringify({ hash: dlItem.infoHash, can: dlItem.canControl }),
  );

  r = await post('/api/v1/pt/downloads/action', { id: dlItem.id, action: 'pause' });
  check(
    'download_pause',
    r.statusCode === 200 && lastMethod === 'torrent-stop',
    `status=${r.statusCode} method=${lastMethod}`,
  );
  r = await get('/api/v1/pt/downloads');
  check(
    'download_paused_status',
    r.json().items[0]?.status === 'paused',
    'status=' + r.json().items[0]?.status,
  );

  r = await post('/api/v1/pt/downloads/action', { id: dlItem.id, action: 'resume' });
  check('download_resume', r.statusCode === 200 && lastMethod === 'torrent-start', lastMethod);

  r = await post('/api/v1/pt/downloads/action', { id: dlItem.id, action: 'remove' });
  check(
    'download_remove',
    r.statusCode === 200 &&
      lastMethod === 'torrent-remove' &&
      lastArgs['delete-local-data'] === false,
    JSON.stringify({ method: lastMethod, args: lastArgs }),
  );

  // 自动下载关闭：只给候选，不再向 transmission 加种
  const beforeOff = addCount;
  r = await post('/api/v1/pt/download/settings', { autoDownload: false });
  check('auto_off_saved', r.statusCode === 200 && r.json().settings.autoDownload === false, 'status=' + r.statusCode);
  r = await post('/api/v1/pt/subscriptions/run', { id: sub.id });
  check(
    'auto_off_no_add',
    r.statusCode === 200 && r.json().ok === false && addCount === beforeOff,
    `ok=${r.json().ok} adds=${addCount - beforeOff}`,
  );
  await post('/api/v1/pt/download/settings', { autoDownload: true });

  // 订阅隔离：另一个用户看不到
  const t2 = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['pt:read', 'pt:write'] },
  });
  const bearer2 = { authorization: 'Bearer ' + (t2.json().token || '') };
  r = await app.inject({ method: 'GET', url: '/api/v1/pt/subscriptions', headers: bearer2 });
  check('subscription_isolation', r.statusCode === 200 && r.json().items.length === 0, 'items=' + r.json().items.length);

  // ---- 站点 / 订阅 CRUD（D7 管理弹窗的后端支撑） ----
  r = await post('/api/v1/pt/sites/upsert', {
    id: sites[0].id,
    name: 'fake-pt-2',
    baseUrl: 'http://pt.local',
    enabled: true,
    priority: 5,
  });
  check('site_update', r.statusCode === 200, 'status=' + r.statusCode);
  r = await get('/api/v1/pt/sites');
  check(
    'site_update_readback',
    r.json().items[0]?.name === 'fake-pt-2' && r.json().items[0]?.priority === 5,
    JSON.stringify(r.json().items[0]),
  );

  r = await post('/api/v1/pt/subscriptions/upsert', {
    id: sub.id,
    mediaTitle: 'Movie',
    mediaYear: '2024',
    quality: '720p',
    hdr: 'all',
    minSeeders: 2,
    enabled: false,
    excludedKeywords: ['CAM'],
  });
  check('subscription_update', r.statusCode === 200, 'status=' + r.statusCode);
  r = await get('/api/v1/pt/subscriptions');
  const updatedSub = r.json().items[0];
  check(
    'subscription_update_readback',
    updatedSub?.quality === '720p' &&
      updatedSub?.minSeeders === 2 &&
      updatedSub?.enabled === false &&
      (updatedSub?.excludedKeywords || []).includes('CAM'),
    JSON.stringify(updatedSub),
  );

  r = await post('/api/v1/pt/subscriptions/delete', { id: sub.id });
  check('subscription_delete', r.statusCode === 200, 'status=' + r.statusCode);
  r = await get('/api/v1/pt/subscriptions');
  check('subscription_delete_gone', r.json().items.length === 0, 'items=' + r.json().items.length);

  r = await post('/api/v1/pt/sites/delete', { id: sites[0].id });
  check('site_delete', r.statusCode === 200, 'status=' + r.statusCode);
  r = await get('/api/v1/pt/sites');
  check('site_delete_gone', r.json().items.length === 0, 'items=' + r.json().items.length);

  await app.close();
  global.fetch = realFetch;
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