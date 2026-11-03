/**
 * 进程外心跳监督（纯状态机，无 Electron 依赖，便于单测）。
 *
 * 规则：
 * - 主进程每 3s 心跳一次；**硬阈值 5 分钟无心跳 ⇒ 杀进程树重启**。
 * - `hang`（默认）：只有心跳彻底断才重启（CPU 高但还活着不杀，避免误杀大扫描）。
 * - `always`：心跳断 或 CPU 连续 ≥95% 都重启。
 * - `off`：只记账不重启。
 * - 退避：窗口内最多重启 `maxRestarts` 次，超了 **GIVE UP** 并留日志，避免无限重启刷屏。
 */
export type AutoRestartMode = 'hang' | 'always' | 'off';

export interface SupervisorOptions {
  mode?: AutoRestartMode;
  /** 慢阈值：超过只告警 */
  softMs?: number;
  /** 硬阈值：超过即判定卡死 */
  hardMs?: number;
  maxRestarts?: number;
  windowMs?: number;
  cpuPct?: number;
  /** CPU 连续超阈值的持续时间才算卡死 */
  cpuHoldMs?: number;
}

export interface HeartbeatMetrics {
  cpuPct?: number;
  rssMb?: number;
  loopDelayMs?: number;
  stage?: string;
}

export interface CheckResult {
  action: 'none' | 'restart' | 'giveup';
  reason: string;
  silentMs: number;
  restartsInWindow: number;
}

export class WatchdogSupervisor {
  private readonly mode: AutoRestartMode;
  private readonly softMs: number;
  private readonly hardMs: number;
  private readonly maxRestarts: number;
  private readonly windowMs: number;
  private readonly cpuPct: number;
  private readonly cpuHoldMs: number;

  private lastBeatAt: number | null = null;
  private lastMetrics: HeartbeatMetrics = {};
  private cpuBreachSince: number | null = null;
  private restartTimes: number[] = [];
  private gaveUp = false;

  constructor(opts: SupervisorOptions = {}) {
    this.mode = opts.mode ?? parseMode(process.env.WATCHDOG_AUTO_RESTART);
    this.softMs = opts.softMs ?? 90_000;
    this.hardMs = opts.hardMs ?? 5 * 60 * 1000;
    this.maxRestarts = opts.maxRestarts ?? 3;
    this.windowMs = opts.windowMs ?? 30 * 60 * 1000;
    this.cpuPct = opts.cpuPct ?? 95;
    this.cpuHoldMs = opts.cpuHoldMs ?? 3 * 60 * 1000;
  }

  beat(now: number, metrics: HeartbeatMetrics = {}): void {
    this.lastBeatAt = now;
    this.lastMetrics = metrics;
    // CPU 超阈值从「第一次观测到」开始计时（心跳本身也是观测点）
    if ((metrics.cpuPct ?? 0) >= this.cpuPct) this.cpuBreachSince ??= now;
    else this.cpuBreachSince = null;
  }

  get mode_(): AutoRestartMode {
    return this.mode;
  }

  get lastMetrics_(): HeartbeatMetrics {
    return { ...this.lastMetrics };
  }

  check(now: number): CheckResult {
    const silentMs = this.lastBeatAt === null ? 0 : Math.max(0, now - this.lastBeatAt);
    const restartsInWindow = this.prune(now);

    if (this.mode === 'off' || this.gaveUp) {
      return { action: 'none', reason: this.gaveUp ? 'gaveUp' : 'off', silentMs, restartsInWindow };
    }
    // 从未收到心跳：可能还在启动，不动作
    if (this.lastBeatAt === null) {
      return { action: 'none', reason: 'starting', silentMs: 0, restartsInWindow };
    }

    const cpuPct = this.lastMetrics.cpuPct ?? 0;
    if (cpuPct >= this.cpuPct) this.cpuBreachSince ??= now;
    else this.cpuBreachSince = null;

    const cpuHang =
      this.mode === 'always' &&
      silentMs < this.hardMs &&
      this.cpuBreachSince !== null &&
      now - this.cpuBreachSince >= this.cpuHoldMs;

    if (silentMs < this.hardMs && !cpuHang) {
      return {
        action: 'none',
        reason: silentMs >= this.softMs ? 'slow' : 'ok',
        silentMs,
        restartsInWindow,
      };
    }

    if (restartsInWindow >= this.maxRestarts) {
      this.gaveUp = true;
      return { action: 'giveup', reason: 'tooManyRestarts', silentMs, restartsInWindow };
    }

    this.restartTimes.push(now);
    this.lastBeatAt = null;
    this.cpuBreachSince = null;
    return {
      action: 'restart',
      reason: cpuHang ? 'cpuHang' : 'noHeartbeat',
      silentMs,
      restartsInWindow: this.prune(now),
    };
  }

  restartCount(now: number): number {
    return this.prune(now);
  }

  private prune(now: number): number {
    this.restartTimes = this.restartTimes.filter((t) => now - t <= this.windowMs);
    return this.restartTimes.length;
  }
}

function parseMode(raw: string | undefined): AutoRestartMode {
  if (raw === 'always' || raw === 'off' || raw === 'hang') return raw;
  return 'hang';
}
