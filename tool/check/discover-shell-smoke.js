/**
 * 影视发现 兼容适配（P4）专用冒烟：
 *   - 评分体系 TMDB ↔ 豆瓣（设置读写 + 列表带回 + 豆瓣统计）
 *   - 豆瓣榜单 fast 首屏（读 douban_chart 缓存，不联网）
 *   - 豆瓣补齐 / 连通性自检的返回结构（无网络也要有结论，不许 500）
 *   - PT 站点连通性测试（真搜一次 + 结果落库）
 *   - 择种规则 CRUD
 *   - 订阅按 TMDB media_id 绑定 + 去重
 *   - 预览按 media_id（无 TMDB Key 时降级，不 500）
 *
 * 全部断言都**不依赖外网**：需要联网的分支用 mock fetch 或直接写缓存表。
 */
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// better-sqlite3 是 Electron ABI：普通 node 起不来，脚本自动用 Electron 自举（同 pt-smoke）
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

const { sql } = require('kysely');

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

const PT_HTML =
  '<table>' +
  '<tr><td><a href="details.php?id=11&hit=1">Movie 2024 1080p HDR10 国语</a></td>' +
  '<td>1.5 GB</td><td>12</td><td>3</td><td>2026-01-01</td>' +
  '<td><a href="download.php?id=11">DL</a></td></tr>' +
  '</table>';

