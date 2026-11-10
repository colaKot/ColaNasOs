import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

/**
 * 内置 transmission-daemon（Windows 用官方 MSI 里的二进制，见 vendor/transmission-win/NOTICE.md）。
 *
 * 定位：让「下载器」栏目**开箱即用**——不再要求用户自己装 transmission。
 * 约束：
 *  - 只监听 127.0.0.1 + 不开鉴权：外部访问一律经内核的 `/transmission/*` 代理（那里有票据鉴权），
 *    daemon 自己不对局域网暴露；
 *  - 配置文件（`-g`）与下载目录（`-w`）都在 ColaNasOs 数据目录下，卸载即带走；
 *  - 崩了最多重启 3 次，之后把错误抛给上层（页面会显示原因），不无限重启刷日志。
 */
const MAX_RESTARTS = 3;

let child: ChildProcess | null = null;
let starting: Promise<string | null> | null = null;
let restarts = 0;
let lastError = '';
let currentPort = 0;
/** 内核重启后复用的那个 daemon 的 pid（不是本进程 spawn 的，但仍是我们拉起来的） */
let adoptedPid = 0;
/** `<configDir>/daemon.json`：记录我们拉起的 daemon 的 pid/port，跨内核重启有效 */
let infoPath = '';

/** 找内置二进制：env → 仓库 vendor → 安装包 resources；都没有则回空（退化为探测外部 daemon） */
export function daemonBinPath(): string {
  // 本项目只跑 Windows NAS：二进制名固定
  const names = ['transmission-daemon.exe'];
  // 内核可能从 dist/src/modules/pt 运行，cwd 也不一定是仓库根，
  // 所以按「env → 若干层 __dirname → cwd」都试一遍。
  const roots = [
    process.env.COLANAS_TRANSMISSION_BIN_DIR || '',
    path.resolve(__dirname, '..', '..', '..', '..', 'vendor', 'transmission-win'),
    path.resolve(__dirname, '..', '..', '..', '..', '..', 'vendor', 'transmission-win'),
    path.resolve(process.cwd(), 'vendor', 'transmission-win'),
    path.resolve(process.cwd(), '..', 'vendor', 'transmission-win'),
  ].filter(Boolean);
  for (const root of roots) {
    for (const name of names) {
      const file = path.join(root, name);
      try {
        if (fs.existsSync(file)) return file;
      } catch {
        /* 下一个 */
      }
    }
  }
  return '';
}

export function daemonRpcUrl(): string {
  return currentPort ? `http://127.0.0.1:${currentPort}/transmission/rpc` : '';
}

export function daemonStatus(): { running: boolean; url: string; error: string } {
  return { running: !!child && !child.killed, url: daemonRpcUrl(), error: lastError };
}


interface DaemonInfo {
  pid: number;
  port: number;
}

function writeDaemonInfo(pid: number, port: number): void {
  if (!infoPath) return;
  try {
    fs.mkdirSync(path.dirname(infoPath), { recursive: true });
    fs.writeFileSync(infoPath, JSON.stringify({ pid, port }), 'utf8');
  } catch {
    /* 写不了标记文件只影响「退出时能不能停掉」，不影响做种 */
  }
}

function readDaemonInfo(): DaemonInfo | null {
  if (!infoPath) return null;
  try {
    const raw = JSON.parse(fs.readFileSync(infoPath, 'utf8')) as DaemonInfo;
    return raw && Number(raw.pid) > 0 ? raw : null;
  } catch {
    return null;
  }
}

function clearDaemonInfo(): void {
  if (!infoPath) return;
  try {
    fs.unlinkSync(infoPath);
  } catch {
    /* 已经没了 */
  }
}

/**
 * 端口上正在 LISTENING 的进程 pid（Windows netstat）。
 * 「退出应用要停掉下载器」靠它把端口换回 pid —— 复用来的实例没有 ChildProcess 句柄。
 */
function pidOnPort(port: number): number {
  if (!port || process.platform !== 'win32') return 0;
  try {
    const r = spawnSync('netstat', ['-ano', '-p', 'TCP'], {
      encoding: 'utf8',
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024,
    });
    // 端口要带边界：光用 includes(':9091') 会误命中 19091 / 29091 这些备用端口。
    const bound = new RegExp(`:${port}(?=\\s|$)`, 'i');
    for (const line of String(r.stdout || '').split(/\r?\n/)) {
      if (!bound.test(line) || !/LISTENING/i.test(line)) continue;
      const parts = line.trim().split(/\s+/);
      const pid = Number(parts[parts.length - 1]);
      if (pid > 0) return pid;
    }
  } catch {
    /* 拿不到就当没有 */
  }
  return 0;
}

/**
 * 端口上的 transmission 是不是「我们拉起来的」：问它自己的 config-dir。
 *
 * 用 session-get 的 `config-dir` 判断，比查进程命令行轻得多，也不用碰 WMI ——
 * 用户自己装的 transmission 用别处的配置目录，绝不会被我们的退出流程误杀。
 */
