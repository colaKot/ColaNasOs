#!/usr/bin/env node
/**
 * 相册检索与「可操作」链路验收：搜索联想 / 人物关系图 / 批量删除预演+撤销 /
 * 人脸重扫预演 / 单张分项重新识别。
 *
 * 直接写入索引行（不依赖真实图片与扫描），聚焦接口语义。
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

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-photo-retrieval-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'lib'), { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['photo:read', 'photo:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };
  const post = (url, payload) => app.inject({ method: 'POST', url, headers: bearer, payload });
  const get = (url) => app.inject({ method: 'GET', url, headers: bearer });

  const now = Math.floor(Date.now() / 1000);
  const emb = (seed) => Buffer.from(new Float32Array(512).fill(seed).buffer);

  await sql`
    insert into photo_libraries (id, name, root_path, created_at, items)
    values ('lib1', 'lib', '/lib', ${now}, 3)
  `.execute(k.db);
  for (const [id, name, size] of [
    ['p1', 'beach.jpg', 100],
    ['p2', 'street.jpg', 200],
    ['p3', 'ticket.png', 300],
  ]) {
    await sql`
      insert into photo_items (id, library_id, rel_path, taken_at, size, mtime, mime, created_at, camera)
      values (${id}, 'lib1', ${'/' + name}, ${now}, ${size}, ${now}, 'image/jpeg', ${now}, 'Canon EOS R5')
    `.execute(k.db);
  }
  await sql`
    insert into photo_scenes (photo_id, label, score, updated_at) values ('p1', '海滩', 0.9, ${now})
  `.execute(k.db);
  await sql`
    insert into photo_activities (photo_id, label, score, updated_at) values ('p1', '游泳', 0.5, ${now})
  `.execute(k.db);
  await sql`
    insert into photo_ocr (photo_id, text, updated_at) values ('p3', '门票 入场券 2026', ${now})
  `.execute(k.db);

  // p1 带 GPS（地点条件用）：上海人民广场附近
  await sql`
    update photo_items set latitude = 31.2304, longitude = 121.4737 where id = 'p1'
  `.execute(k.db);

  // 同一张合照里三张脸：A/B/C，A-B、A-C 各共现 2 次
  for (const cid of ['c1', 'c2', 'c3']) {
    await sql`
      insert into photo_face_clusters (id, name, size, centroid, created_at)
      values (${cid}, ${'人物' + cid}, 2, ${emb(0.5)}, ${now})
    `.execute(k.db);
  }
  const faces = [
    ['f1', 'p1', 'c1'],
    ['f2', 'p1', 'c2'],
    ['f3', 'p1', 'c3'],
    ['f4', 'p2', 'c1'],
    ['f5', 'p2', 'c2'],
  ];
  for (const [fid, pid, cid] of faces) {
    await sql`
      insert into photo_faces (id, photo_id, emb, cluster_id, score, created_at)
      values (${fid}, ${pid}, ${emb(0.5)}, ${cid}, 1, ${now})
    `.execute(k.db);
  }

  let r;

  // 另一个用户的库与照片：读路径必须严格隔离（管理员也不例外）
  await sql`
    insert into photo_libraries (id, name, root_path, owner_id, created_at, items)
    values ('lib2', 'other', '/other', 'u2', ${now}, 0)
  `.execute(k.db);
  await sql`
    insert into photo_items (id, library_id, rel_path, taken_at, size, mtime, mime, created_at)
    values ('p4', 'lib2', '/private.jpg', ${now}, 1, ${now}, 'image/jpeg', ${now})
  `.execute(k.db);

  r = await get('/api/v1/photo/libraries');
  check(
    'library_owner_isolation',
    r.statusCode === 200 && r.json().items.every((x) => x.id !== 'lib2'),
    'items=' + r.json().items.length,
  );

  r = await get('/api/v1/photo/timeline?limit=50');
  check(
    'timeline_owner_isolation',
    r.statusCode === 200 && r.json().items.every((x) => x.libraryId !== 'lib2'),
    'items=' + r.json().items.length,
  );

  // ---- 搜索联想
  r = await post('/api/v1/photo/search/suggest', {});
  const empty = r.json();
  check(
    'suggest_hot',
    r.statusCode === 200 && empty.items.some((x) => x.kind === 'scene') && empty.items.some((x) => x.kind === 'person'),
    JSON.stringify(empty.items.slice(0, 4)),
  );

  r = await post('/api/v1/photo/search/suggest', { q: '海' });
  check(
    'suggest_scene',
    r.statusCode === 200 && r.json().items.some((x) => x.kind === 'scene' && x.value === '海滩'),
    JSON.stringify(r.json().items),
  );

  r = await post('/api/v1/photo/search/suggest', { q: '门票' });
  check(
    'suggest_ocr',
    r.statusCode === 200 && r.json().items.some((x) => x.kind === 'ocr'),
    JSON.stringify(r.json().items),
  );

  r = await post('/api/v1/photo/search/suggest', { q: 'Canon' });
  check(
    'suggest_camera',
    r.statusCode === 200 && r.json().items.some((x) => x.kind === 'camera' && x.count === 3),
    JSON.stringify(r.json().items),
  );

  // ---- 人物关系图
  r = await get('/api/v1/photo/faces/relations');
  const rel = r.json();
  check(
    'relations_edges',
    r.statusCode === 200 &&
      rel.nodes.length === 3 &&
      rel.edges.length === 3 &&
      rel.edges.some((e) => e.photos === 2),
    `nodes=${rel.nodes.length} edges=${rel.edges.length}`,
  );

  // ---- 批量删除：预演 → 执行 → 撤销
  r = await post('/api/v1/photo/trash/preview', { ids: ['p1', 'p2', 'ghost'] });
  const preview = r.json();
  check('trash_preview', r.statusCode === 200 && preview.count === 2 && preview.bytes === 300 && preview.missing === 1, JSON.stringify(preview));

  r = await post('/api/v1/photo/trash/apply', { ids: ['p1', 'p2'] });
  const applied = r.json();
  check('trash_apply', r.statusCode === 200 && applied.count === 2 && applied.operationId, JSON.stringify(applied));

  const trashed = (
    await sql`select count(*) as n from photo_items where in_trash = 1`.execute(k.db)
  ).rows[0];
  check('trash_marked', Number(trashed.n) === 2, 'in_trash=' + trashed.n);

  r = await get('/api/v1/photo/operation/recent');
  check('operation_recent', r.statusCode === 200 && r.json().items.length === 1, JSON.stringify(r.json().items));

  r = await post('/api/v1/photo/operation/undo', { id: applied.operationId });
  check('operation_undo', r.statusCode === 200 && r.json().restored === 2, JSON.stringify(r.json()));

  const restored = (
    await sql`select count(*) as n from photo_items where in_trash = 1`.execute(k.db)
  ).rows[0];
  check('undo_restored', Number(restored.n) === 0, 'in_trash=' + restored.n);

  r = await post('/api/v1/photo/operation/undo', { id: applied.operationId });
  check('undo_twice_409', r.statusCode === 409, 'status=' + r.statusCode);

  // ---- 人脸重扫预演（只读）
  r = await post('/api/v1/photo/faces/rescan/preview', {});
  const rescan = r.json();
  check(
    'rescan_preview',
    r.statusCode === 200 && rescan.photos === 4 && rescan.faceRows === 5 && rescan.missingFaces === 2,
    JSON.stringify(rescan),
  );

  // ---- P2：单张人脸移动 / 跨照片二次合并 / 撤消回滚
  r = await post('/api/v1/photo/faces/move', { faceId: 'f1' });
  const movedOut = r.json();
  check(
    'face_move_out',
    r.statusCode === 200 && movedOut.clusterId === null,
    JSON.stringify(movedOut),
  );

  r = await post('/api/v1/photo/faces/move', { faceId: 'f1', toClusterId: 'c2' });
  check(
    'face_move_to',
    r.statusCode === 200 && r.json().clusterId === 'c2',
    'status=' + r.statusCode,
  );

  r = await post('/api/v1/photo/faces/merge-candidates', { minSim: 0.3, minEvidence: 1, limit: 10 });
  const cands = r.json();
  check(
    'face_candidates_list',
    r.statusCode === 200 && Array.isArray(cands.items) && typeof cands.scanned === 'number',
    `items=${(cands.items || []).length} scanned=${cands.scanned}`,
  );

  r = await post('/api/v1/photo/faces/merge', { fromId: 'c1', toId: 'c2' });
  const merged = r.json();
  check('face_merge_ok', r.statusCode === 200 && merged.moved >= 1, 'moved=' + merged.moved);

  r = await post('/api/v1/photo/faces/merge-undo', { limit: 1 });
  const undone = r.json();
  check(
    'face_merge_undo',
    r.statusCode === 200 && undone.restored === 1 && undone.faces >= 1,
    JSON.stringify(undone),
  );

  const clustersAfter = (await get('/api/v1/photo/faces/clusters?minCount=1')).json();
  check(
    'cluster_recreated',
    clustersAfter.items.some((c) => c.id === 'c1'),
    'n=' + clustersAfter.items.length,
  );

  // 重建簇必须把质心原样写回（512 个 float32 = 2048 字节）；
  // 丢了质心的话，这个簇在后续候选/合并里等于隐形
  const centroidBytes = (
    await sql`select length(centroid) as n from photo_face_clusters where id = 'c1'`.execute(k.db)
  ).rows[0];
  check(
    'undo_cluster_centroid',
    Number(centroidBytes?.n) === 2048,
    'bytes=' + centroidBytes?.n,
  );

  // 缺省阈值跟随聚类参数 mergeClusterSim（不是另拍一个数）：
  // 同一条数据下，缺省阈值的候选数必须 ≤ 放宽到 0.3 的候选数
  r = await post('/api/v1/photo/faces/merge-candidates', {
    minSim: 0.3,
    minEvidence: 1,
    limit: 10,
  });
  const looseCands = r.json();
  r = await post('/api/v1/photo/faces/merge-candidates', {});
  const defaultCands = r.json();
  check(
    'face_candidates_default',
    r.statusCode === 200 &&
      Array.isArray(defaultCands.items) &&
      defaultCands.items.length <= looseCands.items.length,
    `loose=${(looseCands.items || []).length} default=${(defaultCands.items || []).length}`,
  );

  // ---- 交叉筛选的地点条件（含「半径内有 / 半径外没有」两侧）
  r = await post('/api/v1/photo/filter', {
    conditions: { place: { latitude: 31.2304, longitude: 121.4737, radiusKm: 10 } },
  });
  const placeHit = r.json();
  check(
    'filter_place_hit',
    r.statusCode === 200 && placeHit.total === 1 && placeHit.items[0].id === 'p1',
    'total=' + placeHit.total,
  );

  r = await post('/api/v1/photo/filter', {
    conditions: { place: { latitude: 39.9042, longitude: 116.4074, radiusKm: 10 } },
  });
  check(
    'filter_place_miss',
    r.statusCode === 200 && r.json().total === 0,
    'total=' + r.json().total,
  );

  // 地点 + 场景 同时成立（与关系）
  r = await post('/api/v1/photo/filter', {
    conditions: {
      scene: '海滩',
      place: { latitude: 31.2304, longitude: 121.4737, radiusKm: 10 },
    },
  });
  check(
    'filter_place_and_scene',
    r.statusCode === 200 && r.json().total === 1,
    'total=' + r.json().total,
  );

  // ---- 关键词 × 条件（以前筛选生效时搜索词被静默丢掉）
  r = await post('/api/v1/photo/filter', { q: '门票', conditions: {} });
  check('filter_q_only', r.statusCode === 200 && r.json().total === 1, 'total=' + r.json().total);

  // 关键词命中文件名（beach.jpg）+ 场景 海滩 → 同一张 p1
  r = await post('/api/v1/photo/filter', { q: 'beach', conditions: { scene: '海滩' } });
  check(
    'filter_q_and_scene',
    r.statusCode === 200 && r.json().total === 1,
    'total=' + r.json().total,
  );

  // 关键词与场景落在不同照片上 → 与关系下必须为空
  r = await post('/api/v1/photo/filter', { q: '门票', conditions: { scene: '海滩' } });
  check('filter_q_and_scene_miss', r.statusCode === 200 && r.json().total === 0, 'total=' + r.json().total);

  // ---- 单张分项重新识别
  r = await post('/api/v1/photo/ai/rerun', { photoId: 'p1', face: true, place: true, ocr: true, activity: true });
  const rerun = r.json();
  check(
    'rerun_reset',
    r.statusCode === 200 &&
      rerun.reset.sort().join(',') === 'activity,face,ocr,place' &&
      rerun.ignored.includes('tags'),
    JSON.stringify(rerun),
  );

  r = await post('/api/v1/photo/ai/rerun', { photoId: 'ghost' });
  check('rerun_missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(22)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});