#!/usr/bin/env node
/**
 * SP3-05 book 验收：
 *   建库 → 扫描（epub 元数据 / cbz 页数与封面 / pdf 页数 / 增量跳过）
 *   → 书架排序与 cursor → 搜索与格式过滤 → 详情 → 封面（epub/cbz 200，pdf 404）
 *   → 阅读 Range（206）→ 直链令牌 → 收藏与进度（跨用户隔离）→ 删库级联
 *
 * epub/cbz 由脚本内联构造（store 模式 ZIP），不依赖外部工具。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/book-smoke.js
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

const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

// ---------------------------------------------------------------- 最小 ZIP 构造（store）

let crcTable = null;
function crc32(buf) {
  if (!crcTable) {
    crcTable = [];
    for (let n = 0; n < 256; n += 1) {
      let c = n;
      for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (const b of buf) crc = crcTable[(crc ^ b) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function buildZip(entries) {
  const locals = [];
  const central = [];
  let offset = 0;

  for (const e of entries) {
    const name = Buffer.from(e.name, 'utf8');
    const data = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data, 'utf8');
    const crc = crc32(data);

    const local = Buffer.alloc(30 + name.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    name.copy(local, 30);
    locals.push(local, data);

    const cd = Buffer.alloc(46 + name.length);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(20, 4);
    cd.writeUInt16LE(20, 6);
    cd.writeUInt16LE(0x800, 8);
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(data.length, 20);
    cd.writeUInt32LE(data.length, 24);
    cd.writeUInt16LE(name.length, 28);
    cd.writeUInt32LE(offset, 42);
    name.copy(cd, 46);
    central.push(cd);

    offset += local.length + data.length;
  }

  const cdBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cdBuf, eocd]);
}

function epub() {
  const container = `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`;

  const opf = `<?xml version="1.0"?>
<package xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
  <metadata>
    <dc:title>Alpha Book</dc:title>
    <dc:creator>Author A</dc:creator>
    <dc:language>zh</dc:language>
    <dc:publisher>Pub X</dc:publisher>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="cover-img" href="cover.png" media-type="image/png" properties="cover-image"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>`;

  return buildZip([
    { name: 'mimetype', data: 'application/epub+zip' },
    { name: 'META-INF/container.xml', data: container },
    { name: 'OEBPS/content.opf', data: opf },
    { name: 'OEBPS/cover.png', data: PNG_1PX },
    { name: 'OEBPS/c1.xhtml', data: '<html><body><p>hello</p></body></html>' },
  ]);
}

function cbz() {
  return buildZip([
    { name: '1.png', data: PNG_1PX },
    { name: '2.png', data: PNG_1PX },
    {
      name: 'ComicInfo.xml',
      data: '<ComicInfo><Title>Comic Beta</Title><Writer>Author B</Writer></ComicInfo>',
    },
  ]);
}

function pdf() {
  return Buffer.from(
    [
      '%PDF-1.4',
      '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj',
      '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj',
      '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj',
      'trailer << /Root 1 0 R /Size 4 >>',
      '%%EOF',
    ].join('\n'),
    'latin1',
  );
}

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-book-'));
  const filesRoot = path.join(dataDir, 'files');
  const shelf = path.join(filesRoot, 'books');
  fs.mkdirSync(path.join(shelf, 'comics'), { recursive: true });
  fs.writeFileSync(path.join(shelf, 'Alpha.epub'), epub());
  fs.writeFileSync(path.join(shelf, 'comics', 'Beta.cbz'), cbz());
  fs.writeFileSync(path.join(shelf, 'Doc.pdf'), pdf());
  fs.writeFileSync(path.join(shelf, 'Notes.txt'), 'plain text book content');
  fs.writeFileSync(path.join(shelf, 'skip.md'), 'not a book');

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
    payload: { sub: 'u1', scopes: ['book:read', 'book:write', 'files:read'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['book:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };

  const otherRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u3', scopes: ['book:read', 'book:write'] },
  });
  const other = { authorization: 'Bearer ' + otherRes.json().token };

  // 1. 匿名
  let r = await app.inject({ method: 'GET', url: '/api/v1/book/list' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 越界
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries',
    headers: bearer,
    payload: { name: 'bad', path: '../..' },
  });
  check('library_escape_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 3. 建库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries',
    headers: bearer,
    payload: { name: 'Shelf', path: '/books' },
  });
  const lib = r.json();
  check('library_create_ok', r.statusCode === 200 && lib.id && lib.path === 'books', JSON.stringify(lib).slice(0, 80));

  // 4. 重复
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries',
    headers: bearer,
    payload: { name: 'Dup', path: 'books' },
  });
  check('library_duplicate_409', r.statusCode === 409, 'status=' + r.statusCode);

  // 5. 只读不能扫描
  r = await app.inject({ method: 'POST', url: '/api/v1/book/scan', headers: reader, payload: {} });
  check('scan_requires_write', r.statusCode === 403, 'status=' + r.statusCode);

  // 6. 扫描（md 不计入）
  r = await app.inject({ method: 'POST', url: '/api/v1/book/scan', headers: bearer, payload: {} });
  const scan = r.json();
  check('scan_books', r.statusCode === 200 && scan.books === 4 && scan.added === 4, JSON.stringify(scan));

  // 7. 增量
  r = await app.inject({ method: 'POST', url: '/api/v1/book/scan', headers: bearer, payload: {} });
  const again = r.json();
  check('scan_incremental', again.added === 0 && again.skipped === 4, JSON.stringify(again));

  // 8. 书架排序
  r = await app.inject({ method: 'GET', url: '/api/v1/book/list?limit=10', headers: bearer });
  const list = r.json();
  check(
    'list_sorted',
    r.statusCode === 200 && (list.items || []).length === 4 && list.items[0].title === 'Alpha Book',
    (list.items || []).map((x) => x.title).join(','),
  );

  const alpha = (list.items || []).find((x) => x.format === 'epub');
  const beta = (list.items || []).find((x) => x.format === 'cbz');
  const doc = (list.items || []).find((x) => x.format === 'pdf');

  // 9. epub 元数据
  check(
    'epub_metadata',
    !!alpha &&
      alpha.author === 'Author A' &&
      alpha.language === 'zh' &&
      alpha.publisher === 'Pub X' &&
      alpha.hasCover === true,
    alpha ? `${alpha.author}/${alpha.language}/${alpha.publisher}` : 'missing',
  );

  // 10. cbz 页数与作者
  check(
    'cbz_metadata',
    !!beta && beta.pageCount === 2 && beta.author === 'Author B' && beta.hasCover === true,
    beta ? `${beta.pageCount}/${beta.author}` : 'missing',
  );

  // 11. pdf 页数
  check('pdf_pages', !!doc && doc.pageCount === 1, doc ? String(doc.pageCount) : 'missing');

  // 12. cursor
  const p1 = (await app.inject({ method: 'GET', url: '/api/v1/book/list?limit=1', headers: bearer })).json();
  const p2 = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/book/list?limit=1&cursor=' + encodeURIComponent(p1.nextCursor || ''),
      headers: bearer,
    })
  ).json();
  check(
    'cursor_pagination',
    p1.items.length === 1 && !!p1.nextCursor && p2.items.length === 1 && p2.items[0].id !== p1.items[0].id,
    `${p1.items.length}/${p2.items.length}`,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/book/list?cursor=bad', headers: bearer });
  check('bad_cursor_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 13. 搜索与格式过滤
  r = await app.inject({ method: 'GET', url: '/api/v1/book/list?q=alpha', headers: bearer });
  const byKeyword = r.json();
  check('search_keyword', r.statusCode === 200 && byKeyword.items.length === 1, 'items=' + (byKeyword.items || []).length);

  r = await app.inject({ method: 'GET', url: '/api/v1/book/list?format=pdf', headers: bearer });
  const byFormat = r.json();
  check('filter_format', r.statusCode === 200 && byFormat.items.length === 1 && byFormat.items[0].format === 'pdf', 'items=' + (byFormat.items || []).length);

  // 14. 详情
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/book/item?id=' + encodeURIComponent(alpha.id),
    headers: bearer,
  });
  check('item_detail', r.statusCode === 200 && r.json().path === 'books/Alpha.epub', 'status=' + r.statusCode);

  // 15. 封面
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/book/cover?id=' + encodeURIComponent(alpha.id),
    headers: reader,
  });
  check(
    'epub_cover_png',
    r.statusCode === 200 && String(r.headers['content-type']).startsWith('image/png') && r.rawPayload.length > 50,
    `status=${r.statusCode} type=${r.headers['content-type']} bytes=${r.rawPayload.length}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/book/cover?id=' + encodeURIComponent(beta.id),
    headers: reader,
  });
  check('cbz_cover_ok', r.statusCode === 200 && String(r.headers['content-type']).startsWith('image/'), 'status=' + r.statusCode);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/book/cover?id=' + encodeURIComponent(doc.id),
    headers: reader,
  });
  check('pdf_cover_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 16. 阅读（Range）
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/book/file?id=' + encodeURIComponent(alpha.id),
    headers: Object.assign({ range: 'bytes=0-9' }, reader),
  });
  check('file_range_206', r.statusCode === 206 && r.rawPayload.length === 10, 'status=' + r.statusCode);

  // 17. 直链令牌
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/book/file-url?id=' + encodeURIComponent(alpha.id),
    headers: reader,
  });
  const fileUrl = r.json();
  const direct = fileUrl.url
    ? await app.inject({ method: 'GET', url: fileUrl.url, headers: { range: 'bytes=0-4' } })
    : { statusCode: 0 };
  check('file_url_playable', r.statusCode === 200 && direct.statusCode === 206, `url=${r.statusCode} read=${direct.statusCode}`);

  const noAuth = await app.inject({
    method: 'GET',
    url: '/api/v1/book/file?id=' + encodeURIComponent(alpha.id),
  });
  check('file_requires_auth', noAuth.statusCode === 401, 'status=' + noAuth.statusCode);

  // 18. 收藏
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/favorites/add',
    headers: bearer,
    payload: { id: alpha.id },
  });
  const favList = (await app.inject({ method: 'GET', url: '/api/v1/book/list?favorite=1', headers: bearer })).json();
  const otherFav = (await app.inject({ method: 'GET', url: '/api/v1/book/list?favorite=1', headers: other })).json();
  check(
    'favorite_add_isolated',
    r.statusCode === 200 && (favList.items || []).length === 1 && (otherFav.items || []).length === 0,
    `fav=${(favList.items || []).length} other=${(otherFav.items || []).length}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/favorites/remove',
    headers: bearer,
    payload: { id: alpha.id },
  });
  const favAfter = (await app.inject({ method: 'GET', url: '/api/v1/book/list?favorite=1', headers: bearer })).json();
  check('favorite_remove', r.statusCode === 200 && (favAfter.items || []).length === 0, 'fav=' + (favAfter.items || []).length);

  // 19. 进度
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/progress/save',
    headers: bearer,
    payload: { id: alpha.id, position: 'chapter-3', percent: 42 },
  });
  const mine = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/book/progress?id=' + encodeURIComponent(alpha.id),
      headers: bearer,
    })
  ).json();
  const others = (
    await app.inject({
      method: 'GET',
      url: '/api/v1/book/progress?id=' + encodeURIComponent(alpha.id),
      headers: other,
    })
  ).json();
  check(
    'progress_isolated',
    r.statusCode === 200 && mine.percent === 42 && mine.position === 'chapter-3' && others.percent === 0,
    `mine=${mine.percent} other=${others.percent}`,
  );

  // 20. 统计
  r = await app.inject({ method: 'GET', url: '/api/v1/book/stats', headers: bearer });
  const stats = r.json();
  check('stats', r.statusCode === 200 && stats.books === 4 && stats.libraries === 1, JSON.stringify(stats));

  // 21. 删库级联（收藏与进度一起清掉）
  await app.inject({
    method: 'POST',
    url: '/api/v1/book/favorites/add',
    headers: bearer,
    payload: { id: beta.id },
  });
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries/remove',
    headers: bearer,
    payload: { id: lib.id },
  });
  const after = (await app.inject({ method: 'GET', url: '/api/v1/book/stats', headers: bearer })).json();
  check(
    'library_remove_cascade',
    r.statusCode === 200 && after.books === 0 && after.libraries === 0 && after.favorites === 0,
    JSON.stringify(after),
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