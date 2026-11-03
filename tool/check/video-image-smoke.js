'use strict';

/**
 * 图片库 / 混合库验收：
 *   扫描图片 → 列表计数 / 排序 / 文件夹范围 → 图片封面接口
 *   → 文件夹层级（数量 / 封面） → 混合库同名图片隐身
 *   → 首页最近添加包含图片 → 删除图片（文件进回收站 / 索引消失）
 *   → 删除文件夹（整目录进回收站 / 索引前缀清理）
 */
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
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));
process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

let passed = 0;
let failed = 0;
const check = (n, c, d) => {
  if (c) {
    passed += 1;
    console.log('[OK]  ', n.padEnd(30), d === undefined ? '' : d);
  } else {
    failed += 1;
    console.log('[FAIL]', n.padEnd(30), d);
  }
};

const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
);

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-vimg-'));
  const filesRoot = path.join(dataDir, 'files');
  const imgs = path.join(filesRoot, 'imgs');
  const setA = path.join(imgs, 'setA');
  const mixed = path.join(filesRoot, 'mixed');
  fs.mkdirSync(setA, { recursive: true });
  fs.mkdirSync(mixed, { recursive: true });
  fs.writeFileSync(path.join(imgs, 'one.png'), PNG);
  fs.writeFileSync(path.join(setA, 'two.png'), PNG);
  fs.writeFileSync(path.join(setA, 'three.png'), PNG);
  fs.writeFileSync(path.join(mixed, 'cover.png'), PNG);
  fs.writeFileSync(path.join(mixed, 'movie.jpg'), Buffer.alloc(64, 2)); // 与 movie.mp4 同名
  fs.writeFileSync(path.join(mixed, 'movie.mp4'), Buffer.alloc(2048, 1));

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'image-smoke-secret-0123456789';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;
  const bearer = {
    authorization:
      'Bearer ' +
      (await app.inject({
        method: 'POST',
        url: '/api/v1/auth/dev-token',
        payload: { sub: 'img', scopes: ['*'] },
      })).json().token,
  };

  const createLib = async (name, p, libType) => {
    const r = await app.inject({
      method: 'POST',
      url: '/api/v1/video/libraries',
      headers: bearer,
      payload: { name, path: p, libType },
    });
    return r.json();
  };
  const scan = async (id) =>
    (
      await app.inject({
        method: 'POST',
        url: '/api/v1/video/scan',
        headers: bearer,
        payload: { libraryId: id },
      })
    ).json();

  const imageLib = await createLib('Images', '/imgs', 'image');
  const mixedLib = await createLib('Mixed', '/mixed', 'mixed');
  const scanImage = await scan(imageLib.id);
  check('image_scan', scanImage.images === 3, 'images=' + scanImage.images);
  const scanMixed = await scan(mixedLib.id);
  check('mixed_scan', scanMixed.videos === 1 && scanMixed.images === 2, JSON.stringify(scanMixed));

  let r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list?libraryId=${imageLib.id}&limit=20&sortBy=name&sortOrder=desc`,
    headers: bearer,
  });
  const list = r.json();
  check('image_list', list.items.length === 3 && list.items.every((x) => x.mediaType === 'image'), 'n=' + list.items.length);
  check(
    'image_sort_desc',
    list.items.map((x) => x.title).join(',') === 'two,three,one' ||
      list.items.map((x) => x.title).join(',') === 'three,two,one',
    list.items.map((x) => x.title).join(','),
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list/count?libraryId=${imageLib.id}`,
    headers: bearer,
  });
  check('image_count', r.json().total === 3, JSON.stringify(r.json()));

  const first = list.items[0];
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/item?id=${encodeURIComponent(first.id)}`,
    headers: bearer,
  });
  check('image_item', r.statusCode === 200 && r.json().mediaType === 'image', 'status=' + r.statusCode);
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/poster?id=${encodeURIComponent(first.id)}`,
    headers: bearer,
  });
  check('image_poster', r.statusCode === 200 && r.rawPayload.length > 0, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list?libraryId=${imageLib.id}&limit=20&folderPath=imgs/setA&folderMode=exact`,
    headers: bearer,
  });
  check('folder_exact', r.json().items.length === 2, 'n=' + r.json().items.length);

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/image/folders?libraryId=${imageLib.id}`,
    headers: bearer,
  });
  const folders = r.json();
  check(
    'folder_level',
    r.statusCode === 200 && folders.folders.length === 1 && folders.folders[0].name === 'setA' && folders.folders[0].count === 2,
    JSON.stringify(folders.folders),
  );
  check('folder_cover', folders.folders[0].cover && folders.folders[0].cover.mediaType === 'image', 'cover=' + JSON.stringify(folders.folders[0].cover));

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list?libraryId=${mixedLib.id}&limit=20`,
    headers: bearer,
  });
  const mixedList = r.json().items;
  check(
    'mixed_list_hides_same_name',
    mixedList.some((x) => x.mediaType === 'video') &&
      mixedList.some((x) => x.mediaType === 'image') &&
      !mixedList.some((x) => x.title === 'movie' && x.mediaType === 'image'),
    mixedList.map((x) => `${x.mediaType}:${x.title}`).join(','),
  );
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list/count?libraryId=${mixedLib.id}`,
    headers: bearer,
  });
  check('mixed_count', r.json().total === 2, JSON.stringify(r.json()));

  r = await app.inject({ method: 'GET', url: '/api/v1/video/home', headers: bearer });
  const home = r.json();
  const imageRow = (home.recentAdd || []).find((x) => x.libraryId === imageLib.id);
  check(
    'home_recent_add_image',
    !!imageRow && imageRow.libType === 'image' && imageRow.items.some((x) => x.mediaType === 'image'),
    JSON.stringify(imageRow && imageRow.items.map((x) => x.mediaType)),
  );
  const src = (home.sources || []).find((x) => x.id === imageLib.id);
  check('home_image_cover', !!src && !!src.coverPath, 'coverPath=' + (src && src.coverPath));

  // 「首页显示」关闭后，首页任何区块都不能再出现该库（来源 / 最近添加 / 统计）
  const statsBefore = (await app.inject({ method: 'GET', url: '/api/v1/video/stats', headers: bearer })).json();
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/flags',
    headers: bearer,
    payload: { id: imageLib.id, showInHome: false },
  });
  check('hide_in_home_update', r.statusCode === 200 && r.json().showInHome === 0, r.body.slice(0, 100));
  const homeHidden = (await app.inject({ method: 'GET', url: '/api/v1/video/home', headers: bearer })).json();
  check(
    'hide_in_home_sources',
    !(homeHidden.sources || []).some((x) => x.id === imageLib.id),
    'sources=' + (homeHidden.sources || []).map((x) => x.id).join(','),
  );
  check(
    'hide_in_home_recent_add',
    !(homeHidden.recentAdd || []).some((x) => x.libraryId === imageLib.id),
    'recentAdd=' + (homeHidden.recentAdd || []).map((x) => x.libraryId).join(','),
  );
  check(
    'hide_in_home_stats',
    !(homeHidden.recommend || []).some((x) => x.libraryId === imageLib.id),
    'recommend=' + (homeHidden.recommend || []).map((x) => x.libraryId).join(','),
  );
  const statsHidden = (await app.inject({ method: 'GET', url: '/api/v1/video/stats', headers: bearer })).json();
  check(
    'hide_in_home_stats_count',
    statsHidden.libraries === statsBefore.libraries - 1,
    `before=${statsBefore.libraries} after=${statsHidden.libraries}`,
  );
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/libraries/flags',
    headers: bearer,
    payload: { id: imageLib.id, showInHome: true },
  });
  check('hide_in_home_restore', r.statusCode === 200, r.body.slice(0, 100));

  // 删除单张图片
  const victim = list.items.find((x) => x.title === 'one');
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/items/delete',
    headers: bearer,
    payload: { ids: [victim.id] },
  });
  const del = r.json();
  check('image_delete', r.statusCode === 200 && (del.done || []).length === 1, r.body.slice(0, 100));
  check('image_file_gone', !fs.existsSync(path.join(imgs, 'one.png')), 'still on disk');
  check('image_file_trash', fs.existsSync(path.join(filesRoot, '.colanas-trash', del.trashedTo, 'one.png')), 'not in trash');

  // 删除文件夹
  const hadFiles = fs.existsSync(setA);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/video/image/folders/delete',
    headers: bearer,
    payload: { libraryId: imageLib.id, path: 'imgs/setA' },
  });
  check('folder_delete', r.statusCode === 200 && r.json().removed === 2, 'status=' + r.statusCode + ' ' + r.body.slice(0, 80));
  // Windows 上 watcher 可能还握着目录句柄，给它一点时间释放
  await new Promise((ok) => setTimeout(ok, 300));
  const imgsAfter = fs.readdirSync(imgs);
  const setAStill = imgsAfter.includes('setA');
  check(
    'folder_file_gone',
    hadFiles && !setAStill,
    `imgs=${imgsAfter.join(',')} exists=${fs.existsSync(setA)}`,
  );
  check(
    'folder_in_trash',
    fs.existsSync(path.join(filesRoot, '.colanas-trash', r.json().trashedTo, 'setA')),
    'not in trash',
  );
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/video/list?libraryId=${imageLib.id}&limit=20`,
    headers: bearer,
  });
  check('folder_index_gone', r.json().items.length === 0, 'n=' + r.json().items.length);

  console.log(`\n[summary] ${passed}/${passed + failed} passed`);
  await app.close();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    /* 句柄释放延迟 */
  }
  process.exit(failed === 0 ? 0 : 1);
})().catch((err) => {
  console.error('[FATAL]', err && err.stack ? err.stack : err);
  process.exit(1);
});
