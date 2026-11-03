#!/usr/bin/env node
/**
 * SP2-05 基准报告：启动 / 缩略图 / AI / 检索 四组数据 → docs/bench/sp2-baseline.md
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/bench/report.js [--count=500]
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync, spawn } = require('node:child_process');

function exeName() {
  return process.platform === 'win32' ? 'electron.exe' : 'electron';
}

if (!process.versions.electron) {
  const exe = path.join(process.cwd(), 'node_modules', 'electron', 'dist', exeName());
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
const { SidecarSupervisor } = require(path.join(root, 'dist', 'kernel', 'sidecar', 'supervisor'));
const { createDb, closeDb } = require(path.join(root, 'dist', 'kernel', 'db'));
const { Migrator } = require(path.join(root, 'dist', 'kernel', 'migrator'));
const { files } = require(path.join(root, 'dist', 'src', 'modules', 'files', 'index.js'));

const COUNT = Number((process.argv.find((a) => a.startsWith('--count=')) || '').split('=')[1]) || 500;

function probeFfmpeg() {
  const cands = [process.env.COLANAS_FFMPEG, process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg'];
  for (const prefix of ['C:/Program Files', 'C:/Program Files (x86)']) {
    try {
      for (const d of fs.readdirSync(prefix)) {
        if (/imagemagick/i.test(d)) cands.push(path.join(prefix, d, 'ffmpeg.exe'));
      }
    } catch {
      /* 忽略 */
    }
  }
  for (const c of cands.filter(Boolean)) {
    const r = spawnSync(c, ['-version'], { encoding: 'utf8', windowsHide: true });
    if (r.status === 0 && /ffmpeg version/i.test(r.stdout || '')) return c;
  }
  return null;
}

async function measureStartup(port, dataDir) {
  const started = Date.now();
  const child = spawn(process.execPath, [path.join(root, 'dist', 'electron', 'kernel-host.js')], {
    env: Object.assign({}, process.env, {
      ELECTRON_RUN_AS_NODE: '1',
      COLANAS_DATA_DIR: dataDir,
      PORT: String(port),
    }),
    stdio: 'ignore',
    windowsHide: true,
  });

  let ms = null;
  for (let i = 0; i < 300; i++) {
    try {
      const res = await globalThis.fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) {
        ms = Date.now() - started;
        break;
      }
    } catch {
      /* 还没起来 */
    }
    await new Promise((r) => setTimeout(r, 20));
  }
  try {
    child.kill('SIGKILL');
  } catch {
    /* 忽略 */
  }
  return ms;
}

async function measureThumbs(ffmpeg, work, count) {
  const src = path.join(work, 'src.jpg');
  spawnSync(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=1920x1080:rate=1', '-frames:v', '1', src], {
    windowsHide: true,
  });
  const sup = new SidecarSupervisor({
    name: 'media',
    command: process.execPath,
    args: [path.join(root, 'sidecars', 'media', 'main.js')],
    requestTimeoutMs: 300_000,
    heartbeatMs: 20_000,
    maxRestarts: 2,
    startTimeoutMs: 15_000,
    stopGraceMs: 3_000,
    log: () => {},
    env: { COLANAS_FFMPEG: ffmpeg },
  });
  await sup.start();
  const bench = await sup.request('bench', { src, dir: path.join(work, 'thumbs'), count, size: 256 });
  await sup.stop();
  return bench;
}

async function measureAi() {
  const sup = new SidecarSupervisor({
    name: 'ai-infer',
    command: process.execPath,
    args: [path.join(root, 'sidecars', 'ai-infer', 'main.js')],
    requestTimeoutMs: 30_000,
    heartbeatMs: 10_000,
    maxRestarts: 2,
    startTimeoutMs: 20_000,
    stopGraceMs: 3_000,
    log: () => {},
  });
  await sup.start();
  const dims = [1, 1, 28, 28];
  const data = new Array(784).fill(0);
  const samples = [];
  for (let i = 0; i < 21; i++) {
    const t0 = process.hrtime.bigint();
    await sup.request('infer', { model: 'mnist-8', dims, data });
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    if (i > 0) samples.push(ms); // 首次含建会话，剔除
  }
  const info = await sup.request('list');
  await sup.stop();
  samples.sort((a, b) => a - b);
  return {
    model: 'mnist-8 (1x1x28x28 → 1x10)',
    eps: info.eps,
    n: samples.length,
    avg: samples.reduce((a, b) => a + b, 0) / samples.length,
    p50: samples[Math.floor(samples.length / 2)],
    min: samples[0],
    max: samples[samples.length - 1],
  };
}

