import { app, Menu, Tray, dialog, nativeImage, shell, utilityProcess } from 'electron';
import path from 'node:path';
import fs from 'node:fs';
import { WatchdogSupervisor } from '../kernel/watchdog-supervisor';
import type { WatchdogMetrics } from '../kernel/watchdog';
import { isAutostartEnabled, setAutostart, syncAutostart } from './autostart';

/**
 * 「服务端」外壳：**纯托盘 + 内核守护**，不创建任何窗口。
 *
 * 设计取舍（2026-11-10 按用户要求收敛）：
 *   服务端只需要三件事 —— 右下角托盘图标、右键菜单（打开 Web 页面 / 开机自动启动 / 退出）、
 *   以及把内核跑起来并看住它。界面一律用系统浏览器打开 `http://127.0.0.1:<port>`，
 *   不再内嵌 BrowserWindow：省一份 Chromium 渲染进程，也避免「托盘点开是个窗口、
 *   浏览器里又是另一个会话」的两套 UI 问题。
 *
 * 保留的关键能力：
 *   - 单实例锁（第二次启动只打开 Web 页面）
 *   - 内核崩溃自动重启（最多 5 次）+ 进程外看门狗（心跳超时 / CPU 打满）
 *   - 退出前让内核优雅收尾：停种子（发 tracker 的 stopped）→ 停内置 transmission
 */

const PORT = Number(process.env.PORT || 7788);
/** 实际监听端口：内核按 config 的 httpPort 监听后通过 `listening` 消息回传 */
let kernelPort = PORT;
const kernelUrl = (): string => `http://127.0.0.1:${kernelPort}`;
const MAX_RESTARTS = 5;

/**
 * 启动阶段日志：Windows GUI 形态下 stdout/stderr 会被丢弃（打包后排查首启失败
 * 只能看到"进程没了"）。设置 `COLANAS_LAUNCH_LOG=<文件>` 即可把关键阶段落盘。
 */
const LAUNCH_LOG = process.env.COLANAS_LAUNCH_LOG;
function trace(stage: string): void {
  if (!LAUNCH_LOG) return;
  try {
    fs.appendFileSync(LAUNCH_LOG, `${new Date().toISOString()} ${stage}\n`);
  } catch {
    /* 日志不可写不影响启动 */
  }
}
trace(`boot pid=${process.pid} packaged=${app.isPackaged}`);

/** 进程外看门狗：内核 5 分钟无心跳（或 always 模式下 CPU 持续打满）即杀进程重启 */
const guard = new WatchdogSupervisor();
let watchdogTimer: NodeJS.Timeout | null = null;
let watchdogGaveUp = false;

let kernel: Electron.UtilityProcess | null = null;
let tray: Tray | null = null;
let quitting = false;
let crashes = 0;
/** 内核是否已经回传监听端口：没就绪时点「打开 Web 页面」只提示，不打开空白页 */
let kernelReady = false;

// userData 固定成历史路径：产品名从 `ColaNasOs` 改成 `ColaNasOs 服务端` 后，
// Electron 默认会跟着换目录 —— 数据（SQLite）在 APPDATA\colanas_os_server 不受影响，
// 但单实例锁与 Chromium 缓存按 userData 区分，换了就会和已装的旧实例同时跑。
const baseUserData = path.join(app.getPath('appData'), 'colanas_os_server');
try {
  fs.mkdirSync(baseUserData, { recursive: true });
  app.setPath('userData', baseUserData);
} catch (err) {
  trace(`userData pin failed: ${String(err)}`);
}

// 开发实例与日常实例隔离：锁绑定在 userData 路径上，开发实例用独立 userData，
// 两个实例可以同时在线（不再「必须关掉日常实例才能调试」）。
if (process.env.COLANAS_DEV_INSTANCE === '1') {
  app.setPath('userData', path.join(app.getPath('userData'), 'dev-instance'));
  trace(`userData(dev)=${app.getPath('userData')}`);
}

// 显式覆盖 userData（安装包冒烟 / 运维多实例隔离）：必须在单实例锁之前设置，
// 否则两个进程会抢同一把锁。注意 Electron 不接受 `--user-data-dir` 启动参数；
// `app.setPath` 要求目录存在，这里先建。
const userDataOverride = process.env.COLANAS_USER_DATA_DIR;
if (userDataOverride) {
  const dir = path.resolve(userDataOverride);
  fs.mkdirSync(dir, { recursive: true });
  app.setPath('userData', dir);
  trace(`userData=${dir}`);
}

// 单实例：第二次启动直接把 Web 页面打开（没有窗口可聚焦）
const locked = app.requestSingleInstanceLock();
trace(`singleInstance=${locked}`);
if (!locked) {
  app.quit();
} else {
  app.on('second-instance', () => openWeb());
}

function resourcesDir(): string {
  return app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', '..', 'resources');
}

