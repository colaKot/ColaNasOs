/**
 * 开发期内核守护：`tsc` 增量编译 + 自动重启内核。
 *
 * 为什么不用 `npm run dev`（tsx）：
 *   `better-sqlite3` 是按 **Electron ABI** 编译的（NODE_MODULE_VERSION 149），
 *   纯 Node 进程（127）加载会直接抛错 —— 所以必须用 `electron.exe` 以
 *   `ELECTRON_RUN_AS_NODE=1` 的方式跑编译产物，这也是所有冒烟脚本的做法。
 *
 * 用法：`node tool/dev/watch-kernel.js`（由根目录 `dev.bat` 拉起）
 *   - 首次：`tsc -p tsconfig.json` 全量编译，然后起内核
 *   - 之后：`src/**` `kernel/**` 任意文件变化 → 800 ms 去抖 → 增量编译 → 通过就重启内核
 *   - 编译失败：保留上一个内核继续跑，日志里给出 tsc 报错（不白屏）
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..', '..');
const electronExe = path.join(
  root,
  'node_modules',
  'electron',
  'dist',
  process.platform === 'win32' ? 'electron.exe' : 'electron',
);
const tsc = path.join(root, 'node_modules', 'typescript', 'bin', 'tsc');
const entry = path.join(root, 'dist', 'electron', 'kernel-host.js');

// 开发内核默认 7888（正式服务端是 7788）。默认值写 7788 时，直接跑这个脚本
// 而不经 dev.bat，端口自愈会把**正在用的正式内核**当残留进程 kill 掉。
const PORT = process.env.PORT || '7888';
const WATCH_DIRS = ['src', 'kernel', 'electron'];
const DEBOUNCE_MS = 800;

let kernel = null;
let debounceTimer = null;
let building = false;
let pendingRebuild = false;

function log(msg) {
  console.log(`[dev] ${msg}`);
}

/**
 * 找出监听指定端口的 PID（Windows）。
 * `netstat -ano` 的 LISTENING 行形如：
 *   TCP    0.0.0.0:7788    0.0.0.0:0    LISTENING    17856
 */
function listeningPids(port) {
  const r = spawnSync('netstat', ['-ano', '-p', 'TCP'], { encoding: 'utf8', windowsHide: true });
  if (r.status !== 0 || !r.stdout) return [];
  const pids = new Set();
  for (const line of r.stdout.split(/\r?\n/)) {
    const m = /:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$/.exec(line.trim());
    if (m && m[1] === String(port)) pids.add(m[2]);
  }
  return [...pids];
}

function processName(pid) {
  const r = spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], {
    encoding: 'utf8',
    windowsHide: true,
  });
  const m = /^"([^"]+)"/.exec(String(r.stdout || '').trim());
  return m ? m[1] : '';
}

/**
 * 端口自愈：清掉上一次没死透的内核进程。
 *
 * 踩过的坑：`stopKernel()` 等到 exit 事件时 OS 还没把监听套接字还回来，
 * 新内核 bind 就撞 EADDRINUSE 并在 2 秒内自杀；退避重试 4 次全撞在同一具尸体上，
 * 于是 dev.bat 卡在「启动失败，等待文件变化后重启」，用户看到的是「服务没了」。
 *
 * 只清 **electron.exe**：别的程序占着 7788 就让它占着，宁可报错也别乱杀。
 */
function reclaimPort(port) {
  if (process.platform !== 'win32') return false;
  let killed = false;
  for (const pid of listeningPids(port)) {
    if (pid === String(process.pid)) continue;
    const name = processName(pid);
    if (!/^electron(\.exe)?$/i.test(name)) {
      log(`端口 ${port} 被 ${name || `pid ${pid}`} 占用（不是内核进程，不自动清理）`);
      continue;
    }
    log(`端口 ${port} 被残留内核占用（pid ${pid}），清理后重启`);
    spawnSync('taskkill', ['/PID', pid, '/F', '/T'], { windowsHide: true });
    killed = true;
  }
  return killed;
}

function build() {
  const r = spawnSync(process.execPath, [tsc, '-p', 'tsconfig.json'], {
    cwd: root,
    stdio: 'inherit',
  });
  return r.status === 0;
}

