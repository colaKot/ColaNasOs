#!/usr/bin/env node
/**
 * 榜单快照（`media_catalog`）验收：TMDB 发现页与日系榜单共用这套存储。
 *
 * 覆盖的语义（都是"不联外网也能验"的部分）：
 *   1. 没有 Key 时发现页降级而不是 500；
 *   2. 快照清单能反映 age / fresh（重启后榜单不空的依据）；
 *   3. 过期行被清理，保留期内的一行都不动（清理阈值不能误伤）；
 *   4. 日系榜单「清空缓存」能连落库快照一起清。
 *
 * 不做的事：真实抓取 TMDB / JavDB —— 冒烟不联网，`stale` 回退路径靠单测之外的人工验证。
 *
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
const { sql } = require('kysely');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-catalog-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });
  const now = () => Math.floor(Date.now() / 1000);

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['discover:read', 'discover:write', 'video:read', 'video:write'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const noScope = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['video:read'] },
  });
  const noDiscover = { authorization: 'Bearer ' + noScope.json().token };

  const get = (url, headers = bearer) => app.inject({ method: 'GET', url, headers });
  const post = (url, payload, headers = bearer) =>
    app.inject({ method: 'POST', url, headers, payload: payload ?? {} });

  // 1. 表随迁移建好
  const table = (
    await sql`select name from sqlite_master where type = 'table' and name = 'media_catalog'`.execute(
      k.db,
    )
  ).rows[0];
  check('media_catalog_table', !!table, table ? 'exists' : 'missing');

  // 2. 没有 TMDB Key：降级返回，不是 500
  let r = await get('/api/v1/discover/catalog?kind=trending&media=movie');
  const noKey = r.json();
  check(
    'catalog_no_key_degraded',
    r.statusCode === 200 && noKey.degraded === true && noKey.items.length === 0,
    `status=${r.statusCode} degraded=${noKey.degraded}`,
  );

  // 3. 空库：快照清单为空
  r = await get('/api/v1/discover/catalog/snapshots');
  check('snapshots_empty', r.statusCode === 200 && r.json().items.length === 0, 'n=' + r.json().items.length);

  // 4. 权限：discover:read 才能看快照
  r = await get('/api/v1/discover/catalog/snapshots', noDiscover);
  check('snapshots_needs_scope', r.statusCode === 403, 'status=' + r.statusCode);

  // 5. 塞一条 30 天前的过期快照 → 清单能看出不新鲜
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values ('tmdb', 'catalog:movie:trending:1', '{"results":[]}', 0, ${now() - 30 * 86400})
  `.execute(k.db);
  r = await get('/api/v1/discover/catalog/snapshots');
  const staleRow = r.json().items[0] || {};
  check(
    'snapshot_stale_flag',
    r.json().items.length === 1 && staleRow.fresh === false && staleRow.ageSec > 86400,
    `fresh=${staleRow.fresh} age=${staleRow.ageSec}`,
  );

  // 6. 清理：30 天的行被删掉
  r = await post('/api/v1/discover/catalog/prune');
  const pruned = r.json().pruned;
  const leftAfter = (await get('/api/v1/discover/catalog/snapshots')).json().items.length;
  check(
    'prune_removes_expired',
    r.statusCode === 200 && pruned === 1 && leftAfter === 0,
    `pruned=${pruned} left=${leftAfter}`,
  );

  // 7. 新鲜的快照不能被清理（保留期内一行都不动）
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values ('jp_rank', 'movie:daily:https://javdb.com', '{"items":[]}', 0, ${now()})
  `.execute(k.db);
  r = await get('/api/v1/discover/catalog/snapshots');
  const freshRow = r.json().items[0] || {};
  check(
    'snapshot_fresh_flag',
    r.json().items.length === 1 && freshRow.fresh === true && freshRow.catalogType === 'jp_rank',
    `fresh=${freshRow.fresh} type=${freshRow.catalogType}`,
  );

  r = await post('/api/v1/discover/catalog/prune');
  const leftFresh = (await get('/api/v1/discover/catalog/snapshots')).json().items.length;
  check(
    'prune_keeps_fresh',
    r.json().pruned === 0 && leftFresh === 1,
    `pruned=${r.json().pruned} left=${leftFresh}`,
  );

  // 8. 日系榜单「清空缓存」要连落库快照一起清
  r = await post('/api/v1/video/jp_rank/clear');
  const clearedSnapshots = (await get('/api/v1/discover/catalog/snapshots')).json().items.length;
  check(
    'jp_rank_clear_snapshots',
    r.statusCode === 200 && r.json().cleared === 1 && clearedSnapshots === 0,
    `cleared=${r.json().cleared} left=${clearedSnapshots}`,
  );

  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 句柄释放有延迟 */
  }

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
