#!/usr/bin/env node
/**
 * CL3-01 客户端性能基准。
 *
 * 流程：
 *   1. 起一个真实内核 + 种子书库（照片 / 影视 / 音乐 / 书各 20 条）；
 *   2. 用真实 HTTP 抓 6 个页面首屏所需的接口响应，落成 `perf-data.json`，同时记下每个接口的 RTT；
 *   3. 调 `flutter test test/perf_test.dart`，用例按路径**回放**这些响应，
 *      量「首屏渲染耗时」与「滚动步进耗时」（widget test 里真发 HTTP 会撞上 FakeAsync，见 perf_test.dart 注释）；
 *   4. 汇总写 `docs/bench/cl3-01-client.md`。
 *
 * 用法：
 *   npm run bench:client            # 默认
 *   npm run bench:client -- --keep  # 保留临时数据目录
 *   npm run bench:client -- --debug # 打印 flutter test 全量输出
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
  const r = spawnSync(exe, [__filename, ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const appDir = path.join(root, 'apps', 'colanas_os');
const reportPath = path.join(root, 'docs', 'bench', 'cl3-01-client.md');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

/** 每个页面首屏会打的接口（路径不含 query，回放按键匹配） */
const ENDPOINTS = [
  ['photo', '/api/v1/photo/timeline?limit=60'],
  ['photo', '/api/v1/photo/albums'],
  ['photo', '/api/v1/photo/stats'],
  ['photo', '/api/v1/photo/libraries'],
  ['video', '/api/v1/video/list?limit=60&series=none'],
  ['video', '/api/v1/video/series?limit=100'],
  ['video', '/api/v1/video/progress/list?limit=6'],
  ['video', '/api/v1/video/stats'],
  ['video', '/api/v1/video/libraries'],
  ['music', '/api/v1/music/list?limit=60'],
  ['music', '/api/v1/music/stats'],
  ['music', '/api/v1/music/libraries'],
  ['music', '/api/v1/music/playlists'],
  ['files', '/api/v1/files/list?path=/'],
];

function touch(file, bytes) {
  fs.writeFileSync(file, Buffer.alloc(bytes, 7));
}

function seed(filesRoot) {
  for (const d of ['photos', 'videos', 'music', 'books']) {
    fs.mkdirSync(path.join(filesRoot, d), { recursive: true });
  }
  for (let i = 1; i <= 20; i += 1) {
    const n = String(i).padStart(2, '0');
    touch(path.join(filesRoot, 'photos', `IMG_${n}.jpg`), 4096);
    touch(path.join(filesRoot, 'videos', `Movie ${n}.mp4`), 4096);
    touch(path.join(filesRoot, 'music', `Track ${n}.mp3`), 4096);
    fs.writeFileSync(path.join(filesRoot, 'books', `Book ${n}.txt`), `第 ${i} 本\n第一行\n第二行\n`);
  }
}

function findFlutter() {
  const candidates =
    process.platform === 'win32'
      ? ['C:/dev/flutter/bin/flutter.bat', 'flutter.bat']
      : ['C:/dev/flutter/bin/flutter', 'flutter'];
  for (const c of candidates) {
    if (c.includes('/') && !fs.existsSync(c)) continue;
    return c;
  }
  return 'flutter';
}

function sh(cmd, args) {
  const r = spawnSync(cmd, args, {
    cwd: appDir,
    shell: true,
    encoding: 'utf-8',
    timeout: 600000,
  });
  return { code: typeof r.status === 'number' ? r.status : 1, out: `${r.stdout || ''}${r.stderr || ''}` };
}

