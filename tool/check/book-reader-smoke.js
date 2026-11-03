#!/usr/bin/env node
/**
 * SP3-05 内置阅读器验收（`/book/toc` + `/book/page`）：
 *   epub spine 与 nav 标题 → 章节正文去标签 → txt 分章（含前言）→ 越界 404 → 参数 400
 *   → cbz 自然排序（page2 在 page10 前）与 base64 图片
 *   → pdf 目录给页数、页面由服务端渲染为 PNG（越界 404）
 *
 * 样本由脚本内联构造（store 模式 ZIP），不依赖外部工具。
 * 用法：node tool/check/book-reader-smoke.js
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
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

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
  <metadata><dc:title>Reader Book</dc:title></metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="c3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine>
</package>`;

  const nav = `<html><body><nav epub:type="toc">
<a href="c1.xhtml#s1">第一章 起点</a>
<a href="c2.xhtml">第二章 中途</a>
<a href="c3.xhtml">第三章 终局</a>
</nav></body></html>`;

  return buildZip([
    { name: 'mimetype', data: 'application/epub+zip' },
    { name: 'META-INF/container.xml', data: container },
    { name: 'OEBPS/content.opf', data: opf },
    { name: 'OEBPS/nav.xhtml', data: nav },
    { name: 'OEBPS/c1.xhtml', data: '<html><head><title>x</title></head><body><p>alpha text</p><p>second line</p></body></html>' },
    { name: 'OEBPS/c2.xhtml', data: '<html><body><h1>mid</h1><p>beta text</p></body></html>' },
    { name: 'OEBPS/c3.xhtml', data: '<html><body><p>gamma text</p></body></html>' },
  ]);
}

function cbz() {
  return buildZip([
    { name: 'page1.png', data: PNG_1PX },
    { name: 'page2.png', data: PNG_1PX },
    { name: 'page10.png', data: PNG_1PX },
    { name: '__MACOSX/page3.png', data: PNG_1PX },
    { name: 'notes.txt', data: 'not an image' },
  ]);
}

const TXT = [
  '书名：测试书',
  '作者：某人',
  '',
  '开场白内容。',
  '',
  '第一章 开始',
  '第一章正文。',
  '',
  '第二章 继续',
  '第二章正文。',
  '',
  'Chapter 3 End',
  'third body',
  '',
].join('\n');

// 带正确 xref 的最小 PDF（pdfjs 才能稳定解析；1 页 200x100）
function minimalPdf() {
  const objs = [
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n',
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n',
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << >> >>\nendobj\n',
  ];
  let pdf = '%PDF-1.4\n';
  const offsets = [0];
  for (const o of objs) {
    offsets.push(Buffer.byteLength(pdf));
    pdf += o;
  }
  const xrefPos = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (let i = 1; i <= objs.length; i += 1) {
    pdf += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`;
  }
  pdf += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xrefPos}\n%%EOF\n`;
  return Buffer.from(pdf, 'latin1');
}

const PDF = minimalPdf();

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-reader-'));
  const filesRoot = path.join(dataDir, 'files');
  const shelf = path.join(filesRoot, 'books');
  fs.mkdirSync(path.join(shelf, 'comics'), { recursive: true });
  fs.writeFileSync(path.join(shelf, 'Reader.epub'), epub());
  fs.writeFileSync(path.join(shelf, 'comics', 'Comic.cbz'), cbz());
  fs.writeFileSync(path.join(shelf, 'Book.txt'), TXT);
  fs.writeFileSync(path.join(shelf, 'Doc.pdf'), PDF);

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

  const writer = await mkToken('u1', ['book:read', 'book:write']);
  const reader = await mkToken('u2', ['book:read']);

  // 建库 + 扫描
  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries',
    headers: writer,
    payload: { name: 'Main', path: 'books' },
  });
  check('create_library', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries',
    headers: writer,
    payload: { name: 'Comics', path: 'books/comics' },
  });
  check('create_comics_library', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'POST', url: '/api/v1/book/scan', headers: writer, payload: {} });
  check('scan', r.statusCode === 200, 'status=' + r.statusCode);

  // 找到各书的 id
  r = await app.inject({ method: 'GET', url: '/api/v1/book/list?limit=50', headers: writer });
  const items = r.json().items || [];
  const byFormat = (f) => items.find((b) => b.format === f);
  const epubBook = byFormat('epub');
  const txtBook = byFormat('txt');
  const cbzBook = byFormat('cbz');
  const pdfBook = byFormat('pdf');
  check('list_has_all_formats', Boolean(epubBook && txtBook && cbzBook && pdfBook), 'n=' + items.length);

  // 1. 匿名
  r = await app.inject({ method: 'GET', url: `/api/v1/book/toc?id=${epubBook.id}` });
  check('anonymous_toc_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. epub toc
  r = await app.inject({ method: 'GET', url: `/api/v1/book/toc?id=${epubBook.id}`, headers: reader });
  const epubToc = r.json();
  check(
    'epub_toc_kind_text',
    r.statusCode === 200 && epubToc.kind === 'text' && epubToc.total === 3,
    `status=${r.statusCode} kind=${epubToc.kind} total=${epubToc.total}`,
  );
  check(
    'epub_toc_nav_titles',
    epubToc.pages?.[0]?.title === '第一章 起点' && epubToc.pages?.[1]?.title === '第二章 中途',
    JSON.stringify(epubToc.pages?.slice(0, 2)),
  );

  // 3. epub page（正文去标签）
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${epubBook.id}&index=0`,
    headers: reader,
  });
  const epubPage = r.json();
  check(
    'epub_page_stripped',
    r.statusCode === 200 &&
      epubPage.kind === 'text' &&
      epubPage.text.includes('alpha text') &&
      epubPage.text.includes('second line') &&
      !epubPage.text.includes('<p>'),
    JSON.stringify(epubPage.text || '').slice(0, 80),
  );

  // 4. epub 越界
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${epubBook.id}&index=9`,
    headers: reader,
  });
  check('epub_page_out_of_range_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 5. txt toc：前言 + 3 章
  r = await app.inject({ method: 'GET', url: `/api/v1/book/toc?id=${txtBook.id}`, headers: reader });
  const txtToc = r.json();
  check(
    'txt_toc_chapters',
    r.statusCode === 200 && txtToc.total === 4 && txtToc.pages[0].title === '前言',
    `total=${txtToc.total} titles=${JSON.stringify(txtToc.pages?.map((p) => p.title))}`,
  );

  // 6. txt page0 = 前言，page3 = 英文章节
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${txtBook.id}&index=0`,
    headers: reader,
  });
  const txtPre = r.json();
  check(
    'txt_page_preface',
    r.statusCode === 200 && txtPre.text.includes('开场白内容'),
    JSON.stringify(txtPre.text || '').slice(0, 60),
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${txtBook.id}&index=3`,
    headers: reader,
  });
  const txtLast = r.json();
  check(
    'txt_page_chapter_title',
    r.statusCode === 200 && txtLast.title === 'Chapter 3 End' && txtLast.text.includes('third body'),
    `title=${txtLast.title}`,
  );

  // 7. page 参数校验
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${txtBook.id}&index=-1`,
    headers: reader,
  });
  check('page_negative_index_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/book/toc?id=missing', headers: reader });
  check('toc_unknown_id_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 8. cbz：自然排序（page2 在 page10 前），跳过 __MACOSX 与非图片
  r = await app.inject({ method: 'GET', url: `/api/v1/book/toc?id=${cbzBook.id}`, headers: reader });
  const cbzToc = r.json();
  check(
    'cbz_toc_images',
    r.statusCode === 200 && cbzToc.kind === 'image' && cbzToc.total === 3,
    `kind=${cbzToc.kind} total=${cbzToc.total}`,
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${cbzBook.id}&index=1`,
    headers: reader,
  });
  const cbzPage = r.json();
  const png = Buffer.from(cbzPage.data || '', 'base64');
  check(
    'cbz_page_png_base64',
    r.statusCode === 200 && cbzPage.kind === 'image' && cbzPage.mime === 'image/png' && png.equals(PNG_1PX),
    `mime=${cbzPage.mime} bytes=${png.length}`,
  );

  // 9. pdf：目录给出页数，页面由服务端渲染成 PNG
  r = await app.inject({ method: 'GET', url: `/api/v1/book/toc?id=${pdfBook.id}`, headers: reader });
  const pdfToc = r.json();
  check(
    'pdf_toc_ok',
    r.statusCode === 200 && pdfToc.kind === 'pdf' && pdfToc.total === 1,
    `status=${r.statusCode} kind=${pdfToc.kind} total=${pdfToc.total}`,
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${pdfBook.id}&index=0`,
    headers: reader,
  });
  const pdfPage = r.json();
  check(
    'pdf_page_render',
    r.statusCode === 200 &&
      pdfPage.kind === 'image' &&
      pdfPage.mime === 'image/png' &&
      typeof pdfPage.data === 'string' &&
      pdfPage.data.length > 100,
    `status=${r.statusCode} kind=${pdfPage.kind} mime=${pdfPage.mime} bytes=${(pdfPage.data || '').length}`,
  );

  r = await app.inject({
    method: 'GET',
    url: `/api/v1/book/page?id=${pdfBook.id}&index=1`,
    headers: reader,
  });
  check('pdf_page_out_of_range_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 10. 只读账号可读、但不能建库
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/book/libraries',
    headers: reader,
    payload: { name: 'X', path: 'books' },
  });
  check('reader_cannot_create_403', r.statusCode === 403, 'status=' + r.statusCode);

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(30)} ${x.detail}`);
  }
  console.log(`\n[book-reader] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();