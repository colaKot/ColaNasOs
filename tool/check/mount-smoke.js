#!/usr/bin/env node
/**
 * SP3-07 fileMount 验收（内建最小 WebDAV 服务端，不依赖外部服务）：
 *   挂载 CRUD（密码加密落库、列表脱敏）→ 连接测试 → 浏览 → 下载（含 Range）
 *   → 上传 → 新建目录 → 删除 → 只读挂载拒绝写 → 错误密码 401
 *   → rclone 后端（本机未安装时明确 501）→ 删挂载
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/mount-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const http = require('node:http');
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

// ---------------------------------------------------------------- 最小 WebDAV 服务端

const DAV_USER = 'dav';
const DAV_PASS = 's3cret';

function hrefFor(rel, isDir) {
  const enc = rel.split('/').filter(Boolean).map(encodeURIComponent).join('/');
  if (!enc) return '/';
  return `/${enc}${isDir ? '/' : ''}`;
}

function responseXml(rel, isDir, st) {
  const type = isDir
    ? '<d:resourcetype><d:collection/></d:resourcetype>'
    : `<d:resourcetype/><d:getcontentlength>${st.size}</d:getcontentlength>`;
  return (
    '<d:response><d:href>' +
    hrefFor(rel, isDir) +
    '</d:href><d:propstat><d:prop>' +
    type +
    `<d:getlastmodified>${new Date(st.mtimeMs).toUTCString()}</d:getlastmodified>` +
    '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
  );
}

function authed(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  const [u, p] = Buffer.from(header.slice(6), 'base64').toString('utf8').split(':');
  return u === DAV_USER && p === DAV_PASS;
}

function startDav(davRoot) {
  const server = http.createServer((req, res) => {
    if (!authed(req)) {
      res.statusCode = 401;
      res.setHeader('www-authenticate', 'Basic realm="colanas-test"');
      res.end('unauthorized');
      return;
    }

    const rel = decodeURIComponent(new URL(req.url || '/', 'http://localhost').pathname)
      .replace(/^\/+|\/+$/g, '');
    const abs = path.join(davRoot, rel);
    if (!abs.startsWith(davRoot)) {
      res.statusCode = 403;
      res.end('forbidden');
      return;
    }

    try {
      if (req.method === 'PROPFIND') {
        if (!fs.existsSync(abs)) {
          res.statusCode = 404;
          res.end('not found');
          return;
        }
        const st = fs.statSync(abs);
        const parts = [responseXml(rel, st.isDirectory(), st)];
        const depth = String(req.headers.depth || '1');
        if (st.isDirectory() && depth !== '0') {
          for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
            const childRel = rel ? `${rel}/${e.name}` : e.name;
            const childSt = fs.statSync(path.join(abs, e.name));
            parts.push(responseXml(childRel, e.isDirectory(), childSt));
          }
        }
        const body =
          '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">' +
          parts.join('') +
          '</d:multistatus>';
        res.statusCode = 207;
        res.setHeader('content-type', 'application/xml; charset=utf-8');
        res.end(body);
        return;
      }

      if (req.method === 'GET') {
        if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
          res.statusCode = 404;
          res.end('not found');
          return;
        }
        const size = fs.statSync(abs).size;
        const range = req.headers.range;
        const m = range ? /^bytes=(\d+)-(\d*)$/.exec(range) : null;
        if (m) {
          const start = Number(m[1]);
          const end = m[2] ? Number(m[2]) : size - 1;
          if (start >= size || end >= size || start > end) {
            res.statusCode = 416;
            res.setHeader('content-range', `bytes */${size}`);
            res.end();
            return;
          }
          res.statusCode = 206;
          res.setHeader('content-range', `bytes ${start}-${end}/${size}`);
          res.setHeader('content-length', String(end - start + 1));
          res.setHeader('accept-ranges', 'bytes');
          fs.createReadStream(abs, { start, end }).pipe(res);
          return;
        }
        res.statusCode = 200;
        res.setHeader('content-length', String(size));
        res.setHeader('accept-ranges', 'bytes');
        res.setHeader('etag', '"dav-test"');
        fs.createReadStream(abs).pipe(res);
        return;
      }

      if (req.method === 'PUT') {
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        const ws = fs.createWriteStream(abs);
        req.pipe(ws);
        ws.on('finish', () => {
          res.statusCode = 201;
          res.end();
        });
        return;
      }

      if (req.method === 'MKCOL') {
        fs.mkdirSync(abs, { recursive: true });
        res.statusCode = 201;
        res.end();
        return;
      }

      if (req.method === 'DELETE') {
        if (!fs.existsSync(abs)) {
          res.statusCode = 404;
          res.end();
          return;
        }
        fs.rmSync(abs, { recursive: false, force: true });
        res.statusCode = 204;
        res.end();
        return;
      }

      res.statusCode = 405;
      res.end('method not allowed');
    } catch (e) {
      res.statusCode = 500;
      res.end(String(e && e.message));
    }
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-mount-'));
  const davRoot = path.join(tmp, 'dav');
  fs.mkdirSync(path.join(davRoot, 'sub'), { recursive: true });
  fs.writeFileSync(path.join(davRoot, 'readme.txt'), 'hello-webdav');
  fs.writeFileSync(path.join(davRoot, 'sub', 'inner.txt'), 'inner');

  const dav = await startDav(davRoot);
  const dataDir = path.join(tmp, 'data');
  fs.mkdirSync(dataDir, { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['mount:read', 'mount:write'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  const readerRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u2', scopes: ['mount:read'] },
  });
  const reader = { authorization: 'Bearer ' + readerRes.json().token };

  // 1. 匿名
  let r = await app.inject({ method: 'GET', url: '/api/v1/mount/mounts' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  // 2. 非法 kind
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts',
    headers: bearer,
    payload: { name: 'bad', kind: 'ftp', baseUrl: 'ftp://x' },
  });
  check('create_bad_kind_400', r.statusCode === 400, 'status=' + r.statusCode);

  // 3. 建 WebDAV 挂载（密码落库加密）
  const baseUrl = `http://127.0.0.1:${dav.port}/`;
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts',
    headers: bearer,
    payload: { name: 'Test DAV', kind: 'webdav', baseUrl, username: DAV_USER, password: DAV_PASS },
  });
  const davMount = r.json();
  check('create_webdav_ok', r.statusCode === 200 && davMount.id && davMount.status === 'unknown', JSON.stringify(davMount).slice(0, 90));

  const secretRow = await k.db
    .selectFrom('remote_mounts')
    .select(['secret'])
    .where('id', '=', davMount.id)
    .executeTakeFirst();
  check(
    'secret_encrypted',
    !!secretRow && secretRow.secret.startsWith('v1:') && !secretRow.secret.includes(DAV_PASS),
    'cipher=' + String(secretRow && secretRow.secret).slice(0, 12),
  );

  // 4. 列表不含密码字段
  r = await app.inject({ method: 'GET', url: '/api/v1/mount/mounts', headers: bearer });
  const list = r.json();
  check(
    'list_no_secret',
    r.statusCode === 200 && list.items.length === 1 && !('password' in list.items[0]) && !('secret' in list.items[0]),
    'keys=' + Object.keys(list.items[0] || {}).join(','),
  );

  // 5. 连接测试
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts/test',
    headers: bearer,
    payload: { id: davMount.id },
  });
  check('test_ok', r.statusCode === 200 && r.json().status === 'ok', `status=${r.statusCode}`);

  // 6. 浏览根与子目录
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/mount/list?id=' + encodeURIComponent(davMount.id),
    headers: bearer,
  });
  const rootList = r.json();
  const names = (rootList.items || []).map((x) => x.name).join(',');
  check(
    'browse_root',
    r.statusCode === 200 && (rootList.items || []).length === 2 && names.includes('readme.txt') && names.includes('sub'),
    'items=' + names,
  );
  check(
    'browse_dirs_first',
    (rootList.items || [])[0]?.name === 'sub' && (rootList.items || [])[0]?.dir === true,
    'first=' + (rootList.items || [])[0]?.name,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/mount/list?id=' + encodeURIComponent(davMount.id) + '&path=sub',
    headers: bearer,
  });
  const subList = r.json();
  check(
    'browse_sub',
    r.statusCode === 200 && (subList.items || []).length === 1 && subList.items[0].path === 'sub/inner.txt',
    'path=' + (subList.items || [])[0]?.path,
  );

  // 7. 下载 + Range
  r = await app.inject({
    method: 'GET',
    url: '/api/v1/mount/download?id=' + encodeURIComponent(davMount.id) + '&path=readme.txt',
    headers: bearer,
  });
  check('download_body', r.statusCode === 200 && r.body === 'hello-webdav', 'body=' + r.body);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/mount/download?id=' + encodeURIComponent(davMount.id) + '&path=readme.txt',
    headers: Object.assign({ range: 'bytes=0-4' }, bearer),
  });
  check('download_range_206', r.statusCode === 206 && r.body === 'hello', `status=${r.statusCode} body=${r.body}`);

  // 7b. 直链令牌（外部下载器）
  r = await app.inject({
    method: 'GET',
    url: `/api/v1/mount/download-url?id=${encodeURIComponent(davMount.id)}&path=readme.txt`,
    headers: bearer,
  });
  const dlUrl = r.json();
  const direct = dlUrl.url ? await app.inject({ method: 'GET', url: dlUrl.url }) : { statusCode: 0, body: '' };
  check(
    'download_url_works',
    r.statusCode === 200 && direct.statusCode === 200 && direct.body === 'hello-webdav',
    `url=${r.statusCode} get=${direct.statusCode}`,
  );

  // 8. 上传（原始流）
  r = await app.inject({
    method: 'POST',
    url: `/api/v1/mount/upload?id=${encodeURIComponent(davMount.id)}&path=uploaded.txt&size=9`,
    headers: Object.assign({ 'content-type': 'application/x-colanas-upload' }, bearer),
    payload: Buffer.from('upload-ok'),
  });
  const uploaded = fs.existsSync(path.join(davRoot, 'uploaded.txt'))
    ? fs.readFileSync(path.join(davRoot, 'uploaded.txt'), 'utf8')
    : '';
  check('upload_ok', r.statusCode === 200 && uploaded === 'upload-ok', `status=${r.statusCode} content=${uploaded}`);

  // 9. 新建目录与删除
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mkdir',
    headers: bearer,
    payload: { id: davMount.id, path: 'newdir' },
  });
  check('mkdir_ok', r.statusCode === 200 && fs.existsSync(path.join(davRoot, 'newdir')), 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/delete',
    headers: bearer,
    payload: { id: davMount.id, path: 'uploaded.txt' },
  });
  check(
    'delete_ok',
    r.statusCode === 200 && !fs.existsSync(path.join(davRoot, 'uploaded.txt')),
    'status=' + r.statusCode,
  );

  // 10. 只读挂载拒绝写 + 只读令牌拒绝写
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts',
    headers: bearer,
    payload: { name: 'Read Only', kind: 'webdav', baseUrl, username: DAV_USER, password: DAV_PASS, readOnly: true },
  });
  const ro = r.json();
  const roWrite = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mkdir',
    headers: bearer,
    payload: { id: ro.id, path: 'nope' },
  });
  check('readonly_rejects_write', r.statusCode === 200 && roWrite.statusCode === 400, 'status=' + roWrite.statusCode);

  const readerWrite = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mkdir',
    headers: reader,
    payload: { id: davMount.id, path: 'nope2' },
  });
  check('scope_requires_write', readerWrite.statusCode === 403, 'status=' + readerWrite.statusCode);

  // 11. 错误密码 → 401
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts',
    headers: bearer,
    payload: { name: 'Wrong Pass', kind: 'webdav', baseUrl, username: DAV_USER, password: 'wrong' },
  });
  const wrong = r.json();
  const wrongTest = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts/test',
    headers: bearer,
    payload: { id: wrong.id },
  });
  check('wrong_password_401', wrongTest.statusCode === 401, 'status=' + wrongTest.statusCode);

  // 12. rclone 后端（本机未安装 → 明确 501）
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts',
    headers: bearer,
    payload: { name: 'SMB via rclone', kind: 'rclone', baseUrl: 'smb:share' },
  });
  const rc = r.json();
  const rcTest = await app.inject({
    method: 'POST',
    url: '/api/v1/mount/mounts/test',
    headers: bearer,
    payload: { id: rc.id },
  });
  check(
    'rclone_available_or_501',
    r.statusCode === 200 && (rcTest.statusCode === 200 || rcTest.statusCode === 501),
    `create=${r.statusCode} test=${rcTest.statusCode}`,
  );

  // 13. 删除挂载
  for (const id of [davMount.id, ro.id, wrong.id, rc.id]) {
    await app.inject({
      method: 'POST',
      url: '/api/v1/mount/mounts/remove',
      headers: bearer,
      payload: { id },
    });
  }
  r = await app.inject({ method: 'GET', url: '/api/v1/mount/mounts', headers: bearer });
  check('remove_all', r.statusCode === 200 && r.json().items.length === 0, 'items=' + r.json().items.length);

  await app.close();
  await new Promise((resolve) => dav.server.close(resolve));
  fs.rmSync(tmp, { recursive: true, force: true });

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