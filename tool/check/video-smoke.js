#!/usr/bin/env node
/**
 * SP3-03 video 验收：
 *   建库（越界 400 / 重复 409）→ 扫描（ffmpeg 探测时长/宽高/编码）→ 增量跳过
 *   → 列表排序与 cursor → 搜索 → 详情 → 播放 Range（206）→ 海报（JPEG）
 *   → 只读令牌不能扫描（403）→ 删库级联
 *
 * ffmpeg 不在时自动降级：跳过探测/海报断言，只验证索引与接口可用性。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/video-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(process.cwd(), 'node_modules', 'electron', 'dist', process.platform === 'win32' ? 'electron.exe' : 'electron');
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

/** 与 src/modules/video/ffmpeg.ts 一致：环境变量 → vendor（jellyfin-ffmpeg）→ PATH */
function findFfmpeg() {
  const env = process.env.COLANAS_FFMPEG;
  if (env && env.trim()) return env.trim();
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const vendor = path.join(root, 'vendor', 'ffmpeg');
  for (const p of [path.join(vendor, exe), path.join(vendor, 'bin', exe)]) {
    if (fs.existsSync(p)) return p;
  }
  return exe;
}

const FFMPEG = findFfmpeg();
// 让内核模块与冒烟使用同一个二进制（模块默认不再回落 PATH）
if (FFMPEG !== 'ffmpeg' && FFMPEG !== 'ffmpeg.exe') process.env.COLANAS_FFMPEG = FFMPEG;

function hasFfmpeg() {
  const r = spawnSync(FFMPEG, ['-version'], { encoding: 'utf-8' });
  return r.status === 0;
}

