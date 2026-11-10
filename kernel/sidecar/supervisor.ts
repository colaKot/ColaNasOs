import { spawn, type ChildProcess } from 'node:child_process';
import { EventEmitter } from 'node:events';
import crypto from 'node:crypto';
import {
  NdjsonDecoder,
  encodeRequest,
  isEvent,
  isLog,
  isResponse,
  type SidecarError,
  type SidecarLogLevel,
  type SidecarRequest,
  type SidecarRequestPayload,
} from './protocol';

export class SidecarCallError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'SidecarCallError';
  }
}

export type SidecarState = 'stopped' | 'starting' | 'ready' | 'stopping';

export interface SidecarOptions {
  name: string;
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  /** 单次 invoke 超时 */
  requestTimeoutMs?: number;
  /** 心跳间隔；心跳失败即判定僵死并重启 */
  heartbeatMs?: number;
  /** 连续重启上限，超过后放弃（emit 'giveup'） */
  maxRestarts?: number;
  /** 启动到可用（首次 ping 成功）的上限 */
  startTimeoutMs?: number;
  /** 优雅退出总预算 */
  stopGraceMs?: number;
  log?: (level: SidecarLogLevel, message: string, meta?: unknown) => void;
}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

/**
 * Sidecar 进程守护（§7.1 / §7.2）：
 * - NDJSON over stdio
 * - 启动探测 + 周期心跳（僵死自动重启）
 * - 指数退避重启（上限可配）
 * - 优雅退出：shutdown 帧 → SIGTERM → SIGKILL
 */
export class SidecarSupervisor extends EventEmitter {
  private child: ChildProcess | null = null;
  private decoder = new NdjsonDecoder();
  private pending = new Map<string, Pending>();
  private heartbeat: NodeJS.Timeout | null = null;
  private restarts = 0;
  private stopping = false;
  private _state: SidecarState = 'stopped';

  private readonly requestTimeoutMs: number;
  private readonly heartbeatMs: number;
  private readonly maxRestarts: number;
  private readonly startTimeoutMs: number;
  private readonly stopGraceMs: number;

  constructor(private readonly opts: SidecarOptions) {
    super();
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 30_000;
    this.heartbeatMs = opts.heartbeatMs ?? 5_000;
    this.maxRestarts = opts.maxRestarts ?? 5;
    this.startTimeoutMs = opts.startTimeoutMs ?? 10_000;
    this.stopGraceMs = opts.stopGraceMs ?? 5_000;
  }

  get state(): SidecarState {
    return this._state;
  }

  get pid(): number | undefined {
    return this.child?.pid;
  }

  get name(): string {
    return this.opts.name;
  }

  /** 启动并等待首次 ping 通 */
  async start(): Promise<void> {
    if (this._state === 'ready') return;
    this.stopping = false;
    this.restarts = 0;
    this.spawn();
    await this.waitReady();
    this.startHeartbeat();
  }

  /** 业务调用：`invoke` 帧 */
  request<T = unknown>(method: string, params?: unknown, timeoutMs?: number): Promise<T> {
    return this.sendRpc({ type: 'invoke', method, params }, timeoutMs) as Promise<T>;
  }

  async ping(timeoutMs = 1_500): Promise<void> {
    await this.sendRpc({ type: 'ping' }, timeoutMs);
  }

  /** 优雅退出；返回时进程已结束 */
  async stop(): Promise<void> {
    const child = this.child;
    if (!child) {
      this._state = 'stopped';
      return;
    }

    this.stopping = true;
    this._state = 'stopping';
    this.stopHeartbeat();

    const exited = new Promise<void>((resolve) => child.once('exit', () => resolve()));

    try {
      await this.sendRpc({ type: 'shutdown' }, 500);
    } catch {
      /* sidecar 可能已自行退出 */
    }

    const term = setTimeout(() => {
      if (child.exitCode === null) child.kill('SIGTERM');
    }, Math.floor(this.stopGraceMs / 2));

    const kill = setTimeout(() => {
      if (child.exitCode === null) child.kill('SIGKILL');
    }, this.stopGraceMs);

    await exited;
    clearTimeout(term);
    clearTimeout(kill);

    this.child = null;
    this._state = 'stopped';
    this.rejectAll(new SidecarCallError('E_STOPPED', `sidecar ${this.opts.name} stopped`));
  }

  // ---------------------------------------------------------------- 内部

  private spawn(): void {
    const child = spawn(this.opts.command, this.opts.args ?? [], {
      cwd: this.opts.cwd,
      env: { ...process.env, ...this.opts.env, COLANAS_SIDECAR: this.opts.name },
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });

    this.child = child;
    this.decoder = new NdjsonDecoder();
    this._state = 'starting';

    child.stdout?.setEncoding('utf8');
    child.stderr?.setEncoding('utf8');

    child.stdout?.on('data', (chunk: string) => this.onStdout(chunk));
    child.stderr?.on('data', (chunk: string) => {
      this.log('warn', `[${this.opts.name}:stderr] ${String(chunk).trimEnd()}`);
    });

    child.on('error', (err) => {
      this.log('error', `[${this.opts.name}] spawn error: ${err.message}`);
    });

    child.on('exit', (code, signal) => {
      this.rejectAll(
        new SidecarCallError(
          'E_EXITED',
          `sidecar ${this.opts.name} exited (code=${code}, signal=${signal})`,
        ),
      );
      this.child = null;
      this.stopHeartbeat();
      this.emit('exit', code, signal);
      this.log('warn', `[${this.opts.name}] exited code=${code} signal=${signal}`);

      if (this.stopping) {
        this._state = 'stopped';
        return;
      }
      // 退出到重启就绪之间存在窗口期：对外状态必须是 starting，
      // 否则调用方用 `state !== 'ready'` 判断会误认为进程仍可用。
      this._state = 'starting';
      this.scheduleRestart();
    });
  }