async function isOurInstance(port: number): Promise<boolean> {
  if (!port || !infoPath) return false;
  const want = path.dirname(infoPath).replace(/\\/g, '/').toLowerCase();
  const url = `http://127.0.0.1:${port}/transmission/rpc`;
  const ask = async (sessionId?: string): Promise<boolean> => {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(sessionId ? { 'x-transmission-session-id': sessionId } : {}),
      },
      body: JSON.stringify({ method: 'session-get' }),
    });
    const sid = res.headers.get('x-transmission-session-id');
    if (res.status === 409 && sid) return ask(sid);
    const j = (await res.json()) as { arguments?: Record<string, unknown> };
    const got = String(j?.arguments?.['config-dir'] || '')
      .replace(/\\/g, '/')
      .toLowerCase();
    return !!got && got === want;
  };
  try {
    return await ask();
  } catch {
    return false;
  }
}

async function probe(url: string, timeoutMs = 1500): Promise<boolean> {
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ method: 'session-get' }),
      signal: ctl.signal,
    });
    clearTimeout(timer);
    return res.status === 200 || res.status === 409;
  } catch {
    return false;
  }
}

async function pickPort(preferred: number): Promise<number> {
  for (const port of [preferred, 19091, 29091, 39091]) {
    const url = `http://127.0.0.1:${port}/transmission/rpc`;
    // 端口上已经是一个 transmission：直接用，不再拉起第二个
    if (await probe(url, 800)) {
      currentPort = port;
      return port;
    }
  }
  return preferred;
}

/**
 * 确保内置 daemon 在跑；返回 RPC 地址（失败返回 null）。
 * 已经有外部 daemon 占着首选端口时，直接复用那个（不重复启动）。
 */
