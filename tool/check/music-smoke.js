#!/usr/bin/env node
/**
 * SP3-04 music 验收：
 *   建库（越界 400 / 重复 409）→ 扫描（tags / 时长 / 内嵌封面）→ 增量跳过
 *   → 列表排序与 cursor → 关键词 / 艺术家过滤 → 详情 → 统计
 *   → 封面（有/无）→ 播放 Range（206）→ 直链令牌 → 歌单增删查与跨用户隔离 → 删库级联
 *
 * ffmpeg 不在时自动降级：跳过 tags/封面断言，只验证索引与接口可用性。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/music-smoke.js
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
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

/** 与 src/modules/media/ffmpeg-run.ts 一致：环境变量 → vendor（jellyfin-ffmpeg）→ PATH */
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

/** 生成带 tags（可选内嵌封面）的音频；失败返回 false，调用方降级 */
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
  ];
  if (opts.cover) {
    args.push('-f', 'lavfi', '-i', `color=c=blue:size=300x300:duration=${opts.sec}`);
    args.push('-map', '0:a', '-map', '1:v', '-c:v', 'mjpeg', '-disposition:v', 'attached_pic');
  }
  args.push('-c:a', 'aac', '-b:a', '96k', '-t', String(opts.sec));
  for (const [k, v] of Object.entries(opts.meta)) args.push('-metadata', `${k}=${v}`);
  args.push(out);

  const r = spawnSync(FFMPEG, args, { encoding: 'utf-8' });
  return r.status === 0 && fs.existsSync(out) && fs.statSync(out).size > 1000;
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-music-'));
  const filesRoot = path.join(dataDir, 'files');
  const songs = path.join(filesRoot, 'music');
  fs.mkdirSync(songs, { recursive: true });

  const ffmpeg = hasFfmpeg();
  let coverOk = false;
  if (ffmpeg) {
    coverOk = makeAudio(path.join(songs, 'Alpha.m4a'), {
      freq: 440,
      sec: 2,
      cover: true,
      meta: { title: 'Alpha Song', artist: 'Artist A', album: 'Album One', track: '1', date: '2021' },
    });
    makeAudio(path.join(songs, 'Beta.m4a'), {
      freq: 880,
      sec: 3,
      cover: false,
      meta: { title: 'Beta Song', artist: 'Artist B', album: 'Album Two', track: '2/10', date: '2019-05-06' },
    });
  }
  // 兜底：ffmpeg 不可用或封装失败时写占位文件，保证索引链路可验收
  if (!fs.existsSync(path.join(songs, 'Alpha.m4a'))) {
    fs.writeFileSync(path.join(songs, 'Alpha.m4a'), Buffer.alloc(4096, 1));
  }
  if (!fs.existsSync(path.join(songs, 'Beta.m4a'))) {
    fs.writeFileSync(path.join(songs, 'Beta.m4a'), Buffer.alloc(4096, 2));
  }
  fs.writeFileSync(path.join(songs, 'notes.txt'), 'not audio');

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
    payload: { sub: 'u1', scopes: ['music:read', 'music:write', 'files:read'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['music:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };

  const otherRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u3', scopes: ['music:read', 'music:write'] },
  });
  const other = { authorization: 'Bearer ' + otherRes.json().token };

  console.log(`[info] ffmpeg=${ffmpeg ? 'yes' : 'no'} cover=${coverOk ? 'yes' : 'no'}`);

  // 1. 匿名不可读
  let r = await app.inject({ method: 'GET', url: '/api/v1/music/list' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 越界路径
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/libraries',
    headers: bearer,
    payload: { name: 'bad', path: '../../etc' },
  });
  check('library_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 3. 建库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/libraries',
    headers: bearer,
    payload: { name: 'Music', path: '/music' },
  });
  const lib = r.json();
  check('library_create_ok', r.statusCode === 200 && lib.id && lib.path === 'music', JSON.stringify(lib).slice(0, 80));

  // 4. 重复库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/libraries',
    headers: bearer,
    payload: { name: 'Dup', path: 'music' },
  });
  check('library_duplicate_409', r.statusCode === 409, 'status=' + r.statusCode);

  // 5. 只读令牌不能扫描
  r = await app.inject({ method: 'POST', url: '/api/v1/music/scan', headers: reader, payload: {} });
  check('scan_requires_write', r.statusCode === 403, 'status=' + r.statusCode);

  // 6. 扫描（txt 不计入）
  r = await app.inject({ method: 'POST', url: '/api/v1/music/scan', headers: bearer, payload: {} });
  const scan = r.json();
  check('scan_tracks', r.statusCode === 200 && scan.tracks === 2 && scan.added === 2, JSON.stringify(scan));

  // 7. 增量
  r = await app.inject({ method: 'POST', url: '/api/v1/music/scan', headers: bearer, payload: {} });
  const again = r.json();
  check('scan_incremental', again.added === 0 && again.skipped === 2, JSON.stringify(again));

  // 8. 列表（标题序）
  r = await app.inject({ method: 'GET', url: '/api/v1/music/list?limit=10', headers: bearer });
  const list = r.json();
  check(
    'list_sorted',
    r.statusCode === 200 && list.items.length === 2 && list.items[0].title === 'Alpha Song',
    (list.items || []).map((x) => x.title).join(','),
  );

  // 9. tags / 时长（有 ffmpeg 才严格断言）
  const alpha = list.items.find((x) => x.title === 'Alpha Song');
  const beta = list.items.find((x) => x.title === 'Beta Song');
  if (ffmpeg && alpha && beta) {
    check(
      'tags_metadata',
      alpha.artist === 'Artist A' &&
        alpha.album === 'Album One' &&
        alpha.trackNo === 1 &&
        alpha.year === 2021 &&
        Math.abs((alpha.durationMs || 0) - 2000) < 400 &&
        beta.artist === 'Artist B' &&
        beta.album === 'Album Two' &&
        beta.trackNo === 2 &&
        beta.year === 2019,
      `${alpha.artist}/${alpha.album}/${alpha.trackNo}/${alpha.year}/${alpha.durationMs}`,
    );
  } else {
    check('tags_metadata', !!alpha && alpha.artist === null, 'ffmpeg 不可用，降级为 null');
  }

  // 10. cursor 分页
  const p1 = (await app.inject({ method: 'GET', url: '/api/v1/music/list?limit=1', headers: bearer })).json();
  const p2 = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/music/list?limit=1&cursor=' + encodeURIComponent(p1.nextCursor || ''),
      headers: bearer,
    })
  ).json();
  check(
    'cursor_pagination',
    p1.items.length === 1 && !!p1.nextCursor && p2.items.length === 1 && p2.items[0].id !== p1.items[0].id,
    `${p1.items.length}/${p2.items.length}`,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/music/list?cursor=not-a-cursor', headers: bearer });
  check('bad_cursor_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 11. 搜索与艺术家过滤
  r = await app.inject({ method: 'GET', url: '/api/v1/music/list?q=beta', headers: bearer });
  const byKeyword = r.json();
  check('search_keyword', r.statusCode === 200 && byKeyword.items.length === 1 && byKeyword.items[0].title === 'Beta Song', 'items=' + (byKeyword.items || []).length);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/list?artist=' + encodeURIComponent('Artist A'),
    headers: bearer,
  });
  const byArtist = r.json();
  check('filter_artist', r.statusCode === 200 && byArtist.items.length === 1 && byArtist.items[0].title === 'Alpha Song', 'items=' + (byArtist.items || []).length);

  // 12. 详情
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/item?id=' + encodeURIComponent(alpha.id),
    headers: bearer,
  });
  check('item_detail', r.statusCode === 200 && r.json().path === 'music/Alpha.m4a', 'status=' + r.statusCode);

  // 13. 统计
  r = await app.inject({ method: 'GET', url: '/api/v1/music/stats', headers: bearer });
  const stats = r.json();
  check(
    'stats',
    r.statusCode === 200 &&
      stats.tracks === 2 &&
      stats.libraries === 1 &&
      (ffmpeg ? stats.albums === 2 && stats.artists === 2 && Math.abs(stats.durationMs - 5000) < 600 : true),
    JSON.stringify(stats),
  );

  // 14. 封面（有 ffmpeg 且封面生成成功才严格断言）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/cover?id=' + encodeURIComponent(alpha.id),
    headers: reader,
  });
  if (coverOk) {
    check(
      'cover_jpeg',
      r.statusCode === 200 && String(r.headers['content-type']).startsWith('image/jpeg') && r.rawPayload.length > 300,
      `status=${r.statusCode} type=${r.headers['content-type']} bytes=${r.rawPayload.length}`,
    );
  } else {
    check('cover_jpeg', r.statusCode === 404 || r.statusCode === 200, `封面不可用（status=${r.statusCode}），降级`);
  }

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/cover?id=' + encodeURIComponent(beta.id),
    headers: reader,
  });
  check('cover_missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 15. 播放（Range）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/stream?id=' + encodeURIComponent(alpha.id),
    headers: Object.assign({ range: 'bytes=0-9' }, reader),
  });
  check('stream_range_206', r.statusCode === 206 && r.rawPayload.length === 10, 'status=' + r.statusCode);

  // 16. 直链令牌
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/stream-url?id=' + encodeURIComponent(alpha.id),
    headers: reader,
  });
  const streamUrl = r.json();
  const direct = streamUrl.url
    ? await app.inject({ method: 'GET', url: streamUrl.url, headers: { range: 'bytes=0-4' } })
    : { statusCode: 0 };
  check('stream_url_playable', r.statusCode === 200 && direct.statusCode === 206, `url=${r.statusCode} play=${direct.statusCode}`);
  // 与影视同一个口径：有效期必须远大于「一首歌缓冲 + 暂停」的时长
  check(
    'stream_url_ttl_long_enough',
    Number(streamUrl.expiresInSec) >= 6 * 3600,
    'expiresInSec=' + streamUrl.expiresInSec,
  );

  const noAuth = await app.inject({
    method: 'GET',
    url: '/api/v1/music/stream?id=' + encodeURIComponent(alpha.id),
  });
  check('stream_requires_auth', noAuth.statusCode === 401, 'status=' + noAuth.statusCode);

  // 16b. 按需转码：WMA 在 Web 端走 AAC；缺 ffmpeg / sidecar 时回退原始地址
  const wmaFile = path.join(songs, 'Gamma.wma');
  const wmaOk =
    ffmpeg &&
    spawnSync(
      FFMPEG,
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'sine=frequency=660:duration=2',
        '-c:a', 'wmav2', '-b:a', '96k', wmaFile,
      ],
      { encoding: 'utf-8' },
    ).status === 0;
  if (wmaOk) {
    await app.inject({ method: 'POST', url: '/api/v1/music/scan', headers: bearer, payload: {} });
    const gamma = (
      await app.inject({ method: 'GET', url: '/api/v1/music/list?q=gamma', headers: bearer })
    ).json().items[0];
    const auto = (
      await app.inject({
        method: 'GET',
        url: '/api/v1/music/stream-url?format=auto&id=' + encodeURIComponent(gamma.id),
        headers: reader,
      })
    ).json();
    const played = auto.url
      ? await app.inject({ method: 'GET', url: auto.url, headers: { range: 'bytes=0-9' } })
      : { statusCode: 0, headers: {} };
    const type = String(played.headers['content-type'] || '');
    check(
      'transcode_auto',
      auto.transcoded === true
        ? auto.url.includes('format=transcoded') &&
            played.statusCode === 206 &&
            /^audio\/(mp4|aac)/.test(type)
        : !auto.url.includes('format=transcoded') && played.statusCode === 206,
      `transcoded=${auto.transcoded} play=${played.statusCode} type=${type}`,
    );

    const plain = (
      await app.inject({
        method: 'GET',
        url: '/api/v1/music/stream-url?id=' + encodeURIComponent(gamma.id),
        headers: reader,
      })
    ).json();
    check(
      'transcode_original_default',
      plain.transcoded === false && !plain.url.includes('format=transcoded'),
      `transcoded=${plain.transcoded}`,
    );
  } else {
    check('transcode_auto', true, 'ffmpeg 不可用，跳过');
    check('transcode_original_default', true, 'ffmpeg 不可用，跳过');
  }

  // 17. 歌单
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/playlists',
    headers: bearer,
    payload: { name: 'Fav', trackIds: [alpha.id] },
  });
  const playlist = r.json();
  check('playlist_create_ok', r.statusCode === 200 && playlist.id && playlist.tracks === 1, JSON.stringify(playlist).slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/playlists/add',
    headers: bearer,
    payload: { playlistId: playlist.id, trackIds: [beta.id] },
  });
  const plItems = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/music/playlists/items?playlistId=' + encodeURIComponent(playlist.id),
      headers: bearer,
    })
  ).json();
  check(
    'playlist_add_and_list',
    r.statusCode === 200 && plItems.items.length === 2 && plItems.items[0].id === alpha.id,
    `status=${r.statusCode} items=${(plItems.items || []).length} body=${String(r.body).slice(0, 120)}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/playlists/remove',
    headers: bearer,
    payload: { playlistId: playlist.id, trackIds: [beta.id] },
  });
  const afterRemove = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/music/playlists/items?playlistId=' + encodeURIComponent(playlist.id),
      headers: bearer,
    })
  ).json();
  check('playlist_remove', r.statusCode === 200 && afterRemove.items.length === 1, 'items=' + (afterRemove.items || []).length);

  // 18. 跨用户隔离
  const otherLists = (await app.inject({ method: 'GET', url: '/api/v1/music/playlists', headers: other })).json();
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/music/playlists/items?playlistId=' + encodeURIComponent(playlist.id),
    headers: other,
  });
  check('playlist_isolation', otherLists.items.length === 0 && r.statusCode === 404, 'status=' + r.statusCode);

  // 18.5 排序 / 专辑·艺人聚合（P2：此前列表写死标题序，专辑艺人靠前端前 200 首分组）
  const page1 = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/music/list?sort=created&order=desc&limit=1',
      headers: bearer,
    })
  ).json();
  const page2 = (
    await app.inject({
      method: 'GET',
      url:
        '/api/v1/music/list?sort=created&order=desc&limit=1&cursor=' +
        encodeURIComponent(page1.nextCursor || ''),
      headers: bearer,
    })
  ).json();
  check(
    'sort_cursor_pagination',
    page1.items.length === 1 &&
      page2.items.length === 1 &&
      page1.items[0].id !== page2.items[0].id,
    `p1=${page1.items.length} p2=${page2.items.length}`,
  );

  const badSortCursor = await app.inject({
    method: 'GET',
    url: '/api/v1/music/list?sort=created&cursor=not-a-cursor',
    headers: bearer,
  });
  check('sort_bad_cursor_400', badSortCursor.statusCode === 400, 'status=' + badSortCursor.statusCode);

  const albumsRes = (
    await app.inject({ method: 'GET', url: '/api/v1/music/albums?limit=50', headers: bearer })
  ).json();
  check(
    'albums_aggregate',
    albumsRes.items.length === 2 && albumsRes.items.every((a) => a.tracks >= 1),
    'n=' + albumsRes.items.length,
  );

  const artistsRes = (
    await app.inject({ method: 'GET', url: '/api/v1/music/artists?limit=50', headers: bearer })
  ).json();
  check(
    'artists_aggregate',
    artistsRes.items.length === 2 && artistsRes.items.every((a) => a.albums >= 1),
    'n=' + artistsRes.items.length,
  );

  const filteredByAlbum = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/music/list?album=' + encodeURIComponent(alpha.album || ''),
      headers: bearer,
    })
  ).json();
  check(
    'filter_by_album',
    filteredByAlbum.items.length >= 1 && filteredByAlbum.items.every((t) => t.album === alpha.album),
    'n=' + filteredByAlbum.items.length,
  );

  // 19. 删库级联（歌单引用一起清掉）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/libraries/remove',
    headers: bearer,
    payload: { id: lib.id },
  });
  const emptyList = (await app.inject({ method: 'GET', url: '/api/v1/music/list', headers: bearer })).json();
  const emptyPl = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/music/playlists/items?playlistId=' + encodeURIComponent(playlist.id),
      headers: bearer,
    })
  ).json();
  check(
    'library_remove_cascade',
    r.statusCode === 200 && emptyList.items.length === 0 && emptyPl.items.length === 0,
    `tracks=${emptyList.items.length} playlist=${emptyPl.items.length}`,
  );

  // 20. 删歌单
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/music/playlists/delete',
    headers: bearer,
    payload: { playlistId: playlist.id },
  });
  const lists = (await app.inject({ method: 'GET', url: '/api/v1/music/playlists', headers: bearer })).json();
  check('playlist_delete', r.statusCode === 200 && lists.items.length === 0, 'playlists=' + lists.items.length);

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