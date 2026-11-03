/**
 * Flutter 开发服务器守护：把 `flutter run` 的 stdin 接管过来，
 * 于是「按 R」变成一个可以被程序触发的动作。
 *
 * 为什么需要这个：
 *   `flutter run` 的命令（r / R / q）只从**它自己的 stdin** 读。
 *   以前在 dev.bat 的第二个窗口里跑，改完 `packages/**`（nas_core / nas_ui 这类
 *   path 依赖）后必须人到窗口里敲一次 R —— 没人敲就一直跑旧代码，
 *   表现成「前端还是旧的」。
 *
 * 可行性依据（读过 flutter_tools 源码，别改成猜的）：
 *   - `resident_runner.dart` 的 `TerminalHandler.setupTerminal()` 只要 `stayResident`
 *     就会执行，**不检查 stdin 是不是终端**；
 *   - `base/terminal.dart` 的 `keystrokes` 直接读 `_stdio.stdin` 原始字节；
 *   - `singleCharMode` 的 setter 里有 `if (!_stdio.stdinHasTerminal) return;`，
 *     所以管道下不会抛异常，只是不做 raw 模式。
 *   ⇒ 把 stdin 接成管道，往里写 `R` 就是一次热重启。
 *
 * 用法（由 dev.bat 拉起，自己几乎不需要直接跑）：
 *   node tool/dev/flutter-dev.js -d chrome --web-port 5173 --dart-define=...
 *
 * 控制口（只绑 127.0.0.1）：
 *   GET  /status                       → 运行状态 / 已触发次数
 *   POST /hot-restart   （或 /r）      → 等价按 R
 *   POST /hot-reload    （或 /reload） → 等价按 r
 *   POST /quit                         → 等价按 q
 *   curl -X POST "http://127.0.0.1:5174/hot-restart?token=$COLANAS_CTL_TOKEN"
 *
 * 自动 R：
 *   监听 `packages/**` 与 `pubspec.yaml`。path 依赖里的代码改动**不会**被
 *   flutter 的热重载接管（热重载只重编译被改的库，但依赖图的初始化不会重跑），
 *   所以生成客户端 / 改组件库后自动发一次 R。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

const repo = path.join(__dirname, '..', '..');
const appDir = path.join(repo, 'apps', 'colanas_os');
const FLUTTER = process.env.FLUTTER || 'flutter';
const CTL_PORT = Number(process.env.COLANAS_CTL_PORT || 5174);
const CTL_TOKEN = process.env.COLANAS_CTL_TOKEN || '';
const AUTO_RESTART_DEBOUNCE_MS = Number(process.env.COLANAS_AUTO_RESTART_MS || 1200);
/** 视作「需要热重启」的目录（相对仓库根） */
const RESTART_WATCH = ['packages', 'apps/colanas_os/pubspec.yaml'];

const args = process.argv.slice(2);
let child = null;
let startedAt = 0;
let restarts = 0;
let reloads = 0;
let lastRestartAt = 0;
let lastRestartReason = '';

/**
 * 同时写一份日志到 `.devdata/flutter-dev.log`。
 *
 * 为什么需要：dev.bat 双击启动时，这个窗口和 dev.bat 是同一个 —— 进程一退出窗口就没了，
 * 上一版漏了 `run` 子命令，flutter 报 `Could not find an option named "--web-port"`
 * 后立刻退出，只剩「没打开浏览器」这个现象，无从查起。
 */
const LOG_FILE = path.join(repo, '.devdata', 'flutter-dev.log');
try {
  fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
  fs.writeFileSync(LOG_FILE, '');
} catch {
  /* 日志写不了不影响主流程 */
}

