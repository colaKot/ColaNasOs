#!/usr/bin/env node
/**
 * SP3-02 photo 验收：
 *   建库（越界 400 / 重复 409）→ 扫描（忽略非图片）→ 时间轴排序 → EXIF 拍摄时间与尺寸
 *   → cursor 分页 → 关键词 / 时间范围搜索 → 相册增删查 → 跨用户隔离
 *   → 只读 token 不能扫描（403）→ 删库级联清索引与相册成员
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/photo-smoke.js
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

/** 1x1 PNG（只需 IHDR 合法即可被尺寸解析器识别） */
const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

/** 构造带 EXIF DateTimeOriginal 的最小 JPEG（宽 640 × 高 480） */
function buildJpegWithExif(dateStr) {
  const date = Buffer.from(dateStr + '\0', 'latin1');
  const tiff = Buffer.alloc(44 + date.length);
  tiff.write('II', 0, 'latin1');
  tiff.writeUInt16LE(0x2a, 2);
  tiff.writeUInt32LE(8, 4);
  // IFD0：1 个条目，指向 Exif 子 IFD（偏移 26）
  tiff.writeUInt16LE(1, 8);
  tiff.writeUInt16LE(0x8769, 10);
  tiff.writeUInt16LE(4, 12);
  tiff.writeUInt32LE(1, 14);
  tiff.writeUInt32LE(26, 18);
  tiff.writeUInt32LE(0, 22);
  // Exif IFD：DateTimeOriginal（0x9003）指向偏移 44
  tiff.writeUInt16LE(1, 26);
  tiff.writeUInt16LE(0x9003, 28);
  tiff.writeUInt16LE(2, 30);
  tiff.writeUInt32LE(date.length, 32);
  tiff.writeUInt32LE(44, 36);
  tiff.writeUInt32LE(0, 40);
  date.copy(tiff, 44);

  const payload = Buffer.concat([Buffer.from('Exif\0\0', 'latin1'), tiff]);
  const lenBuf = Buffer.alloc(2);
  lenBuf.writeUInt16BE(payload.length + 2);
  const app1 = Buffer.concat([Buffer.from([0xff, 0xe1]), lenBuf, payload]);
  // SOF0：精度 8，高 480，宽 640，3 分量
  const sof = Buffer.from([
    0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0xe0, 0x02, 0x80, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11,
    0x01, 0x03, 0x11, 0x01,
  ]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app1, sof, Buffer.from([0xff, 0xd9])]);
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-photo-'));
  const filesRoot = path.join(dataDir, 'files');
  const photos = path.join(filesRoot, 'photos');
  fs.mkdirSync(path.join(photos, 'trip'), { recursive: true });
  fs.writeFileSync(path.join(photos, 'trip', 'IMG_20240102_120000.png'), PNG_1PX);
  fs.writeFileSync(path.join(photos, 'trip', '2019-05-06 07.08.09.png'), PNG_1PX);
  fs.writeFileSync(path.join(photos, 'exif.jpg'), buildJpegWithExif('2022:03:04 05:06:07'));
  fs.writeFileSync(path.join(photos, 'notes.txt'), 'not an image');

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
    payload: { sub: 'u1', scopes: ['photo:read', 'photo:write', 'files:read', 'tasks:read'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['photo:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };

  const otherRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u3', scopes: ['photo:read', 'photo:write'] },
  });
  const other = { authorization: 'Bearer ' + otherRes.json().token };

  // 1. 匿名不可读
  let r = await app.inject({ method: 'GET', url: '/api/v1/photo/timeline' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 越界路径
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/libraries',
    headers: bearer,
    payload: { name: 'bad', path: '../../etc' },
  });
  check('library_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 3. 建库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/libraries',
    headers: bearer,
    payload: { name: 'Photos', path: '/photos' },
  });
  const lib = r.json();
  check('library_create_ok', r.statusCode === 200 && lib.id && lib.path === 'photos', JSON.stringify(lib).slice(0, 80));

  // 4. 重复库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/libraries',
    headers: bearer,
    payload: { name: 'Dup', path: 'photos' },
  });
  check('library_duplicate_409', r.statusCode === 409, 'status=' + r.statusCode);

  // 5. 只读 token 不能扫描
  r = await app.inject({ method: 'POST', url: '/api/v1/photo/scan', headers: reader, payload: {} });
  check('scan_requires_write', r.statusCode === 403, 'status=' + r.statusCode);

  // 6. 扫描（txt 不计入）
  r = await app.inject({ method: 'POST', url: '/api/v1/photo/scan', headers: bearer, payload: {} });
  const scan = r.json();
  check(
    'scan_images',
    r.statusCode === 200 && scan.images === 3 && scan.added === 3,
    JSON.stringify(scan),
  );

  // 7. 增量：再扫一次全部跳过
  r = await app.inject({ method: 'POST', url: '/api/v1/photo/scan', headers: bearer, payload: {} });
  const again = r.json();
  check('scan_incremental', again.added === 0 && again.skipped === 3, JSON.stringify(again));

  // 8. 时间轴倒序：2024 文件名 > EXIF 2022 > 文件名声明的 2019
  const expect2024 = Math.floor(new Date(2024, 0, 2, 12, 0, 0).getTime() / 1000);
  const expect2022 = Math.floor(new Date(2022, 2, 4, 5, 6, 7).getTime() / 1000);
  const expect2019 = Math.floor(new Date(2019, 4, 6, 7, 8, 9).getTime() / 1000);

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/timeline?limit=10', headers: bearer });
  const tl = r.json();
  const list = tl.items || [];
  check(
    'timeline_order',
    r.statusCode === 200 && list.length === 3 && list[0].takenAt === expect2024,
    list.map((x) => x.takenAt).join(','),
  );

  // 9. EXIF：拍摄时间与尺寸
  const exifItem = list.find((x) => x.path.endsWith('exif.jpg'));
  check(
    'exif_taken_at_size',
    !!exifItem &&
      exifItem.takenAt === expect2022 &&
      exifItem.width === 640 &&
      exifItem.height === 480,
    exifItem ? `${exifItem.takenAt}/${exifItem.width}x${exifItem.height}` : 'missing',
  );
  check(
    'filename_date_fallback',
    list[list.length - 1].takenAt === expect2019,
    String(list[list.length - 1].takenAt),
  );

  // 10. cursor 分页
  const p1 = (await app.inject({ method: 'GET', url: '/api/v1/photo/timeline?limit=1', headers: bearer })).json();
  const p2 = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/photo/timeline?limit=1&cursor=' + encodeURIComponent(p1.nextCursor || ''),
      headers: bearer,
    })
  ).json();
  check(
    'cursor_pagination',
    p1.items.length === 1 &&
      p1.nextCursor &&
      p2.items.length === 1 &&
      p2.items[0].id !== p1.items[0].id,
    `${p1.items.length}/${p2.items.length}`,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/timeline?cursor=not-a-cursor', headers: bearer });
  check('bad_cursor_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 10c. 异步扫描：入队 → 任务可查 → 真的跑完
  // 同步 /photo/scan 要等整个库扫完才返回，客户端 30 s 超时就会「假失败」。
  // 这条验证的是任务化那条路（界面走的口径）。
  r = await app.inject({ method: 'POST', url: '/api/v1/photo/scan/task', headers: bearer, payload: {} });
  const queued = r.json();
  check('scan_task_enqueued', r.statusCode === 200 && Boolean(queued.taskId), r.body.slice(0, 120));
  let scanTask = null;
  for (let i = 0; i < 120; i += 1) {
    const one = await app.inject({
      method: 'GET',
      url: '/api/v1/tasks/' + queued.taskId,
      headers: bearer,
    });
    const j = one.json();
    if (j.state === 'done' || j.state === 'failed') {
      scanTask = j;
      break;
    }
    await new Promise((res) => setTimeout(res, 100));
  }
  check(
    'scan_task_done',
    Boolean(scanTask) && scanTask.state === 'done',
    scanTask ? `${scanTask.state} ${scanTask.error || ''}` : 'timeout',
  );
  r = await app.inject({ method: 'GET', url: '/api/v1/tasks/no-such-task', headers: bearer });
  check('task_get_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 10b. cursor 分页 · 正序 + 同一秒
  // 回归用：asc 分支曾把次键写成 `id <`，而 ORDER BY 是 `taken_at asc, id asc`。
  // 不同拍摄时间时 `taken_at > ?` 就能推进，那条错误路径根本不生效 ——
  // 只有「同一秒的照片跨页」才会重复 + 漏图，所以这里必须把时间压成同一个值。
  const before = await k.db.selectFrom('photo_items').select(['id', 'taken_at']).execute();
  await k.db.updateTable('photo_items').set({ taken_at: 1700000000 }).execute();
  const walked = [];
  let walkCur = null;
  for (let i = 0; i < 6; i++) {
    const url =
      '/api/v1/photo/timeline?order=asc&limit=1' +
      (walkCur ? '&cursor=' + encodeURIComponent(walkCur) : '');
    const page = (await app.inject({ method: 'GET', url, headers: bearer })).json();
    for (const it of page.items || []) walked.push(it.id);
    walkCur = page.nextCursor;
    if (!walkCur) break;
  }
  check(
    'cursor_asc_same_second',
    walked.length === before.length && new Set(walked).size === before.length,
    `walked=${walked.length} unique=${new Set(walked).size} total=${before.length}`,
  );
  // 还原拍摄时间：后面的时间范围用例（2020–2023）依赖它
  for (const b of before) {
    await k.db.updateTable('photo_items').set({ taken_at: b.taken_at }).where('id', '=', b.id).execute();
  }

  // 11. 关键词搜索
  r = await app.inject({ method: 'GET', url: '/api/v1/photo/search?q=exif', headers: bearer });
  const byKeyword = r.json();
  check(
    'search_keyword',
    r.statusCode === 200 && byKeyword.items.length === 1 && byKeyword.items[0].path.endsWith('exif.jpg'),
    'items=' + (byKeyword.items || []).length,
  );

  // 12. 时间范围
  const from = Math.floor(new Date(2020, 0, 1).getTime() / 1000);
  const to = Math.floor(new Date(2023, 0, 1).getTime() / 1000);
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/photo/search?from=${from}&to=${to}`,
    headers: bearer,
  });
  const byRange = r.json();
  check('search_time_range', r.statusCode === 200 && byRange.items.length === 1, 'items=' + (byRange.items || []).length);

  // 13. 统计
  r = await app.inject({ method: 'GET', url: '/api/v1/photo/stats', headers: bearer });
  const stats = r.json();
  check(
    'stats',
    r.statusCode === 200 && stats.items === 3 && stats.libraries === 1 && stats.latest === expect2024,
    JSON.stringify(stats),
  );

  // 14. 相册
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/albums',
    headers: bearer,
    payload: { name: 'Trip 2024', itemIds: [list[0].id] },
  });
  const album = r.json();
  check('album_create_ok', r.statusCode === 200 && album.id && album.items === 1, JSON.stringify(album).slice(0, 80));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/albums/add',
    headers: bearer,
    payload: { albumId: album.id, itemIds: [list[1].id, list[2].id] },
  });
  const albumItems = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/photo/albums/items?albumId=' + encodeURIComponent(album.id),
      headers: bearer,
    })
  ).json();
  check(
    'album_add_and_list',
    r.statusCode === 200 && albumItems.items.length === 3 && albumItems.items[0].id === list[0].id,
    'items=' + (albumItems.items || []).length,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/albums/remove',
    headers: bearer,
    payload: { albumId: album.id, itemIds: [list[2].id] },
  });
  const afterRemove = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/photo/albums/items?albumId=' + encodeURIComponent(album.id),
      headers: bearer,
    })
  ).json();
  check(
    'album_remove',
    r.statusCode === 200 && afterRemove.items.length === 2,
    'items=' + (afterRemove.items || []).length,
  );

  // 14.5 网页上传（原始流 → 写来源目录 → 增量入库）
  const uploadName = `upload-${Date.now()}.png`;
  const uploadUrl = (fileName, dir) =>
    `/api/v1/photo/upload?libraryId=${encodeURIComponent(lib.id)}&fileName=${encodeURIComponent(fileName)}` +
    (dir ? `&dir=${encodeURIComponent(dir)}` : '');
  const uploadHeaders = { ...bearer, 'content-type': 'application/x-colanas-upload' };

  r = await app.inject({
    method: 'POST',
    url: uploadUrl(uploadName),
    headers: uploadHeaders,
    payload: PNG_1PX,
  });
  const uploaded = r.json();
  check(
    'upload_ok',
    r.statusCode === 200 &&
      uploaded.ok === true &&
      uploaded.indexed >= 1 &&
      uploaded.size > 0 &&
      String(uploaded.path || '').startsWith('手机上传/'),
    JSON.stringify(uploaded),
  );

  r = await app.inject({
    method: 'POST',
    url: uploadUrl(uploadName),
    headers: uploadHeaders,
    payload: PNG_1PX,
  });
  check(
    'upload_dedupe',
    r.statusCode === 200 && String(r.json().path || '').includes('-1'),
    JSON.stringify(r.json()),
  );

  r = await app.inject({
    method: 'POST',
    url: uploadUrl('not-image.txt'),
    headers: uploadHeaders,
    payload: Buffer.from('nope'),
  });
  check('upload_type_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: uploadUrl(uploadName, '../escape'),
    headers: uploadHeaders,
    payload: PNG_1PX,
  });
  check('upload_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 15. 跨用户隔离
  const otherAlbums = (
    await app.inject({ method: 'GET', url: '/api/v1/photo/albums', headers: other })
  ).json();
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/albums/items?albumId=' + encodeURIComponent(album.id),
    headers: other,
  });
  check('album_isolation', otherAlbums.items.length === 0 && r.statusCode === 404, 'status=' + r.statusCode);

  // 16. 删库级联
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/libraries/remove',
    headers: bearer,
    payload: { id: lib.id },
  });
  const emptyTl = (await app.inject({ method: 'GET', url: '/api/v1/photo/timeline', headers: bearer })).json();
  const emptyAlbum = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/photo/albums/items?albumId=' + encodeURIComponent(album.id),
      headers: bearer,
    })
  ).json();
  check(
    'library_remove_cascade',
    r.statusCode === 200 && emptyTl.items.length === 0 && emptyAlbum.items.length === 0,
    `timeline=${emptyTl.items.length} album=${emptyAlbum.items.length}`,
  );

  // 17. 删相册
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/albums/delete',
    headers: bearer,
    payload: { albumId: album.id },
  });
  const albums = (await app.inject({ method: 'GET', url: '/api/v1/photo/albums', headers: bearer })).json();
  check('album_delete', r.statusCode === 200 && albums.items.length === 0, 'albums=' + albums.items.length);

  // 18. 扫描策略（自动监视 / 周期校验 / 跳过隐藏文件）
  r = await app.inject({ method: 'GET', url: '/api/v1/photo/scan-policy', headers: reader });
  const policy0 = r.json();
  check(
    'scan_policy_default',
    r.statusCode === 200 &&
      policy0.autoWatch === true &&
      policy0.verifyHours === 6 &&
      policy0.skipHidden === true,
    JSON.stringify(policy0),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/scan-policy',
    headers: bearer,
    payload: { autoWatch: false, verifyHours: 0, skipHidden: false },
  });
  const policy1 = r.json();
  check(
    'scan_policy_update',
    r.statusCode === 200 &&
      policy1.autoWatch === false &&
      policy1.verifyHours === 0 &&
      policy1.skipHidden === false,
    JSON.stringify(policy1),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/scan-policy', headers: reader });
  check(
    'scan_policy_persisted',
    r.json().autoWatch === false && r.json().verifyHours === 0,
    JSON.stringify(r.json()),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/scan-policy',
    headers: bearer,
    payload: { verifyHours: 999 },
  });
  check('scan_policy_range_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 19. 瓦片本地缓存代理（预置缓存直接命中；越界 / 未知源）
  const tileFile = path.join(dataDir, 'photo-tiles', 'esri', '3', '4', '5.png');
  fs.mkdirSync(path.dirname(tileFile), { recursive: true });
  fs.writeFileSync(tileFile, PNG_1PX);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/map/tile?z=3&x=4&y=5&server=esri',
    headers: bearer,
  });
  check(
    'tile_cache_hit',
    r.statusCode === 200 &&
      String(r.headers['content-type']).startsWith('image/png') &&
      Buffer.compare(r.rawPayload, PNG_1PX) === 0,
    `status=${r.statusCode} type=${r.headers['content-type']} bytes=${r.rawPayload.length}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/map/tile?z=30&x=0&y=0',
    headers: bearer,
  });
  check('tile_range_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/map/tile?z=3&x=4&y=5&server=nope',
    headers: bearer,
  });
  check('tile_server_404', r.statusCode === 404, 'status=' + r.statusCode);

  await app.inject({
    method: 'POST',
    url: '/api/v1/photo/scan-policy',
    headers: bearer,
    payload: { autoWatch: true, verifyHours: 6, skipHidden: true },
  });


  // 20. 智能相册规则：自定义条件（时间 / 场景 / 人物 / 地点）CRUD + 查询
  // 前面删库用例已清空索引，先重建库并重扫，规则才有可命中的照片
  await app.inject({
    method: 'POST',
    url: '/api/v1/photo/libraries',
    headers: bearer,
    payload: { name: 'Rules', path: '/photos' },
  });
  await app.inject({ method: 'POST', url: '/api/v1/photo/scan', headers: bearer, payload: {} });
  const ruleTimeline = (
    await app.inject({ method: 'GET', url: '/api/v1/photo/timeline?limit=10', headers: bearer })
  ).json().items || [];

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules',
    headers: bearer,
    payload: { name: '空规则', conditions: {} },
  });
  check('smart_rule_empty_400', r.statusCode === 400, 'status=' + r.statusCode);

  const p2020 = Math.floor(new Date(2020, 0, 1).getTime() / 1000);
  const p2025 = Math.floor(new Date(2025, 0, 1).getTime() / 1000);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules',
    headers: bearer,
    payload: { name: '2020-2024', conditions: { from: p2020, to: p2025 } },
  });
  const rule = r.json();
  check(
    'smart_rule_create',
    r.statusCode === 200 && !!rule.id && rule.items === 2,
    `status=${r.statusCode} items=${rule.items}`,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/smart-rules', headers: bearer });
  const rules = r.json().items || [];
  check(
    'smart_rule_list',
    r.statusCode === 200 && rules.length === 1 && rules[0].items === 2 && !!rules[0].coverPath,
    `n=${rules.length}`,
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/photo/smart-rules/items?id=${rule.id}`,
    headers: bearer,
  });
  check(
    'smart_rule_items',
    r.statusCode === 200 && (r.json().items || []).length === 2,
    `n=${(r.json().items || []).length}`,
  );

  // 同一张 2024 照片补场景 / 人脸 / 坐标，验证三类条件都能命中
  const target = ruleTimeline[0];
  const ruleTs = Math.floor(Date.now() / 1000);
  await k.db
    .insertInto('photo_scenes')
    .values({ photo_id: target.id, label: 'beach', score: 0.9, updated_at: ruleTs })
    .execute();
  await k.db
    .insertInto('photo_faces')
    .values({
      id: 'f-smoke',
      photo_id: target.id,
      emb: Buffer.from([1, 2, 3]),
      cluster_id: 'c-smoke',
      score: 1,
      created_at: ruleTs,
    })
    .execute();
  await app.inject({
    method: 'POST',
    url: '/api/v1/photo/geo/set',
    headers: bearer,
    payload: { ids: [target.id], latitude: 31.23, longitude: 121.47 },
  });

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules',
    headers: bearer,
    payload: { name: '海边', conditions: { scene: 'beach' } },
  });
  const sceneRule = r.json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules',
    headers: bearer,
    payload: { name: '某人', conditions: { faceClusterId: 'c-smoke' } },
  });
  const personRule = r.json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules',
    headers: bearer,
    payload: {
      name: '上海',
      conditions: { place: { latitude: 31.23, longitude: 121.47, radiusKm: 5 } },
    },
  });
  const placeRule = r.json();
  check(
    'smart_rule_conditions_hit',
    sceneRule.items === 1 && personRule.items === 1 && placeRule.items === 1,
    `scene=${sceneRule.items} person=${personRule.items} place=${placeRule.items}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules/update',
    headers: bearer,
    payload: { id: rule.id, name: '改名', conditions: { from: p2020, to: p2025 } },
  });
  check(
    'smart_rule_update',
    r.statusCode === 200 && r.json().name === '改名' && r.json().items === 2,
    `status=${r.statusCode}`,
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/photo/smart-rules/items?id=${rule.id}`,
    headers: other,
  });
  check('smart_rule_cross_user_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/smart-rules/delete',
    headers: bearer,
    payload: { id: rule.id },
  });
  const afterDelete = await app.inject({
    method: 'GET',
    url: `/api/v1/photo/smart-rules/items?id=${rule.id}`,
    headers: bearer,
  });
  check(
    'smart_rule_delete',
    r.statusCode === 200 && r.json().ok === true && afterDelete.statusCode === 404,
    `status=${r.statusCode}`,
  );

  // ---------------------------------------------------------------- 混合检索 / 场景多标签 / 人脸
  // 这些接口是本轮新增的「把 AI 结果接到界面」的通道，至少要保证：
  // 参数校验到位、没数据时给空数组而不是 500、owner 隔离不泄漏。

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/search/hybrid', headers: bearer });
  check('hybrid_search_requires_q', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/search/hybrid?q=' + encodeURIComponent('sample') + '&limit=10',
    headers: bearer,
  });
  const hybrid = r.json();
  check(
    'hybrid_search_ok',
    r.statusCode === 200 &&
      Array.isArray(hybrid.items) &&
      typeof hybrid.total === 'number' &&
      Array.isArray(hybrid.tags) &&
      Array.isArray(hybrid.unmatched) &&
      typeof hybrid.degraded === 'boolean',
    JSON.stringify({ n: hybrid.items && hybrid.items.length, total: hybrid.total, degraded: hybrid.degraded }),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/scene-tags/summary', headers: bearer });
  check(
    'scene_tags_summary_ok',
    r.statusCode === 200 && Array.isArray(r.json().items),
    'items=' + ((r.json().items || []).length),
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/photo/scene-tags?label=' + encodeURIComponent('天空'),
    headers: bearer,
  });
  check(
    'scene_tags_by_label_ok',
    r.statusCode === 200 && Array.isArray(r.json().items) && r.json().label === '天空',
    'status=' + r.statusCode,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/face/image?id=nope', headers: bearer });
  check('face_image_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/face/image', headers: bearer });
  check('face_image_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/faces/dissolve',
    headers: bearer,
    payload: { clusterId: 'not-exists' },
  });
  check('face_dissolve_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/faces/dissolve',
    headers: bearer,
    payload: {},
  });
  check('face_dissolve_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 19. P2：相册元数据 / 年视图 / 回收站批次 / 行程连线 / 人脸候选
  // 前面的用例会永久删除部分照片，这里重新取当前还在索引里的照片
  const fresh = (
    await app.inject({ method: 'GET', url: '/api/v1/photo/timeline?limit=10', headers: bearer })
  ).json().items;
  if (fresh.length >= 3) {
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/albums',
      headers: bearer,
      payload: { name: 'P2 Meta', itemIds: [fresh[0].id, fresh[1].id] },
    });
    const p2Album = r.json();
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/albums/update',
      headers: bearer,
      payload: {
        albumId: p2Album.id,
        description: '海边三日',
        sortOrder: 20,
      },
    });
    const p2Updated = r.json();
    check(
      'album_update_meta',
      r.statusCode === 200 && p2Updated.description === '海边三日' && p2Updated.sortOrder === 20,
      `status=${r.statusCode} desc=${p2Updated.description}`,
    );

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/albums/update',
      headers: bearer,
      payload: { albumId: p2Album.id, coverItemId: fresh[2].id },
    });
    check('album_cover_member_400', r.statusCode === 400, 'status=' + r.statusCode);

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/albums/update',
      headers: bearer,
      payload: { albumId: p2Album.id, coverItemId: fresh[1].id },
    });
    const withCover = r.json();
    check(
      'album_cover_set',
      r.statusCode === 200 &&
        withCover.coverItemId === fresh[1].id &&
        withCover.coverPath === fresh[1].path,
      `cover=${withCover.coverPath}`,
    );

    const calYear = new Date(fresh[0].takenAt * 1000).getFullYear();
    r = await app.inject({
      method: 'GET',
      url: '/api/v1/photo/calendar?year=' + calYear,
      headers: bearer,
    });
    const cal = r.json();
    check(
      'calendar_months',
      r.statusCode === 200 && cal.year === calYear && cal.months.length === 12 && cal.total >= 1,
      `year=${cal.year} total=${cal.total}`,
    );

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/delete',
      headers: bearer,
      payload: { ids: [fresh[2].id], toTrash: true },
    });
    const del = r.json();
    check(
      'trash_batch_created',
      r.statusCode === 200 && del.trashed === true && !!del.batchId,
      `batch=${del.batchId}`,
    );

    const batches = (
      await app.inject({ method: 'GET', url: '/api/v1/photo/trash/batches', headers: bearer })
    ).json();
    check(
      'trash_batches_list',
      batches.items.some((b) => b.batchId === del.batchId && b.count === 1),
      'groups=' + batches.items.length,
    );

    const batchItems = (
      await app.inject({
        method: 'GET',
        url: '/api/v1/photo/trash?batchId=' + encodeURIComponent(del.batchId),
        headers: bearer,
      })
    ).json();
    check(
      'trash_batch_items',
      batchItems.items.length === 1 && batchItems.items[0].batchId === del.batchId,
      'n=' + batchItems.items.length,
    );

    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/trash/restore',
      headers: bearer,
      payload: { batchId: del.batchId },
    });
    check(
      'trash_restore_batch',
      r.statusCode === 200 && r.json().restored === 1,
      'restored=' + r.json().restored,
    );

    // 交叉筛选：条件为空必须返回空集（否则一个前端 bug 就能把整库拉出来）
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/filter',
      headers: bearer,
      payload: { conditions: {} },
    });
    check(
      'filter_empty_conditions',
      r.statusCode === 200 && r.json().items.length === 0,
      'n=' + r.json().items.length,
    );

    // 收藏条件
    await app.inject({
      method: 'POST',
      url: '/api/v1/photo/favorite',
      headers: bearer,
      payload: { ids: [fresh[0].id], favorite: true },
    });
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/filter',
      headers: bearer,
      payload: { conditions: { favorite: true } },
    });
    const favFiltered = r.json();
    check(
      'filter_favorite',
      r.statusCode === 200 &&
        favFiltered.total >= 1 &&
        favFiltered.items.every((i) => i.favorite === true),
      'total=' + favFiltered.total,
    );

    // 时间窗（该照片拍摄时间前后一天）
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/filter',
      headers: bearer,
      payload: {
        conditions: { from: fresh[0].takenAt - 86400, to: fresh[0].takenAt + 86400 },
      },
    });
    const timeFiltered = r.json();
    check(
      'filter_time_range',
      r.statusCode === 200 && timeFiltered.total >= 1,
      'total=' + timeFiltered.total,
    );

    // 不存在的场景标签 → 0（而不是忽略条件返回全库）
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/photo/filter',
      headers: bearer,
      payload: { conditions: { scene: '__no_such_scene__' } },
    });
    check(
      'filter_unknown_scene_zero',
      r.statusCode === 200 && r.json().total === 0,
      'total=' + r.json().total,
    );
  } else {
    check('album_update_meta', false, 'need >=3 photos, got ' + fresh.length);
  }

  r = await app.inject({ method: 'GET', url: '/api/v1/photo/map/journey', headers: bearer });
  const journey = r.json();
  check(
    'map_journey_ok',
    r.statusCode === 200 && Array.isArray(journey.segments) && typeof journey.distanceKm === 'number',
    `segments=${journey.segments ? journey.segments.length : -1}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/faces/move',
    headers: bearer,
    payload: { faceId: 'not-exists' },
  });
  check('face_move_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/faces/merge-candidates',
    headers: bearer,
    payload: { minSim: 0.7, minEvidence: 3, limit: 5 },
  });
  const cands = r.json();
  check(
    'face_candidates_ok',
    r.statusCode === 200 && Array.isArray(cands.items),
    'items=' + (cands.items || []).length,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/photo/faces/merge-undo',
    headers: bearer,
    payload: { limit: 1 },
  });
  check(
    'face_merge_undo_ok',
    r.statusCode === 200 && typeof r.json().restored === 'number',
    'restored=' + r.json().restored,
  );

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