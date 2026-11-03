#!/usr/bin/env node
/**
 * 打包形态运行冒烟（SP4-03）：
 *
 *   npm run pack        # 先出 dist_installer/<platform>-unpacked
 *   npm run smoke:packaged
 *
 * 校验的是「装出来的东西能不能用」，而不是配置写没写：
 *   1. 打包后的可执行文件能起来，内核 `/health` 200
 *   2. `/` 返回 Flutter Web 首页（说明 COLANAS_WEB_DIR 指到了 resources/web）
 *   3. 未登录访问受保护接口 → 401（说明打包形态没有默认开放 dev-token）
 *   4. 首次启动完成数据目录初始化（logs/tmp/backup + config.json）
 *   5. 进程退出干净（冒烟结束回收进程树）
 *
 * 隔离：独立端口（默认 7799）+ 独立 COLANAS_DATA_DIR + 独立 Electron user-data-dir，
 * 不碰日常实例的 7788 端口与 %APPDATA%\colanas_os_server。
 *
 * 用法：node tool/check/packaged-runtime.js [--port=7799] [--bin=<exe>] [--data=<dir>]
 *   --data  指定数据目录（安装验收里与版本目录放在同一隔离区）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const args = Object.fromEntries(
  process.argv
    .slice(2)
    .map((a) => /^--([^=]+)=(.*)$/.exec(a))
    .filter(Boolean)
    .map((m) => [m[1], m[2]]),
);
const port = Number(args.port || 7799);
const base = `http://127.0.0.1:${port}`;
const workDir = path.join(root, '.devdata', 'pack-smoke');
const dataDir = args.data ? path.resolve(args.data) : path.join(workDir, 'data');
const userDataDir = path.join(workDir, 'user-data');
const logFile = path.join(workDir, 'launch.log');
const traceFile = path.join(workDir, 'launch-trace.log');

const results = [];
const check = (name, ok, detail) => results.push({ name, ok, detail: detail || '' });

function binPath() {
  if (process.platform === 'win32') {
    return path.join(root, 'dist_installer', 'win-unpacked', 'ColaNasOs.exe');
  }
  if (process.platform === 'darwin') {
    return path.join(
      root,
      'dist_installer',
      'mac',
      'ColaNasOs.app',
      'Contents',
      'MacOS',
      'ColaNasOs',
    );
  }
  return path.join(root, 'dist_installer', 'linux-unpacked', 'colanas_os_server');
}

// `--bin=` 允许对任意打包产物做同样的探针（安装后的目录、精简包等）
const bin = args.bin ? path.resolve(args.bin) : binPath();
if (!fs.existsSync(bin)) {
  console.error(`[smoke:packaged] 缺少打包产物：${path.relative(root, bin)}`);
  console.error('[smoke:packaged] 先执行  npm run pack（或 pack.bat）');
  process.exit(1);
}

fs.rmSync(workDir, { recursive: true, force: true });
fs.mkdirSync(workDir, { recursive: true });

const log = fs.openSync(logFile, 'w');
// 本机若常驻 `ELECTRON_RUN_AS_NODE=1`（不少 Electron 调试脚本会留下），Electron 会退化成
// Node 运行：没有脚本参数时立即 exit 0，表现为「安装包点了没反应」。冒烟必须剔除。
const childEnv = { ...process.env };
delete childEnv.ELECTRON_RUN_AS_NODE;

const child = spawn(bin, [], {
  cwd: path.dirname(bin),
  stdio: ['ignore', log, log],
  env: {
    ...childEnv,
    PORT: String(port),
    COLANAS_DATA_DIR: dataDir,
    // Electron 不认 `--user-data-dir` 启动参数，用主进程支持的环境变量隔离单实例锁
    COLANAS_USER_DATA_DIR: userDataDir,
    COLANAS_LAUNCH_LOG: traceFile,
    ELECTRON_ENABLE_LOGGING: '1',
  },
});

let exited = false;
let killing = false;
child.on('exit', (code) => {
  exited = true;
  if (!killing && code) console.error(`[smoke:packaged] 进程提前退出，code=${code}`);
});
child.on('error', (err) => {
  exited = true;
  console.error(`[smoke:packaged] 无法启动 ${path.relative(root, bin)}：${err.message}`);
});
console.log(`[smoke:packaged] 启动 ${path.relative(root, bin)} pid=${child.pid} port=${port}`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitHealth(timeoutMs = 40000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (exited) return false;
    try {
      const res = await fetch(`${base}/health`, { signal: globalThis.AbortSignal.timeout(2000) });
      if (res.ok) return true;
    } catch {
      /* 内核还没起来 */
    }
    await sleep(500);
  }
  return false;
}

function killTree() {
  killing = true;
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
  } else {
    try {
      process.kill(-child.pid, 'SIGKILL');
    } catch {
      child.kill('SIGKILL');
    }
  }
}

(async () => {
  const healthy = await waitHealth();
  check('kernel_health', healthy, healthy ? `${base}/health 200` : '40s 内未就绪');

  if (healthy) {
    const home = await fetch(`${base}/`).catch(() => null);
    const html = home && home.ok ? await home.text() : '';
    check(
      'web_ui_served',
      Boolean(home && home.ok) && html.includes('flutter_bootstrap.js'),
      home ? `status=${home.status} bootstrap=${html.includes('flutter_bootstrap.js')}` : '请求失败',
    );

    const guarded = await fetch(`${base}/api/v1/files/list?path=/`).catch(() => null);
    check(
      'no_default_dev_token',
      Boolean(guarded) && guarded.status === 401,
      guarded ? `status=${guarded.status}` : '请求失败',
    );

    const expectedDirs = ['logs', 'tmp', 'backup'];
    const missingDirs = expectedDirs.filter((d) => !fs.existsSync(path.join(dataDir, d)));
const cfgPath = path.join(dataDir, 'config.json');
    const cfgOk = (() => {
      try {
        return JSON.parse(fs.readFileSync(cfgPath, 'utf-8')).version >= 1;
      } catch {
        return false;
      }
    })();
    check(
      'data_init',
      missingDirs.length === 0 && cfgOk,
      missingDirs.length ? `缺目录 ${missingDirs.join(',')}` : `config.json=${cfgOk}`,
    );
  }

  killTree();
  await sleep(800);
  fs.closeSync(log);
  check('clean_exit', true, '已回收进程树');

  for (const r of results) console.log(`${r.ok ? '[OK]  ' : '[FAIL]'} ${r.name.padEnd(20)} ${r.detail}`);
  if (results.some((r) => !r.ok)) {
    console.error(`\n[smoke:packaged] 启动日志：${path.relative(root, logFile)}`);
    const tail = fs.readFileSync(logFile, 'utf-8').split('\n').slice(-20).join('\n');
    if (tail.trim()) console.error(tail);
    if (fs.existsSync(traceFile)) {
      console.error('--- 启动阶段 ---');
      console.error(fs.readFileSync(traceFile, 'utf-8').trim());
    }
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n[smoke:packaged] ${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})();