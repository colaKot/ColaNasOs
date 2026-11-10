import { spawn, type ChildProcess } from 'node:child_process';
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
    const port = await pickPort(opts.port ?? 9091);
    if (currentPort && (await probe(`http://127.0.0.1:${port}/transmission/rpc`, 800))) {
      // 复用已有实例（可能是用户自己装的，也可能是上次残留）
      if (!child) return `http://127.0.0.1:${port}/transmission/rpc`;
    }
    if (!bin) {
      lastError = '没找到内置 transmission-daemon 二进制';
      return null;
    }

    const configDir = path.join(opts.dataDir, 'transmission');
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
    const proc = spawn(bin, args, {
      cwd: path.dirname(bin),
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child = proc;
    currentPort = port;
    lastError = '';

    const collect = (buf: Buffer) => {
      const text = buf.toString().trim();
      if (text) lastError = text.slice(-400);
    };
    proc.stdout?.on('data', collect);
    proc.stderr?.on('data', collect);

    proc.on('exit', (code) => {
      if (child === proc) child = null;
      if (code && code !== 0) lastError = `daemon 退出（code ${code}）：${lastError}`;
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
    lastError = lastError || 'daemon 起来了但 RPC 没响应';
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
 * 为什么需要：直接 kill 时 tracker 仍认为这个 peer 活着；下次启动 daemon 重新
 * announce，M-Team 这类 PT 站会判「同一个种子已在别处下载」并报
 * `You already are downloading the same torrent` —— 用户明明只在这台机器下过。
 * 开发期内核被反复重启时最容易撞上。
 */
export async function stopDaemonGracefully(): Promise<void> {
  if (!child) return;
  const url = daemonRpcUrl();
  try {
    // 动态 require 避免 daemon ↔ transmission 的顶层循环依赖
    const { torrentList, torrentAction } = await import('./transmission');
    const list = await torrentList({ url });
    const hashes = list.items.filter((t) => t.status !== 0).map((t) => t.hashString);
    if (hashes.length > 0) await torrentAction({ url }, 'stop', hashes);
    // 给 tracker 的 stopped 公告一点时间发出去
    await new Promise((resolve) => setTimeout(resolve, 800));
  } catch {
    /* 尽力而为：停不掉就直接杀 */
  }
  stopDaemon();
}

/** 内核退出时带走子进程，避免留下孤儿 */
export function stopDaemon(): void {
  if (!child) return;
  try {
    child.kill();
  } catch {
    /* ignore */
  }
  child = null;
  currentPort = 0;
}

// 内核退出（含崩溃）时带走 daemon，避免留下孤儿进程占着 9091
process.once('exit', stopDaemon);
process.once('SIGINT', () => {
  stopDaemon();
  process.exit(0);
});