const realFetch = global.fetch;
global.fetch = async (url, init) => {
  const u = String(url);
  if (u.startsWith('http://pt.local/torrents.php')) {
    return new globalThis.Response(PT_HTML, {
      status: 200,
      headers: { 'content-type': 'text/html' },
    });
  }
  // 豆瓣：mock 成「连不上」，验证降级路径不会抛 500
  if (u.includes('douban.com')) {
    return new globalThis.Response('', { status: 503 });
  }
  return realFetch(url, init);
};

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-dw-'));
  fs.mkdirSync(path.join(dataDir, 'files'), { recursive: true });
  process.env.COLANAS_FILES_ROOT = path.join(dataDir, 'files');
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  // 别让 dev 环境里残留的 TMDB Key / 代理影响断言
  delete process.env.HTTP_PROXY;
  delete process.env.HTTPS_PROXY;
  delete process.env.http_proxy;
  delete process.env.https_proxy;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: {
      sub: 'u1',
      scopes: ['pt:read', 'pt:write', 'discover:read', 'discover:write'],
    },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };
  const post = (url, payload) =>
    app.inject({ method: 'POST', url, headers: bearer, payload: payload || {} });
  const get = (url) => app.inject({ method: 'GET', url, headers: bearer });

  // ---------------------------------------------------------------- 评分体系
  let r = await get('/api/v1/discover/settings');
  check(
    'settings_provider_default',
    r.statusCode === 200 && r.json().ratingProvider === 'tmdb',
    JSON.stringify(r.json()),
  );

  r = await post('/api/v1/discover/settings', { ratingProvider: 'douban' });
  check(
    'settings_provider_set',
    r.statusCode === 200 && r.json().ratingProvider === 'douban',
    'status=' + r.statusCode,
  );
  r = await get('/api/v1/discover/settings');
  check('settings_provider_persisted', r.json().ratingProvider === 'douban', '');

  // 非法值回落 tmdb，再改回 douban（后续用例按豆瓣口径）
  r = await post('/api/v1/discover/settings', { ratingProvider: 'bogus' });
  check('settings_provider_invalid_falls_back', r.json().ratingProvider === 'tmdb', '');
  await post('/api/v1/discover/settings', { ratingProvider: 'douban' });

  // 列表响应要带 rating_provider（TMDB 没配也要带，页面据此切换评分口径）
  r = await get('/api/v1/discover/catalog?kind=popular&media=movie&page=1');
  check(
    'catalog_carries_provider',
    r.statusCode === 200 && r.json().ratingProvider === 'douban',
    JSON.stringify({ status: r.statusCode, body: r.json() }).slice(0, 200),
  );

  // ---------------------------------------------------------------- 豆瓣缓存 / fast
  const stamp = Math.floor(Date.now() / 1000);
  await sql`
    insert into douban_chart (kind, code, douban_id, rank, title, rating, payload, updated_at)
    values ('movie', 'hot', '1292052', 1, '肖申克的救赎', 9.7,
            ${JSON.stringify({
              id: 278,
              mediaType: 'movie',
              title: '肖申克的救赎',
              originalTitle: 'The Shawshank Redemption',
              overview: '',
              posterPath: '/a.jpg',
              backdropPath: null,
              year: 1994,
              rating: 8.7,
              ratingDouban: 9.7,
              doubanId: '1292052',
              doubanUrl: 'https://movie.douban.com/subject/1292052/',
              rank: 1,
            })}, ${stamp})
  `.execute(k.db);
  await sql`
    insert into douban_ratings (media_id, media_type, douban_id, title, year, rating, vote_count, url, updated_at)
    values (278, 'movie', '1292052', '肖申克的救赎', '1994', 9.7, 2800000,
            'https://movie.douban.com/subject/1292052/', ${stamp})
  `.execute(k.db);

  r = await post('/api/v1/discover/douban/catalogs/movie', { code: 'hot', fast: true });
  const fast = r.json();
  check(
    'douban_catalog_fast_reads_cache',
    r.statusCode === 200 &&
      fast.items.length === 1 &&
      fast.items[0].title === '肖申克的救赎' &&
      fast.items[0].ratingDouban === 9.7 &&
      fast.ratingProvider === 'douban',
    JSON.stringify(fast).slice(0, 240),
  );

  r = await post('/api/v1/discover/douban/catalogs/tv', { code: 'showing' });
  check(
    'douban_catalog_unsupported_code',
    r.statusCode === 200 && r.json().degraded === true && r.json().items.length === 0,
    JSON.stringify(r.json()).slice(0, 160),
  );

  r = await post('/api/v1/discover/douban/enrich', { mediaIds: [], mediaType: 'movie' });
  check(
    'douban_enrich_empty',
    r.statusCode === 200 && Object.keys(r.json().items || {}).length === 0,
    JSON.stringify(r.json()),
  );

  r = await post('/api/v1/discover/douban/test', { cookie: '' });
  const testBody = r.json();
  check(
    'douban_test_shape',
    r.statusCode === 200 &&
      typeof testBody.site?.ok === 'boolean' &&
      testBody.cookie?.provided === false &&
      typeof testBody.tmdb_match?.total === 'number',
    JSON.stringify(testBody).slice(0, 240),
  );

  r = await get('/api/v1/discover/cache/stats');
  check(
    'cache_stats_counts_douban',
    r.statusCode === 200 &&
      r.json().douban?.ratingRows >= 1 &&
      r.json().douban?.provider === 'douban',
    JSON.stringify(r.json().douban || {}),
  );

  // ---------------------------------------------------------------- 详情（快照命中，不联网）
  // 详情路由要求「已配置 Key」才会读快照，这里塞一个假 Key（命中快照后不会真联网）
  await post('/api/v1/discover/settings', { apiKey: 'test-key-for-snapshot' });
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values ('tmdb', 'detail:movie:278',
            ${JSON.stringify({
              id: 278,
              title: '肖申克的救赎',
              original_title: 'The Shawshank Redemption',
              overview: '希望让人自由',
              poster_path: '/p.jpg',
              backdrop_path: null,
              release_date: '1994-09-10',
              runtime: 142,
              vote_average: 8.7,
              vote_count: 25000,
              status: 'Released',
              tagline: '希望让人自由',
              original_language: 'en',
              production_countries: [{ iso_3166_1: 'US', name: '美国' }],
              production_companies: [{ name: 'Castle Rock Entertainment' }],
              networks: [],
              created_by: [],
              genres: [{ id: 18, name: '剧情' }],
              credits: {
                cast: [
                  { name: '蒂姆·罗宾斯', character: 'Andy', profile_path: '/c1.jpg' },
                  { name: '摩根·弗里曼', character: 'Ellis', profile_path: null },
                ],
              },
              external_ids: { imdb_id: 'tt0111161' },
            })}, 1, ${stamp})
    on conflict(catalog_type, key) do update set
      payload = excluded.payload, snapshot_at = excluded.snapshot_at
  `.execute(k.db);

  r = await get('/api/v1/discover/detail?id=278&media=movie');
  const detail = r.json();
  check(
    'detail_cast_members',
    r.statusCode === 200 &&
      detail.castMembers?.length === 2 &&
      detail.castMembers[0].name === '蒂姆·罗宾斯' &&
      detail.castMembers[0].profilePath === '/c1.jpg',
    JSON.stringify(detail.castMembers || []).slice(0, 200),
  );
  check(
    'detail_imdb_and_douban',
    detail.imdbId === 'tt0111161' &&
      detail.doubanUrl === 'https://movie.douban.com/subject/1292052/' &&
      detail.ratingDouban === 9.7,
    JSON.stringify({
      imdb: detail.imdbId,
      douban: detail.doubanUrl,
      rating: detail.ratingDouban,
    }),
  );
  // 参考详情页「信息」区逐项渲染这些字段，以前后端不回 → 整块空白
  check(
    'detail_info_fields',
    detail.status === 'Released' &&
      detail.originalLanguage === 'en' &&
      detail.voteCount === 25000 &&
      (detail.countries || []).includes('美国') &&
      (detail.companies || []).includes('Castle Rock Entertainment'),
    JSON.stringify({
      status: detail.status,
      lang: detail.originalLanguage,
      votes: detail.voteCount,
      countries: detail.countries,
      companies: detail.companies,
    }),
  );

  // ---------------------------------------------------------------- PT 站点测试
  r = await post('/api/v1/pt/sites/upsert', {
    name: 'fake-pt',
    baseUrl: 'http://pt.local',
    cookie: 'PHPSESSID=secret-value',
    priority: 10,
  });
  check('site_upsert', r.statusCode === 200, 'status=' + r.statusCode);

  r = await get('/api/v1/pt/sites');
  const site = (r.json().items || [])[0] || {};
  check('site_list_has_test_fields', site.id && site.lastTestStatus === null, JSON.stringify(site).slice(0, 200));

  r = await post(`/api/v1/pt/sites/${site.id}/test`);
  check(
    'site_test_ok',
    r.statusCode === 200 && r.json().ok === true && r.json().status === 'ok' && r.json().items === 1,
    JSON.stringify(r.json()),
  );
  r = await get('/api/v1/pt/sites');
  check(
    'site_test_status_persisted',
    (r.json().items || [])[0]?.lastTestStatus === 'ok',
    JSON.stringify((r.json().items || [])[0] || {}).slice(0, 200),
  );

  // ---------------------------------------------------------------- 择种规则 CRUD
  r = await post('/api/v1/pt/rules/list');
  check('rule_list_empty', r.statusCode === 200 && r.json().items.length === 0, 'status=' + r.statusCode);

  r = await post('/api/v1/pt/rules/add', {
    name: '只看 4K',
    quality: '4k',
    hdr: 'hdr10',
    minSeeders: 5,
    excludedKeywords: ['cam'],
  });
  const ruleId = r.json().id;
  check('rule_add', r.statusCode === 200 && !!ruleId, JSON.stringify(r.json()));

  r = await post('/api/v1/pt/rules/list');
  const rule = (r.json().items || [])[0] || {};
  check(
    'rule_list_after_add',
    r.json().items.length === 1 && rule.quality === '4k' && rule.minSeeders === 5 &&
      Array.isArray(rule.excludedKeywords) && rule.excludedKeywords[0] === 'cam',
    JSON.stringify(rule).slice(0, 200),
  );

  r = await post('/api/v1/pt/rules/update', { id: ruleId, name: '改名', enabled: false });
  check('rule_update', r.statusCode === 200, 'status=' + r.statusCode);
  r = await post('/api/v1/pt/rules/list');
  check(
    'rule_update_applied',
    (r.json().items || [])[0]?.name === '改名' && (r.json().items || [])[0]?.enabled === false,
    JSON.stringify((r.json().items || [])[0] || {}).slice(0, 160),
  );

  r = await post('/api/v1/pt/rules/update', { id: 'nope', name: 'x' });
  check('rule_update_missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  await post('/api/v1/pt/rules/delete', { id: ruleId });
  r = await post('/api/v1/pt/rules/list');
  check('rule_delete', r.json().items.length === 0, JSON.stringify(r.json()).slice(0, 120));

  // ---------------------------------------------------------------- 订阅按 media_id
  r = await post('/api/v1/pt/subscriptions/upsert', {
    mediaId: 550,
    mediaType: 'movie',
    mediaTitle: '搏击俱乐部',
    posterPath: '/p.jpg',
    enabled: true,
  });
  check('sub_create_by_media_id', r.statusCode === 200 && r.json().ok === true, JSON.stringify(r.json()).slice(0, 160));

  r = await get('/api/v1/pt/subscriptions');
  const sub = (r.json().items || [])[0] || {};
  check(
    'sub_list_has_media_id',
    (r.json().items || []).length === 1 && sub.mediaId === 550 && sub.mediaType === 'movie',
    JSON.stringify(sub).slice(0, 200),
  );

  // 再订阅同一部片：不应新增第二行（按 media_id 去重）
  await post('/api/v1/pt/subscriptions/upsert', {
    mediaId: 550,
    mediaType: 'movie',
    mediaTitle: '搏击俱乐部',
    enabled: true,
  });
  r = await get('/api/v1/pt/subscriptions');
  check(
    'sub_dedupe_by_media_id',
    (r.json().items || []).length === 1,
    'rows=' + (r.json().items || []).length,
  );

  // 同 id 不同类型要能并存（movie / tv 不串）
  await post('/api/v1/pt/subscriptions/upsert', {
    mediaId: 550,
    mediaType: 'tv',
    mediaTitle: '搏击俱乐部(剧)',
    enabled: true,
  });
  r = await get('/api/v1/pt/subscriptions');
  check('sub_movie_tv_coexist', (r.json().items || []).length === 2, 'rows=' + (r.json().items || []).length);

  // ---------------------------------------------------------------- 预览按 media_id
  r = await post('/api/v1/pt/downloads/preview', { mediaId: 550, mediaType: 'movie' });
  check(
    'preview_by_media_id_no_crash',
    r.statusCode === 200 && Array.isArray(r.json().items),
    JSON.stringify(r.json()).slice(0, 160),
  );

  const passed = results.filter((x) => x.ok).length;
  for (const x of results) {
    console.log(`${x.ok ? 'PASS' : 'FAIL'}  ${x.name}${x.ok ? '' : '  ' + x.detail}`);
  }
  console.log(`[discover-shell] ${passed}/${results.length} passed`);

  await app.close();
  fs.rmSync(dataDir, { recursive: true, force: true });
  process.exit(passed === results.length ? 0 : 1);
})().catch((e) => {
  console.error('执行失败:', e);
  process.exit(1);
});
