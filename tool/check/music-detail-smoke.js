#!/usr/bin/env node
/* global URLSearchParams */
/**
 * 专辑 / 歌手详情页 + Last.fm（热度 / 绑定 / Scrobble）验收。
 *
 * 覆盖的都是「新加的东西」，不重复 music-compat-smoke 已经验过的列表外形：
 *   1. /compat/album/detail、/compat/artist/detail 的聚合口径（曲目数、年份、专辑列表）；
 *   2. /compat/list 的 `dedupe=1`（同名同歌手只留最新一版）与 `sort_by=album_order`；
 *   3. 没配 API Key 时 `sort_by=hot` 必须降级到本地播放量（不能报错）；
 *   4. Last.fm 凭证保存 / 打码 / 绑定（auth.getToken → callback → auth.getSession）；
 *   5. `track.scrobble` 的 **MD5 签名**：mock 里用同一 secret 重算 api_sig 做比对，
 *      算法错了这条就红。
 *
 * 出站全程 mock（`__setLastfmFetch`），不联网、不依赖任何真实 Key。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 *
 * 用法：node tool/check/music-detail-smoke.js
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

const API_KEY = '0123456789abcdef0123456789abcdef';
const API_SECRET = 'fedcba9876543210fedcba9876543210';

const lastfm = require(path.join(root, 'dist', 'src', 'modules', 'music', 'lastfm.js'));

let sigOk = false;
let lastScrobble = null;

const jsonRes = (obj) => ({
  ok: true,
  status: 200,
  headers: { get: () => 'application/json' },
  json: async () => obj,
});

// 假 Last.fm：方法名对着实现里真正调的那几个
lastfm.__setLastfmFetch(async (url, init = {}) => {
  const u = new URL(url);
  if ((init.method || 'GET').toUpperCase() === 'POST') {
    const p = Object.fromEntries(new URLSearchParams(String(init.body || '')));
    // 关键断言：签名必须能用同一个 secret 重算出来
    sigOk = p.api_sig === lastfm.lastfmSig(p, API_SECRET);
    if (p.method === 'auth.getToken') return jsonRes({ token: 'TOK-TEST-1' });
    if (p.method === 'auth.getSession') {
      return jsonRes({ session: { name: 'tiezhu', key: 'SK-TEST-1' } });
    }
    if (p.method === 'track.scrobble') {
      lastScrobble = p;
      return jsonRes({ scrobbles: { scrobble: { track: [p.track] }, '@attr': { accepted: 1, ignored: 0 } } });
    }
    return jsonRes({});
  }
  const method = u.searchParams.get('method');
  if (method === 'auth.getToken') return jsonRes({ token: 'TOK-TEST-1' });
  if (method === 'artist.gettoptracks') {
    return jsonRes({
      toptracks: {
        track: [
          { name: '晴天', playcount: '900', listeners: '300', '@attr': { rank: '1' } },
          { name: '七里香', playcount: '500', listeners: '200', '@attr': { rank: '2' } },
        ],
      },
    });
  }
  if (method === 'album.getinfo') {
    return jsonRes({
      album: {
        name: '葉惠美',
        playcount: '1234',
        listeners: '456',
        url: 'https://www.last.fm/music/x',
        wiki: { summary: '一张专辑。 <a href="https://www.last.fm/x">Read more</a>' },
        image: [{ '#text': '' }, { '#text': 'https://img.local/cover.jpg' }],
        tags: { tag: [{ name: 'pop' }, { name: 'mandopop' }] },
      },
    });
  }
  if (method === 'artist.getinfo') {
    return jsonRes({
      artist: {
        url: 'https://www.last.fm/music/x',
        stats: { listeners: '10000', playcount: '50000' },
        bio: { summary: '华语歌手 <a href="https://www.last.fm/y">Read more</a>' },
        image: [{ '#text': '' }],
        tags: { tag: [{ name: 'mandopop' }] },
      },
    });
  }
  return jsonRes({});
});

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-music-detail-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'music'), { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail == null ? '' : String(detail).slice(0, 160) });
  const post = (url, headers, payload) =>
    app.inject({ method: 'POST', url, headers, payload: payload || {} });

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['music:read', 'music:write'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  // ---------------------------------------------------------------- 造数据
  const now = Math.floor(Date.now() / 1000);
  await sql`
    insert into music_libraries (id, name, root_path, created_at, items)
    values ('lib1', 't', 'music', ${now}, 4)
  `.execute(k.db);
  // 同一张专辑三首，音轨号故意乱序插入；外加一首同名重复（旧版本，用于 dedupe）
  const rows = [
    ['t1', 'music/a1.mp3', '晴天', '周杰倫', '葉惠美', 1, 2003, now - 100],
    ['t2', 'music/a2.mp3', '七里香', '周杰倫', '葉惠美', 3, 2003, now - 100],
    ['t3', 'music/a3.mp3', '以父之名', '周杰倫', '葉惠美', 2, 2003, now - 100],
    ['t4', 'music/dup/晴天.mp3', '晴天', '周杰倫', '葉惠美', 1, 2003, now],
    // 简繁差异：归一后应算同一首（只留 mtime 新的那条）
    ['t5', 'music/cn/a.m4a', '我爱你', '周杰倫', '愛', 1, 2004, now - 200],
    ['t6', 'music/cn/b.mp3', '我愛你', '周杰倫', '愛', 1, 2004, now - 100],
    // 现场版：允许与录音室版共存
    ['t7', 'music/live/q.mp3', '七里香 (Live)', '周杰倫', '演唱會', 1, 2005, now - 100],
  ];
  for (const [id, rel, title, artist, album, no, year, mtime] of rows) {
    await sql`
      insert into music_tracks
        (id, library_id, rel_path, title, artist, album, album_artist, track_no, year,
         duration, size, mtime, created_at, has_cover)
      values (${id}, 'lib1', ${rel}, ${title}, ${artist}, ${album}, ${artist}, ${no}, ${year},
              200000, 4096, ${mtime}, ${mtime}, ${id === 't1' ? 1 : 0})
    `.execute(k.db);
  }
  // 本地播放次数：让「没配 Key 时的热度」有可排序的依据
  for (let i = 0; i < 5; i += 1) {
    await sql`
      insert into music_plays (id, item_id, owner_id, played_at)
      values (${'p' + i}, 't2', 'u1', ${(now - i) * 1000})
    `.execute(k.db);
  }

  let r = await post('/api/v1/music/compat/list', bearer, {
    page: 1,
    page_size: 50,
    artists: ['周杰倫'],
    sort_by: 'hot',
    dedupe: 1,
  });
  let body = r.json();
  check('list_hot_degrades_without_key', body.hot_source === 'local', 'source=' + body.hot_source);
  check(
    'list_hot_local_playcount_first',
    (body.items || [])[0] && (body.items || [])[0].title === '七里香',
    (body.items || []).map((x) => x.title).join(','),
  );
  check('list_hot_play_count', (body.items || [])[0] && (body.items || [])[0].play_count === 5,
    JSON.stringify((body.items || [])[0] || {}).slice(0, 80));

  // ---------------------------------------------------------------- Last.fm 凭证
  r = await post('/api/v1/music/compat/lastfm/config', bearer, {
    api_key: API_KEY,
    api_secret: API_SECRET,
  });
  body = r.json();
  check('lastfm_config_saved', body.configured === true && body.secret_configured === true, JSON.stringify(body));
  check('lastfm_config_masked', !String(body.api_key_masked).includes(API_KEY), body.api_key_masked);

  r = await app.inject({ method: 'GET', url: '/api/v1/music/compat/lastfm/config', headers: bearer });
  body = r.json();
  check('lastfm_config_get', body.configured === true && body.linked === false, JSON.stringify(body).slice(0, 100));
  check('lastfm_secret_never_echoed', JSON.stringify(body).indexOf(API_SECRET) < 0, 'leak');

  // 配了 Key 之后热度应走 Last.fm 排名（晴天 rank 1 → 排第一）
  r = await post('/api/v1/music/compat/list', bearer, {
    page: 1,
    page_size: 50,
    artists: ['周杰倫'],
    sort_by: 'hot',
    dedupe: 1,
  });
  body = r.json();
  check('list_hot_uses_lastfm', body.hot_source === 'lastfm', 'source=' + body.hot_source);
  check(
    'list_hot_rank_first',
    (body.items || [])[0] && (body.items || [])[0].title === '晴天' && (body.items || [])[0].hot_rank === 1,
    JSON.stringify((body.items || [])[0] || {}).slice(0, 100),
  );

  // ---------------------------------------------------------------- 专辑详情
  r = await post('/api/v1/music/compat/album/detail', bearer, { name: '葉惠美' });
  body = r.json();
  check('album_detail_found', r.statusCode === 200 && body.found === true, JSON.stringify(body).slice(0, 120));
  check('album_detail_track_count', body.track_count === 4, 'count=' + body.track_count);
  check('album_detail_artist', body.artist === '周杰倫', body.artist);
  check('album_detail_year', String(body.year) === '2003', body.year);
  check('album_detail_cover', String(body.cover_path || '').endsWith('a1.mp3'), body.cover_path);
  check('album_detail_crowd', body.crowd && body.crowd.playcount === 1234 && body.crowd.listeners === 456,
    JSON.stringify(body.crowd || {}).slice(0, 100));
  check('album_detail_summary_clean', !/[<>]/.test(String((body.crowd || {}).summary || '')),
    (body.crowd || {}).summary);

  r = await post('/api/v1/music/compat/album/detail', bearer, { name: '不存在的专辑' });
  check('album_detail_missing', r.json().found === false, JSON.stringify(r.json()).slice(0, 80));

  // ---------------------------------------------------------------- 歌手详情
  r = await post('/api/v1/music/compat/artist/detail', bearer, { name: '周杰倫' });
  body = r.json();
  check('artist_detail_found', body.found === true, JSON.stringify(body).slice(0, 120));
  check('artist_detail_track_count', body.track_count === 7, 'count=' + body.track_count);
  check(
    'artist_detail_albums',
    Array.isArray(body.albums) &&
      body.albums.length === 3 &&
      body.albums.some((a) => a.name === '葉惠美'),
    JSON.stringify((body.albums || []).map((a) => a.name)),
  );
  check('artist_detail_crowd', body.crowd && body.crowd.listeners === 10000,
    JSON.stringify(body.crowd || {}).slice(0, 100));

  // ---------------------------------------------------------------- 列表：去重 / 专辑顺序 / 热度
  r = await post('/api/v1/music/compat/list', bearer, {
    page: 1,
    page_size: 50,
    artists: ['周杰倫'],
    dedupe: 1,
  });
  body = r.json();
  const deduped = (body.items || []).filter((it) => it.title === '晴天');
  check('list_dedupe_single', deduped.length === 1, 'n=' + deduped.length);
  check('list_dedupe_keeps_latest', deduped[0] && String(deduped[0].full_path || '').includes('dup'),
    deduped[0] && deduped[0].full_path);

  // 简繁差异必须算同一首（我爱你 / 我愛你）
  r = await post('/api/v1/music/compat/list', bearer, {
    page: 1,
    page_size: 50,
    artists: ['周杰倫'],
    dedupe: 1,
  });
  body = r.json();
  const cnTitles = (body.items || []).filter((it) => /我爱你|我愛你/.test(it.title));
  check('list_dedupe_cn_simplified_traditional', cnTitles.length === 1,
    cnTitles.map((x) => x.title).join(','));

  // 现场版必须与录音室版共存（七里香 / 七里香 (Live)）
  const liveTitles = (body.items || []).filter((it) => /七里香/.test(it.title));
  check('list_dedupe_keeps_live_version', liveTitles.length === 2,
    liveTitles.map((x) => x.title).join(','));

  r = await post('/api/v1/music/compat/list', bearer, {
    page: 1,
    page_size: 50,
    albums: ['葉惠美'],
    sort_by: 'album_order',
    sort_order: 'asc',
  });
  body = r.json();
  const titles = (body.items || []).map((it) => it.title);
  check(
    'list_album_order',
    titles.indexOf('晴天') < titles.indexOf('以父之名') && titles.indexOf('以父之名') < titles.indexOf('七里香'),
    titles.join(','),
  );

  // ---------------------------------------------------------------- 绑定流程
  r = await post('/api/v1/music/compat/lastfm/link/start', bearer, {});
  body = r.json();
  check('lastfm_link_start', body.ok === true && String(body.url || '').includes('token=TOK-TEST-1'),
    String(body.url || '').slice(0, 80));

  // 回调是浏览器打开的（无 JWT）——必须免鉴权
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/compat/lastfm/link/callback?token=TOK-TEST-1&format=json',
  });
  body = r.json();
  check('lastfm_callback_public', r.statusCode === 200 && body.ok === true, `status=${r.statusCode} ${JSON.stringify(body).slice(0, 80)}`);
  check('lastfm_callback_username', body.username === 'tiezhu', body.username);

  r = await app.inject({ method: 'GET', url: '/api/v1/music/compat/lastfm/link/status', headers: bearer });
  body = r.json();
  check('lastfm_status_linked', body.linked === true && body.username === 'tiezhu', JSON.stringify(body));

  // 重复用同一个 token 应失败（pending 已消费）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/compat/lastfm/link/callback?token=TOK-TEST-1&format=json',
  });
  check('lastfm_callback_replay_rejected', r.json().ok === false, JSON.stringify(r.json()).slice(0, 80));

  // ---------------------------------------------------------------- Scrobble
  r = await post('/api/v1/music/compat/lastfm/scrobble', bearer, {
    artist: '周杰倫',
    track: '晴天',
    album: '葉惠美',
    timestamp: now,
    duration: 200,
  });
  body = r.json();
  check('scrobble_ok', body.ok === true && body.accepted === 1, JSON.stringify(body));
  check('scrobble_signed', sigOk === true, sigOk ? 'api_sig ok' : 'api_sig mismatch');
  check('scrobble_payload', lastScrobble && lastScrobble.track === '晴天' && lastScrobble.sk === 'SK-TEST-1',
    JSON.stringify(lastScrobble || {}).slice(0, 120));

  r = await post('/api/v1/music/compat/lastfm/link/unlink', bearer, {});
  check('lastfm_unlink', r.json().ok === true, JSON.stringify(r.json()));

  r = await post('/api/v1/music/compat/lastfm/scrobble', bearer, {
    artist: '周杰倫',
    track: '晴天',
    timestamp: now,
  });
  check('scrobble_not_linked', r.json().reason === 'not_linked', JSON.stringify(r.json()));

  // ---------------------------------------------------------------- 汇总
  let failed = 0;
  for (const item of results) {
    if (item.ok) {
      console.log(`[OK]   ${item.name}${item.detail ? '  ' + item.detail : ''}`);
    } else {
      failed += 1;
      console.log(`[FAIL] ${item.name}  ${item.detail}`);
    }
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true });
  } catch {
    /* 日志句柄可能还开着，忽略 */
  }
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('[FATAL]', err);
  process.exit(1);
});