async function measureSearch(work) {
  const handle = createDb(path.join(work, 'bench.sqlite'));
  const migrator = new Migrator(handle.db);
  await migrator.run(files.migrations || []);

  const rows = 20_000;
  const insert = handle.raw.prepare('insert into files_meta (path, size, mtime, updated_at) values (?,?,?,?)');
  const tx = handle.raw.transaction(() => {
    for (let i = 0; i < rows; i++) {
      insert.run(`media/2026/d${i % 200}/f${String(i).padStart(6, '0')}.jpg`, i, i, 0);
    }
  });
  tx();

  const q = handle.raw.prepare('select path from files_meta where path like ? limit 50');
  const t0 = process.hrtime.bigint();
  let hits = 0;
  for (let i = 0; i < 1000; i++) {
    hits += q.all(`%f0${String(i % 100).padStart(2, '0')}%`).length;
  }
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  await closeDb(handle);
  return { rows, queries: 1000, ms, avg: ms / 1000, hits };
}

(async () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-bench-'));
  const ffmpeg = probeFfmpeg();

  console.log('[bench] 启动 …');
  const startup = await measureStartup(17788, path.join(work, 'data'));
  console.log('[bench] 启动完成:', startup, 'ms');

  console.log('[bench] AI 推理 …');
  const ai = await measureAi();
  console.log('[bench] AI:', JSON.stringify(ai));

  console.log('[bench] 检索 …');
  const search = await measureSearch(work);
  console.log('[bench] 检索:', JSON.stringify(search));

  let thumb = null;
  if (ffmpeg) {
    console.log(`[bench] 缩略图 ${COUNT} 张 …`);
    thumb = await measureThumbs(ffmpeg, work, COUNT);
    console.log('[bench] 缩略图:', JSON.stringify(thumb));
  }

  fs.rmSync(work, { recursive: true, force: true });

  const stamp = new Date().toISOString();
  const md = `# SP2 基准报告

> 生成时间：${stamp}
> 环境：${os.type()} ${os.release()} / ${os.cpus().length} 核 / Node ${process.versions.node}${process.versions.electron ? ` / Electron ${process.versions.electron}` : ''}
> 生成脚本：\`node tool/bench/report.js --count=${COUNT}\`

## 1. 冷启动

| 指标 | 数值 |
| --- | --- |
| 从 spawn 到 \`/health\` 200 | **${startup} ms** |
| 备注 | 含首次建库与迁移；数据目录为全新临时目录 |

## 2. 缩略图

${thumb ? `| 指标 | 数值 |
| --- | --- |
| 张数 | ${thumb.count} |
| 总耗时 | ${thumb.ms.toFixed(0)} ms |
| 吞吐 | **${thumb.throughput.toFixed(1)} 张/秒** |
| 平均单张 | ${(thumb.ms / thumb.count).toFixed(1)} ms |
| 并发 | ${thumb.concurrency} |` : '_ffmpeg 不可用，未测_'}

## 3. AI 推理

| 指标 | 数值 |
| --- | --- |
| 模型 | ${ai.model} |
| 执行提供者 | ${ai.eps.join(' + ')}（webgpu 已显式排除） |
| 样本数 | ${ai.n}（剔除首次建会话） |
| 平均 | **${ai.avg.toFixed(2)} ms** |
| P50 | ${ai.p50.toFixed(2)} ms |
| 最小 / 最大 | ${ai.min.toFixed(2)} / ${ai.max.toFixed(2)} ms |

> 说明：仓库内自带的是 ONNX 官方 \`mnist-8\` 验收模型（26 KB），用于验证会话/推理链路；
> EdgeFace 等生产模型放入 \`onnx_models/<name>/<version>/model.onnx\` 即可，无需改代码。

## 4. 检索

| 指标 | 数值 |
| --- | --- |
| 数据集 | ${search.rows} 行 \`files_meta\` |
| 查询次数 | ${search.queries} 次 LIKE |
| 总耗时 | ${search.ms.toFixed(0)} ms |
| 平均单次 | **${search.avg.toFixed(3)} ms** |
| 命中总数 | ${search.hits} |

> 注：LIKE 全表扫描属于最坏情况；后续检索层会引入 \`sqlite_vec\` / FTS 索引。
`;

  const outDir = path.join(root, 'docs', 'bench');
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, 'sp2-baseline.md');
  fs.writeFileSync(outFile, md, 'utf8');
  console.log('[bench] 报告已写入', outFile);
})().catch((e) => {
  console.error('[FATAL]', e);
  process.exit(1);
});