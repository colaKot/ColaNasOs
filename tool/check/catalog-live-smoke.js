#!/usr/bin/env node
/**
 * 榜单**链路**验收：用一个本地假 TMDB 跑完整条路。
 *
 * 为什么要有这个（而不是 `smoke:catalog` 那种只查表的）：
 * `smoke:catalog` 证明的是"存储语义对不对"，但它碰不到"抓取 → 落库 → 回退"这条链路；
 * 真实 TMDB 又需要 Key + 外网，进不了门禁。假上游是唯一能两者兼顾的办法：
 *   baseUrl 指到本地 http server，抓取走的是**真的 tmdbGet**，落库存的是**真的 media_catalog**。
 *
 * 四条断言：
 *   1. 上游正常 → 出条目、不降级、快照落库；
 *   2. 快照里的条目数与被抓取的条数一致；
 *   3. 上游 500 且**没有**快照 → 降级（degraded + reason），不 500；
 *   4. 上游 500 但**有**过期快照 → 回退快照并标 `stale`。
 *
 * 不联网：假上游监听 127.0.0.1 随机端口。
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const http = require('node:http');
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

const CARDS = [
  {
    id: 101,
    title: '假片 A',
    original_title: 'Fake A',
    overview: '上游返回的第一条',
    poster_path: '/a.jpg',
    backdrop_path: null,
    release_date: '2026-01-01',
    vote_average: 7.5,
  },
  {
    id: 102,
    title: '假片 B',
    original_title: 'Fake B',
    overview: '',
    poster_path: null,
    backdrop_path: null,
    release_date: '2026-02-02',
    vote_average: 6.5,
  },
];

(async () => {
  // ---- 假上游：trending 正常，popular 一律 500（用来验降级与回退）
  const hits = { trending: 0, popular: 0 };
  const discoverHits = [];
  const server = http.createServer((req, res) => {
    const url = String(req.url || '');
    res.setHeader('content-type', 'application/json');
    if (url.startsWith('/3/discover/movie')) {
      discoverHits.push(url);
      res.end(JSON.stringify({ page: 1, total_pages: 1, results: CARDS }));
      return;
    }
    if (url.startsWith('/3/trending/movie/week')) {
      hits.trending += 1;
      res.end(JSON.stringify({ page: 1, total_pages: 1, results: CARDS }));
      return;
    }
    hits.popular += 1;
    res.statusCode = 500;
    res.end(JSON.stringify({ status_message: 'upstream down' }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-catalog-live-'));
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
    payload: { sub: 'u1', scopes: ['discover:read', 'discover:write'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };
  const get = (url) => app.inject({ method: 'GET', url, headers: bearer });
  const post = (url, payload) => app.inject({ method: 'POST', url, headers: bearer, payload });

  // 把 TMDB 基址指到假上游
  const saved = await post('/api/v1/discover/settings', {
    apiKey: 'test-key',
    baseUrl: `http://127.0.0.1:${port}/3`,
  });
  check('settings_saved', saved.statusCode === 200, 'status=' + saved.statusCode);

  // 1. 上游正常 → 出条目
  let r = await get('/api/v1/discover/catalog?kind=trending&media=movie');
  const live = r.json();
  check(
    'catalog_live_ok',
    r.statusCode === 200 &&
      live.degraded === false &&
      live.items.length === CARDS.length &&
      live.items[0].title === '假片 A',
    `n=${live.items.length} degraded=${live.degraded}`,
  );
  check('upstream_hit', hits.trending === 1, 'trending=' + hits.trending);

  // 2. 落库了，且条数一致
  r = await get('/api/v1/discover/catalog/snapshots');
  const snaps = r.json().items || [];
  const trendingSnap = snaps.find((s) => s.key.includes('trending')) || {};
  check(
    'snapshot_written',
    snaps.length === 1 && trendingSnap.itemCount === CARDS.length,
    `n=${snaps.length} items=${trendingSnap.itemCount}`,
  );

  // 2.1 D6：多风格 / 年代区间 / 原始语言（服务端把逗号转成 TMDB 的 | 与 gte/lte 日期）
  r = await get(
    '/api/v1/discover/catalog?media=movie&genre=28,12&yearFrom=2000&yearTo=2010&language=ja&minVote=6',
  );
  const filtered = r.json();
  const upstreamUrl = discoverHits.length > 0
    ? new URL('http://x' + discoverHits[0])
    : null;
  check(
    'catalog_multi_filter',
    r.statusCode === 200 &&
      filtered.items.length === CARDS.length &&
      upstreamUrl?.searchParams.get('with_genres') === '28|12' &&
      upstreamUrl?.searchParams.get('primary_release_date.gte') === '2000-01-01' &&
      upstreamUrl?.searchParams.get('primary_release_date.lte') === '2010-12-31' &&
      upstreamUrl?.searchParams.get('with_original_language') === 'ja',
    `items=${filtered.items.length}`,
  );

  // 2.2 收藏：卡片 favorited 标记 + 列表 + 取消
  r = await post('/api/v1/discover/favorites/set', {
    id: CARDS[0].id,
    mediaType: 'movie',
    favorite: true,
  });
  check('favorite_set', r.statusCode === 200 && r.json().favorite === true, 'status=' + r.statusCode);

  r = await get('/api/v1/discover/catalog?kind=trending&media=movie');
  check(
    'favorite_marked',
    r.statusCode === 200 && r.json().items[0].favorited === true,
    JSON.stringify(r.json().items[0]?.favorited),
  );

  r = await get('/api/v1/discover/favorites');
  check(
    'favorite_list',
    r.statusCode === 200 &&
      (r.json().items || []).some(
        (x) => x.id === CARDS[0].id && x.mediaType === 'movie',
      ),
    'items=' + (r.json().items || []).length,
  );

  await post('/api/v1/discover/favorites/set', {
    id: CARDS[0].id,
    mediaType: 'movie',
    favorite: false,
  });
  r = await get('/api/v1/discover/catalog?kind=trending&media=movie');
  check(
    'favorite_unmarked',
    r.statusCode === 200 && r.json().items[0].favorited === false,
    JSON.stringify(r.json().items[0]?.favorited),
  );

  // 2.3 语言多选：逐语言取第一页、去重合并（分页退化为单页）
  r = await get('/api/v1/discover/catalog?media=movie&language=zh,ja&minVote=6');
  const multiLang = r.json();
  const lastPages = discoverHits.slice(-2).map((u) => new URL('http://x' + u));
  const sentLangs = lastPages
    .map((u) => u.searchParams.get('with_original_language'))
    .sort();
  check(
    'catalog_multi_language',
    r.statusCode === 200 &&
      multiLang.items.length === CARDS.length &&
      sentLangs.join(',') === 'ja,zh' &&
      lastPages.every((u) => u.searchParams.get('page') === '1'),
    `items=${multiLang.items.length} langs=${sentLangs.join(',')}`,
  );

  // 3. 上游 500 且没有快照 → 降级（不是 500）
  r = await get('/api/v1/discover/catalog?kind=upcoming&media=movie');
  const downNoSnap = r.json();
  check(
    'catalog_down_degraded',
    r.statusCode === 200 && downNoSnap.degraded === true && downNoSnap.items.length === 0,
    `degraded=${downNoSnap.degraded}`,
  );

  // 4. 上游 500 但有**过期**快照 → 回退 + stale
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values ('tmdb', 'catalog:movie:popular:1',
            ${JSON.stringify({ page: 1, total_pages: 1, results: [CARDS[1]] })}, 1, ${now() - 10 * 3600})
  `.execute(k.db);
  r = await get('/api/v1/discover/catalog?kind=popular&media=movie');
  const stale = r.json();
  check(
    'catalog_stale_fallback',
    r.statusCode === 200 &&
      stale.degraded === false &&
      stale.stale === true &&
      stale.items.length === 1 &&
      stale.items[0].id === CARDS[1].id,
    `stale=${stale.stale} n=${stale.items.length}`,
  );
  check('upstream_hit_popular', hits.popular >= 1, 'popular=' + hits.popular);

  await app.close();
  await new Promise((resolve) => server.close(resolve));
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 句柄释放有延迟 */
  }

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