function startKernel(): void {
  if (quitting) return;
  trace('startKernel');

  // 安装包形态：Flutter Web 产物在 `resources/web`（见 electron-builder.js），
  // 契约在 `resources/contracts`，不能沿用仓库内的相对路径。
  const env: NodeJS.ProcessEnv = { ...process.env };
  // 未显式指定 PORT（运维 / 冒烟）时让内核读取 config 的 httpPort；
  // 显式 PORT 仍然优先，避免破坏测试对固定端口的依赖。
  if (!process.env.PORT) delete env.PORT;
  if (app.isPackaged) {
    env.COLANAS_WEB_DIR = path.join(process.resourcesPath, 'web');
    env.COLANAS_CONTRACTS_DIR = path.join(process.resourcesPath, 'contracts');
    // 地名与行政区划随包分发：安装版的记忆页 / 地图才能显示省市区。
    const geoDir = path.join(process.resourcesPath, 'geo');
    env.COLANAS_GEONAMES = path.join(geoDir, 'geonames.sqlite');
    env.COLANAS_CHINA_DIVISIONS = path.join(geoDir, 'china-divisions.json');
    // 内置 transmission-daemon：内核在没配置外部下载器时直接拉起它
    env.COLANAS_TRANSMISSION_BIN_DIR = path.join(process.resourcesPath, 'transmission-daemon');
    // 内置 transmission Web UI（静态）：内核 /transmission/web/* 从这里读
    env.COLANAS_TRANSMISSION_WEB_DIR = path.join(process.resourcesPath, 'transmission-web');
    const modelsDir = path.join(process.resourcesPath, 'models');
    if (fs.existsSync(modelsDir)) env.COLANAS_MODEL_DIR = modelsDir;
  }

  kernel = utilityProcess.fork(path.join(__dirname, 'kernel-host.js'), [], {
    stdio: 'inherit',
    serviceName: 'colanas-kernel',
    env,
  });
  trace(`kernel forked pid=${kernel.pid}`);

  kernel.on('message', (msg: unknown) => {
    const payload = msg as { type?: string; metrics?: WatchdogMetrics; port?: number } | null;
    if (payload && payload.type === 'listening') {
      const p = Number(payload.port);
      if (Number.isFinite(p) && p > 0) kernelPort = p;
      kernelReady = true;
      trace(`kernel listening port=${kernelPort}`);
      // 托盘提示里直接给地址：用户鼠标悬停就知道服务在哪
      tray?.setToolTip(`ColaNasOs 服务端 — ${kernelUrl()}`);
      return;
    }
    if (payload && payload.type === 'heartbeat') {
      guard.beat(Date.now(), payload.metrics ?? {});
    }
  });

  kernel.on('exit', (code) => {
    trace(`kernel exit code=${code}`);
    kernel = null;
    kernelReady = false;
    tray?.setToolTip('ColaNasOs 服务端 — 内核重启中');
    if (quitting) return;

    crashes += 1;
    if (crashes > MAX_RESTARTS) {
      const msg = `内核连续退出 ${crashes} 次（最后一次退出码 ${code}），已停止自动重启。`;
      console.error('[shell]', msg);
      tray?.setToolTip('ColaNasOs 服务端 — 内核已停止');
      dialog.showErrorBox('ColaNasOs', msg);
      return;
    }

    const delay = Math.min(1000 * 2 ** (crashes - 1), 8000);
    console.error(`[shell] kernel exited (code=${code}), restart #${crashes} in ${delay}ms`);
    setTimeout(startKernel, delay);
  });
}

function stopKernel(): void {
  if (!kernel) return;
  kernel.kill();
  kernel = null;
  kernelReady = false;
}

/**
 * 退出应用前让内核优雅收尾：停种子（向 tracker 发 stopped）→ 杀内置 transmission。
 *
 * 为什么必须由外壳发起：daemon 是 detached 常驻进程，内核被 kill（开发期重启、
 * 崩溃重启）时**故意不动它**，否则每次重启都是一次新的 tracker 请求，PT 站会
 * 累计成「多个做种位置」。只有用户真的退出应用，才需要把下载器一起停掉 ——
 * 「因为软件才拉起来的，退软件就该一起退」。
 *
 * 内核回 `shutdown-done` 后立刻退出；最多等 4s（发 stopped + 落日志足够），
 * 超时就直接杀，别把退出流程卡死。
 */
async function shutdownKernelGracefully(timeoutMs = 4000): Promise<void> {
  const proc = kernel;
  if (!proc) return;
  await new Promise<void>((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(finish, timeoutMs);
    proc.once('message', (msg: unknown) => {
      if ((msg as { type?: string } | null)?.type === 'shutdown-done') finish();
    });
    proc.once('exit', finish);
    try {
      proc.postMessage({ type: 'shutdown' });
    } catch {
      finish();
    }
  });
}

