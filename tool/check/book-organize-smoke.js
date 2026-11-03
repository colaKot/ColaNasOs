#!/usr/bin/env node
/**
 * 合集 / 归档 / 自定义列表验收（book 二期）：
 *   合集设置与聚合列表（书数 / 封面书 = 序号最小的那本）→ 合集条目按序号排序 → 清除合集 →
 *   合集名搜索与 cursor 翻页 → 未知合集 404 / 非法 cursor 400 →
 *   归档（`/book/list?archived=` 三态 + 跨用户隔离）→
 *   自定义列表（建 / 重名 409 / 加入幂等 / 条目按加入顺序 / 移出 / 跨用户 404 / 删除级联）→
 *   只读写操作 403、匿名 401。
 *
 * 素材用最小 txt（扫描只看扩展名与体积，不需要 epub 解析）。
 * 用法：node tool/check/book-organize-smoke.js
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
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

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-bookorg-'));
  const filesRoot = path.join(dataDir, 'files');
  const shelf = path.join(filesRoot, 'books');
  fs.mkdirSync(shelf, { recursive: true });
  for (const name of ['Alpha.txt', 'Beta.txt', 'Gamma.txt']) {
    fs.writeFileSync(path.join(shelf, name), Buffer.from(`${name}\n第一行\n第二行\n`, 'utf8'));
  }

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

  const owner = await mkToken('u1', ['book:read', 'book:write']);
  const reader = await mkToken('u2', ['book:read']);
  const other = await mkToken('u3', ['book:read', 'book:write']);

  const call = (method, url, headers, payload) =>
    app.inject({ method, url, headers, ...(payload === undefined ? {} : { payload }) });

  let r = await call('POST', '/api/v1/book/libraries', owner, { name: 'Shelf', path: 'books' });
  check('create_library', r.statusCode === 200, 'status=' + r.statusCode);

  r = await call('POST', '/api/v1/book/scan', owner, {});
  check('scan', r.statusCode === 200, 'status=' + r.statusCode);

  r = await call('GET', '/api/v1/book/list?limit=50', owner);
  const books = r.json().items || [];
  const byName = (name) => books.find((b) => b.path.endsWith(name));
  const alpha = byName('Alpha.txt');
  const beta = byName('Beta.txt');
  const gamma = byName('Gamma.txt');
  check('indexed_books', Boolean(alpha && beta && gamma), 'n=' + books.length);

  // 1. 鉴权
  r = await call('GET', '/api/v1/book/collections');
  check('collections_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await call('POST', '/api/v1/book/collection', reader, { id: alpha.id, name: 'Trilogy' });
  check('collection_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await call('POST', '/api/v1/book/archive', reader, { id: alpha.id });
  check('archive_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  r = await call('POST', '/api/v1/book/lists', reader, { name: 'Mine' });
  check('list_create_reader_403', r.statusCode === 403, 'status=' + r.statusCode);

  // 2. 合集：Alpha 序号 2、Beta 序号 1 → 列表封面是 Beta
  r = await call('POST', '/api/v1/book/collection', owner, {
    id: alpha.id,
    name: 'Trilogy',
    index: 2,
  });
  check('collection_set_alpha', r.statusCode === 200 && r.json().ok === true, 'status=' + r.statusCode);
  r = await call('POST', '/api/v1/book/collection', owner, {
    id: beta.id,
    name: 'Trilogy',
    index: 1,
  });
  check('collection_set_beta', r.statusCode === 200, 'status=' + r.statusCode);

  r = await call('GET', '/api/v1/book/collections', owner);
  const cols = r.json().items || [];
  const trilogy = cols.find((c) => c.name === 'Trilogy');
  check(
    'collection_aggregate',
    Boolean(trilogy) && trilogy.books === 2 && trilogy.coverId === beta.id,
    `item=${JSON.stringify(trilogy)}`,
  );

  r = await call('GET', `/api/v1/book/collections/items?name=${encodeURIComponent('Trilogy')}`, owner);
  const items = r.json().items || [];
  check(
    'collection_items_ordered',
    items.length === 2 && items[0].id === beta.id && items[1].id === alpha.id,
    'order=' + JSON.stringify(items.map((x) => x.path)),
  );
  check(
    'collection_fields_on_book',
    items[0].collection === 'Trilogy' && items[0].collectionIndex === 1,
    `c=${items[0] && items[0].collection} i=${items[0] && items[0].collectionIndex}`,
  );

  // 3. 合集搜索与分页（再造一个合集）
  r = await call('POST', '/api/v1/book/collection', owner, {
    id: gamma.id,
    name: 'Singles',
  });
  check('collection_set_gamma', r.statusCode === 200, 'status=' + r.statusCode);

  r = await call('GET', '/api/v1/book/collections?limit=1', owner);
  const page1 = r.json();
  check(
    'collections_cursor_page1',
    (page1.items || []).length === 1 && typeof page1.nextCursor === 'string',
    `n=${(page1.items || []).length}`,
  );
  r = await call(
    'GET',
    `/api/v1/book/collections?limit=1&cursor=${encodeURIComponent(page1.nextCursor)}`,
    owner,
  );
  const page2 = r.json();
  check(
    'collections_cursor_page2',
    (page2.items || []).length === 1 && page2.items[0].name !== page1.items[0].name,
    `names=${page1.items[0].name},${(page2.items[0] || {}).name}`,
  );

  r = await call('GET', '/api/v1/book/collections?q=Tril', owner);
  check(
    'collections_search',
    (r.json().items || []).length === 1 && r.json().items[0].name === 'Trilogy',
    'items=' + JSON.stringify((r.json().items || []).map((x) => x.name)),
  );

  r = await call('GET', '/api/v1/book/collections?cursor=not-base64', owner);
  check('collections_bad_cursor_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await call('GET', `/api/v1/book/collections/items?name=${encodeURIComponent('Nope')}`, owner);
  check('collection_items_unknown_404', r.statusCode === 404, 'status=' + r.statusCode);

  // 4. 清除合集
  r = await call('POST', '/api/v1/book/collection', owner, { id: gamma.id, name: '' });
  check('collection_clear', r.statusCode === 200, 'status=' + r.statusCode);
  r = await call('GET', '/api/v1/book/collections', owner);
  const afterClear = (r.json().items || []).map((c) => c.name);
  check('collection_cleared', !afterClear.includes('Singles'), 'names=' + JSON.stringify(afterClear));

  // 5. 归档：三态 + 跨用户隔离
  r = await call('POST', '/api/v1/book/archive', owner, { id: alpha.id });
  check('archive_set', r.statusCode === 200, 'status=' + r.statusCode);

  r = await call('GET', '/api/v1/book/list?archived=1', owner);
  const archived = (r.json().items || []).map((b) => b.id);
  check('archive_filter_only', archived.length === 1 && archived[0] === alpha.id, 'n=' + archived.length);

  r = await call('GET', '/api/v1/book/list?archived=0', owner);
  const active = (r.json().items || []).map((b) => b.id);
  check('archive_filter_excludes', !active.includes(alpha.id) && active.length === 2, 'n=' + active.length);

  r = await call('GET', `/api/v1/book/item?id=${encodeURIComponent(alpha.id)}`, other);
  check('archive_cross_user_isolated', r.statusCode === 200 && r.json().archived === false, `archived=${r.json().archived}`);

  await call('POST', '/api/v1/book/archive', owner, { id: alpha.id, archived: false });
  r = await call('GET', '/api/v1/book/list?archived=1', owner);
  check('archive_clear', r.statusCode === 200 && (r.json().items || []).length === 0, 'n=' + (r.json().items || []).length);

  // 6. 自定义列表
  r = await call('POST', '/api/v1/book/lists', owner, { name: '阅读计划' });
  check('list_create', r.statusCode === 200 && typeof r.json().id === 'string', 'status=' + r.statusCode);
  const listId = r.json().id;

  r = await call('POST', '/api/v1/book/lists', owner, { name: '阅读计划' });
  check('list_duplicate_409', r.statusCode === 409, 'status=' + r.statusCode);

  r = await call('POST', '/api/v1/book/lists', owner, { name: '   ' });
  check('list_empty_name_400', r.statusCode === 400, 'status=' + r.statusCode);

  await call('POST', '/api/v1/book/lists/add', owner, { listId, bookId: alpha.id });
  await call('POST', '/api/v1/book/lists/add', owner, { listId, bookId: gamma.id });
  r = await call('POST', '/api/v1/book/lists/add', owner, { listId, bookId: alpha.id });
  check('list_add_idempotent', r.statusCode === 200, 'status=' + r.statusCode);

  r = await call('GET', `/api/v1/book/lists/items?listId=${encodeURIComponent(listId)}`, owner);
  const listItems = r.json().items || [];
  check(
    'list_items_in_add_order',
    listItems.length === 2 && listItems[0].id === alpha.id && listItems[1].id === gamma.id,
    'order=' + JSON.stringify(listItems.map((x) => x.path)),
  );

  r = await call('GET', '/api/v1/book/lists', owner);
  const myLists = r.json().items || [];
  const mine = myLists.find((l) => l.id === listId);
  check('list_count', Boolean(mine) && mine.books === 2, `books=${mine && mine.books}`);

  r = await call('GET', '/api/v1/book/list?listId=' + encodeURIComponent(listId), owner);
  check('list_filter_on_shelf', (r.json().items || []).length === 2, 'n=' + (r.json().items || []).length);

  r = await call('GET', `/api/v1/book/lists/items?listId=${encodeURIComponent(listId)}`, other);
  check('list_cross_user_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await call('POST', '/api/v1/book/lists/items/remove', owner, { listId, bookId: gamma.id });
  check('list_remove_item', r.statusCode === 200, 'status=' + r.statusCode);
  r = await call('GET', `/api/v1/book/lists/items?listId=${encodeURIComponent(listId)}`, owner);
  check('list_after_remove', (r.json().items || []).length === 1, 'n=' + (r.json().items || []).length);

  r = await call('POST', '/api/v1/book/lists/remove', owner, { id: listId });
  check('list_remove', r.statusCode === 200, 'status=' + r.statusCode);
  r = await call('GET', `/api/v1/book/lists/items?listId=${encodeURIComponent(listId)}`, owner);
  check('list_removed_cascade', r.statusCode === 404, 'status=' + r.statusCode);
  r = await call('POST', '/api/v1/book/lists/remove', other, { id: listId });
  check('list_remove_cross_user_404', r.statusCode === 404, 'status=' + r.statusCode);

  const failed = results.filter((x) => !x.ok);
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(30)} ${x.detail}`);
  }
  console.log(`\n[book-organize] ${results.length - failed.length}/${results.length} passed`);
  await app.close();
  process.exit(failed.length ? 1 : 0);
})();