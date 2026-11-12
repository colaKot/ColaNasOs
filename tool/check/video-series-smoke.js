#!/usr/bin/env node
/**
 * 剧集验收（`/video/series` + `/video/series/items` + `list?series=none`）：
 *   扫描按目录/文件名识别剧名与季集（`S01E02`、`1x02`）→ 影片不带 series
 *   → 剧集列表（季数 / 集数 / 封面 id，剧名序）→ 某剧按季、集排序
 *   → 关键词过滤、cursor 翻页、未知剧名 404、鉴权三态
 *
 * 素材用空文件占位：扫描对探测失败的视频照样入库，因此**不依赖 ffmpeg**。
 * 用法：node tool/check/video-series-smoke.js
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
  'Breaking Bad/Season 2/S02E01 - Seven Thirty-Seven.mkv',
  'The Wire/S01/The.Wire.1x02.mkv',
  'The Wire/S01/The.Wire.1x01.mkv',
  // 第二季故意只放 E01 与 E04 → 缺集应为 E02、E03
  'The Wire/S02/The.Wire.2x01.mkv',
  'The Wire/S02/The.Wire.2x04.mkv',
  'Inception.2010.mkv',
];

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-series-'));
  const filesRoot = path.join(dataDir, 'files');
  const media = path.join(filesRoot, 'media');
  for (const rel of FILES) {
    const abs = path.join(media, rel.split('/').join(path.sep));
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, Buffer.alloc(4096, 3));
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
  check(
    'scan',
    r.statusCode === 200 && r.json().added >= FILES.length,
    `status=${r.statusCode} added=${r.json().added}`,
  );

  // 1. 影片（series=none）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/list?series=none&limit=50',
    headers: reader,
  });
  const movies = r.json().items || [];
  check(
    'movies_only',
    r.statusCode === 200 &&
      movies.length === 1 &&
      movies[0].title.includes('Inception') &&
      movies[0].series === null,
    `n=${movies.length} title=${movies[0] && movies[0].title} series=${movies[0] && movies[0].series}`,
  );

  // 2. 全部影片里剧集字段已填
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?limit=50', headers: reader });
  const all = r.json().items || [];
  const pilot = all.find((i) => i.path.endsWith('S01E01 - Pilot.mkv'));
  check(
    'item_has_series_fields',
    all.length === FILES.length &&
      pilot &&
      pilot.series === 'Breaking Bad' &&
      pilot.season === 1 &&
      pilot.episode === 1,
    `n=${all.length} pilot=${JSON.stringify(pilot && { s: pilot.series, se: pilot.season, ep: pilot.episode })}`,
  );

  // 3. 剧集列表
  r = await app.inject({ method: 'GET', url: '/api/v1/video/series', headers: reader });
  const series = r.json().items || [];
  const bb = series.find((s) => s.name === 'Breaking Bad');
  const tw = series.find((s) => s.name === 'The Wire');
  check(
    'series_list',
    r.statusCode === 200 &&
      series.length === 2 &&
      series[0].name === 'Breaking Bad' &&
      bb.seasons === 2 &&
      bb.episodes === 3 &&
      tw.seasons === 2 &&
      tw.episodes === 4 &&
      typeof bb.coverId === 'string',
    `items=${JSON.stringify(series.map((s) => [s.name, s.seasons, s.episodes]))}`,
  );

  // 4. 某剧的季 / 集排序
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series/items?name=' + encodeURIComponent('Breaking Bad'),
    headers: reader,
  });
  const eps = r.json().items || [];
  check(
    'series_items_sorted',
    r.statusCode === 200 &&
      eps.length === 3 &&
      eps[0].season === 1 &&
      eps[0].episode === 1 &&
      eps[1].episode === 2 &&
      eps[2].season === 2 &&
      eps[2].episode === 1,
    `order=${JSON.stringify(eps.map((e) => `${e.season}x${e.episode}`))}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series/items?name=' + encodeURIComponent('The Wire'),
    headers: reader,
  });
  const twEps = r.json().items || [];
  check(
    'nxnn_naming',
    r.statusCode === 200 &&
      twEps.length === 4 &&
      twEps[0].episode === 1 &&
      twEps[1].episode === 2 &&
      twEps[0].season === 1 &&
      twEps[2].season === 2 &&
      twEps[2].episode === 1 &&
      twEps[3].episode === 4,
    `order=${JSON.stringify(twEps.map((e) => `${e.season}x${e.episode}`))}`,
  );

  // 4.1 整季缺集：The Wire 第二季缺 E02、E03；Breaking Bad 无缺口
  const twMissing = r.json().missing || [];
  check(
    'series_missing',
    twMissing.length === 1 &&
      twMissing[0].season === 2 &&
      JSON.stringify(twMissing[0].episodes) === JSON.stringify([2, 3]),
    `missing=${JSON.stringify(twMissing)}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series/items?name=' + encodeURIComponent('Breaking Bad'),
    headers: reader,
  });
  check(
    'series_no_missing',
    r.statusCode === 200 && (r.json().missing || []).length === 0,
    `missing=${JSON.stringify(r.json().missing)}`,
  );

  // 3.1 首页推荐：电视剧按剧聚合（一部剧一张卡），电影保持一条
  r = await app.inject({ method: 'GET', url: '/api/v1/video/home', headers: reader });  const rec = r.json().recommend || [];
  const recBb = rec.find((x) => x.seriesInfo && x.seriesInfo.name === 'Breaking Bad');
  const recTw = rec.find((x) => x.seriesInfo && x.seriesInfo.name === 'The Wire');
  const recMovie = rec.find((x) => !x.seriesInfo && !x.series);
  check(
    'home_recommend_series',
    r.statusCode === 200 &&
      rec.length === 3 &&
      rec.every((x) => !x.series || !!x.seriesInfo) &&
      recBb &&
      recBb.title === 'Breaking Bad' &&
      recBb.seriesInfo.seasons === 2 &&
      recBb.seriesInfo.episodes === 3 &&
      recTw &&
      recTw.seriesInfo.episodes === 4 &&
      recMovie &&
      recMovie.title.includes('Inception'),
    `rec=${JSON.stringify(rec.map((x) => [x.title, x.seriesInfo && x.seriesInfo.episodes]))}`,
  );

  // 3.2 已看集数 → 剧级三态（0 未看 / 0<n<总 未看完 / =总 已看完）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series/items?name=' + encodeURIComponent('Breaking Bad'),
    headers: reader,
  });
  const bbFirst = (r.json().items || [])[0];
  await app.inject({
    method: 'POST',
    url: '/api/v1/video/watch',
    headers: writer,
    payload: { ids: [bbFirst.id], watched: true },
  });
  r = await app.inject({ method: 'GET', url: '/api/v1/video/series', headers: writer });
  const bbRow = (r.json().items || []).find((s) => s.name === 'Breaking Bad');
  check(
    'series_watched_episodes',
    r.statusCode === 200 && bbRow && bbRow.watchedEpisodes === 1 && bbRow.episodes === 3,
    `bb=${JSON.stringify(bbRow && [bbRow.watchedEpisodes, bbRow.episodes])}`,
  );

  // 3.3 观看状态筛选：看了 1/3 的剧只出现在「未看完」里
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series?watched=watching',
    headers: writer,
  });
  check(
    'series_filter_watching',
    r.statusCode === 200 &&
      (r.json().items || []).length === 1 &&
      r.json().items[0].name === 'Breaking Bad',
    `items=${JSON.stringify((r.json().items || []).map((s) => s.name))}`,
  );
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series?watched=unwatched',
    headers: writer,
  });
  check(
    'series_filter_unwatched',
    r.statusCode === 200 &&
      (r.json().items || []).length === 1 &&
      r.json().items[0].name === 'The Wire',
    `items=${JSON.stringify((r.json().items || []).map((s) => s.name))}`,
  );

  // 3.4 排序：集数降序 The Wire(4) 在前；游标能接着翻下一页
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series?sortBy=episodes&limit=1',
    headers: reader,
  });
  const sortPage1 = r.json();
  const sortCursor = sortPage1.nextCursor;
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series?sortBy=episodes&limit=1&cursor=' + encodeURIComponent(sortCursor || ''),
    headers: reader,
  });
  check(
    'series_sort_by_episodes',
    sortPage1.items &&
      sortPage1.items.length === 1 &&
      sortPage1.items[0].name === 'The Wire' &&
      r.statusCode === 200 &&
      (r.json().items || [])[0]?.name === 'Breaking Bad',
    `p1=${JSON.stringify((sortPage1.items || []).map((s) => s.name))} p2=${JSON.stringify((r.json().items || []).map((s) => s.name))}`,
  );

  // 3.5 智能合集按剧聚合：一部剧只出一张卡，且带 seriesInfo
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/smart-albums/items?key=unwatched&limit=50',
    headers: reader,
  });
  const albumSeries = (r.json().items || [])
    .filter((x) => x.seriesInfo)
    .map((x) => x.seriesInfo.name);
  check(
    'smart_album_one_card_per_series',
    r.statusCode === 200 &&
      albumSeries.length === new Set(albumSeries).size &&
      albumSeries.includes('The Wire') &&
      albumSeries.includes('Breaking Bad'),
    `series=${JSON.stringify(albumSeries)}`,
  );

  // 3.6 普通合集同样按剧聚合：把整部剧的每一集都放进合集，也只出一张卡
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/list?series=' + encodeURIComponent('Breaking Bad') + '&limit=50',
    headers: writer,
  });
  const bbIds = (r.json().items || []).map((x) => x.id);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/upsert',
    headers: writer,
    payload: { name: 'TV collection' },
  });
  const tvCol = r.json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/items',
    headers: writer,
    payload: { id: tvCol.id, itemIds: bbIds, action: 'add' },
  });
  const colItems = r.json().items || [];
  check(
    'collection_one_card_per_series',
    r.statusCode === 200 &&
      bbIds.length === 3 &&
      colItems.length === 1 &&
      colItems[0].seriesInfo &&
      colItems[0].seriesInfo.name === 'Breaking Bad' &&
      colItems[0].seriesInfo.episodes === 3,
    `eps=${bbIds.length} cards=${JSON.stringify(colItems.map((x) => x.title))}`,
  );
  r = await app.inject({ method: 'GET', url: '/api/v1/video/collections', headers: writer });
  check(
    'collection_count_per_series',
    r.statusCode === 200 && r.json().items[0] && r.json().items[0].items === 1,
    `items=${r.json().items[0] && r.json().items[0].items}`,
  );

  // 5. 关键词 + cursor 翻页
  r = await app.inject({ method: 'GET', url: '/api/v1/video/series?q=wire', headers: reader });
  check(
    'series_keyword',
    r.statusCode === 200 &&
      (r.json().items || []).length === 1 &&
      r.json().items[0].name === 'The Wire',
    `items=${JSON.stringify((r.json().items || []).map((s) => s.name))}`,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/video/series?limit=1', headers: reader });
  const page1 = r.json();
  check(
    'series_cursor_page1',
    r.statusCode === 200 &&
      page1.items.length === 1 &&
      page1.items[0].name === 'Breaking Bad' &&
      !!page1.nextCursor,
    `n=${page1.items.length} next=${page1.nextCursor}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series?limit=1&cursor=' + encodeURIComponent(page1.nextCursor),
    headers: reader,
  });
  const page2 = r.json();
  check(
    'series_cursor_page2',
    r.statusCode === 200 &&
      page2.items.length === 1 &&
      page2.items[0].name === 'The Wire' &&
      page2.nextCursor === null,
    `n=${page2.items.length} name=${page2.items[0] && page2.items[0].name}`,
  );

  // 6. 异常与鉴权
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series/items?name=' + encodeURIComponent('No Such Show'),
    headers: reader,
  });
  check('unknown_series_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/video/series' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/video/series', headers: outsider });
  check('missing_scope_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series?cursor=not-base64',
    headers: reader,
  });
  check('bad_cursor_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 剧集级收藏：set → list（聚合季/集数 + 封面）→ 未知剧 404 → 取消
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/series/favorites/set',
    headers: writer,
    payload: { series: 'Breaking Bad', favorite: true },
  });
  check('series_fav_set', r.statusCode === 200 && r.json().favorite === true, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/video/series/favorites', headers: writer });
  const favs = r.json().items || [];
  const bbFav = favs.find((f) => f.series === 'Breaking Bad');
  check(
    'series_fav_list',
    r.statusCode === 200 &&
      Boolean(bbFav) &&
      bbFav.seasons === 2 &&
      bbFav.episodes === 3 &&
      Boolean(bbFav.coverId),
    `items=${favs.length} seasons=${bbFav && bbFav.seasons} episodes=${bbFav && bbFav.episodes}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/series/favorites/set',
    headers: writer,
    payload: { series: 'No Such Series', favorite: true },
  });
  check('series_fav_unknown_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/series/favorites/set',
    headers: writer,
    payload: { series: 'Breaking Bad', favorite: false },
  });
  const afterUnfav = await app.inject({
    method: 'GET',
    url: '/api/v1/video/series/favorites',
    headers: writer,
  });
  check(
    'series_fav_remove',
    r.statusCode === 200 && (afterUnfav.json().items || []).length === 0,
    'items=' + (afterUnfav.json().items || []).length,
  );

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(26)} ${x.detail}`);
  }
  console.log(`\n[video-series] ${results.length - failed.length}/${results.length} passed`);
  await app.close();
  process.exit(failed.length ? 1 : 0);
})();