/** 用系统默认浏览器打开服务端 Web 页面（服务端自己没有窗口） */
function openWeb(): void {
  if (!kernelReady) {
    // 内核还没回传端口：这时候打开浏览器只会看到连接被拒，先给个明确提示
    void dialog.showMessageBox({
      type: 'info',
      title: 'ColaNasOs 服务端',
      message: '服务正在启动，请稍候再试',
      detail: `端口 ${kernelPort}，就绪后会自动更新托盘提示。`,
      buttons: ['好'],
    });
    return;
  }
  void shell.openExternal(`${kernelUrl()}/`);
}

function createTray(): void {
  // 托盘图标 = 品牌图单独渲染的 16/32 两档，按 DPI 交给系统挑：
  // 100% 缩放用 16×16 原始像素，150%/200% 用 32×32，不会把大图缩放糊掉。
  // 以前这里是脚本画的「紫底白圈」，跟安装包图标完全不是一套。
  const dir = resourcesDir();
  const trayIcon = ((): ReturnType<typeof nativeImage.createEmpty> => {
    const img = nativeImage.createEmpty();
    for (const [scaleFactor, name] of [
      [1, 'tray16.png'],
      [2, 'tray.png'],
    ] as const) {
      try {
        const file = path.join(dir, name);
        if (fs.existsSync(file)) {
          img.addRepresentation({ scaleFactor, buffer: fs.readFileSync(file) });
        }
      } catch (err) {
        trace(`tray icon ${name} failed: ${String(err)}`);
      }
    }
    if (img.isEmpty() || img.getScaleFactors().length === 0) {
      const fallback = nativeImage.createFromPath(path.join(dir, 'tray.png'));
      return fallback.isEmpty() ? nativeImage.createEmpty() : fallback;
    }
    return img;
  })();
  tray = new Tray(trayIcon);
  tray.setToolTip('ColaNasOs 服务端 — 启动中');
  rebuildTrayMenu();
  // 左键单击 = 打开 Web 页面（托盘程序的习惯动作）
  tray.on('click', () => openWeb());
  // Windows 上双击也走一次：有人习惯双击托盘
  tray.on('double-click', () => openWeb());
}

function rebuildTrayMenu(): void {
  if (!tray) return;
  const startOnBoot = isAutostartEnabled();
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: '打开 Web 页面', click: () => openWeb() },
      {
        label: '开机自动启动',
        type: 'checkbox',
        checked: startOnBoot,
        click: (item) => {
          // 落盘到数据目录 config.json（默认 false），再按当前 exe 写系统启动项。
          // 开发态只记状态、不动注册表，免得把安装版的启动项改成 electron.exe。
          setAutostart(item.checked);
          trace(`autostart=${item.checked}`);
          rebuildTrayMenu();
        },
      },
      { type: 'separator' },
      {
        label: '退出',
        click: () => {
          // 别在这里置 quitting：before-quit 靠它判断「第一次退出」，
          // 提前置 true 会把停种子 / 停内置下载器的优雅关闭整段跳过。
          app.quit();
        },
      },
    ]),
  );
}

app.whenReady().then(() => {
  trace('app ready');
  // 托盘勾选状态来源是数据目录里的设置；顺带按当前 exe 路径对账系统启动项
  const autostart = syncAutostart();
  console.log(`[shell] ColaNasOs 服务端 ${app.getVersion()} 启动（开机自启=${autostart ? '开' : '关'}）`);
  startKernel();
  createTray();

  // 进程外看门狗：内核「端口还在听但卡死」时也能拉回来
  watchdogTimer = setInterval(() => {
    const decision = guard.check(Date.now());
    if (decision.action === 'restart' && !watchdogGaveUp) {
      console.error('[watchdog] kernel unresponsive, restart:', decision);
      crashes = 0;
      stopKernel();
      startKernel();
    } else if (decision.action === 'giveup' && !watchdogGaveUp) {
      watchdogGaveUp = true;
      const msg = '内核多次无响应，已停止自动重启（详见 watchdog.log）。';
      console.error('[watchdog]', msg);
      dialog.showErrorBox('ColaNasOs', msg);
    }
  }, 5000);
  watchdogTimer.unref?.();

  // macOS 点 Dock 图标：打开 Web 页面
  app.on('activate', () => openWeb());
});

app.on('before-quit', (e) => {
  if (quitting) return;
  // 先拦住这次退出，等内核把下载器停干净（最多 4s）再真正退出。
  // 不拦的话 Electron 会立刻走进程销毁，内核来不及发 tracker 的 stopped。
  e.preventDefault();
  quitting = true;
  if (watchdogTimer) clearInterval(watchdogTimer);
  void (async () => {
    try {
      await shutdownKernelGracefully();
    } catch {
      /* 内核已崩/已退：忽略 */
    }
    stopKernel();
    app.exit(0);
  })();
});