function log(msg) {
  const line = `[flutter-dev] ${msg}`;
  console.log(line);
  try {
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${line}\n`);
  } catch {
    /* 同上 */
  }
}

/** 往 flutter 的 stdin 写一个命令字符（不带换行：它读的是原始字节流） */
function sendKey(key, reason) {
  if (!child || !child.stdin || child.stdin.destroyed) {
    log(`stdin 不可写，忽略 ${key}（${reason}）`);
    return false;
  }
  try {
    child.stdin.write(key);
    if (key === 'R') {
      restarts += 1;
      lastRestartAt = Date.now();
      lastRestartReason = reason;
      log(`→ 已发送 R 热重启（${reason}，累计 ${restarts} 次）`);
    } else if (key === 'r') {
      reloads += 1;
      log(`→ 已发送 r 热重载（${reason}）`);
    } else {
      log(`→ 已发送 ${key}（${reason}）`);
    }
    return true;
  } catch (err) {
    log(`写 stdin 失败：${String(err)}`);
    return false;
  }
}

function startFlutter() {
  if (!fs.existsSync(path.join(appDir, 'pubspec.yaml'))) {
    log(`[x] 找不到 ${appDir}\\pubspec.yaml`);
    process.exit(1);
  }
  log(`启动：${FLUTTER} ${args.join(' ')}`);
  log(`工作目录：${appDir}`);
  startedAt = Date.now();
  // 走 cmd.exe 包一层：Windows 上 flutter 是 .bat，必须经 shell 才能跑；
  // stdio 里 stdin 用 pipe（我们要往里写命令），stdout/stderr 直通控制台。
  // 注意：`cmd /c` 对「命令本身带引号」的解析有坑，所以这里假设 flutter 可执行文件
  // 路径不含空格（dev.bat 里 `call %FLUTTER% run` 也是同一假设）。
  child = spawn('cmd.exe', ['/c', FLUTTER, ...args], {
    cwd: appDir,
    stdio: ['pipe', 'inherit', 'inherit'],
    windowsHide: false,
  });
  child.on('exit', (code, signal) => {
    if (code !== 0 && code !== null) {
      log(`flutter 退出（code=${code}）。若这里是 64，多半是参数写错（比如漏了 run 子命令）`);
    } else {
      log(`flutter 退出（code=${code} signal=${signal}）`);
    }
    child = null;
    server.close(() => {});
    process.exit(typeof code === 'number' ? code : 0);
  });
  child.on('error', (err) => {
    log(`[x] 启动失败：${String(err)}`);
    process.exit(1);
  });
}

// ---------------------------------------------------------------- 自动 R

let timer = null;

function scheduleRestart(file) {
  clearTimeout(timer);
  timer = setTimeout(() => {
    sendKey('R', `文件变化 ${file}`);
  }, AUTO_RESTART_DEBOUNCE_MS);
}

function watch(target) {
  const full = path.isAbsolute(target) ? target : path.join(repo, target);
  if (!fs.existsSync(full)) return;
  const isDir = fs.statSync(full).isDirectory();
  if (isDir) {
    fs.watch(full, { recursive: true }, (_ev, filename) => {
      if (!filename) return;
      if (/(^|[/\\])(node_modules|\.dart_tool|build|\.git)([/\\]|$)/.test(filename)) return;
      if (!/\.(dart|yaml)$/.test(filename)) return;
      scheduleRestart(path.join(target, String(filename)));
    });
  } else {
    fs.watch(full, () => scheduleRestart(target));
  }
}

// ---------------------------------------------------------------- 窗口输入转发

/**
 * stdin 被我们接管之后，**窗口里本来敲不了 R 了** —— 那是接管 stdin 的代价。
 * 这里把控制台上的 r / R / q 再转发给 flutter，两条路都留着：
 * 想手敲还是能手敲（敲完记得回车，控制台是行模式），不想敲就靠自动 / HTTP。
 * 只转发这三个字符，别的东西一律丢掉，免得误触别的 flutter 命令。
 */
function forwardConsoleInput() {
  if (!process.stdin.isTTY) return;
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    for (const ch of String(chunk)) {
      if (ch === 'R') sendKey('R', '窗口手动输入');
      else if (ch === 'r') sendKey('r', '窗口手动输入');
      else if (ch === 'q') sendKey('q', '窗口手动输入');
    }
  });
  process.stdin.on('error', () => {
    /* 窗口关了就算了，flutter 那边还有 SIGINT 兜底 */
  });
}

// ---------------------------------------------------------------- 控制口

const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', `http://127.0.0.1:${CTL_PORT}`);

  // 只接受本机 + 可选 token：这口能重启/退出开发进程，不该被随便一页 JS 碰到
  const origin = String(req.socket.remoteAddress || '');
  if (!/^(::1|::ffff:127\.0\.0\.1|127\.0\.0\.1)$/.test(origin)) {
    res.writeHead(403, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'loopback only' }));
    return;
  }
  if (CTL_TOKEN) {
    const got = url.searchParams.get('token') || String(req.headers['x-ctl-token'] || '');
    if (got !== CTL_TOKEN) {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad token' }));
      return;
    }
  }

  const route = url.pathname.replace(/\/+$/, '') || '/';
  const reply = (body) => {
    res.writeHead(200, {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      // 允许浏览器端 DevTools 面板直接点（仅本机；不带凭证也能过预检）
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'x-ctl-token, content-type',
    });
    res.end(JSON.stringify(body));
  };

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'x-ctl-token, content-type',
      'access-control-allow-methods': 'GET, POST, OPTIONS',
    });
    res.end();
    return;
  }

  if (route === '/status' || route === '/') {
    reply({
      running: child != null,
      pid: child ? child.pid : null,
      uptimeMs: startedAt ? Date.now() - startedAt : 0,
      restarts,
      reloads,
      lastRestartAt: lastRestartAt || null,
      lastRestartReason: lastRestartReason || null,
      flutterArgs: args,
      ctlPort: CTL_PORT,
    });
    return;
  }

  // 大写 R = 热重启（会丢状态、重新跑 main），小写 r = 热重载
  if (route === '/hot-restart' || route === '/restart' || route === '/R') {
    const ok = sendKey('R', 'HTTP 手动触发');
    reply({ ok, sent: 'R', restarts });
    return;
  }
  if (route === '/hot-reload' || route === '/reload' || route === '/r') {
    const ok = sendKey('r', 'HTTP 手动触发');
    reply({ ok, sent: 'r', reloads });
    return;
  }
  if (route === '/quit' || route === '/q') {
    const ok = sendKey('q', 'HTTP 手动触发');
    reply({ ok, sent: 'q' });
    return;
  }

  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(
    JSON.stringify({
      error: 'unknown route',
      routes: ['/status', '/hot-restart', '/hot-reload', '/quit'],
    }),
  );
});

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    log(`[!] 控制口 ${CTL_PORT} 已被占用（旧的 flutter-dev 还在跑？）`);
    log('    本次仍会启动 flutter，但 R 只能靠自动监视 / 窗口里手敲');
    return;
  }
  log(`[!] 控制口异常：${String(err)}`);
});

function shutdown(sig) {
  log(`收到 ${sig}，退出…`);
  sendKey('q', `进程收到 ${sig}`);
  setTimeout(() => {
    try {
      if (child) child.kill();
    } catch {
      /* 已退出 */
    }
    process.exit(0);
  }, 800);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

startFlutter();
forwardConsoleInput();
server.listen(CTL_PORT, '127.0.0.1', () => {
  log(`控制口就绪 http://127.0.0.1:${CTL_PORT}/status${CTL_TOKEN ? '（需 token）' : ''}`);
  log(`  POST /hot-restart  → 等价按 R${CTL_TOKEN ? `?token=${CTL_TOKEN}` : ''}`);
  log(`  POST /hot-reload   → 等价按 r`);
  log(`  POST /quit         → 等价按 q`);
});
for (const t of RESTART_WATCH) watch(t);
log(`自动热重启监视：${RESTART_WATCH.join('、')}`);
