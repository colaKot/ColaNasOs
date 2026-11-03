#!/usr/bin/env node
/**
 * files 写操作验收（新建 / 改名 / 移动 / 删除到回收站 / 还原 / 真删）：
 *   建目录 → 改名 → 移动 → 删进回收站 → 回收站可见 → 还原 → 真删
 *   安全：越界 403 / 删根 400 / 改名带分隔符 400 / 移动进自己子目录 400 / 只读 403
 *
 * 依赖 Electron 运行时（better-sqlite3 ABI），脚本自动自举。
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
    console.error('[FATAL] cannot find electron');
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

process.env.COLANAS_LOG_FILE = '0';
process.chdir(root);

let passed = 0;
let failed = 0;
const ok = (n, d) => {
  passed += 1;
  console.log('[OK]  ', n.padEnd(28), d === undefined ? '' : d);
};
const bad = (n, d) => {
  failed += 1;
  console.log('[FAIL]', n.padEnd(28), d);
};
const check = (n, c, d) => (c ? ok(n, d) : bad(n, d));

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-fops-'));
  const filesRoot = path.join(dataDir, 'files');
  fs.mkdirSync(path.join(filesRoot, 'docs'), { recursive: true });
  fs.writeFileSync(path.join(filesRoot, 'docs', 'a.txt'), 'aaa');
  fs.writeFileSync(path.join(filesRoot, 'docs', 'b.txt'), 'bbb');
  fs.mkdirSync(path.join(filesRoot, 'keep'), { recursive: true });

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const { app } = k;

  const bearer = {
    authorization:
      'Bearer ' +
      (await app.inject({ method: 'POST', url: '/api/v1/auth/dev-token', payload: { sub: 'ops', scopes: ['*'] } }))
        .json().token,
  };
  const reader = {
    authorization:
      'Bearer ' +
      (await app.inject({
        method: 'POST',
        url: '/api/v1/auth/dev-token',
        payload: { sub: 'ops-r', scopes: ['files:read'] },
      })).json().token,
  };
  const post = (url, payload, headers = bearer) =>
    app.inject({ method: 'POST', url, headers, payload });
  const abs = (...p) => path.join(filesRoot, ...p);
  const has = (...p) => fs.existsSync(abs(...p));

  // 1. 新建目录
  let r = await post('/api/v1/files/mkdir', { path: 'docs/sub/deep' });
  check('mkdir_ok', r.statusCode === 200 && has('docs', 'sub', 'deep'), 'status=' + r.statusCode + ' ' + r.body.slice(0, 120));

  r = await post('/api/v1/files/mkdir', { path: 'docs/sub/deep' });
  check('mkdir_conflict_409', r.statusCode === 409, 'status=' + r.statusCode);

  // 2. 改名
  r = await post('/api/v1/files/rename', { path: 'docs/a.txt', name: 'a-renamed.txt' });
  check(
    'rename_ok',
    r.statusCode === 200 && has('docs', 'a-renamed.txt') && !has('docs', 'a.txt'),
    'status=' + r.statusCode,
  );

  r = await post('/api/v1/files/rename', { path: 'docs/b.txt', name: '../escape.txt' });
  check('rename_rejects_separator', r.statusCode === 400, 'status=' + r.statusCode);

  r = await post('/api/v1/files/rename', { path: 'docs/b.txt', name: 'b-renamed.txt' });
  check('rename_second_ok', r.statusCode === 200 && has('docs', 'b-renamed.txt'), 'status=' + r.statusCode);

  // 3. 移动
  r = await post('/api/v1/files/move', { paths: ['docs/a-renamed.txt'], to: 'keep' });
  check(
    'move_ok',
    r.statusCode === 200 && has('keep', 'a-renamed.txt') && !has('docs', 'a-renamed.txt'),
    'status=' + r.statusCode + ' ' + r.body.slice(0, 120),
  );

  // 目录不能移进自己的子目录
  r = await post('/api/v1/files/move', { paths: ['docs'], to: 'docs/sub' });
  const mv = r.json();
  check(
    'move_into_self_rejected',
    r.statusCode === 200 && (mv.failed || []).length === 1 && (mv.done || []).length === 0,
    r.body.slice(0, 160),
  );

  // 复制
  r = await post('/api/v1/files/move', { paths: ['keep/a-renamed.txt'], to: 'docs', copy: true });
  check(
    'copy_ok',
    r.statusCode === 200 && has('docs', 'a-renamed.txt') && has('keep', 'a-renamed.txt'),
    'status=' + r.statusCode,
  );

  // 4. 删除进回收站
  r = await post('/api/v1/files/delete', { paths: ['docs/b-renamed.txt'] });
  const del = r.json();
  check(
    'delete_to_trash',
    r.statusCode === 200 && del.done && del.done.length === 1 && !has('docs', 'b-renamed.txt'),
    r.body.slice(0, 160),
  );
  check('trash_has_batch', Boolean(del.trashedTo), 'trashedTo=' + del.trashedTo);

  // 5. 回收站可见
  r = await app.inject({ method: 'GET', url: '/api/v1/files/trash', headers: bearer });
  const tl = r.json();
  const batch = (tl.batches || []).find((b) => b.batch === del.trashedTo);
  const item = batch && (batch.items || []).find((i) => i.name === 'docs/b-renamed.txt');
  check(
    'trash_list_contains',
    r.statusCode === 200 && Boolean(item),
    'batches=' + (tl.batches || []).length,
  );

  // 6. 还原
  r = await post('/api/v1/files/trash/restore', {
    batch: del.trashedTo,
    paths: ['docs/b-renamed.txt'],
  });
  check(
    'trash_restore_ok',
    r.statusCode === 200 && has('docs', 'b-renamed.txt'),
    r.body.slice(0, 160),
  );

  // 7. 真删
  r = await post('/api/v1/files/delete', { paths: ['docs/b-renamed.txt'], permanent: true });
  check(
    'permanent_delete_ok',
    r.statusCode === 200 && !has('docs', 'b-renamed.txt'),
    'status=' + r.statusCode,
  );

  // 8. 安全护栏
  r = await post('/api/v1/files/delete', { paths: ['..'] });
  const escape = r.json();
  check(
    'delete_escape_blocked',
    (escape.failed || []).length === 1,
    JSON.stringify(escape).slice(0, 160),
  );

  r = await post('/api/v1/files/delete', { paths: ['.'] });
  const rootDel = r.json();
  check('delete_root_refused', (rootDel.failed || []).length === 1, JSON.stringify(rootDel).slice(0, 160));

  r = await post('/api/v1/files/mkdir', { path: '../outside' });
  check('mkdir_escape_blocked', r.statusCode === 403 || r.statusCode === 400, 'status=' + r.statusCode);

  // 9. 权限：只读 token 不能写
  r = await post('/api/v1/files/mkdir', { path: 'nope' }, reader);
  check('readonly_forbidden', r.statusCode === 403, 'status=' + r.statusCode);

  // 10. 清空回收站
  await post('/api/v1/files/delete', { paths: ['docs/a-renamed.txt'] });
  r = await post('/api/v1/files/trash/empty', {});
  check('trash_empty_ok', r.statusCode === 200, 'status=' + r.statusCode);
  check('trash_empty_removed', !fs.existsSync(abs('.colanas-trash')) || !fs.readdirSync(abs('.colanas-trash')).length, 'trash dir not empty');

  // 11. 文件操作日志（U-F 余）：写入口 → 查询 → 过滤 → 分页
  const getLogs = (qs) =>
    app.inject({ method: 'GET', url: '/api/v1/files/op-logs?' + qs, headers: bearer });

  r = await getLogs('uid=ops&limit=200');
  const logs = r.json();
  const items = logs.items || [];
  check(
    'oplog_list_ok',
    r.statusCode === 200 && items.length > 0 && items.every((i) => i.uid === 'ops'),
    'status=' + r.statusCode + ' items=' + items.length,
  );
  check(
    'oplog_total_matches',
    Number(logs.total) >= items.length && Number(logs.total) > 0,
    'total=' + logs.total + ' items=' + items.length,
  );
  const actions = new Set(items.map((i) => i.action));
  check(
    'oplog_actions_cover',
    ['mkdir', 'rename', 'move', 'copy', 'trash', 'delete', 'restore', 'empty'].every((a) =>
      actions.has(a),
    ),
    [...actions].join(','),
  );
  check(
    'oplog_failed_recorded',
    items.some((i) => i.status === 'failed' && String(i.detail || '').length > 0),
    'failed=' + items.filter((i) => i.status === 'failed').length,
  );

  r = await getLogs('uid=ops&action=rename&status=ok&limit=200');
  const renamed = r.json().items || [];
  check(
    'oplog_filter_action',
    r.statusCode === 200 &&
      renamed.length > 0 &&
      renamed.every((i) => i.action === 'rename' && i.status === 'ok'),
    'items=' + renamed.length,
  );

  r = await getLogs('uid=ops&q=' + encodeURIComponent('a-renamed') + '&limit=200');
  const hits = r.json().items || [];
  check(
    'oplog_keyword',
    r.statusCode === 200 && hits.length > 0 && hits.every((i) => String(i.path).includes('a-renamed')),
    'items=' + hits.length,
  );

  const page1 = (await getLogs('uid=ops&limit=2&offset=0')).json();
  const page2 = (await getLogs('uid=ops&limit=2&offset=1')).json();
  check(
    'oplog_paging',
    (page1.items || []).length === 2 &&
      (page2.items || []).length === 2 &&
      page1.items[0].id !== page2.items[0].id &&
      page1.total === page2.total,
    'limit=' + page1.limit + ' offset=' + page2.offset,
  );

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
