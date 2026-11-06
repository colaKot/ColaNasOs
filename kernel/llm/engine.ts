import { spawn, type ChildProcess } from 'node:child_process';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

/**
 * 本地小模型引擎：常驻一个 `llama-server`，用 OpenAI 兼容接口做**短请求**（翻译）。
 *
 * 为什么常驻而不是像 `kernel/tts/engine.ts` 那样每次 spawn：
 *   `llama-tts` 是一次性 CLI，只能整块起进程；而翻译是「一条新闻一次请求」，
 *   90 条就是 90 次。Qwen3-1.7B 加载一次约 3~6 秒（Vulkan 首启还要编译着色器），
 *   逐条起进程会把 86 秒的活干成十几分钟。所以这里用 `llama-server` + HTTP。
 *
 * 三条硬约束，改之前先读：
 *   1. **空闲就退出**（默认 5 分钟）：常驻会一直占着约 1GB 显存/内存，用户不生成新闻时
 *      没理由占着。下次调用再拉起，3~6 秒可以接受。
 *   2. **请求串行**：`-np 1` 时并发请求会在服务端排队，但客户端并发发出去容易被限流成 503，
 *      所以这里自己上个互斥队列，外部可以放心 mapLimit。
 *   3. **GPU 失败退 CPU**：Vulkan 在部分驱动上直接崩（780M 实测可用，但别假设都行），
 *      启动阶段进程退出或健康检查超时就自动用 `-ngl 0` 重来一次。
 */

export interface LocalLlmOptions {
  binPath: string;
  modelPath: string;
  /** GPU 卸载层数，99 = 全卸载；0 = 纯 CPU */
  ngl?: number;
  /** 上下文长度：一条新闻的 prompt 不到 1k token，4096 足够 */
  ctxSize?: number;
  threads?: number;
  /** 空闲多久自动退出（毫秒），0 = 常驻不退出 */
  idleMs?: number;
  log?: (level: 'debug' | 'info' | 'warn' | 'error', message: string) => void;
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface ChatOptions {
  temperature?: number;
  maxTokens?: number;
  /** 要求服务端返回 JSON 对象（llama.cpp 的 json_object 是 grammar 级的，比 prompt 约束可靠） */
  jsonObject?: boolean;
  timeoutMs?: number;
}

export interface ChatResult {
  content: string;
  promptTokens: number;
  completionTokens: number;
  ms: number;
}

const START_TIMEOUT_MS = 60_000;
const DEFAULT_IDLE_MS = 5 * 60 * 1000;
/** 本地推理服务只绑回环：端口探测、启动参数与请求地址共用同一个 host */
const LOOPBACK_HOST = '127.0.0.1';

/** 端口探测：让系统给一个空闲端口，避免固定端口被别的程序占走 */
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, LOOPBACK_HOST, () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => (port ? resolve(port) : reject(new Error('拿不到空闲端口'))));
    });
  });
}

export class LocalLlm {
  private child: ChildProcess | null = null;
  private starting: Promise<string> | null = null;
  private base = '';
  private chain: Promise<unknown> = Promise.resolve();
  private idle: NodeJS.Timeout | null = null;
  private closed = false;
  /** 最近的输出，进程异常退出时用来报错（llama.cpp 的错都在 stderr 末尾） */
  private tail: string[] = [];

  constructor(private readonly opts: LocalLlmOptions) {}

  get state(): string {
    if (this.starting) return 'starting';
    return this.child ? 'ready' : 'stopped';
  }

  available(): boolean {
    if (this.closed) return false;
    if (process.env.COLANAS_LLM_DISABLED === '1') return false;
    return true;
  }

  async chat(messages: ChatMessage[], options: ChatOptions = {}): Promise<ChatResult> {
    const base = await this.ensure();
    // 串行化：见文件头第 2 条
    const run = () =>
      this.post(base, messages, options).finally(() => this.scheduleIdle());
    const next = this.chain.then(run, run);
    this.chain = next.catch(() => undefined);
    return next;
  }

  /** 预热：进生成流程时先把模型拉起来，别让第一条新闻等启动。失败要带出真实错因 */
  async warmup(): Promise<void> {
    await this.ensure();
  }

  async stop(): Promise<void> {
    this.closed = true;
    await this.killChild();
  }

  // ---------------------------------------------------------------- 内部

  /** 只杀进程，不关引擎：空闲回收用这个，下次调用还能重新拉起 */
  private async killChild(): Promise<void> {
    this.clearIdle();
    const child = this.child;
    this.child = null;
    this.base = '';
    if (!child) return;
    await new Promise<void>((resolve) => {
      let done = false;
      const finish = (): void => {
        if (done) return;
        done = true;
        resolve();
      };
      child.once('exit', finish);
      try {
        child.kill();
      } catch {
        finish();
      }
      setTimeout(finish, 2_000);
    });
  }

