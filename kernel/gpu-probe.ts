import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

/**
 * Windows 显卡信息探针（方案 B：注册表静态信息 + GPU 性能计数器）。
 *
 * 为什么要子进程：
 *   Node 没有读取 Windows 性能计数器（PDH）的能力，也没有注册表 API；
 *   `Get-Counter` 单次固定 1.6~1.9s（内部要等两次采样），`typeperf` 只认本地化计数器名，
 *   两者都只能放在后台。
 *
 * 为什么是「常驻一个 PowerShell + 空闲自动退出」：
 *   - 每 3s 起一次进程要付 PowerShell 启动开销（约 200~400ms CPU），远超采样本身；
 *   - 逐实例 new PerformanceCounter 实测 35% 单核（本机 421 个 GPU 引擎实例）；
 *   - 实际用 PerformanceCounterCategory.ReadCategory 批量读 + RawValue 差分，6 次采样共 0.06s CPU；
 *   - 即便这样，没人看监控时也不该占内存，所以 60s 无请求就退出。
 *
 * 契约：`/system/monitor` 只读这里的内存缓存，**请求路径上永远不产生子进程**。
 */

export interface GpuInfo {
  name: string;
  driverVersion: string;
  usagePercent: number;
  memUsed: number;
  memTotal: number;
}

interface StaticInfo {
  name: string;
  driverVersion: string;
  memTotal: number;
}

interface SampleInfo {
  at: number;
  usage: number;
  memUsed: number;
}

/** 多少毫秒没有 /monitor 请求就停掉探针（无人看监控时零占用） */
const IDLE_STOP_MS = 60_000;
/** 采样超过这个时间没更新视为陈旧（进程卡死/被杀），返回 null 而不是旧值 */
const SAMPLE_STALE_MS = 15_000;
/** 意外退出后的重启冷却，避免崩溃循环 */
const RESTART_COOLDOWN_MS = 30_000;

class GpuProbe {
  private child: ChildProcess | null = null;
  private stopping = false;
  private buf = '';
  private statics: StaticInfo | null = null;
  private sample: SampleInfo | null = null;
  private lastTouch = 0;
  private lastExitAt = 0;
  private janitor: NodeJS.Timeout | null = null;
  private resolvedScript = '';

  /** 静态信息：启动时读一次注册表；采样：每 3s 一行 JSON */
  private scriptPath(): string {
    if (this.resolvedScript) return this.resolvedScript;
    const env = process.env.COLANAS_GPU_PROBE;
    // 开发态在仓库根；打包态 sidecars 在 <安装目录>/resources/sidecars（extraResources）
    const resourcesPath = (process as unknown as { resourcesPath?: string }).resourcesPath;
    const candidates = [
      env && env.trim() ? env.trim() : '',
      path.join(__dirname, '..', '..', 'sidecars', 'gpu', 'gpu-probe.ps1'),
      path.join(process.cwd(), 'sidecars', 'gpu', 'gpu-probe.ps1'),
      resourcesPath ? path.join(resourcesPath, 'sidecars', 'gpu', 'gpu-probe.ps1') : '',
      path.join(path.dirname(process.execPath), 'resources', 'sidecars', 'gpu', 'gpu-probe.ps1'),
    ].filter((p) => p && fs.existsSync(p));
    this.resolvedScript = candidates[0] ?? path.join(process.cwd(), 'sidecars', 'gpu', 'gpu-probe.ps1');
    return this.resolvedScript;
  }