  private async waitReady(): Promise<void> {
    const deadline = Date.now() + this.startTimeoutMs;
    let lastErr: Error | null = null;

    while (Date.now() < deadline) {
      if (!this.child) throw new Error(`sidecar ${this.opts.name} 启动失败：进程已退出`);
      try {
        await this.ping(Math.min(1_000, deadline - Date.now()));
        this._state = 'ready';
        this.emit('ready');
        return;
      } catch (err) {
        lastErr = err as Error;
        await delay(100);
      }
    }

    this.killChild();
    this._state = 'stopped';
    throw new SidecarCallError(
      'E_START_TIMEOUT',
      `sidecar ${this.opts.name} 在 ${this.startTimeoutMs}ms 内未就绪：${lastErr?.message ?? 'unknown'}`,
    );
  }

  private scheduleRestart(): void {
    if (this.stopping) return;

    this.restarts += 1;
    if (this.restarts > this.maxRestarts) {
      this._state = 'stopped';
      this.log('error', `[${this.opts.name}] 连续重启 ${this.restarts - 1} 次仍失败，放弃`);
      this.emit('giveup');
      return;
    }

    const delayMs = Math.min(500 * 2 ** (this.restarts - 1), 8_000);
    this.log('warn', `[${this.opts.name}] restart #${this.restarts} in ${delayMs}ms`);
    this.emit('restart', this.restarts, delayMs);

    setTimeout(() => {
      if (this.stopping) return;
      this.spawn();
      this.waitReady()
        .then(() => {
          this.restarts = 0;
          this.startHeartbeat();
          this.log('info', `[${this.opts.name}] recovered (pid=${this.pid})`);
        })
        .catch((err: Error) => {
          this.log('error', `[${this.opts.name}] restart failed: ${err.message}`);
          this.killChild();
        });
    }, delayMs);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeat = setInterval(() => {
      if (this._state !== 'ready' || this.stopping) return;
      // 判活超时**不能**比心跳间隔还短：sidecar 是单线程的，一次重活
      // （ffmpeg 冷启动探编码器、4K 分片收尾落盘）就可能让事件循环卡几秒，
      // 超时一刀下去就是 SIGKILL —— 正在跑的转码全死（表现是「4K 一播就报错」）。
      // 现在给足一个完整心跳周期（不足 3s 的按 3s 兜底），真僵死仍会被杀掉重启。
      this.ping(Math.max(3_000, this.heartbeatMs)).catch(() => {
        this.log('error', `[${this.opts.name}] heartbeat timeout, killing for restart`);
        this.killChild();
      });
    }, this.heartbeatMs);
    this.heartbeat.unref?.();
  }

  private stopHeartbeat(): void {
    if (this.heartbeat) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
  }

  private killChild(): void {
    const child = this.child;
    if (!child) return;
    try {
      child.kill('SIGKILL');
    } catch {
      /* 已退出 */
    }
  }

  private onStdout(chunk: string): void {
    for (const msg of this.decoder.push(chunk)) this.dispatch(msg);
  }

  private dispatch(msg: unknown): void {
    if (isResponse(msg)) {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      clearTimeout(pending.timer);
      if (msg.ok) pending.resolve(msg.result);
      else pending.reject(new SidecarCallError(msg.error.code, msg.error.message));
      return;
    }

    if (isEvent(msg)) {
      this.emit('event', msg.event, msg.data);
      return;
    }

    if (isLog(msg)) {
      this.log(msg.level, `[${this.opts.name}] ${msg.message}`);
      return;
    }

    this.log('warn', `[${this.opts.name}] 未知帧: ${JSON.stringify(msg).slice(0, 200)}`);
  }

  private sendRpc(msg: SidecarRequestPayload, timeoutMs?: number): Promise<unknown> {
    const child = this.child;
    if (!child || !child.stdin || child.killed) {
      return Promise.reject(new SidecarCallError('E_NOT_RUNNING', `sidecar ${this.opts.name} 未运行`));
    }

    const id = crypto.randomUUID();
    const frame = encodeRequest({ ...msg, id } as SidecarRequest);
    const timeout = timeoutMs ?? this.requestTimeoutMs;

    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new SidecarCallError(
            'E_TIMEOUT',
            `sidecar ${this.opts.name} ${msg.type === 'invoke' ? msg.method : msg.type} 超时 ${timeout}ms`,
          ),
        );
      }, timeout);
      timer.unref?.();

      this.pending.set(id, { resolve, reject, timer });
      child.stdin!.write(frame);
    });
  }

  private rejectAll(err: SidecarError | SidecarCallError): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(err instanceof Error ? err : new SidecarCallError(err.code, err.message));
      this.pending.delete(id);
    }
  }

  private log(level: SidecarLogLevel, message: string): void {
    if (this.opts.log) this.opts.log(level, message);
    else this.emit('log', level, message);
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}