#!/usr/bin/env node
/**
 * 打包产物里的 PDF 阅读探针（SP3-05 二期）。
 *
 *   npm run pack
 *   npm run smoke:packaged-pdf
 *
 * 用打包后的内核（asar.unpacked 里的 @napi-rs/canvas + pdfjs）跑一遍
 * 「建库 → 扫描 → toc(kind=pdf) → page(PNG)」，验证原生渲染模块真的随包可用。
 * 构建与 verify 覆盖不到这一类问题（只有真跑产物才暴露）。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const unpacked = path.join(root, 'dist_installer', 'win-unpacked');
const exe = path.join(unpacked, 'ColaNasOs.exe');
const asar = path.join(unpacked, 'resources', 'app.asar');
if (!fs.existsSync(exe) || !fs.existsSync(asar)) {
  console.error('[smoke:packaged-pdf] 缺少打包产物，先执行 npm run pack');
  process.exit(1);
}

const port = Number(process.env.PORT || 7802);
const base = `http://127.0.0.1:${port}`;
const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-pack-pdf-'));
const dataDir = path.join(workDir, 'data');
const filesRoot = path.join(workDir, 'files');
const logFile = path.join(workDir, 'kernel.log');

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

fs.mkdirSync(path.join(filesRoot, 'books'), { recursive: true });
fs.mkdirSync(dataDir, { recursive: true });
fs.writeFileSync(path.join(filesRoot, 'books', 'Doc.pdf'), minimalPdf());

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const env = {
  ...process.env,
  ELECTRON_RUN_AS_NODE: '1',
  PORT: String(port),
  COLANAS_DATA_DIR: dataDir,
  COLANAS_FILES_ROOT: filesRoot,
  COLANAS_DEV_TOKEN: '1',
  COLANAS_LOG_FILE: '0',
  COLANAS_WEB_DIR: path.join(unpacked, 'resources', 'web'),
  COLANAS_CONTRACTS_DIR: path.join(unpacked, 'resources', 'contracts'),
};
delete env.ELECTRON_USER_DATA_DIR;

const log = fs.openSync(logFile, 'w');
const child = spawn(exe, [path.join('resources', 'app.asar', 'dist', 'electron', 'kernel-host.js')], {
  cwd: unpacked,
  stdio: ['ignore', log, log],
  env,
});

function killTree() {
  spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
}

async function waitHealth(timeoutMs = 45000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/health`, { signal: globalThis.AbortSignal.timeout(2000) });
      if (res.ok) return true;
    } catch {
      /* 还没起来 */
    }
    await sleep(500);
  }
  return false;
}

async function api(method, url, token, body) {
  return fetch(`${base}${url}`, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
}

(async () => {
  const healthy = await waitHealth();
  check('kernel_health', healthy, healthy ? '200' : '未就绪');
  if (!healthy) return finish();

  const tokenRes = await api('POST', '/api/v1/auth/dev-token', null, {
    sub: 'pack-pdf',
    scopes: ['book:read', 'book:write'],
  });
  const token = tokenRes.ok ? (await tokenRes.json()).token : null;
  check('dev_token', Boolean(token), token ? 'ok' : `status=${tokenRes.status}`);
  if (!token) return finish();

  let r = await api('POST', '/api/v1/book/libraries', token, { name: 'Pack', path: 'books' });
  check('create_library', r.ok, `status=${r.status}`);
  r = await api('POST', '/api/v1/book/scan', token, {});
  check('scan', r.ok, `status=${r.status}`);

  r = await api('GET', '/api/v1/book/list?limit=10', token);
  const items = r.ok ? (await r.json()).items || [] : [];
  const pdfBook = items.find((i) => String(i.format) === 'pdf');
  check('book_indexed', Boolean(pdfBook), `n=${items.length}`);
  if (!pdfBook) return finish();

  r = await api('GET', `/api/v1/book/toc?id=${encodeURIComponent(pdfBook.id)}`, token);
  const toc = r.ok ? await r.json() : {};
  check(
    'pdf_toc',
    r.ok && toc.kind === 'pdf' && toc.total === 1,
    `status=${r.status} kind=${toc.kind} total=${toc.total}`,
  );

  r = await api(
    'GET',
    `/api/v1/book/page?id=${encodeURIComponent(pdfBook.id)}&index=0`,
    token,
  );
  const page = r.ok ? await r.json() : {};
  check(
    'pdf_render_png',
    r.ok && page.kind === 'image' && page.mime === 'image/png' && (page.data || '').length > 500,
    `status=${r.status} kind=${page.kind} bytes=${(page.data || '').length}`,
  );

  finish();
})();

function finish() {
  killTree();
  fs.closeSync(log);
  for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(18)} ${r.detail}`);
  const failed = results.filter((r) => !r.ok);
  if (failed.length && fs.existsSync(logFile)) {
    console.error(`[smoke:packaged-pdf] 内核日志：${logFile}`);
    console.error(fs.readFileSync(logFile, 'utf-8').split('\n').slice(-20).join('\n'));
  }
  fs.rmSync(workDir, { recursive: true, force: true });
  console.log(`\n[smoke:packaged-pdf] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
}