  /** 只读缓存；同时把「有人在看」告诉探针，用来推迟空闲退出 */
  info(): GpuInfo | null {
    if (process.platform !== 'win32') return null;
    this.lastTouch = Date.now();
    this.ensureStarted();
    this.ensureJanitor();
    const st = this.statics;
    const s = this.sample;
    // 静态信息（名字 / 驱动 / 显存）来自注册表，比第一次采样早 ~1s 到。
    // 只认采样的话，刚打开页面那一下会显示「未检测到」，而详情页过两秒又有了 ——
    // 看起来像两处逻辑不一致（2026-11-03 反馈）。
    const placeholder = (): GpuInfo | null =>
      st
        ? {
            name: st.name,
            driverVersion: st.driverVersion,
            usagePercent: 0,
            memUsed: 0,
            memTotal: st.memTotal,
          }
        : null;
    if (!s) return placeholder();
    if (Date.now() - s.at > SAMPLE_STALE_MS) return placeholder();
    return {
      name: st?.name || 'GPU',
      driverVersion: st?.driverVersion || '',
      usagePercent: s.usage,
      memUsed: s.memUsed,
      memTotal: st?.memTotal || 0,
    };
  }

  /** 内核关闭时调用 */
  stop(): void {
    if (this.janitor) {
      clearInterval(this.janitor);
      this.janitor = null;
    }
    const child = this.child;
    this.child = null;
    this.sample = null;
    if (!child) return;
    this.stopping = true;
    try {
      child.kill();
    } catch {
      /* 已退出 */
    }
  }

  private ensureJanitor(): void {
    if (this.janitor) return;
    this.janitor = setInterval(() => {
      if (this.child && Date.now() - this.lastTouch > IDLE_STOP_MS) this.stop();
    }, 15_000);
    this.janitor.unref?.();
  }

  private ensureStarted(): void {
    if (this.child || this.stopping) return;
    if (Date.now() - this.lastExitAt < RESTART_COOLDOWN_MS) return;
    const script = this.scriptPath();
    if (!fs.existsSync(script)) return;

    let child: ChildProcess;
    try {
      child = spawn(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
        { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] },
      );
    } catch {
      this.lastExitAt = Date.now();
      return;
    }
    this.child = child;
    this.buf = '';
    this.lastTouch = Date.now();

    child.stdout?.on('data', (chunk: Buffer | string) => this.onData(chunk.toString()));
    child.on('error', () => {
      if (this.child === child) this.child = null;
      this.lastExitAt = Date.now();
      this.sample = null;
    });
    child.on('exit', () => {
      if (this.child === child) this.child = null;
      // 主动停止（空闲/内核关闭）不算崩溃，不进入重启冷却
      if (!this.stopping) this.lastExitAt = Date.now();
      this.stopping = false;
      this.sample = null;
    });
  }

  private onData(chunk: string): void {
    this.buf += chunk;
    // 防御异常输出把缓冲撑爆
    if (this.buf.length > 256 * 1024) this.buf = '';
    for (;;) {
      const nl = this.buf.indexOf('\n');
      if (nl < 0) break;
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      this.handleLine(line);
    }
  }

  private handleLine(line: string): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    if (msg.t === 'statics') {
      const list = Array.isArray(msg.adapters) ? msg.adapters : [];
      const adapters = list
        .filter((a): a is Record<string, unknown> => !!a && typeof a === 'object')
        .map((a) => ({
          name: String(a.name ?? ''),
          driverVersion: String(a.driverVersion ?? ''),
          memTotal: Number(a.memTotal) || 0,
        }))
        .filter((a) => a.name);
      // 显存最大的适配器是主 GPU；虚拟显示器 memTotal=0，自然排在后面
      adapters.sort((a, b) => b.memTotal - a.memTotal);
      const main = adapters[0];
      if (main) {
        this.statics = { name: main.name, driverVersion: main.driverVersion, memTotal: main.memTotal };
      }
      return;
    }
    if (msg.t === 'sample') {
      const usage = Number(msg.usage);
      const memUsed = Number(msg.memUsed);
      if (!Number.isFinite(usage) || !Number.isFinite(memUsed)) return;
      this.sample = {
        at: Date.now(),
        usage: Math.max(0, Math.min(100, Math.round(usage * 10) / 10)),
        memUsed: Math.max(0, Math.round(memUsed)),
      };
    }
  }
}

export const gpuProbe = new GpuProbe();