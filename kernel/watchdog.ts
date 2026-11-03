import fs from 'node:fs';
import path from 'node:path';
import { monitorEventLoopDelay } from 'node:perf_hooks';

/**
 * 进程内看门狗：解决「进程没崩、端口还在听、但界面卡死」的闷死故障。
 *
 * 采样与阈值（全部可用环境变量压低，便于真机造一个卡死再验证）：
 *
 * | 指标 | 采样 | 触发 |
 * | --- | --- | --- |
 * | 主进程 CPU | 30s | 窗口内持续 ≥95%（默认 5 分钟）⇒ error |
 * | 事件循环延迟 | 5s | 连续 3 次 > 3s ⇒ error（说明有同步阻塞） |
 * | 内存 RSS | 60s | > 2560MB ⇒ warn（10 分钟最多一条） |
 * | worker 风暴 | 实时 | 同一 worker 10 分钟内拉起 > 8 次 ⇒ error |
 *
 * 除主日志外**再落一份独立 `watchdog.log`**：winston/pino 的写入队列本身可能已经被卡住。
 * `mark(stage)` 记录启动阶段，卡死时能看出卡在哪一步。
 *
 * 注意：进程内看门狗只**记账**，杀进程/重启由进程外监督（`watchdog-supervisor.ts`）做。
 */
export interface WatchdogThresholds {
  cpuPct: number;
  cpuWindowMs: number;
  loopDelayMs: number;
  loopBreaks: number;
  rssMb: number;
  workerStormCount: number;
  workerStormWindowMs: number;
}

export interface WatchdogMetrics {
  cpuPct: number;
  loopDelayMs: number;
  rssMb: number;
  stage: string;
  uptimeSec: number;
  at: number;
}

export interface WatchdogEvent {
  level: 'warn' | 'error';
  kind: 'cpu' | 'loop' | 'rss' | 'worker' | 'stage';
  message: string;
  metrics: WatchdogMetrics;
}

export interface WatchdogOptions {
  dataDir: string;
  thresholds?: Partial<WatchdogThresholds>;
  log?: {
    info?: (obj: unknown, msg: string) => void;
    warn?: (obj: unknown, msg: string) => void;
    error?: (obj: unknown, msg: string) => void;
  };
  /** 每次心跳（3s）回调：外壳用它做进程外监督 */
  onBeat?: (metrics: WatchdogMetrics) => void;
}

const DEFAULTS: WatchdogThresholds = {
  cpuPct: Number(process.env.WATCHDOG_CPU_PCT) || 95,
  cpuWindowMs: Number(process.env.WATCHDOG_CPU_WINDOW_MS) || 5 * 60 * 1000,
  loopDelayMs: Number(process.env.WATCHDOG_LOOP_DELAY_MS) || 3000,
  loopBreaks: Number(process.env.WATCHDOG_LOOP_BREAKS) || 3,
  rssMb: Number(process.env.WATCHDOG_RSS_MB) || 2560,
  workerStormCount: Number(process.env.WATCHDOG_WORKER_STORM) || 8,
  workerStormWindowMs: 10 * 60 * 1000,
};

const LOG_MAX_BYTES = 5 * 1024 * 1024;

export class Watchdog {
  private readonly thresholds: WatchdogThresholds;
  private readonly logFile: string;
  private readonly loop = monitorEventLoopDelay({ resolution: 20 });
  private readonly timers: NodeJS.Timeout[] = [];

  private stage = 'init';
  private lastCpu: { usage: NodeJS.CpuUsage; at: number } | null = null;
  private cpuBreachSince: number | null = null;
  private loopBreaks = 0;
  private lastRssWarnAt = 0;
  private workerStarts = new Map<string, number[]>();
  private lastMetrics: WatchdogMetrics;

  constructor(private readonly opts: WatchdogOptions) {
    this.thresholds = { ...DEFAULTS, ...(opts.thresholds ?? {}) };
    this.logFile = path.join(opts.dataDir, 'watchdog.log');
    this.lastMetrics = {
      cpuPct: 0,
      loopDelayMs: 0,
      rssMb: 0,
      stage: this.stage,
      uptimeSec: 0,
      at: Date.now(),
    };
  }

  start(): void {
    try {
      this.loop.enable();
    } catch {
      /* 已启用 */
    }
    this.schedule(5_000, () => this.sampleLoop());
    this.schedule(10_000, () => this.sampleCpu());
    this.schedule(60_000, () => this.sampleRss());
    this.schedule(3_000, () => this.beat());
    this.emit('info', { stage: this.stage }, 'watchdog started');
  }

  stop(): void {
    for (const t of this.timers) clearInterval(t);
    this.timers.length = 0;
    try {
      this.loop.disable();
    } catch {
      /* noop */
    }
  }