  private log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void {
    this.opts.log?.(level, message);
  }

  private clearIdle(): void {
    if (this.idle) clearTimeout(this.idle);
    this.idle = null;
  }

  private scheduleIdle(): void {
    const idleMs = this.opts.idleMs ?? DEFAULT_IDLE_MS;
    this.clearIdle();
    if (idleMs <= 0 || !this.child) return;
    this.idle = setTimeout(() => {
      this.idle = null;
      if (!this.child) return;
      this.log('info', `本地模型空闲 ${Math.round(idleMs / 1000)}s，退出以释放内存`);
      void this.killChild();
    }, idleMs);
    this.idle.unref?.();
  }

  private async ensure(): Promise<string> {
    if (this.closed) throw new Error('本地模型已关闭');
    if (this.child && this.base) return this.base;
    if (this.starting) return this.starting;

    this.starting = (async () => {
      const ngl = this.opts.ngl ?? 99;
      try {
        return await this.launch(ngl);
      } catch (e) {
        if (ngl === 0) throw e;
        this.log('warn', `GPU 启动失败（${String((e as Error).message)}），改用 CPU 重试`);
        return this.launch(0);
      }
    })();

    try {
      return await this.starting;
    } finally {
      this.starting = null;
    }
  }

  private async launch(ngl: number): Promise<string> {
    const port = await freePort();
    const threads = this.opts.threads ?? Math.max(4, Math.min(8, os.cpus().length - 4));
    const args = [
      '-m',
      this.opts.modelPath,
      '--host',
      LOOPBACK_HOST,
      '--port',
      String(port),
      '-c',
      String(this.opts.ctxSize ?? 4096),
      '-t',
      String(threads),
      '-ngl',
      String(ngl),
      '-np',
      '1',
      // 预热交给第一次真实请求：--no-warmup 省 1~2 秒启动，首条请求会慢一点点
      '--no-warmup',
    ];
    this.tail = [];
    this.log('info', `启动本地模型：${this.opts.modelPath}（ngl=${ngl}）`);
    const child = spawn(this.opts.binPath, args, {
      cwd: path.dirname(this.opts.binPath),
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    this.child = child;

    const keep = (chunk: Buffer): void => {
      for (const line of chunk.toString('utf8').split(/\r?\n/)) {
        if (!line.trim()) continue;
        this.tail.push(line);
        if (this.tail.length > 40) this.tail.shift();
      }
    };
    child.stdout?.on('data', keep);
    child.stderr?.on('data', keep);
    child.on('exit', (code, signal) => {
      if (this.child === child) {
        this.child = null;
        this.base = '';
      }
      if (!this.closed) {
        this.log('warn', `本地模型进程退出（code=${code} signal=${signal}）：${this.tail.slice(-3).join(' / ')}`);
      }
    });

    const base = `http://${LOOPBACK_HOST}:${port}`;
    const deadline = Date.now() + START_TIMEOUT_MS;
    for (;;) {
      if (!this.child) throw new Error(`进程已退出：${this.tail.slice(-3).join(' / ')}`);
      if (Date.now() > deadline) {
        await this.killChild();
        throw new Error(`启动超时（${START_TIMEOUT_MS / 1000}s）`);
      }
      try {
        const res = await fetch(`${base}/health`, { signal: AbortSignal.timeout(1_500) });
        if (res.ok) break;
      } catch {
        // 还没起来
      }
      await new Promise((r) => setTimeout(r, 300));
    }

    this.base = base;
    this.log('info', `本地模型就绪：${base}（${Math.round((START_TIMEOUT_MS - (deadline - Date.now())) / 1000)}s）`);
    this.scheduleIdle();
    return base;
  }

  private async post(base: string, messages: ChatMessage[], options: ChatOptions): Promise<ChatResult> {
    const t0 = Date.now();
    const body: Record<string, unknown> = {
      messages,
      temperature: options.temperature ?? 0,
      max_tokens: options.maxTokens ?? 400,
      stream: false,
      // Qwen3 是混合思考模型：不关掉会先吐一长段推理，翻译这种任务纯属浪费
      chat_template_kwargs: { enable_thinking: false },
    };
    if (options.jsonObject) body.response_format = { type: 'json_object' };

    const res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(options.timeoutMs ?? 60_000),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      throw new Error(`HTTP ${res.status} ${detail.slice(0, 200)}`);
    }
    const json = (await res.json()) as {
      choices?: Array<{ message?: { content?: string }; finish_reason?: string }>;
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    };
    return {
      content: (json.choices?.[0]?.message?.content || '').trim(),
      promptTokens: json.usage?.prompt_tokens ?? 0,
      completionTokens: json.usage?.completion_tokens ?? 0,
      ms: Date.now() - t0,
    };
  }
}