export async function ensureDaemon(opts: {
  dataDir: string;
  downloadDir: string;
  port?: number;
}): Promise<string | null> {
  if (child && !child.killed && currentPort) return daemonRpcUrl();
  if (starting) return starting;

  starting = (async () => {
    const bin = daemonBinPath();
    const configDir = path.join(opts.dataDir, 'transmission');
    infoPath = path.join(configDir, 'daemon.json');
    const port = await pickPort(opts.port ?? 9091);
    if (currentPort && (await probe(`http://127.0.0.1:${port}/transmission/rpc`, 800))) {
      // 复用已有实例：可能是内核重启前我们拉起的那个（标记文件还在），
      // 也可能是用户自己装的 transmission。只有前者记成「我们的」，
      // 退出应用时才敢停；外部的一律不动。
      if (!child) {
        if (await isOurInstance(port)) {
          const pid = pidOnPort(port);
          adoptedPid = pid;
          // 补写标记：旧版本内核留下的 daemon 没有 daemon.json，
          // 认回来的这一步顺便把它补上，之后「退出应用」才停得掉。
          if (pid) writeDaemonInfo(pid, port);
        } else {
          adoptedPid = 0;
        }
        return `http://127.0.0.1:${port}/transmission/rpc`;
      }
    }
    if (!bin) {
      lastError = '没找到内置 transmission-daemon 二进制';
      return null;
    }

    try {
      fs.mkdirSync(configDir, { recursive: true });
      fs.mkdirSync(opts.downloadDir, { recursive: true });
    } catch {
      /* 目录建不出来就让 daemon 自己报错 */
    }

    const args = [
      '-f', // 前台运行，便于守护
      '-g', configDir,
      '-w', opts.downloadDir,
      '-p', String(port),
      '-r', '127.0.0.1', // RPC 只听本机；外部访问走内核代理
      '-T', // 不开鉴权（本机回环 + 内核代理已做鉴权）
      '--no-portmap', // 别去改路由器，避免 Windows 防火墙弹窗
    ];
    // 输出落文件：detached 之后没有管道可读，daemon 崩了要能从日志里看原因
    const logFile = path.join(configDir, 'daemon.log');
    let outFd: number | 'ignore';
    try {
      outFd = fs.openSync(logFile, 'a');
    } catch {
      outFd = 'ignore';
    }
    // detached + unref：daemon **不跟着内核进程死**。
    // 这条很关键：内核每重启一次（开发期改代码会重启几十次），如果 daemon 跟着重启，
    // transmission 会以新 peer-id 重新 announce，而旧 session 没来得及发 stopped，
    // M-Team 那边就把每次重启当成一个「做种位置」，攒到 3 个以上直接拒绝 announce：
    // `You cannot seed the same torrent from more than 3 locations.`（2026-11-10 复现）
    const proc = spawn(bin, args, {
      cwd: path.dirname(bin),
      windowsHide: true,
      detached: true,
      stdio: ['ignore', outFd, outFd],
    });
    proc.unref();
    if (typeof outFd === 'number') {
      try {
        fs.closeSync(outFd);
      } catch {
        /* 子进程已继承句柄，父进程这份关掉即可 */
      }
    }
    child = proc;
    currentPort = port;
    adoptedPid = 0;
    lastError = '';
    // 记下 pid/port：内核重启后新进程靠它认回「这是我们拉起来的 daemon」，
    // 用户退出应用时才知道该停谁（外部 transmission 则不会写这个文件）。
    if (proc.pid) writeDaemonInfo(proc.pid, port);

    const readTail = (): string => {
      try {
        return fs.readFileSync(logFile, 'utf8').slice(-400).trim();
      } catch {
        return '';
      }
    };

    proc.on('exit', (code) => {
      if (child === proc) child = null;
      if (code && code !== 0) lastError = `daemon 退出（code ${code}）：${readTail()}`;
      // 非主动退出：有限次重启
      if (code && restarts < MAX_RESTARTS) {
        restarts += 1;
        currentPort = 0;
        void ensureDaemon(opts).catch(() => {});
      }
    });

    // 等它把 RPC 端口开起来
    for (let i = 0; i < 40; i += 1) {
      if (await probe(`http://127.0.0.1:${port}/transmission/rpc`, 800)) {
        return `http://127.0.0.1:${port}/transmission/rpc`;
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    lastError = lastError || readTail() || 'daemon 起来了但 RPC 没响应';
    return null;
  })();

  try {
    return await starting;
  } finally {
    starting = null;
  }
}

/**
 * 优雅停止：先让所有活动种子停下来（Transmission 会向 tracker 发 event=stopped），
 * 再杀进程。
 *
 * 谁调用：
 * - 用户**退出应用**：外壳 → 内核 app.close() → pt 模块 onClose → 这里；
 * - 内核被 kill（开发期改代码重启、崩溃重启）：**不会**走到这里，daemon 继续做种。
 *
 * 能停的对象有两类：
 * - 本进程刚 spawn 的（`child`）；
 * - 内核重启前我们拉起、这次复用的（`adoptedPid`，靠 `<configDir>/daemon.json` 认回）。
 * 用户自己装的 transmission 没有标记文件，碰都不碰。
 */
export async function stopDaemonGracefully(): Promise<void> {
  const info = readDaemonInfo();
  const port = currentPort || info?.port || 0;
  // 复用来的实例没有 ChildProcess 句柄：按「端口上现在是谁」拿 pid，
  // 并且要求它就是我们记下的那个，避免 pid 复用杀错进程。
  const reusedPid = port ? pidOnPort(port) : 0;
  // 复用的实例必须确实占着这个端口，且 pid 与「本次认回的」或「标记文件里的」
  // 一致，否则 pid 被别的进程复用时会误杀。
  const confirmed =
    reusedPid && (adoptedPid === reusedPid || info?.pid === reusedPid) ? reusedPid : 0;
  const pid = child?.pid || confirmed;
  const url = daemonRpcUrl() || (port ? `http://127.0.0.1:${port}/transmission/rpc` : '');
  if (!url && !pid) return;

  try {
    if (url) {
      // 动态 require 避免 daemon ↔ transmission 的顶层循环依赖
      const { torrentList, torrentAction } = await import('./transmission');
      const list = await torrentList({ url });
      // 批量动作必须用**数字 id**：传 hashString 会返回 success 但状态不变
      // （4.1.4 上实测过），等于没停，tracker 那边就留下一个死 session。
      const ids = list.items.filter((t) => t.status !== 0).map((t) => String(t.id));
      if (ids.length > 0) await torrentAction({ url }, 'stop', ids);
      // 给 tracker 的 stopped 公告一点时间发出去
      await new Promise((resolve) => setTimeout(resolve, 1500));
    }
  } catch {
    /* 尽力而为：停不掉就直接杀 */
  }

  if (child) {
    stopDaemon();
    return;
  }
  // 复用来的实例：本进程没有句柄，只能按 pid 杀（pid 已确认是端口上这个 daemon）
  if (pid) {
    try {
      process.kill(pid);
    } catch {
      /* 已经退了 */
    }
  }
  adoptedPid = 0;
  currentPort = 0;
  clearDaemonInfo();
}

/** 停止本进程 spawn 的 daemon（内核退出时**不再自动调用**，见文件末尾说明） */
export function stopDaemon(): void {
  if (!child) return;
  try {
    child.kill();
  } catch {
    /* ignore */
  }
  child = null;
  currentPort = 0;
  adoptedPid = 0;
  clearDaemonInfo();
}

// 内核退出**不带走 daemon**。
//
// 以前这里挂了 `process.once('exit', stopDaemon)`：内核一退出（开发期改代码、
// 崩溃重启都算）daemon 就被杀，下次启动再拉起一个——transmission 会用新的
// peer-id 重新 announce，旧 session 又来不及发 stopped，tracker 就把每次重启
// 记成一个做种位置，攒到 3 个就开始拒绝：`You cannot seed the same torrent
// from more than 3 locations.`（2026-11-10 定位）
//
// 现在 daemon 是 detached 常驻进程：内核重启后 ensureDaemon 探测到端口上已经有
// 实例，直接复用同一个 session，做种不中断，tracker 那边也只有一条记录。
// 真要停它用 stopDaemonGracefully()（会先给 tracker 发 stopped）。
