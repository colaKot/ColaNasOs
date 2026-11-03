import {
  app,
  BrowserWindow,
  Menu,
  Tray,
  dialog,
  nativeImage,
  shell,
  utilityProcess,
} from 'electron';
import path from 'node:path';
import fs from 'node:fs';
import { WatchdogSupervisor } from '../kernel/watchdog-supervisor';
import type { WatchdogMetrics } from '../kernel/watchdog';

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

let win: BrowserWindow | null = null;
let kernel: Electron.UtilityProcess | null = null;
let tray: Tray | null = null;
let quitting = false;
let crashes = 0;

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

// 单实例：第二次启动只聚焦既有窗口
const locked = app.requestSingleInstanceLock();
trace(`singleInstance=${locked}`);
if (!locked) {
  app.quit();
} else {
  app.on('second-instance', () => {
    showWindow();
  });
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
  // 显式 PORT 仍然优先，避免破坏 Docker / 测试对固定端口的依赖。
  if (!process.env.PORT) delete env.PORT;
  if (app.isPackaged) {
    env.COLANAS_WEB_DIR = path.join(process.resourcesPath, 'web');
    env.COLANAS_CONTRACTS_DIR = path.join(process.resourcesPath, 'contracts');
    // 地名与行政区划随包分发：安装版的记忆页 / 地图才能显示省市区。
    const geoDir = path.join(process.resourcesPath, 'geo');
    env.COLANAS_GEONAMES = path.join(geoDir, 'geonames.sqlite');
    env.COLANAS_CHINA_DIVISIONS = path.join(geoDir, 'china-divisions.json');
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
      trace(`kernel listening port=${kernelPort}`);
      if (win) {
        const webIndex = app.isPackaged
          ? path.join(process.resourcesPath, 'web', 'index.html')
          : path.join(__dirname, '..', '..', 'apps', 'colanas_os', 'build', 'web', 'index.html');
        void win.loadURL(
          fs.existsSync(webIndex) ? `${kernelUrl()}/` : `${kernelUrl()}/health`,
        );
      }
      return;
    }
    if (payload && payload.type === 'heartbeat') {
      guard.beat(Date.now(), payload.metrics ?? {});
    }
  });

  kernel.on('exit', (code) => {
    trace(`kernel exit code=${code}`);
    kernel = null;
    if (quitting) return;

    crashes += 1;
    if (crashes > MAX_RESTARTS) {
      const msg = `内核连续退出 ${crashes} 次（最后一次退出码 ${code}），已停止自动重启。`;
      console.error('[shell]', msg);
      tray?.setToolTip('ColaNasOs — 内核已停止');
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
}

function createWindow(): void {
  if (win) {
    showWindow();
    return;
  }

  win = new BrowserWindow({
    width: 1280,
    height: 800,
    show: false,
    title: 'ColaNasOs',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  win.once('ready-to-show', () => win?.show());
  win.on('closed', () => {
    win = null;
  });
  win.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: 'deny' };
  });

  // 有 Web 产物就加载应用（内核内置静态托管，同源免 CORS）；没有则退回健康页（SP0 形态）。
  // 安装包里产物在 `resources/web`（asar 内没有仓库相对路径），必须单独判断。
  const webIndex = app.isPackaged
    ? path.join(process.resourcesPath, 'web', 'index.html')
    : path.join(__dirname, '..', '..', 'apps', 'colanas_os', 'build', 'web', 'index.html');
  const targetUrl = fs.existsSync(webIndex) ? `${kernelUrl()}/` : `${kernelUrl()}/health`;

  // 渲染进程报错（页面里看到的红字多半来自这里）：落到 userData/ui.log，
// 便于用户点一遍后按时间定位，而不是只能看到一句「出错了」。
  const uiLog = path.join(app.getPath('userData'), 'ui.log');
  const writeUiLog = (line: string): void => {
    try {
      fs.appendFileSync(uiLog, `${new Date().toISOString()} ${line}\n`);
    } catch {
      /* 日志不可写不影响页面 */
    }
  };
  win.webContents.on('console-message' as any, (...args: any[]) => {
    const d = args[1];
    const level = typeof d === 'object' && d ? d.level : args[1];
    const message = typeof d === 'object' && d ? d.message : args[2];
    const source = typeof d === 'object' && d ? d.sourceId : args[4];
    const line = typeof d === 'object' && d ? d.lineNumber : args[3];
    if (level === 'error' || level === 'warning' || level === 3 || level === 2) {
      writeUiLog(`[console:${level}] ${message} (${source}:${line})`);
    }
  });
  win.webContents.on('render-process-gone' as any, (_e: unknown, details: unknown) => {
    writeUiLog(`[render-gone] ${JSON.stringify(details)}`);
  });

  // 内核（utilityProcess）通常比窗口慢 1~3s：首屏加载失败就短暂重试，
  // 否则窗口会停在 ERR_CONNECTION_REFUSED，用户需要手动刷新。
  let loadAttempt = 0;
  const retryLoad = (): void => {
    if (!win || loadAttempt >= 20) return;
    loadAttempt += 1;
    trace(`window reload attempt=${loadAttempt}`);
    setTimeout(() => {
      if (win) void win.loadURL(targetUrl);
    }, 500);
  };
  win.webContents.on('did-fail-load', (_event, code, desc, url, isMainFrame) => {
    if (!isMainFrame || code === -3) return; // -3 = 被新的 loadURL 取消
    trace(`window load failed code=${code} ${desc} url=${url}`);
    retryLoad();
  });
  void win.loadURL(targetUrl);
}

function showWindow(): void {
  if (!win) {
    createWindow();
    return;
  }
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

function createTray(): void {
  const icon = nativeImage.createFromPath(path.join(resourcesDir(), 'tray.png'));
  tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon);
  tray.setToolTip('ColaNasOs');
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: '打开主界面', click: () => showWindow() },
      { label: '在浏览器中打开', click: () => void shell.openExternal(`${kernelUrl()}/health`) },
      { type: 'separator' },
      {
        label: '重启内核',
        click: () => {
          crashes = 0;
          stopKernel();
          startKernel();
        },
      },
      { type: 'separator' },
      {
        label: '退出',
        click: () => {
          quitting = true;
          app.quit();
        },
      },
    ]),
  );
  tray.on('click', () => showWindow());
}

app.whenReady().then(() => {
  trace('app ready');
  startKernel();
  createWindow();
  createTray();

  // 进程外看门狗：内核「端口还在听但界面卡死」时也能拉回来
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

  app.on('activate', () => showWindow());
});

// 关窗不退出（常驻托盘），与 NAS 客户端习惯一致
app.on('window-all-closed', () => {
  /* keep running in tray */
});

app.on('before-quit', () => {
  quitting = true;
  if (watchdogTimer) clearInterval(watchdogTimer);
  stopKernel();
});
