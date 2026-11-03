#!/usr/bin/env node
/**
 * 观看进度验收（`/video/progress` + `/video/progress/save` + `/video/progress/list`）：
 *   未看过返回 0% → 保存后回读 → 覆盖保存 → percent 越界 400
 *   → 跨用户隔离（B 看不到 A 的进度）→ 列表按更新时间倒序、可按剧名过滤
 *   → 未知 id 404 → 匿名 401 / 缺 scope 403
 *
 * 素材用空文件占位，**不依赖 ffmpeg**。
 * 用法：node tool/check/video-progress-smoke.js
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

const FILES = [
  'Breaking Bad/Season 1/S01E01 - Pilot.mkv',
  'Breaking Bad/Season 1/S01E02 - Cat in the Bag.mkv',
  'Inception.2010.mkv',
];

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-vprog-'));
  const filesRoot = path.join(dataDir, 'files');
  const media = path.join(filesRoot, 'media');
  for (const rel of FILES) {
    const abs = path.join(media, rel.split('/').join(path.sep));
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, Buffer.alloc(2048, 5));
  }

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

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

  const writer = await mkToken('u1', ['video:read', 'video:write']);
  const reader = await mkToken('u2', ['video:read']);
  const outsider = await mkToken('u3', ['music:read']);

  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries',
    headers: writer,
    payload: { name: 'Media', path: 'media' },
  });
  check('create_library', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: writer, payload: {} });
  check('scan', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?limit=50', headers: writer });
  const items = r.json().items || [];
  const pilot = items.find((i) => i.path.endsWith('S01E01 - Pilot.mkv'));
  const ep2 = items.find((i) => i.path.endsWith('S01E02 - Cat in the Bag.mkv'));
  const movie = items.find((i) => i.path.endsWith('Inception.2010.mkv'));
  check('indexed', Boolean(pilot && ep2 && movie), 'n=' + items.length);

  const getProgress = (id, headers) =>
    app.inject({
      method: 'GET',
      url: `/api/v1/video/progress?id=${encodeURIComponent(id)}`,
      headers,
    });
  const save = (payload, headers) =>
    app.inject({
      method: 'POST',
      url: '/api/v1/video/progress/save',
      headers: headers || writer,
      payload,
    });

  // 1. 未看过
  r = await getProgress(pilot.id, writer);
  const fresh = r.json();
  check(
    'fresh_is_zero',
    r.statusCode === 200 &&
      fresh.percent === 0 &&
      fresh.position === '' &&
      fresh.itemId === pilot.id,
    `status=${r.statusCode} percent=${fresh.percent}`,
  );

  // 2. 保存 + 回读
  r = await save({ id: pilot.id, percent: 40, position: '120s' });
  const saved = r.json();
  check(
    'save_ok',
    r.statusCode === 200 &&
      saved.percent === 40 &&
      saved.position === '120s' &&
      saved.updatedAt > 0,
    `status=${r.statusCode} percent=${saved.percent} pos=${saved.position}`,
  );

  r = await getProgress(pilot.id, writer);
  check(
    'read_back',
    r.json().percent === 40 && r.json().position === '120s',
    JSON.stringify(r.json()),
  );

  // 3. 覆盖保存
  r = await save({ id: pilot.id, percent: 75 });
  check(
    'overwrite',
    r.statusCode === 200 && r.json().percent === 75,
    `percent=${r.json().percent}`,
  );

  // 4. 越界
  r = await save({ id: pilot.id, percent: 120 });
  check('percent_out_of_range_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await save({ id: pilot.id });
  check('percent_missing_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 5. 跨用户隔离
  r = await getProgress(pilot.id, reader);
  check(
    'other_user_isolated',
    r.statusCode === 200 && r.json().percent === 0,
    `percent=${r.json().percent}`,
  );

  r = await save({ id: pilot.id, percent: 60 }, reader);
  check('reader_cannot_save_403', r.statusCode === 403, 'status=' + r.statusCode);

  // 6. 列表：第二集后保存，应排在前面；可按剧名过滤
  r = await save({ id: ep2.id, percent: 10, position: '30s' });
  check('save_second', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/video/progress/list', headers: writer });
  const list = r.json().items || [];
  check(
    'list_sorted_desc',
    r.statusCode === 200 &&
      list.length === 2 &&
      list[0].itemId === ep2.id &&
      list[1].itemId === pilot.id,
    `order=${JSON.stringify(list.map((x) => x.title))}`,
  );
  check(
    'list_has_series_fields',
    list.every((x) => typeof x.percent === 'number') &&
      list.some((x) => x.series === 'Breaking Bad' && x.season === 1 && x.episode === 2),
    JSON.stringify(list[0]),
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/progress/list?series=' + encodeURIComponent('Breaking Bad'),
    headers: writer,
  });
  check(
    'list_series_filter',
    r.statusCode === 200 && (r.json().items || []).length === 2,
    `n=${(r.json().items || []).length}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/progress/list?series=' + encodeURIComponent('No Such Show'),
    headers: writer,
  });
  check(
    'list_unknown_series_empty',
    r.statusCode === 200 && (r.json().items || []).length === 0,
    `n=${(r.json().items || []).length}`,
  );

  // 7. 未知 id
  r = await getProgress('missing', writer);
  check('unknown_get_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await save({ id: 'missing', percent: 10 });
  check('unknown_save_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 8. 鉴权
  r = await app.inject({ method: 'GET', url: `/api/v1/video/progress?id=${pilot.id}` });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await getProgress(pilot.id, outsider);
  check('missing_scope_403', r.statusCode === 403, 'status=' + r.statusCode);

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(26)} ${x.detail}`);
  }
  console.log(`\n[video-progress] ${results.length - failed.length}/${results.length} passed`);
  await app.close();
  process.exit(failed.length ? 1 : 0);
})();
