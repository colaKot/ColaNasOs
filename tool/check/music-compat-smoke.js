#!/usr/bin/env node
/**
 * 既有实现 音乐兼容层（`/api/v1/music/compat/*`）验收：
 *   来源增删扫 → 列表（排序 / 分页 / 搜索 / 过滤 / 收藏 / 历史）
 *   → 详情 → 专辑艺人聚合 → 歌单增删查 → 合集增删查
 *   → 歌词读写 → 曲目删除 → 时长单位（秒）
 *
 * 这层是给「从 既有实现 整页搬过来的音乐前端」用的：int id（= rowid）、
 * page/pageSize 偏移分页、snake_case。这里只验它的外形与语义，不验播放。
 *
 * ffmpeg 不在时自动降级（跳过 tags / 聚合严格断言），只验结构与增删改链路。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/music-compat-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { sql } = require('kysely');

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

// ---------------------------------------------------------------- 在线刮削 mock
// 所有断言都不依赖外网：把 scrape.ts 的出站请求换成可控假响应。
// 必须在 startKernel() 之前设置 —— compat 路由 require 的是同一个模块实例。
const scrape = require(path.join(root, 'dist', 'src', 'modules', 'music', 'scrape.js'));
const FAKE_JPEG = Uint8Array.from([0xff, 0xd8, 0xff, 0xd9]);
const fakeRes = (obj, type, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  headers: { get: (n) => (String(n).toLowerCase() === 'content-type' ? type : null) },
  json: async () => obj,
  arrayBuffer: async () => FAKE_JPEG.buffer.slice(0),
});
const LRCLIB_FAKE = [
  {
    id: 'L1', trackName: '鲜花', artistName: '回春丹乐队', albumName: '鲜花', duration: 341,
    syncedLyrics: '[00:00.00]鲜花\n[00:12.34]回春丹乐队\n', plainLyrics: '鲜花 回春丹乐队',
  },
  // 只有纯文本、没有时间轴：写进 .lrc 也解析不出来，应当被过滤掉
  { id: 'L2', trackName: '无名', artistName: '', albumName: '', duration: 200, plainLyrics: '纯文本' },
];
const ITUNES_FAKE = {
  resultCount: 2,
  results: [
    {
      trackName: '鲜花', artistName: '回春丹乐队', trackTimeMillis: 1000,
      artworkUrl100: 'https://img.local/art/100x100bb.jpg',
    },
    // 现场版：标题很像但时长差得远，必须被打分压下去
    {
      trackName: '鲜花 (现场)', artistName: '回春丹', trackTimeMillis: 182000,
      artworkUrl100: 'https://img.local/live/100x100bb.jpg',
    },
  ],
};
// 真实场景：中文单曲的正版封面挂在「<标题> - Single」这个专辑上
const ITUNES_ALBUM_FAKE = {
  resultCount: 1,
  results: [
    {
      collectionName: '鲜花 - Single', artistName: 'Young Dan',
      artworkUrl100: 'https://img.local/art/100x100bb.jpg',
    },
  ],
};
let itunesMode = 'ok'; // ok | error | empty
let imageHits = 0;
let lrclibHits = 0;
let albumHits = 0;
scrape.__setFetch(async (url) => {
  const u = String(url);
  if (u.startsWith('https://lrclib.net/')) {
    lrclibHits += 1;
    // 模拟 LRCLIB 的词序敏感：「鲜花 回春丹乐队」0 条，「鲜花」才有
    const q = new URL(u).searchParams.get('q') || '';
    return fakeRes(q === '鲜花' ? LRCLIB_FAKE : [], 'application/json');
  }
  if (u.startsWith('https://itunes.apple.com/')) {
    if (itunesMode === 'error') return fakeRes(null, 'text/plain', 503);
    if (itunesMode === 'empty') return fakeRes({ resultCount: 0, results: [] }, 'application/json');
    const entity = new URL(u).searchParams.get('entity');
    if (entity === 'album') albumHits += 1;
    return fakeRes(entity === 'album' ? ITUNES_ALBUM_FAKE : ITUNES_FAKE, 'application/json');
  }
  if (u.startsWith('https://img.local/')) {
    imageHits += 1;
    return fakeRes(null, 'image/jpeg');
  }
  return fakeRes(null, 'text/plain', 404);
});

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

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
if (FFMPEG !== 'ffmpeg' && FFMPEG !== 'ffmpeg.exe') process.env.COLANAS_FFMPEG = FFMPEG;

function hasFfmpeg() {
  return spawnSync(FFMPEG, ['-version'], { encoding: 'utf-8' }).status === 0;
}

function makeAudio(out, opts) {
  const args = [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    `sine=frequency=${opts.freq}:duration=${opts.sec}`,
    '-c:a',
    'aac',
    '-b:a',
    '96k',
    '-t',
    String(opts.sec),
  ];
  for (const [k, v] of Object.entries(opts.meta)) args.push('-metadata', `${k}=${v}`);
  args.push(out);
  const r = spawnSync(FFMPEG, args, { encoding: 'utf-8' });
  return r.status === 0 && fs.existsSync(out) && fs.statSync(out).size > 1000;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-music-compat-'));
  const filesRoot = path.join(dataDir, 'files');
  const songs = path.join(filesRoot, 'music');
  fs.mkdirSync(songs, { recursive: true });

  const ffmpeg = hasFfmpeg();
  if (ffmpeg) {
    makeAudio(path.join(songs, 'Alpha.m4a'), {
      freq: 440,
      sec: 2,
      meta: { title: 'Alpha Song', artist: 'Artist A', album: 'Album One', track: '1', date: '2021' },
    });
    makeAudio(path.join(songs, 'Beta.m4a'), {
      freq: 880,
      sec: 3,
      meta: { title: 'Beta Song', artist: 'Artist B', album: 'Album Two', track: '2/10', date: '2019' },
    });
  }
  if (!fs.existsSync(path.join(songs, 'Alpha.m4a'))) {
    fs.writeFileSync(path.join(songs, 'Alpha.m4a'), Buffer.alloc(4096, 1));
  }
  if (!fs.existsSync(path.join(songs, 'Beta.m4a'))) {
    fs.writeFileSync(path.join(songs, 'Beta.m4a'), Buffer.alloc(4096, 2));
  }

  // 简繁 / 模糊搜索的中文曲目：单独放一个来源，等上面那些「2 首歌」的计数断言
  // 全部跑完再挂载，避免改动原有断言。文件名本身用繁体，ffmpeg 缺席时也能测。
  const cnSongs = path.join(filesRoot, 'music_cn');
  fs.mkdirSync(cnSongs, { recursive: true });
  const cnFixtures = [
    { file: '我愛臺妹.m4a', meta: { title: '我愛臺妹', artist: 'MC HotDog', album: '我愛臺妹' } },
    { file: '鮮花.m4a', meta: { title: '鮮花', artist: '回春丹樂隊', album: '鮮花' } },
    { file: '我爱的人.m4a', meta: { title: '我爱的人', artist: '周杰伦', album: '我們都愛這個倫' } },
    { file: 'track_cn_007.m4a', meta: { title: '晴天', artist: '周杰倫', album: '葉惠美' } },
  ];
  for (const f of cnFixtures) {
    const out = path.join(cnSongs, f.file);
    if (ffmpeg) makeAudio(out, { freq: 660, sec: 1, meta: f.meta });
    if (!fs.existsSync(out)) fs.writeFileSync(out, Buffer.alloc(4096, 3));
  }
  // 旁挂 LRC：验证 detail 会把歌词回给搬运过来的播放器
  fs.writeFileSync(path.join(cnSongs, '鮮花.lrc'), '[00:00.00]鲜花\n[00:12.34]回春丹乐队\n', 'utf8');

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });
  const post = async (url, headers, payload) =>
    app.inject({ method: 'POST', url, headers, payload: payload || {} });

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['music:read', 'music:write', 'files:read'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['music:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };

  console.log(`[info] ffmpeg=${ffmpeg ? 'yes' : 'no'}`);

  // ---------------------------------------------------------------- 鉴权

  let r = await post('/api/v1/music/compat/list', {}, { page: 1 });
  check('anon_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await post('/api/v1/music/compat/source/add', reader, { path: 'music' });
  check('source_add_requires_write', r.statusCode === 403, 'status=' + r.statusCode);

  // ---------------------------------------------------------------- 来源

  r = await post('/api/v1/music/compat/source/add', bearer, { path: '../../etc' });
  check('source_add_escape_400', r.statusCode === 400 || r.json().ok === false, JSON.stringify(r.json()).slice(0, 60));

  r = await post('/api/v1/music/compat/source/add', bearer, { path: 'music' });
  const addRes = r.json();
  check('source_add_ok', r.statusCode === 200 && addRes.ok === true && addRes.id > 0, JSON.stringify(addRes));

  r = await post('/api/v1/music/compat/source/add', bearer, { path: 'music' });
  check('source_add_idempotent', r.json().id === addRes.id, 'id=' + r.json().id);

  r = await post('/api/v1/music/compat/source/list', bearer, {});
  const sources = r.json();
  check(
    'source_list',
    Array.isArray(sources) && sources.length === 1 && sources[0].path === 'music' && sources[0].exists === true,
    JSON.stringify(sources).slice(0, 100),
  );

  r = await post('/api/v1/music/compat/source/scan', bearer, { path: 'music', sync: true });
  const scanRes = r.json();
  check('source_scan', r.statusCode === 200 && scanRes.ok === true, JSON.stringify(scanRes).slice(0, 100));

  // ---------------------------------------------------------------- 列表

  r = await post('/api/v1/music/compat/list', bearer, { page: 1, page_size: 30 });
  let list = r.json();
  check(
    'list_shape',
    r.statusCode === 200 &&
      Array.isArray(list.items) &&
      list.items.length === 2 &&
      list.pagination &&
      list.pagination.total === 2 &&
      list.pagination.page === 1 &&
      list.pagination.hasNextPage === false,
    JSON.stringify(list.pagination || {}),
  );

  const alpha = (list.items || []).find((x) => x.title === 'Alpha Song');
  const beta = (list.items || []).find((x) => x.title === 'Beta Song');
  check(
    'list_sorted_by_title',
    (list.items || []).map((x) => x.title).join(',') === 'Alpha Song,Beta Song',
    (list.items || []).map((x) => x.title).join(','),
  );

  // 关键字段外形（既有实现 的 fromJson 靠这些字段）
  check(
    'track_fields',
    !!alpha &&
      typeof alpha.id === 'number' &&
      alpha.id > 0 &&
      alpha.filename === 'Alpha.m4a' &&
      alpha.path === 'music' &&
      alpha.first_file_path === 'music/Alpha.m4a' &&
      alpha.full_path === 'music/Alpha.m4a' && // 别把 root 再拼一遍
      alpha.show_type === 'music' &&
      typeof alpha.is_favorite === 'number' &&
      alpha.album_artist !== undefined,
    JSON.stringify(alpha || {}).slice(0, 160),
  );

  // 时长口径：库里毫秒、对外秒
  if (ffmpeg && alpha && beta) {
    check(
      'duration_in_seconds',
      Math.abs(Number(alpha.duration) - 2) <= 1 && Math.abs(Number(beta.duration) - 3) <= 1,
      `alpha=${alpha.duration} beta=${beta.duration}`,
    );
    check(
      'tags_metadata',
      alpha.artist === 'Artist A' && alpha.album === 'Album One' && String(alpha.year) === '2021',
      `${alpha.artist}/${alpha.album}/${alpha.year}`,
    );
  } else {
    check('duration_in_seconds', !!alpha && Number(alpha.duration) === 0, 'ffmpeg 不可用，降级');
    check('tags_metadata', !!alpha && alpha.artist === '', 'ffmpeg 不可用，降级');
  }

  // 分页
  r = await post('/api/v1/music/compat/list', bearer, { page: 1, page_size: 1 });
  const p1 = r.json();
  check(
    'pagination_page1',
    p1.items.length === 1 && p1.pagination.totalPages === 2 && p1.pagination.hasNextPage === true,
    JSON.stringify(p1.pagination),
  );
  r = await post('/api/v1/music/compat/list', bearer, { page: 2, page_size: 1 });
  const p2 = r.json();
  check(
    'pagination_page2',
    p2.items.length === 1 && p2.pagination.page === 2 && p2.pagination.hasPrevPage === true,
    JSON.stringify(p2.pagination),
  );

  // 搜索 / 过滤
  r = await post('/api/v1/music/compat/list', bearer, { search: 'beta' });
  check('list_search', r.json().items.length === 1 && r.json().items[0].title === 'Beta Song', 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/list', bearer, { artists: ['Artist A'] });
  check('list_filter_artist', ffmpeg ? r.json().items.length === 1 : r.json().items.length === 0, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/list', bearer, { albums: ['Album Two'] });
  check('list_filter_album', ffmpeg ? r.json().items.length === 1 : r.json().items.length === 0, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/list', bearer, { sourceList: ['music'] });
  check('list_filter_source', r.json().items.length === 2, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/list', bearer, { sourceList: ['nope'] });
  check('list_filter_unknown_source_empty', r.json().items.length === 0, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/list', bearer, { sort_by: 'title', sort_order: 'desc' });
  check('list_sort_desc', r.json().items[0].title === 'Beta Song', r.json().items[0].title);

  r = await post('/api/v1/music/compat/list/count', bearer, {});
  check('list_count', r.json().songs === 2, JSON.stringify(r.json()));

  // ---------------------------------------------------------------- 详情

  r = await post('/api/v1/music/compat/detail', bearer, { index_id: alpha.id });
  check('detail_by_index_id', r.json().title === 'Alpha Song', JSON.stringify(r.json()).slice(0, 80));

  r = await post('/api/v1/music/compat/detail', bearer, { file_path: 'music/Alpha.m4a' });
  check('detail_by_rel_path', r.json().id === alpha.id, 'id=' + r.json().id);

  r = await post('/api/v1/music/compat/detail', bearer, { file_path: path.join(songs, 'Alpha.m4a') });
  check('detail_by_full_path', r.json().id === alpha.id, 'id=' + r.json().id);

  r = await post('/api/v1/music/compat/detail', bearer, { index_id: 999999 });
  check('detail_missing_empty', r.statusCode === 200 && r.json().id === undefined, JSON.stringify(r.json()));

  // ---------------------------------------------------------------- 专辑 / 艺人聚合

  r = await post('/api/v1/music/compat/album/list', bearer, { page: 1, page_size: 30 });
  const albums = r.json();
  check(
    'album_list',
    ffmpeg
      ? albums.items.length === 2 && albums.items.every((x) => x.key_type === 'album' && x.index_count === 1)
      : albums.items.length === 0,
    JSON.stringify(albums.items).slice(0, 140),
  );

  r = await post('/api/v1/music/compat/artist/list', bearer, { page: 1, page_size: 30 });
  const artists = r.json();
  check(
    'artist_list',
    ffmpeg
      ? artists.items.length === 2 && artists.items.every((x) => x.key_type === 'artist')
      : artists.items.length === 0,
    JSON.stringify(artists.items).slice(0, 140),
  );

  // ---------------------------------------------------------------- 收藏

  r = await post('/api/v1/music/compat/favorite/batch', bearer, { index_ids: [alpha.id], is_favorite: 1 });
  check('favorite_on', r.json().ok === true && r.json().affected === 1, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/list', bearer, { is_favorite: 1 });
  const favList = r.json();
  check(
    'list_favorite_filter',
    favList.items.length === 1 && favList.items[0].id === alpha.id && favList.items[0].is_favorite === 1,
    'n=' + favList.items.length,
  );

  // 收藏按用户隔离
  r = await post('/api/v1/music/compat/list', reader, { is_favorite: 1 });
  check('favorite_isolated', r.json().items.length === 0, 'n=' + r.json().items.length);

  await post('/api/v1/music/compat/favorite/batch', bearer, { index_ids: [alpha.id], is_favorite: 0 });
  r = await post('/api/v1/music/compat/list', bearer, { is_favorite: 1 });
  check('favorite_off', r.json().items.length === 0, 'n=' + r.json().items.length);

  // ---------------------------------------------------------------- 历史

  r = await post('/api/v1/music/compat/history/refresh', bearer, { index_id: alpha.id });
  check('history_refresh', r.json().ok === true, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/list', bearer, { isHistory: 1 });
  const hist = r.json();
  check('list_history', hist.items.length === 1 && hist.items[0].id === alpha.id, 'n=' + hist.items.length);

  r = await post('/api/v1/music/compat/list', reader, { isHistory: 1 });
  check('history_isolated', r.json().items.length === 0, 'n=' + r.json().items.length);

  // ---------------------------------------------------------------- 歌单

  r = await post('/api/v1/music/compat/playlist/create', bearer, { name: '我的歌单' });
  const pl = r.json();
  check('playlist_create', pl.id > 0 && pl.name === '我的歌单', JSON.stringify(pl));

  r = await post('/api/v1/music/compat/playlist/index/add', bearer, {
    list_id: pl.id,
    index_ids: [alpha.id, beta.id],
  });
  check('playlist_index_add', r.json().ok === true && r.json().added === 2, JSON.stringify(r.json()));

  // 歌单详情：子列表传 list_id（= music_playlists.rowid）
  r = await post('/api/v1/music/compat/list', bearer, { list_id: pl.id });
  check('list_by_playlist', r.json().items.length === 2, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/list', reader, { list_id: pl.id });
  check('list_by_playlist_isolated', r.json().items.length === 0, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/playlist/list', bearer, { page: 1, page_size: 30 });
  const pll = r.json();
  check(
    'playlist_list_with_previews',
    pll.items.length === 1 && pll.items[0].id === pl.id && pll.items[0].previews.length === 2,
    'previews=' + (pll.items[0] || {}).previews,
  );

  r = await post('/api/v1/music/compat/playlist/list', reader, {});
  check('playlist_isolated', r.json().items.length === 0, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/playlist/update', bearer, { id: pl.id, name: '改名了' });
  check('playlist_update', r.json().name === '改名了', JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/playlist/index/remove', bearer, {
    list_id: pl.id,
    index_ids: [beta.id],
  });
  check('playlist_index_remove', r.json().ok === true && r.json().removed === 1, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/playlist/delete', bearer, { id: pl.id });
  check('playlist_delete', r.json().ok === true, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/playlist/list', bearer, {});
  check('playlist_deleted_gone', r.json().items.length === 0, 'n=' + r.json().items.length);

  // ---------------------------------------------------------------- 合集

  r = await post('/api/v1/music/compat/collection/create', bearer, {
    name: '合集A',
    path_list: ['music'],
  });
  const col = r.json();
  check('collection_create', col.id > 0, JSON.stringify(col));

  r = await post('/api/v1/music/compat/collection/get', bearer, { id: col.id });
  const colGet = r.json();
  check(
    'collection_get',
    colGet.id === col.id && colGet.name === '合集A' && colGet.path_list.length === 1 && colGet.previews.length === 2,
    JSON.stringify(colGet).slice(0, 160),
  );

  r = await post('/api/v1/music/compat/collection/list', bearer, { page: 1, page_size: 20 });
  check('collection_list', r.json().items.length === 1 && r.json().total === 1, JSON.stringify(r.json().total));

  r = await post('/api/v1/music/compat/collection/get', reader, { id: col.id });
  check('collection_isolated', r.json().id === 0, JSON.stringify(r.json()).slice(0, 60));

  r = await post('/api/v1/music/compat/list', bearer, { collection_id: col.id });
  check('list_by_collection', r.json().items.length === 2, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/collection/update', bearer, {
    id: col.id,
    name: '合集B',
    path_list: ['music'],
  });
  check('collection_update', r.json().ok === true, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/collection/delete', bearer, { id: col.id });
  check('collection_delete', r.json().affected === 1, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/collection/list', bearer, {});
  check('collection_deleted_gone', r.json().items.length === 0, 'n=' + r.json().items.length);

  // ---------------------------------------------------------------- 歌词

  r = await post('/api/v1/music/compat/lyric/search', bearer, { title: 'Alpha Song', artist: 'Artist A' });
  check('lyric_search_empty', r.statusCode === 200 && Array.isArray(r.json()), 'status=' + r.statusCode);

  r = await post('/api/v1/music/compat/lyric/set', bearer, {
    music_path: 'music/Alpha.m4a',
    lrc: '[00:00.00]hello\n[00:01.00]world\n',
  });
  const lyricSet = r.json();
  const lrcFile = path.join(songs, 'Alpha.lrc');
  check(
    'lyric_set_writes_file',
    lyricSet.ok === true && fs.existsSync(lrcFile) && fs.readFileSync(lrcFile, 'utf8').includes('hello'),
    JSON.stringify(lyricSet).slice(0, 100),
  );

  // ---------------------------------------------------------------- 来源改名 / 删除

  r = await post('/api/v1/music/compat/source/update', bearer, { id: addRes.id, path: 'music' });
  check('source_update', r.json().ok === true, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/source/relocate', bearer, { id: addRes.id, new_path: 'music' });
  check('source_relocate', r.json().ok === true, JSON.stringify(r.json()));

  // 单曲删除（客户端传的是库内相对路径）
  r = await post('/api/v1/music/compat/delete', bearer, { paths: ['Alpha.m4a'] });
  check('track_delete_by_suffix', r.json().affected === 1, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/list', bearer, {});
  check('track_deleted_gone', r.json().items.length === 1, 'n=' + r.json().items.length);

  r = await post('/api/v1/music/compat/source/delete', bearer, { id: addRes.id });
  check('source_delete', r.json().ok === true, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/source/list', bearer, {});
  check('source_delete_gone', r.json().length === 0, 'n=' + r.json().length);

  r = await post('/api/v1/music/compat/list', bearer, {});
  check('tracks_cascade_deleted', r.json().items.length === 0, 'n=' + r.json().items.length);

  // ---------------------------------------------------------------- 简繁 / 模糊搜索

  r = await post('/api/v1/music/compat/source/add', bearer, { path: 'music_cn' });
  check('cn_source_add', r.statusCode === 200 && r.json().ok === true, JSON.stringify(r.json()).slice(0, 100));

  r = await post('/api/v1/music/compat/source/scan', bearer, { path: 'music_cn', sync: true });
  check('cn_source_scan', r.statusCode === 200 && r.json().ok === true, JSON.stringify(r.json()).slice(0, 100));

  // ---------------------------------------------------------------- 来源扫描策略
  // 这三个开关以前是硬编码常量（1/1/0），source/update 还硬性要 path ——
  // 前端点一下必然「操作失败、开关弹回去」。现在必须真落库。
  const srcList = await post('/api/v1/music/compat/source/list', bearer, {});
  const cnSrc = (srcList.json() || []).find((s) => s.path === 'music_cn');
  r = await post('/api/v1/music/compat/source/update', bearer, {
    id: cnSrc.id,
    scan_when_start: 0,
    scan_when_change: 0,
    scan_interval_hours: 2,
  });
  check(
    'source_policy_update',
    r.statusCode === 200 && r.json().ok === true,
    JSON.stringify(r.json()).slice(0, 100),
  );

  r = await post('/api/v1/music/compat/source/list', bearer, {});
  const policyBack = (r.json() || []).find((s) => s.path === 'music_cn');
  check(
    'source_policy_persisted',
    !!policyBack &&
      policyBack.scan_when_start === 0 &&
      policyBack.scan_when_change === 0 &&
      policyBack.scan_interval === 1 &&
      policyBack.scan_interval_ms === 7200000,
    JSON.stringify(policyBack || {}).slice(0, 160),
  );

  // 关掉间隔扫描（前端发 scan_interval:0）必须能落回 0
  await post('/api/v1/music/compat/source/update', bearer, {
    id: cnSrc.id,
    scan_interval: 0,
    scan_interval_ms: 0,
  });
  r = await post('/api/v1/music/compat/source/list', bearer, {});
  const policyOff = (r.json() || []).find((s) => s.path === 'music_cn');
  check(
    'source_policy_interval_off',
    !!policyOff && policyOff.scan_interval === 0 && policyOff.scan_interval_ms === 0,
    JSON.stringify(policyOff || {}).slice(0, 160),
  );

  r = await post('/api/v1/music/compat/list', bearer, { page: 1, page_size: 30 });
  check('cn_all_tracks', r.json().items.length === 4, 'n=' + r.json().items.length);

  const titlesOf = async (search) => {
    const res = await post('/api/v1/music/compat/list', bearer, { page: 1, page_size: 30, search });
    return (res.json().items || []).map((x) => x.title);
  };

  let t = await titlesOf('我爱台妹'); // 简体查繁体
  check('search_simp_query_trad_title', t.includes('我愛臺妹'), JSON.stringify(t));

  t = await titlesOf('我愛臺妹');
  check('search_trad_query_trad_title', t.includes('我愛臺妹'), JSON.stringify(t));

  t = await titlesOf('我台妹'); // 跳字：中间少了「愛」
  check('search_subsequence', t.includes('我愛臺妹'), JSON.stringify(t));

  t = await titlesOf('鲜花'); // 简体查繁体（《鲜花》场景）
  check('search_simp_query_trad_title_2', t.includes('鮮花'), JSON.stringify(t));

  t = await titlesOf('我愛的人'); // 繁体查简体
  check('search_trad_query_simp_title', t.includes('我爱的人'), JSON.stringify(t));

  t = await titlesOf('track_cn_007'); // 文件名（rel_path）也进搜索列
  check('search_rel_path', t.length >= 1, JSON.stringify(t));

  t = await titlesOf('鲜花');
  check('search_no_cross_hit', !t.includes('我愛臺妹'), JSON.stringify(t));

  t = await titlesOf('track cn 007'); // 多词 AND：每个词各自命中，不拼成一长串
  check('search_multi_term', t.length >= 1, JSON.stringify(t));

  if (ffmpeg) {
    t = await titlesOf('鲜花 回春丹'); // 跨列：标题 / 艺人各命中一个词
    check('search_multi_term_cross_col', t.includes('鮮花'), JSON.stringify(t));
  }

  // 播放器取词：detail 必须回 { item, lyrics }，只回平铺字段会一直显示「暂无歌词」
  r = await post('/api/v1/music/compat/detail', bearer, { file_path: 'music_cn/鮮花.m4a' });
  const cnDetail = r.json();
  check(
    'detail_returns_item_and_lyrics',
    cnDetail.title === '鮮花' &&
      !!cnDetail.item &&
      cnDetail.item.filename === '鮮花.m4a' &&
      String(cnDetail.lyrics || '').includes('[00:12.34]'),
    JSON.stringify({ title: cnDetail.title, lyrics: cnDetail.lyrics }).slice(0, 160),
  );

  // 主模块（cursor 分页）同样走新搜索
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/list?q=' + encodeURIComponent('我台妹'),
    headers: bearer,
  });
  check(
    'main_list_subsequence',
    r.statusCode === 200 && (r.json().items || []).some((x) => x.title === '我愛臺妹'),
    JSON.stringify((r.json().items || []).map((x) => x.title)).slice(0, 120),
  );

  // ---------------------------------------------------------------- 在线刮削（歌词 / 封面）

  r = await post('/api/v1/music/compat/lyric/search', bearer, { keyword: '鲜花 回春丹乐队' });
  const foundLyrics = r.json();
  check(
    'lyric_search_online',
    r.statusCode === 200 &&
      Array.isArray(foundLyrics) &&
      foundLyrics.length === 1 && // 纯文本条目被过滤
      foundLyrics[0].source === 'lrclib' &&
      foundLyrics[0].duration === 341000 && // 前端 fromMap 把 duration 当毫秒
      String(foundLyrics[0].lrc).includes('[00:12.34]'),
    JSON.stringify(foundLyrics).slice(0, 200),
  );
  // 前端拼的「标题 艺人」在 LRCLIB 上查不到，必须按标题单词兜底再查一轮
  check('lyric_search_fallback_query', lrclibHits === 2, 'lrclibHits=' + lrclibHits);

  r = await post('/api/v1/music/compat/lyric/search', bearer, { keyword: '' });
  check(
    'lyric_search_empty_keyword',
    Array.isArray(r.json()) && r.json().length === 0,
    JSON.stringify(r.json()),
  );

  const coverPath = 'music_cn/鮮花.m4a'; // ffmpeg 造的假音频，没有内嵌封面流
  const coverUrl = (size) =>
    '/api/v1/music/compat/cover?path=' + encodeURIComponent(coverPath) + '&size=' + size;

  r = await app.inject({ method: 'GET', url: coverUrl(300), headers: bearer });
  const hitsBefore = imageHits;
  check(
    'cover_online_fallback',
    r.statusCode === 200 &&
      String(r.headers['content-type'] || '').includes('image/jpeg') &&
      (r.rawPayload || []).length > 0,
    'status=' + r.statusCode + ' bytes=' + (r.rawPayload || []).length,
  );
  check('cover_album_channel_first', albumHits > 0, 'albumHits=' + albumHits);

  r = await app.inject({ method: 'GET', url: coverUrl(300), headers: bearer });
  check(
    'cover_online_cached',
    r.statusCode === 200 && imageHits === hitsBefore,
    'imageHits=' + imageHits + ' before=' + hitsBefore,
  );

  // 网络抖动不能写「查无此图」哨兵，否则这首歌永远没机会重试
  itunesMode = 'error';
  r = await app.inject({ method: 'GET', url: coverUrl(301), headers: bearer });
  check('cover_network_error_is_404', r.statusCode === 404, 'status=' + r.statusCode);
  itunesMode = 'ok';
  r = await app.inject({ method: 'GET', url: coverUrl(301), headers: bearer });
  check('cover_network_error_retryable', r.statusCode === 200, 'status=' + r.statusCode);

  // 明确「查无此图」才落哨兵，之后不再联网
  itunesMode = 'empty';
  r = await app.inject({ method: 'GET', url: coverUrl(302), headers: bearer });
  check('cover_explicit_empty_is_404', r.statusCode === 404, 'status=' + r.statusCode);
  const hitsAtEmpty = imageHits;
  itunesMode = 'ok';
  r = await app.inject({ method: 'GET', url: coverUrl(302), headers: bearer });
  check(
    'cover_explicit_empty_writes_sentinel',
    r.statusCode === 404 && imageHits === hitsAtEmpty,
    'status=' + r.statusCode + ' imageHits=' + imageHits,
  );

  // 手机端 media_kit 只能拿到 URL、带不了 Authorization 头，token 只能放 query。
  // 白名单漏掉 /music/compat/stream 就会 401 → 播放条出来了却不播放、时长也空。
  const qToken = tokenRes.json().token;
  const streamPath = '/api/v1/music/compat/stream?path=' + encodeURIComponent('music_cn/鮮花.m4a');
  r = await app.inject({
    method: 'GET',
    url: streamPath + '&token=' + encodeURIComponent(qToken),
    headers: { range: 'bytes=0-15' },
  });
  check('stream_query_token_auth', r.statusCode !== 401, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: streamPath, headers: { range: 'bytes=0-15' } });
  check('stream_without_token_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 老库 rel_path 混着反斜杠（`G:\music/x.flac`），客户端回传的是 normSlashes
  // 后的正斜杠；findTrackRow 不统一斜杠的话，真库封面 / 播放 / 删除全 404。
  await sql`update music_tracks
               set rel_path = ${'music_cn\\鮮花.m4a'}
             where rel_path = ${'music_cn/鮮花.m4a'}`.execute(k.db);

  r = await post('/api/v1/music/compat/detail', bearer, { file_path: 'music_cn/鮮花.m4a' });
  check('detail_mixed_slash_rel_path', r.json().title === '鮮花', JSON.stringify(r.json()).slice(0, 100));

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/compat/cover?path=' + encodeURIComponent('music_cn/鮮花.m4a'),
    headers: bearer,
  });
  // 接了在线兜底后可能是 200（二进制图片，不能 json()）或 404「cover unavailable」；
  // 只要不是 404「no cover」，就证明混合斜杠路径成功解析到了曲目。
  const mixedBody = r.statusCode === 404 ? r.json() : {};
  check(
    'cover_mixed_slash_rel_path',
    !(r.statusCode === 404 && mixedBody.message === 'no cover'),
    'status=' + r.statusCode + ' msg=' + String(mixedBody.message || ''),
  );

  // ---------------------------------------------------------------- 扫描默认入队
  // 整库几万首要逐个 probe，同步跑必然撞客户端 30s 超时；默认必须立刻返回任务 id。
  r = await post('/api/v1/music/compat/source/scan', bearer, { path: 'music_cn' });
  const queued = r.json();
  check(
    'source_scan_enqueues',
    r.statusCode === 200 &&
      queued.ok === true &&
      queued.queued === true &&
      Array.isArray(queued.tasks) &&
      queued.tasks.length === 1 &&
      typeof queued.tasks[0].taskId === 'string',
    JSON.stringify(queued).slice(0, 140),
  );

  // ---------------------------------------------------------------- 汇总

  console.log('');
  let failed = 0;
  for (const it of results) {
    if (!it.ok) failed += 1;
    console.log(`${it.ok ? 'PASS' : 'FAIL'}  ${it.name}${it.ok ? '' : '  →  ' + it.detail}`);
  }
  console.log(`\n${results.length - failed}/${results.length} passed`);
  if (failed > 0) {
    for (const it of results) if (!it.ok) console.log(`  [detail] ${it.name}: ${it.detail}`);
  }

  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true });
  } catch {
    /* 日志句柄可能还开着，忽略 */
  }
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