  mark(stage: string): void {
    this.stage = stage;
    this.emit('info', { stage }, `stage: ${stage}`);
  }

  /** 由 sidecar supervisor / worker 池调用 */
  noteWorkerStart(name: string): void {
    const now = Date.now();
    const list = (this.workerStarts.get(name) ?? []).filter(
      (t) => now - t <= this.thresholds.workerStormWindowMs,
    );
    list.push(now);
    this.workerStarts.set(name, list);
    if (list.length > this.thresholds.workerStormCount) {
      this.emit('error', { worker: name, count: list.length }, `worker storm: ${name}`);
      // 触发后清空，避免每 3s 刷一条
      this.workerStarts.set(name, []);
    }
  }

  snapshot(): WatchdogMetrics {
    return { ...this.lastMetrics };
  }

  private schedule(everyMs: number, fn: () => void): void {
    const timer = setInterval(() => {
      try {
        fn();
      } catch (err) {
        this.emit('warn', { err: String(err) }, 'watchdog sample failed');
      }
    }, everyMs);
    timer.unref?.();
    this.timers.push(timer);
  }

  private sampleLoop(): void {
    const meanMs = this.loop.mean / 1e6;
    this.loop.reset();
    this.lastMetrics.loopDelayMs = Math.round(meanMs);

    if (meanMs > this.thresholds.loopDelayMs) {
      this.loopBreaks += 1;
      if (this.loopBreaks >= this.thresholds.loopBreaks) {
        this.emit('error', { meanMs: Math.round(meanMs) }, 'event loop blocked');
        this.loopBreaks = 0;
      }
    } else {
      this.loopBreaks = 0;
    }
  }

  private sampleCpu(): void {
    const now = Date.now();
    const usage = process.cpuUsage();
    if (!this.lastCpu) {
      // 首次只记基线，避免用整段启动时间算平均
      this.lastCpu = { usage, at: now };
      return;
    }
    const elapsedUs = (now - this.lastCpu.at) * 1000;
    const deltaUs =
      usage.user - this.lastCpu.usage.user + (usage.system - this.lastCpu.usage.system);
    this.lastCpu = { usage, at: now };
    const pct = elapsedUs > 0 ? (deltaUs / elapsedUs) * 100 : 0;
    this.lastMetrics.cpuPct = Math.round(pct * 10) / 10;

    if (pct >= this.thresholds.cpuPct) {
      this.cpuBreachSince ??= now;
      if (now - this.cpuBreachSince >= this.thresholds.cpuWindowMs) {
        this.emit('error', { pct: this.lastMetrics.cpuPct }, 'sustained high cpu');
        this.cpuBreachSince = null;
      }
    } else {
      this.cpuBreachSince = null;
    }
  }

  private sampleRss(): void {
    const mb = Math.round(process.memoryUsage().rss / 1024 / 1024);
    this.lastMetrics.rssMb = mb;
    if (mb > this.thresholds.rssMb && Date.now() - this.lastRssWarnAt > 10 * 60 * 1000) {
      this.lastRssWarnAt = Date.now();
      this.emit('warn', { rssMb: mb }, 'high memory');
    }
  }

  private beat(): void {
    this.lastMetrics = {
      ...this.lastMetrics,
      stage: this.stage,
      uptimeSec: Math.round(process.uptime()),
      at: Date.now(),
    };
    this.opts.onBeat?.(this.snapshot());
  }

  private emit(level: 'info' | 'warn' | 'error', obj: Record<string, unknown>, msg: string): void {
    const metrics = { ...this.lastMetrics, stage: this.stage, at: Date.now() };
    const entry = { at: new Date().toISOString(), level, msg, ...obj, metrics };
    try {
      this.writeLine(JSON.stringify(entry));
    } catch {
      /* 日志写不进去也不能让看门狗自己崩 */
    }
    if (level === 'error') this.opts.log?.error?.(entry, msg);
    else if (level === 'warn') this.opts.log?.warn?.(entry, msg);
    else this.opts.log?.info?.(entry, msg);
  }

  private writeLine(line: string): void {
    try {
      const st = fs.existsSync(this.logFile) ? fs.statSync(this.logFile) : null;
      if (st && st.size > LOG_MAX_BYTES) {
        fs.truncateSync(this.logFile, 0);
      }
      fs.appendFileSync(this.logFile, line + '\n', 'utf-8');
    } catch {
      /* 磁盘满 / 权限问题：忽略，避免影响主流程 */
    }
  }
}

export function createWatchdog(opts: WatchdogOptions): Watchdog {
  return new Watchdog(opts);
}
