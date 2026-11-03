import { randomUUID } from 'node:crypto';
import type { WebSocket } from 'ws';
import * as pty from 'node-pty';

/**
 * 真正的 PTY 终端（SP3-10 二期）。
 *
 * 与 `/system/exec` 的区别：exec 是**只读白名单 + 无 shell + 5 秒超时**；
 * 这里是完整交互式 shell（管理员权限，scope `system:write`），因此必须：
 *   - 单用户并发上限（默认 2 个会话）；
 *   - 空闲回收（默认 30 分钟）；
 *   - 输出限流（默认 512 KB/s，超出丢弃，防止 `yes` 拖死内核）；
 *   - PTY 环境变量白名单（不把 `COLANAS_*` 密钥带进子进程）。
 *
 * 协议（JSON 文本帧）：
 *   客户端 → 服务端：`{type:'input',data}` / `{type:'resize',cols,rows}` / `{type:'close'}`
 *   服务端 → 客户端：`{type:'ready',id,shell}` / `{type:'data',data}` / `{type:'exit',code,reason?}` / `{type:'error',message}`
 */

const MAX_SESSIONS_PER_OWNER = 2;
const IDLE_MS = 30 * 60_000;
const MAX_OUTPUT_PER_SEC = 512 * 1024;

const byOwner = new Map<string, Set<string>>();

export interface TerminalOptions {
  owner: string;
  cols?: number;
  rows?: number;
  log?: {
    info: (...args: unknown[]) => void;
    warn: (...args: unknown[]) => void;
  };
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.min(max, Math.max(min, Math.trunc(value)));
}

/** 只把终端需要的基础变量传给 shell，避免密钥外泄。 */
function safeEnv(): Record<string, string> {
  const keep = [
    'PATH',
    'Path',
    'PATHEXT',
    'ComSpec',
    'SystemRoot',
    'WINDIR',
    'USERPROFILE',
    'HOME',
    'TEMP',
    'TMP',
    'LANG',
    'LC_ALL',
    'SHELL',
    'TERM',
  ];
  const env: Record<string, string> = { TERM: 'xterm-256color' };
  for (const key of keep) {
    const value = process.env[key];
    if (typeof value === 'string' && value) env[key] = value;
  }
  return env;
}

function defaultShell(): { file: string; args: string[] } {
  if (process.platform === 'win32') {
    return { file: process.env.ComSpec || 'cmd.exe', args: [] };
  }
  return { file: process.env.SHELL || '/bin/sh', args: ['-l'] };
}

export function attachTerminal(socket: WebSocket, options: TerminalOptions): void {
  const { owner } = options;
  const active = byOwner.get(owner) ?? new Set<string>();
  if (active.size >= MAX_SESSIONS_PER_OWNER) {
    socket.send(JSON.stringify({ type: 'error', message: 'too many terminal sessions' }));
    socket.close(1013, 'too many sessions');
    return;
  }

  const send = (payload: Record<string, unknown>) => {
    if (socket.readyState !== socket.OPEN) return;
    try {
      socket.send(JSON.stringify(payload));
    } catch {
      /* 对端已断：忽略 */
    }
  };

  const shell = defaultShell();
  let term: pty.IPty;
  try {
    term = pty.spawn(shell.file, shell.args, {
      name: 'xterm-256color',
      cols: clamp(Number(options.cols), 20, 400),
      rows: clamp(Number(options.rows), 5, 200),
      cwd: process.env.USERPROFILE || process.env.HOME || process.cwd(),
      env: safeEnv(),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    options.log?.warn?.({ err: message }, 'terminal spawn failed');
    send({ type: 'error', message: `spawn failed: ${message}` });
    socket.close(1011, 'spawn failed');
    return;
  }

  const id = randomUUID();
  active.add(id);
  byOwner.set(owner, active);
  options.log?.info?.({ id, owner, shell: shell.file }, 'terminal session opened');

  let disposed = false;
  let lastAt = Date.now();
  let budget = MAX_OUTPUT_PER_SEC;

  const cleanup = (reason?: string) => {
    if (disposed) return;
    disposed = true;
    try {
      term.kill();
    } catch {
      /* 进程已退出 */
    }
    active.delete(id);
    if (active.size === 0) byOwner.delete(owner);
    options.log?.info?.({ id, reason }, 'terminal session closed');
  };

  const idleTimer = setInterval(() => {
    if (Date.now() - lastAt < IDLE_MS) return;
    send({ type: 'exit', code: null, reason: 'idle' });
    cleanup('idle');
    socket.close(1000, 'idle');
  }, 60_000);
  idleTimer.unref?.();

  const budgetTimer = setInterval(() => {
    budget = MAX_OUTPUT_PER_SEC;
  }, 1000);
  budgetTimer.unref?.();

  term.onData((data) => {
    if (disposed || budget <= 0) return;
    budget -= data.length;
    send({ type: 'data', data });
  });

  term.onExit(({ exitCode }) => {
    send({ type: 'exit', code: exitCode });
    cleanup('exit');
    socket.close(1000, 'exit');
  });

  socket.on('message', (raw: unknown) => {
    lastAt = Date.now();
    type ClientMessage = { type?: string; data?: string; cols?: number; rows?: number };
    let msg: ClientMessage | null;
    try {
      msg = JSON.parse(String(raw)) as ClientMessage;
    } catch {
      send({ type: 'error', message: 'invalid json' });
      return;
    }
    if (!msg) return;

    if (msg.type === 'input' && typeof msg.data === 'string') {
      term.write(msg.data);
    } else if (msg.type === 'resize') {
      try {
        term.resize(clamp(Number(msg.cols), 20, 400), clamp(Number(msg.rows), 5, 200));
      } catch {
        /* 进程已退出 */
      }
    } else if (msg.type === 'close') {
      send({ type: 'exit', code: null, reason: 'closed' });
      cleanup('client');
      socket.close(1000, 'closed');
    }
  });

  socket.on('close', () => {
    clearInterval(idleTimer);
    clearInterval(budgetTimer);
    cleanup('socket');
  });
  socket.on('error', () => {
    clearInterval(idleTimer);
    clearInterval(budgetTimer);
    cleanup('error');
  });

  send({ type: 'ready', id, shell: shell.file });
}