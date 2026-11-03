#!/usr/bin/env node
/**
 * SP3-11（RSS 子集）验收：订阅 / 解析 / 幂等刷新 / 列表 / 级联删除 / 非法协议。
 *
 * 用内联 XML，不依赖外网。
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/rss-smoke.js
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
const { sql } = require('kysely');

// 测试环境不落盘日志：临时目录在 app.close() 后立刻删除，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

process.chdir(root);

const XML = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title><![CDATA[ColaNasOs 测试源]]></title>
  <item>
    <title>第一条 &amp; 实体</title>
    <link>https://example.com/a</link>
    <guid isPermaLink="false">a-1</guid>
    <pubDate>Wed, 29 Oct 2026 10:00:00 GMT</pubDate>
    <description><![CDATA[<p>摘要 <b>A</b></p>]]></description>
  </item>
  <item>
    <title>第二条</title>
    <link>https://example.com/b</link>
    <guid>b-2</guid>
    <pubDate>Thu, 30 Oct 2026 10:00:00 GMT</pubDate>
    <description>摘要 B</description>
  </item>
</channel></rss>`;

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-rss-'));
  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

  const t = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['rss:read', 'rss:write'] },
  });
  const bearer = { authorization: 'Bearer ' + (t.json().token || '') };

  let r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/feeds',
    headers: bearer,
    payload: { xml: XML },
  });
  const feed = r.json();
  check(
    'feed_add',
    r.statusCode === 200 && feed.id && feed.title.includes('ColaNasOs'),
    `status=${r.statusCode} title=${feed.title}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/rss/items',
    headers: bearer,
  });
  const addedItems = r.json();
  check(
    'add_ingests_items',
    r.statusCode === 200 && addedItems.total === 2,
    `total=${addedItems.total}`,
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/feeds/refresh',
    headers: bearer,
    payload: { id: feed.id, xml: XML },
  });
  const first = r.json();
  check('refresh_no_duplicates', r.statusCode === 200 && first.added === 0 && first.skipped === 2, JSON.stringify(first));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/feeds/refresh',
    headers: bearer,
    payload: { id: feed.id, xml: XML },
  });
  const second = r.json();
  check('refresh_idempotent', second.added === 0 && second.skipped === 2, JSON.stringify(second));

  r = await app.inject({ method: 'GET', url: '/api/v1/rss/items', headers: bearer });
  const items = r.json();
  check(
    'items_sorted',
    r.statusCode === 200 && items.total === 2 && items.items[0].guid === 'b-2',
    `total=${items.total} first=${items.items && items.items[0] && items.items[0].guid}`,
  );
  check(
    'items_entity_decoded',
    items.items.some((x) => x.title === '第一条 & 实体'),
    items.items.map((x) => x.title).join(' | '),
  );
  check(
    'items_summary_stripped',
    items.items.some((x) => x.summary === '摘要 A'),
    items.items.map((x) => x.summary).join(' | '),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/rss/items?feedId=' + encodeURIComponent(feed.id), headers: bearer });
  check('items_filter', r.statusCode === 200 && r.json().total === 2, 'total=' + r.json().total);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/feeds/refresh',
    headers: bearer,
    payload: { id: feed.id, url: 'ftp://example.com/rss' },
  });
  check('bad_protocol_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/feeds/refresh',
    headers: bearer,
    payload: { id: 'nope' },
  });
  check('refresh_missing_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/rss/feeds', headers: bearer });
  check('feed_list', r.statusCode === 200 && r.json().items.length === 1, 'items=' + r.json().items.length);

  // ---- RSS 自动下载规则：命中 → 建 PT 订阅（去重） ----
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/rules/upsert',
    headers: bearer,
    payload: { feedId: feed.id, titleRegex: '第一条' },
  });
  check('rule_create', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/rss/rules', headers: bearer });
  const rules = r.json().items || [];
  check(
    'rule_list',
    r.statusCode === 200 && rules.length === 1 && !!rules[0].feedTitle,
    JSON.stringify(rules[0] || {}),
  );
  const ruleId = rules[0]?.id;

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/rules/run',
    headers: bearer,
    payload: { id: ruleId },
  });
  check(
    'rule_run',
    r.statusCode === 200 && r.json().matched >= 1 && r.json().created >= 1,
    JSON.stringify(r.json()),
  );

  const subs = await sql`
    select media_title from pt_subscriptions where uid = 'u1'
  `.execute(k.db);
  check(
    'rule_subscription',
    subs.rows.some((x) => String(x.media_title).includes('第一条')),
    JSON.stringify(subs.rows),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/rules/run',
    headers: bearer,
    payload: { id: ruleId },
  });
  check('rule_run_dedup', r.statusCode === 200 && r.json().created === 0, JSON.stringify(r.json()));

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/rules/upsert',
    headers: bearer,
    payload: { feedId: feed.id, titleRegex: '(' },
  });
  check('rule_bad_regex_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/rules/delete',
    headers: bearer,
    payload: { id: ruleId },
  });
  check('rule_delete', r.statusCode === 200, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/rss/feeds/remove',
    headers: bearer,
    payload: { id: feed.id },
  });
  const afterItems = await app.inject({ method: 'GET', url: '/api/v1/rss/items', headers: bearer });
  check('remove_cascade', r.json().ok === true && afterItems.json().total === 0, 'total=' + afterItems.json().total);

  await app.close();
  try { fs.rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch { /* 句柄释放有延迟 */ }

  let failed = 0;
  for (const x of results) {
    console.log(`${x.ok ? '[OK]  ' : '[FAIL]'} ${x.name.padEnd(24)} ${x.detail}`);
    if (!x.ok) failed++;
  }
  console.log(`[summary] ${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});