function makeVideo(out, size, seconds, fps = 25) {
  const r = spawnSync(
    FFMPEG,
    [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      `testsrc=size=${size}:rate=${fps}:duration=${seconds}`,
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      out,
    ],
    { encoding: 'utf-8' },
  );
  if (r.status === 0 && fs.existsSync(out) && fs.statSync(out).size > 1000) return true;

  // libx264 缺失时回落到内置 mpeg4
  const r2 = spawnSync(
    FFMPEG,
    [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      `testsrc=size=${size}:rate=${fps}:duration=${seconds}`,
      '-c:v',
      'mpeg4',
      out,
    ],
    { encoding: 'utf-8' },
  );
  return r2.status === 0 && fs.existsSync(out) && fs.statSync(out).size > 1000;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-video-'));
  const filesRoot = path.join(dataDir, 'files');
  const movies = path.join(filesRoot, 'movies');
  fs.mkdirSync(movies, { recursive: true });
  fs.writeFileSync(path.join(movies, 'readme.txt'), 'not a video');

  const ffmpeg = hasFfmpeg();
  const madeA = ffmpeg && makeVideo(path.join(movies, 'Alpha.mp4'), '320x240', 2);
  const madeB = ffmpeg && makeVideo(path.join(movies, 'Beta.mp4'), '640x360', 3);
  // ffmpeg 不可用时写占位文件，保证"索引 + 接口"链路仍可验收
  if (!madeA) fs.writeFileSync(path.join(movies, 'Alpha.mp4'), Buffer.alloc(2048, 1));
  if (!madeB) fs.writeFileSync(path.join(movies, 'Beta.mp4'), Buffer.alloc(2048, 2));

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['video:read', 'video:write', 'files:read'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['video:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };

  console.log(`[info] ffmpeg=${ffmpeg ? 'yes' : 'no'} probe-ready=${madeA && madeB ? 'yes' : 'no'}`);

  // 1. 匿名不可读
  let r = await app.inject({ method: 'GET', url: '/api/v1/video/list' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 越界路径
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries',
    headers: bearer,
    payload: { name: 'bad', path: '../../etc' },
  });
  check('library_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 3. 建库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries',
    headers: bearer,
    payload: { name: 'Movies', path: '/movies' },
  });
  const lib = r.json();
  check('library_create_ok', r.statusCode === 200 && lib.id && lib.path === 'movies', JSON.stringify(lib).slice(0, 80));

  // 4. 重复库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries',
    headers: bearer,
    payload: { name: 'Dup', path: 'movies' },
  });
  check('library_duplicate_409', r.statusCode === 409, 'status=' + r.statusCode);

  // 5. 只读令牌不能扫描
  r = await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: reader, payload: {} });
  check('scan_requires_write', r.statusCode === 403, 'status=' + r.statusCode);

  // 6. 扫描（txt 不计入）
  r = await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: bearer, payload: {} });
  const scan = r.json();
  check('scan_videos', r.statusCode === 200 && scan.videos === 2 && scan.added === 2, JSON.stringify(scan));

  // 7. 增量
  r = await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: bearer, payload: {} });
  const again = r.json();
  check('scan_incremental', again.added === 0 && again.skipped === 2, JSON.stringify(again));

  // 8. 列表（标题序 Alpha < Beta）
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?limit=10', headers: bearer });
  const list = r.json();
  check(
    'list_sorted',
    r.statusCode === 200 && list.items.length === 2 && list.items[0].title === 'Alpha',
    (list.items || []).map((x) => x.title).join(','),
  );

  // 9. probe 结果（有 ffmpeg 才严格断言）
  if (madeA && madeB) {
    const alpha = list.items.find((x) => x.title === 'Alpha');
    const beta = list.items.find((x) => x.title === 'Beta');
    check(
      'probe_metadata',
      !!alpha &&
        !!beta &&
        Math.abs((alpha.durationMs || 0) - 2000) < 300 &&
        alpha.width === 320 &&
        alpha.height === 240 &&
        beta.width === 640 &&
        beta.height === 360 &&
        !!alpha.videoCodec,
      alpha ? `${alpha.durationMs}ms ${alpha.width}x${alpha.height} ${alpha.videoCodec}` : 'missing',
    );
    check(
      'scan_probed_count',
      scan.probed === 2,
      'probed=' + scan.probed,
    );
  } else {
    const alpha = list.items.find((x) => x.title === 'Alpha');
    check('probe_metadata', !!alpha && alpha.durationMs === null, 'ffmpeg 不可用，降级为 null');
  }

  // 10. cursor 分页
  const p1 = (await app.inject({ method: 'GET', url: '/api/v1/video/list?limit=1', headers: bearer })).json();
  const p2 = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/video/list?limit=1&cursor=' + encodeURIComponent(p1.nextCursor || ''),
      headers: bearer,
    })
  ).json();
  check(
    'cursor_pagination',
    p1.items.length === 1 && !!p1.nextCursor && p2.items.length === 1 && p2.items[0].id !== p1.items[0].id,
    `${p1.items.length}/${p2.items.length}`,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?cursor=not-a-cursor', headers: bearer });
  check('bad_cursor_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 11. 搜索
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?q=beta', headers: bearer });
  const searched = r.json();
  check(
    'search_keyword',
    r.statusCode === 200 && searched.items.length === 1 && searched.items[0].title === 'Beta',
    'items=' + (searched.items || []).length,
  );

  // 12. 详情
  const betaItem = searched.items[0];
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/item?id=' + encodeURIComponent(betaItem.id),
    headers: bearer,
  });
  check(
    'item_detail',
    r.statusCode === 200 && r.json().path === 'movies/Beta.mp4',
    'status=' + r.statusCode,
  );

  // 12b. 画质徽章字段（4K / HDR / 杜比）必须出现在列表与详情里（默认 false 也算在位）
  const flagKeys = ['is4k', 'hdr10', 'hdr10plus', 'hlg', 'dolbyVision', 'dolbyAtmos'];
  const detail = r.json();
  check(
    'media_flags_fields',
    flagKeys.every((key) => typeof detail[key] === 'boolean'),
    flagKeys.map((key) => `${key}=${detail[key]}`).join(','),
  );

  // 12c. 合集：创建 → 加片 → 列表计数 → 隔离 → 重命名 → 移出 → 删除
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/upsert',
    headers: bearer,
    payload: { name: 'Weekend' },
  });
  const col = r.json();
  check('collection_create', r.statusCode === 200 && !!col.id, JSON.stringify(col).slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/items',
    headers: bearer,
    payload: { id: col.id, itemIds: [betaItem.id], action: 'add' },
  });
  check(
    'collection_add_item',
    r.statusCode === 200 && r.json().items.length === 1 && r.json().items[0].id === betaItem.id,
    'status=' + r.statusCode,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/video/collections', headers: bearer });
  check(
    'collection_list_count',
    r.statusCode === 200 && r.json().items.length === 1 && r.json().items[0].items === 1,
    JSON.stringify(r.json()).slice(0, 100),
  );

  // 12c-1 合集元数据：简介 / 顺序 / 封面（封面必须是成员）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/upsert',
    headers: bearer,
    payload: { id: col.id, name: 'Weekend', description: '海边两日', sortOrder: 30 },
  });
  const colMeta = r.json();
  check(
    'collection_meta_saved',
    r.statusCode === 200 && colMeta.description === '海边两日' && colMeta.sortOrder === 30,
    `desc=${colMeta.description} sort=${colMeta.sortOrder}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/upsert',
    headers: bearer,
    payload: { id: col.id, name: 'Weekend', coverItemId: 'not-a-member' },
  });
  check('collection_cover_member_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/upsert',
    headers: bearer,
    payload: { id: col.id, name: 'Weekend', coverItemId: betaItem.id },
  });
  check(
    'collection_cover_set',
    r.statusCode === 200 && r.json().coverItemId === betaItem.id,
    'cover=' + r.json().coverItemId,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/video/collections', headers: reader });
  check('collection_isolation', r.statusCode === 200 && r.json().items.length === 0, JSON.stringify(r.json()).slice(0, 80));

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/collections/items?id=' + encodeURIComponent(col.id),
    headers: reader,
  });
  check('collection_items_isolation_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/upsert',
    headers: bearer,
    payload: { id: col.id, name: 'Weekend v2' },
  });
  check('collection_rename', r.statusCode === 200 && r.json().name === 'Weekend v2', JSON.stringify(r.json()).slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/items',
    headers: bearer,
    payload: { id: col.id, itemIds: [betaItem.id], action: 'remove' },
  });
  check('collection_remove_item', r.statusCode === 200 && r.json().items.length === 0, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/collections/delete',
    headers: bearer,
    payload: { id: col.id },
  });
  const afterDelete = await app.inject({ method: 'GET', url: '/api/v1/video/collections', headers: bearer });
  check(
    'collection_delete',
    r.statusCode === 200 && afterDelete.json().items.length === 0,
    'status=' + r.statusCode,
  );

  // 12d. 媒体浏览：库根目录逐级浏览（文件夹 / 视频 / 其它）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/browse?libraryId=' + encodeURIComponent(lib.id),
    headers: bearer,
  });
  const browse = r.json();
  const betaBrowse = (browse.items || []).find((x) => x.name === 'Beta.mp4');
  const txtBrowse = (browse.items || []).find((x) => x.name === 'readme.txt');
  check(
    'browse_root',
    r.statusCode === 200 &&
      browse.items.length === 3 &&
      betaBrowse &&
      betaBrowse.mediaType === 'video' &&
      betaBrowse.id === betaItem.id &&
      txtBrowse &&
      txtBrowse.mediaType === 'other',
    JSON.stringify(browse).slice(0, 160),
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/browse?libraryId=' + encodeURIComponent(lib.id) + '&path=' + encodeURIComponent('../'),
    headers: bearer,
  });
  check('browse_path_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/browse?libraryId=nope',
    headers: bearer,
  });
  check('browse_unknown_library_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 12e. 重复视频（当前两条片子片名不同 → 0 组；归一化逻辑由单测覆盖）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/duplicates?libraryId=' + encodeURIComponent(lib.id),
    headers: bearer,
  });
  const dups = r.json();
  check(
    'duplicates_empty',
    r.statusCode === 200 && Array.isArray(dups.groups) && dups.groups.length === 0 && dups.scanned >= 2,
    JSON.stringify(dups).slice(0, 120),
  );

  // 12f. 智能合集：预设规则计数 + 条目（与计数同一份条件）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/smart-albums',
    headers: bearer,
  });
  const smart = r.json();
  const smartMap = Object.fromEntries((smart.items || []).map((x) => [x.key, x.count]));
  check(
    'smart_albums_counts',
    r.statusCode === 200 &&
      smartMap.recent30 === 2 &&
      smartMap.unwatched === 2 &&
      smartMap['4k'] === 0 &&
      smartMap.hdr === 0,
    JSON.stringify(smartMap),
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/smart-albums/items?key=recent30',
    headers: bearer,
  });
  check(
    'smart_album_items',
    r.statusCode === 200 && r.json().items.length === 2,
    'items=' + (r.json().items || []).length,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/smart-albums/items?key=nope',
    headers: bearer,
  });
  check('smart_album_unknown_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 13. 统计
  r = await app.inject({ method: 'GET', url: '/api/v1/video/stats', headers: bearer });
  const stats = r.json();
  check(
    'stats',
    r.statusCode === 200 && stats.items === 2 && stats.libraries === 1,
    JSON.stringify(stats),
  );

  // 14. 播放（Range）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/stream?id=' + encodeURIComponent(betaItem.id),
    headers: Object.assign({ range: 'bytes=0-9' }, reader),
  });
  check('stream_range_206', r.statusCode === 206 && r.rawPayload.length === 10, 'status=' + r.statusCode);

  // 14b. 外部播放器直链（短期令牌，无需 Authorization 头）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/stream-url?id=' + encodeURIComponent(betaItem.id),
    headers: reader,
  });
  const streamUrl = r.json();
  const direct = streamUrl.url
    ? await app.inject({ method: 'GET', url: streamUrl.url, headers: { range: 'bytes=0-4' } })
    : { statusCode: 0 };
  check(
    'stream_url_playable',
    r.statusCode === 200 && !!streamUrl.url && direct.statusCode === 206,
    `url=${r.statusCode} play=${direct.statusCode}`,
  );

  const noAuth = await app.inject({
    method: 'GET',
    url: '/api/v1/video/stream?id=' + encodeURIComponent(betaItem.id),
  });
  check('stream_requires_auth', noAuth.statusCode === 401, 'status=' + noAuth.statusCode);

  // 15. 海报（有 ffmpeg 才断言；否则 404 属预期降级）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/poster?id=' + encodeURIComponent(betaItem.id),
    headers: reader,
  });
  if (madeB) {
    check(
      'poster_jpeg',
      r.statusCode === 200 && String(r.headers['content-type']).startsWith('image/jpeg') && r.rawPayload.length > 500,
      `status=${r.statusCode} type=${r.headers['content-type']} bytes=${r.rawPayload.length}`,
    );
  } else {
    check('poster_jpeg', r.statusCode === 404, 'ffmpeg 不可用，海报 404 属预期');
  }

  // 16. 未知 id
  r = await app.inject({ method: 'GET', url: '/api/v1/video/item?id=nope', headers: bearer });
  check('item_404', r.statusCode === 404, 'status=' + r.statusCode);

  // ================================================================ 媒体信息层（V1-V4）
  // 16.1 事后补 nfo：文件没变，增量扫描也必须把元数据吃进来。
  //      这条是「搜刮/显示全不对」的根因回归：旧实现只按 size+mtime 跳过，
  //      用户补了 nfo 界面永远不更新。
  fs.writeFileSync(
    path.join(movies, 'Alpha.nfo'),
    [
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
      '<movie>',
      '  <title>Alpha 2049</title>',
      '  <year>2019</year>',
      '  <rating>8.4</rating>',
      '  <plot>测试剧情</plot>',
      '  <genre>科幻</genre>',
      '  <country>美国</country>',
      '  <uniqueid type="imdb">tt1000001</uniqueid>',
      '  <uniqueid type="tmdb">603</uniqueid>',
      '</movie>',
    ].join('\n'),
    'utf-8',
  );
  r = await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: bearer, payload: {} });
  const scanNfo = r.json();
  check('scan_backfill_nfo', r.statusCode === 200 && (scanNfo.nfoFilled || 0) >= 1, JSON.stringify(scanNfo));

  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?q=Alpha', headers: bearer });
  const alphaScraped = (r.json().items || [])[0];
  check(
    'nfo_applied',
    !!alphaScraped &&
      alphaScraped.title === 'Alpha 2049' &&
      alphaScraped.year === 2019 &&
      Math.abs(alphaScraped.score - 8.4) < 0.01 &&
      (alphaScraped.genres || []).includes('科幻') &&
      (alphaScraped.regions || []).includes('美国') &&
      alphaScraped.imdbId === 'tt1000001' &&
      alphaScraped.tmdbId === 603 &&
      alphaScraped.nfoSource === 'nfo',
    JSON.stringify(alphaScraped || {}).slice(0, 160),
  );

  // 16.2 筛选：类型 / 年份 / 已刮削
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?genres=' + encodeURIComponent('科幻'), headers: bearer });
  check('list_filter_genre', r.statusCode === 200 && (r.json().items || []).length === 1, 'items=' + (r.json().items || []).length);
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?years=2019', headers: bearer });
  check('list_filter_year', r.statusCode === 200 && (r.json().items || []).length === 1, 'items=' + (r.json().items || []).length);
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?scraped=false', headers: bearer });
  check('list_filter_unscraped', r.statusCode === 200 && (r.json().items || []).length === 1, 'items=' + (r.json().items || []).length);

  // 16.3 排序：评分降序把刮削过的排前面
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?sortBy=score&sortOrder=desc', headers: bearer });
  const sortedByScore = r.json();
  check(
    'list_sort_score',
    r.statusCode === 200 && (sortedByScore.items || [])[0]?.title === 'Alpha 2049',
    (sortedByScore.items || []).map((x) => x.title).join(','),
  );
  // 评分排序 + 分页要能翻到底（游标换了格式，容易翻不动）
  const scoreP1 = (await app.inject({ method: 'GET', url: '/api/v1/video/list?sortBy=score&limit=1', headers: bearer })).json();
  const scoreP2 = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/video/list?sortBy=score&limit=1&cursor=' + encodeURIComponent(scoreP1.nextCursor || ''),
      headers: bearer,
    })
  ).json();
  check(
    'sort_cursor_pagination',
    scoreP1.items.length === 1 && scoreP2.items.length === 1 && scoreP2.items[0].id !== scoreP1.items[0].id,
    `${scoreP1.items.length}/${scoreP2.items.length}`,
  );

  // 16.4 计数与按库统计
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list/count', headers: bearer });
  const count = r.json();
  check('list_count', r.statusCode === 200 && count.total === 2 && count.scraped === 1, JSON.stringify(count));
  r = await app.inject({ method: 'GET', url: '/api/v1/video/stats?libraryId=' + lib.id, headers: bearer });
  const libStats = r.json();
  check(
    'stats_by_library',
    r.statusCode === 200 && libStats.libraries === 1 && libStats.items === 2,
    JSON.stringify(libStats),
  );

  // ================================================================ 已观看（V7）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/watch',
    headers: bearer,
    payload: { ids: [alphaScraped.id], watched: true },
  });
  check('watch_mark', r.statusCode === 200 && r.json().updated === 1, JSON.stringify(r.json()));
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?q=Alpha', headers: bearer });
  check('watch_reflected', (r.json().items || [])[0]?.watched === true, JSON.stringify((r.json().items || [])[0] || {}).slice(0, 80));
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?watched=true', headers: bearer });
  check('watch_filter', (r.json().items || []).length === 1, 'items=' + (r.json().items || []).length);
  // 按用户隔离：另一个用户看不到 u1 的已看标记
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?watched=true', headers: reader });
  check('watch_isolation', (r.json().items || []).length === 0, 'items=' + (r.json().items || []).length);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/watch',
    headers: bearer,
    payload: { ids: [alphaScraped.id], watched: false },
  });
  check('watch_unmark', r.json().updated === 1, JSON.stringify(r.json()));

  // ================================================================ 首页四段（V4）
  r = await app.inject({ method: 'GET', url: '/api/v1/video/home', headers: bearer });
  const home = r.json();
  check(
    'home_sections',
    r.statusCode === 200 &&
      Array.isArray(home.sources) &&
      home.sources.length === 1 &&
      Array.isArray(home.recommend) &&
      home.recommend.length === 2 &&
      Array.isArray(home.recentPlay) &&
      Array.isArray(home.recentAdd) &&
      home.recentAdd.length === 1 &&
      (home.recentAdd[0].items || []).length === 2,
    JSON.stringify({ s: home.sources?.length, r: home.recommend?.length, a: home.recentAdd?.length }),
  );

  // ================================================================ 排重四钥匙（V6）
  // 16.2 nfo 冲突合并：判据是「磁盘 mtime vs 我们上次写库时间」
  //      —— 之前一律 coalesce，用户手改 nfo 后重扫永远不生效。
  const alphaNfo = path.join(movies, 'Alpha.nfo');
  // ① 用户改过（文件比 nfo_updated_at 新）→ 以文件为准，覆盖库里的旧值
  await sql`
    update video_items set nfo_name = 'DB 旧名', nfo_year = 2001, nfo_updated_at = ${Math.floor(Date.now() / 1000) - 3600}
     where rel_path = 'movies/Alpha.mp4'
  `.execute(k.db);
  fs.writeFileSync(
    alphaNfo,
    '<?xml version="1.0" encoding="UTF-8"?>\n<movie>\n  <title>手改名</title>\n  <year>2020</year>\n  <uniqueid type="imdb">tt1000001</uniqueid>\n</movie>\n',
    'utf-8',
  );
  const nowDate = new Date();
  fs.utimesSync(alphaNfo, nowDate, nowDate);
  await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: bearer, payload: {} });
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?q=Alpha', headers: bearer });
  const editedItem = (r.json().items || [])[0] || {};
  check(
    'nfo_user_edit_wins',
    editedItem.title === '手改名' && editedItem.year === 2020,
    JSON.stringify({ title: editedItem.title, year: editedItem.year }),
  );

  // ② 库里比文件新（例如刚刮削过）→ 保留库里的值，不被旧文件打回去
  await sql`
    update video_items set nfo_name = 'DB 新名', nfo_year = 2021, nfo_updated_at = ${Math.floor(Date.now() / 1000) + 3600}
     where rel_path = 'movies/Alpha.mp4'
  `.execute(k.db);
  await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: bearer, payload: {} });
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?q=Alpha', headers: bearer });
  const keptItem = (r.json().items || [])[0] || {};
  check(
    'nfo_db_newer_kept',
    keptItem.title === 'DB 新名' && keptItem.year === 2021,
    JSON.stringify({ title: keptItem.title, year: keptItem.year }),
  );

  // 让 Beta 的 nfo 与 Alpha 共用同一个 IMDB —— 名字完全不同，只有 imdb 这把钥匙能并上
  fs.writeFileSync(
    path.join(movies, 'Beta.nfo'),
    '<movie><title>完全不同的名字</title><year>2021</year><uniqueid type="imdb">tt1000001</uniqueid></movie>',
    'utf-8',
  );
  await app.inject({ method: 'POST', url: '/api/v1/video/scan', headers: bearer, payload: {} });
  r = await app.inject({ method: 'GET', url: '/api/v1/video/duplicates', headers: bearer });
  const dup = r.json();
  check(
    'duplicates_by_imdb',
    r.statusCode === 200 &&
      dup.groups.length === 1 &&
      dup.groups[0].count === 2 &&
      (dup.groups[0].keys || []).some((x) => String(x).startsWith('imdb:')),
    JSON.stringify({ groups: dup.groups.length, keys: dup.groups[0]?.keys }).slice(0, 120),
  );
  const dupItems = dup.groups[0]?.items || [];
  check(
    'duplicates_suggest_keep',
    dupItems.filter((x) => x.suggestedKeep).length === 1,
    'suggested=' + dupItems.filter((x) => x.suggestedKeep).length,
  );

  // ================================================================ 刮削（V3）
  // 没配 TMDB Key 时必须回 unavailable（而不是 500，也不能静默成功）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/scrape/start',
    headers: bearer,
    payload: { id: alphaScraped.id },
  });
  const scrapeNoKey = r.json();
  check(
    'scrape_without_key',
    r.statusCode === 200 && scrapeNoKey.status === 'unavailable',
    JSON.stringify(scrapeNoKey).slice(0, 120),
  );
  r = await app.inject({ method: 'GET', url: '/api/v1/video/tmdb/settings', headers: bearer });
  const tmdbSet = r.json();
  check(
    'tmdb_settings_get',
    r.statusCode === 200 && tmdbSet.configured === false && typeof tmdbSet.minScore === 'number' && tmdbSet.writeSidecar === false,
    JSON.stringify(tmdbSet),
  );

  // 清理刮削：元数据清空 → 标题回退文件名 → 海报口 404
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/scrape/cleanup',
    headers: bearer,
    payload: { id: alphaScraped.id },
  });
  check('scrape_cleanup', r.statusCode === 200 && r.json().cleared === true, JSON.stringify(r.json()));
  r = await app.inject({ method: 'GET', url: '/api/v1/video/list?q=Alpha', headers: bearer });
  const afterCleanup = (r.json().items || [])[0];
  check(
    'cleanup_resets_title',
    !!afterCleanup && afterCleanup.title === 'Alpha' && afterCleanup.year === null && afterCleanup.nfoSource === 'none',
    JSON.stringify(afterCleanup || {}).slice(0, 120),
  );
  r = await app.inject({ method: 'GET', url: '/api/v1/video/art?id=' + encodeURIComponent(alphaScraped.id), headers: bearer });
  check('art_404_without_meta', r.statusCode === 404, 'status=' + r.statusCode);

  // 22. 库级开关（此前这些列只有读没有写）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/flags',
    headers: bearer,
    payload: { id: lib.id, showInHome: false, autoScrape: true, audioNormalize: true },
  });
  const flags = r.json();
  check(
    'library_flags_saved',
    r.statusCode === 200 &&
      flags.showInHome === 0 &&
      flags.autoScrape === 1 &&
      flags.audioNormalize === 1,
    `home=${flags.showInHome} auto=${flags.autoScrape} norm=${flags.audioNormalize}`,
  );

  const libsAfter = (
    await app.inject({ method: 'GET', url: '/api/v1/video/libraries', headers: bearer })
  ).json();
  const libRow = libsAfter.items.find((x) => x.id === lib.id) || {};
  check(
    'library_flags_in_list',
    libRow.showInHome === 0 && libRow.autoScrape === 1 && libRow.scrapeEnabled === 1,
    `home=${libRow.showInHome} auto=${libRow.autoScrape}`,
  );

  // 关掉刮削时 autoScrape 仍可能为 1（服务端只存原值），执行时才会跳过 —— 断言这条语义
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/flags',
    headers: bearer,
    payload: { id: lib.id, showInHome: true, autoScrape: false },
  });
  check(
    'library_flags_reset',
    r.statusCode === 200 && r.json().showInHome === 1 && r.json().autoScrape === 0,
    `home=${r.json().showInHome} auto=${r.json().autoScrape}`,
  );

  // 22c. 演员作品关联：给条目写 nfo_actors → 重建 → 演员列表/作品都能查到
  //      （`jp_actor_items` 以前没有任何写入点，所以"影片数"恒为 0）
  await sql`
    update video_items set nfo_actors = '["テスト 花子"]' where id = ${betaItem.id}
  `.execute(k.db);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/jp_actor/rebuild',
    headers: bearer,
    payload: {},
  });
  const rebuilt = r.json();
  check(
    'actor_rebuild',
    r.statusCode === 200 && rebuilt.links >= 1 && rebuilt.actors >= 1,
    `links=${rebuilt.links} actors=${rebuilt.actors}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/jp_actor/list?limit=50',
    headers: bearer,
  });
  const actorRow = (r.json().items || []).find((a) => a.name === 'テスト 花子') || {};
  check(
    'actor_list_count',
    r.statusCode === 200 && actorRow.items === 1,
    `items=${actorRow.items}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/jp_actor/works?name=' + encodeURIComponent('テスト 花子'),
    headers: bearer,
  });
  const works = r.json();
  check(
    'actor_works_hit',
    r.statusCode === 200 && works.items.length === 1 && works.items[0].id === betaItem.id,
    'n=' + works.items.length,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/jp_actor/works?name=' + encodeURIComponent('查无此人'),
    headers: bearer,
  });
  check('actor_works_miss', r.statusCode === 200 && r.json().items.length === 0, 'n=' + r.json().items.length);

  // 22d. 日榜角标：写入一期榜单快照 → 列表里该番号带 rankDaily
  await sql`
    update video_items set code = 'ABC-123' where id = ${betaItem.id}
  `.execute(k.db);
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values ('jp_rank', 'movie:daily:https://javdb.com',
            '[{"rank":3,"code":"ABC-123","title":"beta"}]', 1, ${Math.floor(Date.now() / 1000)})
    on conflict(catalog_type, key) do update set payload = excluded.payload,
      snapshot_at = excluded.snapshot_at
  `.execute(k.db);
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/list?libraryId=' + encodeURIComponent(lib.id) + '&limit=50',
    headers: bearer,
  });
  const ranked = (r.json().items || []).find((x) => x.id === betaItem.id) || {};
  check('list_rank_badge', r.statusCode === 200 && ranked.rankDaily === 3, `rank=${ranked.rankDaily}`);

  // 22e. 演员作品排序：收藏优先（其次未看，再按入库时间）
  await sql`
    update video_items set nfo_actors = '["テスト 花子"]' where rel_path = 'movies/Alpha.mp4'
  `.execute(k.db);
  await app.inject({
    method: 'POST',
    url: '/api/v1/video/jp_actor/rebuild',
    headers: bearer,
    payload: {},
  });
  // 把入库较早的 Alpha 标成收藏，它应当排到 Beta 前面
  const alphaRow = (
    await sql`select id from video_items where rel_path = 'movies/Alpha.mp4'`.execute(k.db)
  ).rows[0];
  await app.inject({
    method: 'POST',
    url: '/api/v1/video/favorites/set',
    headers: bearer,
    payload: { ids: [alphaRow.id], favorite: true },
  });
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/jp_actor/works?name=' + encodeURIComponent('テスト 花子'),
    headers: bearer,
  });
  const orderedWorks = r.json().items || [];
  check(
    'actor_works_favorite_first',
    r.statusCode === 200 && orderedWorks.length === 2 && orderedWorks[0].id === alphaRow.id,
    'first=' + (orderedWorks[0] || {}).id + ' n=' + orderedWorks.length,
  );

  // 22b. 「入库即刮」的任务处理器必须真的注册了（拼错的 type 只会在运行期静默不跑）
  const registered = k.queue.registered();
  check(
    'autoscrape_task_registered',
    registered.includes('video.scrape.auto') && registered.includes('video.scan'),
    'registered=' + registered.filter((t) => t.startsWith('video.')).join(','),
  );

  // 23. 观看历史：筛选（未看完 / 已看完）+ 清空
  await app.inject({
    method: 'POST',
    url: '/api/v1/video/progress/save',
    headers: bearer,
    payload: { id: betaItem.id, position: '00:10:00', percent: 40 },
  });
  let pl = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/video/progress/list?state=unfinished',
      headers: bearer,
    })
  ).json();
  check('history_unfinished', pl.items.length === 1 && pl.items[0].percent === 40, 'n=' + pl.items.length);

  pl = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/video/progress/list?state=finished',
      headers: bearer,
    })
  ).json();
  check('history_finished_empty', pl.items.length === 0, 'n=' + pl.items.length);

  await app.inject({
    method: 'POST',
    url: '/api/v1/video/progress/save',
    headers: bearer,
    payload: { id: betaItem.id, position: '00:59:00', percent: 96 },
  });
  pl = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/video/progress/list?state=finished',
      headers: bearer,
    })
  ).json();
  check('history_finished_hit', pl.items.length === 1 && pl.items[0].percent === 96, 'n=' + pl.items.length);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/progress/clear',
    headers: bearer,
    payload: { onlyFinished: true },
  });
  check('history_clear_finished', r.statusCode === 200 && r.json().cleared === 1, JSON.stringify(r.json()));

  const afterClear = (
    await app.inject({ method: 'GET', url: '/api/v1/video/progress/list', headers: bearer })
  ).json();
  check('history_after_clear', afterClear.items.length === 0, 'n=' + afterClear.items.length);

  // 17. 删库级联
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/remove',
    headers: bearer,
    payload: { id: lib.id },
  });
  const after = (await app.inject({ method: 'GET', url: '/api/v1/video/stats', headers: bearer })).json();
  check(
    'library_remove_cascade',
    r.statusCode === 200 && after.items === 0 && after.libraries === 0,
    JSON.stringify(after),
  );

  // ---- SMB 片源：创建不 stat、列表只读缓存、probe 才真探（800ms 超时不拖住接口）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries',
    headers: bearer,
    payload: {
      name: 'smb-lib',
      connType: 'smb',
      host: '192.0.2.1',
      share: 'media',
      subPath: 'movies',
      username: 'nas',
      password: 'secret',
    },
  });
  const smb = r.json();
  check(
    'smb_library_create',
    r.statusCode === 200 && smb.connType === 'smb' && smb.onlineState === 0,
    JSON.stringify(smb).slice(0, 120),
  );
  check('smb_unc_path', smb.path === '\\\\192.0.2.1\\media\\movies', smb.path);

  // 改 SMB 子路径 = root_path 变了。以前按 root 对不上旧行就拿旧 id 去 insert，
  // 主键冲突直接 500；现在按位置复用旧行，路径能正常改。
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/update',
    headers: bearer,
    payload: { id: smb.id, subPath: 'movies2' },
  });
  check(
    'smb_update_changed_path',
    r.statusCode === 200 && r.json().path === '\\\\192.0.2.1\\media\\movies2',
    'status=' + r.statusCode + ' ' + r.body.slice(0, 120),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/video/libraries', headers: bearer });
  check(
    'smb_list_reads_cache',
    r.json().items.some((x) => x.id === smb.id && x.onlineState === 0),
    'cached=0',
  );

  const probeStart = Date.now();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/sources/probe',
    headers: bearer,
    payload: { id: smb.id },
  });
  const probeMs = Date.now() - probeStart;
  check(
    'smb_probe_offline',
    r.statusCode === 200 && r.json().onlineState === 2 && probeMs < 3000,
    `state=${r.json().onlineState} ms=${probeMs}`,
  );

  // 离线来源：索引行还在，但列表 / 统计不能再显示，封面也不能去 stat 网络盘
  await sql`
    insert into video_items
      (id, library_id, rel_path, title, container, size, mtime, created_at, media_type)
    values ('smb-offline-item', ${smb.id}, ${'\\\\192.0.2.1\\media\\movies2\\Offline.mp4'},
            'Offline.Movie', 'mkv', 1000, 100, 100, 'video')
  `.execute(k.db);
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list?libraryId=${smb.id}`,
    headers: bearer,
  });
  check(
    'smb_offline_hidden_from_list',
    r.statusCode === 200 && !r.json().items.some((x) => x.id === 'smb-offline-item'),
    'items=' + r.json().items.map((x) => x.id).join(','),
  );
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/stats?libraryId=${smb.id}`,
    headers: bearer,
  });
  check('smb_offline_stats', r.json().items === 0, JSON.stringify(r.json()));
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/video/art?id=smb-offline-item',
    headers: bearer,
  });
  check('smb_offline_art_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/remove',
    headers: bearer,
    payload: { id: smb.id },
  });
  check('smb_offline_cleanup', r.statusCode === 200, r.body.slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/sources/probe',
    headers: bearer,
    payload: { id: 'no-such' },
  });
  check('smb_probe_unknown_404', r.statusCode === 404, 'status=' + r.statusCode);

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