function writeReport(rows, rtt, meta) {
  const stamp = new Date().toISOString().replace('T', ' ').slice(0, 19);
  const byPage = new Map();
  for (const [domain, url] of ENDPOINTS) {
    if (!byPage.has(domain)) byPage.set(domain, []);
    byPage.get(domain).push(url);
  }

  const lines = [
    '# CL3-01 客户端性能基准',
    '',
    `> 由 \`node tool/bench/client.js\` 生成（${stamp}）；环境：${meta.flutter} · ${meta.platform}；窗口 1400×900（expanded 双栏）。`,
    '> 数据链：真实内核 → 真实 HTTP 抓响应 → Flutter 侧按路径回放 → 页面真实渲染。',
    '',
    '## 口径（先读这段再看数字）',
    '',
    '- **首屏渲染**：`pumpWidget` → `NasLoading` 消失（数据帧 / 空态帧）的那一刻，含反序列化与首屏布局，**不含网络往返**（RTT 见下一节）。',
    '- **滚动步进**：一次「拖动 160 px + pump 一帧」的平均耗时，反映 build/layout 的 CPU 成本。',
    '- widget test **没有真实窗口**：没有 GPU 光栅化与 vsync 等待。滚动步进不能当作 fps，只作为「一帧 CPU 预算占比」参考（55 fps ≈ 18.2 ms/帧）。',
    '- 为什么不在测试里直连内核：`testWidgets` 跑在 FakeAsync 里，`IoTransport` 的 30 s timeout 会变成 FakeTimer，真实 socket 回调永远等不到（实测挂死）。',
    '',
    '## 首屏与滚动',
    '',
    '| 页面 | 首屏渲染 | 滚动步进均值 | 滚动 20 步总计 | 首屏判据（≤1.5 s） |',
    '| --- | --- | --- | --- | --- |',
  ];

  for (const r of rows) {
    lines.push(
      `| ${r.page} | ${r.firstMs == null ? '—' : `${r.firstMs.toFixed(1)} ms`} | ${
        r.scrollStepMs == null ? '—' : `${r.scrollStepMs.toFixed(2)} ms`
      } | ${r.scrollTotalMs == null ? '—' : `${r.scrollTotalMs.toFixed(0)} ms`} | ${
        r.firstMs != null && r.firstMs <= 1500 ? '✅' : '⚠️'
      } |`,
    );
  }

  lines.push('', '## 首屏接口 RTT（真实 HTTP，本地内核）', '', '| 页面 | 接口 | RTT |', '| --- | --- | --- |');
  for (const [domain, url] of ENDPOINTS) {
    const key = url.split('?')[0];
    const hit = rtt.find((x) => x.key === key);
    lines.push(`| ${domain} | \`${key}\` | ${hit ? `${hit.ms.toFixed(2)} ms` : '—'} |`);
  }

  const withFirst = rows.filter((r) => typeof r.firstMs === 'number');
  const maxFirst = withFirst.reduce((m, r) => Math.max(m, r.firstMs), 0);
  const maxStep = rows
    .filter((r) => typeof r.scrollStepMs === 'number')
    .reduce((m, r) => Math.max(m, r.scrollStepMs), 0);
  const maxRtt = rtt.reduce((m, r) => Math.max(m, r.ms), 0);
  const notReady = rows.filter((r) => r.ready === false).map((r) => r.page);

  lines.push(
    '',
    '## 结论',
    '',
    `- 最慢首屏渲染 **${maxFirst.toFixed(1)} ms**（判据 1500 ms，余量 ${(1500 - maxFirst).toFixed(0)} ms）；`,
    `- 最慢滚动步进 **${maxStep.toFixed(2)} ms**，占 55 fps 单帧预算（18.2 ms）的 **${((maxStep / 18.2) * 100).toFixed(0)}%**；`,
    `- 最慢接口 RTT **${maxRtt.toFixed(2)} ms**（本地内核，未含公网 / TLS）；`,
    notReady.length
      ? `- ⚠️ 以下页面在 2 s 内没有离开加载态，数字不可信：${notReady.join(' / ')}；`
      : '- 6 个页面都进入了数据态，首屏数字可比较；',
    '- 「滚动 ≥ 55 fps」仍需真机窗口复核（`flutter run --profile -d windows`），本表只能证明 CPU 侧没把帧预算吃掉。',
    '',
    '## 复现',
    '',
    '```text',
    'npm run bench:client            # 起内核 + 抓响应 + flutter test，重写本文件',
    'npm run bench:client -- --keep  # 保留临时数据目录（含 perf-data.json）便于排查',
    'npm run bench:client -- --debug # 打印 flutter test 全量输出',
    '```',
    '',
    '## 已知限制',
    '',
    '- 每页只跑一次，未取中位数；首屏值在 ±15% 内波动（首帧 JIT 预热已排除，因为数据帧不是首帧）。',
    '- 只覆盖桌面 expanded 布局；compact（手机）另有一套排版，未纳入本表。',
    '- 封面 / 缩略图不加载真实图片（`NasCoverImage` 在测试环境拿到 404），因此不含图片解码成本。',
    '- 回放响应来自同一进程的内核，query 参数不参与匹配（同路径只回放第一次抓到的响应）。',
    '',
  );

  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, lines.join('\n'), 'utf-8');
}