/** 同步睡眠（`Atomics.wait`）：清理端口后必须等一下才能 bind，但这里还是同步上下文 */
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function startKernel(attempt = 1) {
  if (!fs.existsSync(entry)) {
    log('dist/electron/kernel-host.js 不存在，先编译');
    if (!build()) {
      log('首次编译失败，请修复后保存任意文件重试');
      return;
    }
  }
  // 先看看端口是不是被上一具「没死透的内核」占着
  if (reclaimPort(PORT)) {
    // taskkill 是异步回收的，给它一点时间把套接字还回来
    sleepSync(400);
  }
  const startedAt = Date.now();
  kernel = spawn(electronExe, [entry], {
    cwd: root,
    stdio: 'inherit',
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: '1',
      PORT,
      NODE_ENV: process.env.NODE_ENV || 'development',
      // 开发工具默认开 dev-token + CORS；生产（start.bat）不设，二者都不启用
      COLANAS_DEV_TOKEN: process.env.COLANAS_DEV_TOKEN || '1',
      // 开发实例标记：内核会探活正式版（7788），命中后跳过后台任务
      COLANAS_DEV_INSTANCE: process.env.COLANAS_DEV_INSTANCE || '1',
    },
  });
  kernel.on('exit', (code) => {
    log(`内核退出（code=${code}）`);
    kernel = null;
    // 起来不到 2 秒就退出 ⇒ 大概率是 EADDRINUSE：stopKernel 等到 exit 事件时
    // OS 还没把监听套接字还回来，新进程 bind 就撞上。退避重试，别干等下一次
    // 文件变化（那样用户看到的是「服务没了」）。
    const quick = Date.now() - startedAt < 2000;
    if (code !== 0 && quick && attempt < 4) {
      const wait = 500 * attempt;
      log(`${wait}ms 后重试启动（第 ${attempt + 1} 次）`);
      setTimeout(() => {
        if (kernel === null) startKernel(attempt + 1);
      }, wait);
      return;
    }
    if (code !== 0) log('启动失败，等待文件变化后重启');
  });
  log(`内核启动中 → http://127.0.0.1:${PORT}`);
}

function stopKernel() {
  if (!kernel) return Promise.resolve();
  const child = kernel;
  kernel = null;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 已退出 */
      }
      resolve();
    }, 3000);
    child.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
    try {
      child.kill();
    } catch {
      clearTimeout(timer);
      resolve();
    }
  });
}

async function rebuildAndRestart(reason) {
  if (building) {
    pendingRebuild = true;
    return;
  }
  building = true;
  log(`检测到变化（${reason}），编译中…`);
  const ok = build();
  if (ok) {
    await stopKernel();
    // 给 OS 一点时间把监听套接字还回来：exit 事件早于端口真正释放，
    // 紧接着 bind 会撞 EADDRINUSE（新内核起 2 秒内自杀）。
    await new Promise((r) => setTimeout(r, 300));
    startKernel();
  } else {
    log('编译失败：内核保持运行，修复后再保存');
  }
  building = false;
  if (pendingRebuild) {
    pendingRebuild = false;
    void rebuildAndRestart('pending');
  }
}

function watch(dir) {
  const full = path.join(root, dir);
  if (!fs.existsSync(full)) return;
  fs.watch(full, { recursive: true }, (_event, filename) => {
    if (!filename) return;
    if (/(^|[/\\])(node_modules|dist|\.git)([/\\]|$)/.test(filename)) return;
    if (!/\.(ts|js|json)$/.test(filename)) return;
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => void rebuildAndRestart(filename), DEBOUNCE_MS);
  });
}

async function shutdown() {
  log('正在退出…');
  await stopKernel();
  // 整个开发环境退出时把内置 transmission 一起停掉（种子先发 stopped 再杀）。
  // 注意：**重启内核**不会走这里，那时 daemon 继续做种，tracker 不会多出一条 session。
  try {
    spawnSync(process.execPath, [path.join(__dirname, 'stop-daemon.js')], {
      stdio: 'inherit',
      windowsHide: true,
      timeout: 10000,
    });
  } catch {
    /* 停不掉就交给下次启动时探测 */
  }
  process.exit(0);
}

process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());

log(`仓库：${root}`);
if (!build()) {
  log('首次编译失败：修好后再保存任意 ts 文件即可');
}
startKernel();
for (const d of WATCH_DIRS) watch(d);
log('监听中：src/** kernel/** electron/**（Ctrl+C 退出）');