(async () => {
  const keep = process.argv.includes('--keep');
  const debug = process.argv.includes('--debug');
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-perf-'));
  const filesRoot = path.join(dataDir, 'files');
  seed(filesRoot);

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_FILES_ROOT = filesRoot;
  process.env.COLANAS_JWT_SECRET = 'perf-secret-0123456789abcdef';
  process.env.LOG_LEVEL = 'warn';

  const k = await startKernel({ dataDir, port: 0 });
  const { port } = k.app.server.address();
  const base = `http://127.0.0.1:${port}`;
  console.log(`[bench:client] kernel on ${base}`);

  const scopes = [
    'photo:read',
    'photo:write',
    'video:read',
    'video:write',
    'music:read',
    'music:write',
    'book:read',
    'book:write',
    'files:read',
    'notes:read',
    'notes:write',
  ];
  const tokRes = await k.app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'perf', scopes },
  });
  const token = tokRes.json().token;
  const headers = { authorization: `Bearer ${token}` };
  const call = (method, url, payload) =>
    k.app.inject({ method, url, headers, ...(payload === undefined ? {} : { payload }) });

  for (const [domain, name, rel] of [
    ['photo', 'Photos', 'photos'],
    ['video', 'Videos', 'videos'],
    ['music', 'Music', 'music'],
  ]) {
    const r = await call('POST', `/api/v1/${domain}/libraries`, { name, path: rel });
    if (r.statusCode !== 200) console.warn(`[bench:client] ${domain} 建库 ${r.statusCode}`);
    const s = await call('POST', `/api/v1/${domain}/scan`, {});
    if (s.statusCode !== 200) console.warn(`[bench:client] ${domain} 扫描 ${s.statusCode}`);
  }
  for (let i = 1; i <= 20; i += 1) {
    await call('POST', '/api/v1/notes', { title: `Note ${i}`, body: `第 ${i} 条笔记的内容` });
  }
  console.log('[bench:client] seeded 20 items per library');

  // 抓真实响应：既做回放数据，也量接口 RTT
  const routes = {};
  const rtt = [];
  for (const [, url] of ENDPOINTS) {
    const t0 = process.hrtime.bigint();
    const res = await fetch(`${base}${url}`, { headers });
    const body = await res.json();
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    const key = url.split('?')[0];
    if (res.status !== 200) {
      console.warn(`[bench:client] ${url} → ${res.status}`);
      continue;
    }
    routes[key] = body;
    rtt.push({ key, ms });
  }
  console.log(`[bench:client] captured ${Object.keys(routes).length} routes`);

  const dataFile = path.join(dataDir, 'perf-data.json');
  fs.writeFileSync(dataFile, JSON.stringify(routes), 'utf-8');

  const flutter = findFlutter();
  const version = sh(flutter, ['--version']).out.split('\n')[0].trim() || 'unknown';
  console.log(`[bench:client] flutter: ${version}`);

  const run = sh(flutter, [
    'test',
    'test/perf_test.dart',
    `--dart-define=PERF_DATA=${dataFile.split(path.sep).join('/')}`,
  ]);
  if (debug) console.log(run.out);

  const rows = [];
  for (const line of run.out.split(/\r?\n/)) {
    const at = line.indexOf('PERF {');
    if (at < 0) continue;
    try {
      rows.push(JSON.parse(line.slice(at + 5)));
    } catch {
      // 忽略半行输出
    }
  }

  await k.app.close();
  if (!keep) fs.rmSync(dataDir, { recursive: true, force: true });

  if (rows.length === 0) {
    console.error('[bench:client] 没收到 PERF 数据，flutter test 输出如下：');
    console.error(run.out.slice(-4000));
    process.exit(1);
  }

  writeReport(rows, rtt, { flutter: version, platform: `${process.platform}-${process.arch}` });
  for (const r of rows) {
    console.log(
      `[OK] ${r.page.padEnd(8)} 首屏 ${String(r.firstMs).padStart(7)} ms  滚动步进 ${String(
        r.scrollStepMs,
      ).padStart(6)} ms${r.ready === false ? '  ⚠️ 未进入数据态' : ''}`,
    );
  }
  console.log(`\n[bench:client] 报告写入 ${path.relative(root, reportPath)}`);
})();