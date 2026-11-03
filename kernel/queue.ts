import crypto from 'node:crypto';
import { sql } from 'kysely';

export type TaskState = 'pending' | 'running' | 'paused' | 'done' | 'failed' | 'canceled';

export interface TaskRow {
  id: string;
  type: string;
  payload: string;
  state: TaskState;
  priority: number;
  attempts: number;
  max_attempts: number;
  progress: number;
  error: string | null;
  next_run_at: number | null;
  created_at: number;
  started_at: number | null;
  finished_at: number | null;
}

export interface EnqueueOptions {
  priority?: number;
  maxAttempts?: number;
}

/** 任务执行上下文：进度与结构化日志都通过它回传，handler 不必自己拼 SQL */
export interface TaskContext {
  id: string;
  type: string;
  attempt: number;
  progress(pct: number): Promise<void>;
  log(level: 'info' | 'warn' | 'error', message: string, meta?: unknown): void;
  /** handler 内部可主动检查是否已被取消（长任务应按块轮询） */
  isCanceled(): Promise<boolean>;
}

export type TaskHandler = (payload: unknown, ctx: TaskContext) => Promise<unknown>;

export interface WorkerOptions {
  /** 并发执行数，默认 1（媒体/AI 任务都是 CPU 或 IO 密集型） */
  concurrency?: number;
  /** 空闲轮询间隔，默认 500 ms */
  pollMs?: number;
}

const RETRY_BASE_MS = 15_000;
const RETRY_MAX_MS = 5 * 60_000;

/** 重试基数可覆盖（冒烟用小值，避免测试等 15 s） */
function retryBaseMs(): number {
  const raw = Number(process.env.COLANAS_TASK_RETRY_BASE_MS);
  return Number.isFinite(raw) && raw > 0 ? raw : RETRY_BASE_MS;
}

/**
 * 持久化任务队列（SQLite）。
 *
 * - 状态机：pending → running → done / failed / canceled
 * - **生产者**：任何模块 `k.tasks.enqueue(type, payload)`，payload 必须是可 JSON 序列化的
 * - **消费者**：`register(type, handler)` 之后由内核 worker 循环 `claim → 执行 → complete/fail`
 * - 失败按 `15s × 2^(attempt-1)`（上限 5 min）退避重投，直到 `max_attempts`
 * - 进程重启时 `recover()` 把 running 回滚为 pending —— 重启不丢任务
 */
export class TaskQueue {
  private handlers = new Map<string, TaskHandler>();
  private running = 0;
  private stopped = true;
  private loopTimer: NodeJS.Timeout | null = null;
  private draining: Promise<void> = Promise.resolve();
  private options: Required<WorkerOptions> = { concurrency: 1, pollMs: 500 };

  constructor(
    private readonly db: any,
    private readonly raw: any,
    private readonly log?: (level: 'warn' | 'info', message: string, meta?: unknown) => void,
  ) {}

  static async create(db: any, raw: any, log?: (level: 'warn' | 'info', message: string, meta?: unknown) => void): Promise<TaskQueue> {
    await sql`
      create table if not exists tasks (
        id text primary key,
        type text not null,
        payload text not null,
        state text not null,
        priority integer not null default 1,
        attempts integer not null default 0,
        max_attempts integer not null default 3,
        progress real not null default 0,
        error text,
        next_run_at integer,
        created_at integer not null,
        started_at integer,
        finished_at integer
      )
    `.execute(db);

    await sql`
      create index if not exists idx_tasks_state
      on tasks (state, priority, created_at)
    `.execute(db);

    // 老库补列（`next_run_at` 是重试退避用的）
    try {
      await sql`alter table tasks add column next_run_at integer`.execute(db);
    } catch {
      /* 已存在 */
    }

    return new TaskQueue(db, raw, log);
  }

  // ------------------------------------------------------------ 生产者

  async enqueue(type: string, payload: unknown, opts: EnqueueOptions = {}): Promise<string> {
    const id = crypto.randomUUID();
    await sql`
      insert into tasks (id, type, payload, state, priority, max_attempts, created_at)
      values (${id}, ${type}, ${JSON.stringify(payload ?? null)}, 'pending',
              ${opts.priority ?? 1}, ${opts.maxAttempts ?? 3}, ${Date.now()})
    `.execute(this.db);
    return id;
  }

  /**
   * 去重入队：同类型 + 同 payload 已有 pending / running 时直接复用。
   * 用于「同一库的补全任务」，避免扫描风暴把队列堆满同一条任务。
   */
  async enqueueIfIdle(type: string, payload: unknown, opts: EnqueueOptions = {}): Promise<{ id: string; reused: boolean }> {
    const body = JSON.stringify(payload ?? null);
    const existing = (
      await sql<{ id: string }>`
        select id from tasks
         where type = ${type} and payload = ${body} and state in ('pending', 'running')
         limit 1
      `.execute(this.db)
    ).rows[0];
    if (existing) return { id: existing.id, reused: true };
    return { id: await this.enqueue(type, payload, opts), reused: false };
  }

  // ------------------------------------------------------------ 消费者

  register(type: string, handler: TaskHandler): void {
    if (this.handlers.has(type)) throw new Error(`task handler already registered: ${type}`);
    this.handlers.set(type, handler);
  }

  registered(): string[] {
    return [...this.handlers.keys()].sort();
  }

  start(opts: WorkerOptions = {}): void {
    if (!this.stopped) return;
    this.options.concurrency = Math.max(1, Math.min(opts.concurrency ?? 1, 8));
    this.options.pollMs = Math.max(50, opts.pollMs ?? 500);
    this.stopped = false;
    this.log?.('info', 'task worker started', {
      concurrency: this.options.concurrency,
      handlers: this.registered(),
    });
    this.tick();
  }

  /** 停止领取新任务，并等待正在执行的最多 10 s（超时后交由 recover 在下次启动重投） */
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.loopTimer) {
      clearTimeout(this.loopTimer);
      this.loopTimer = null;
    }
    const deadline = Date.now() + 10_000;
    while (this.running > 0 && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  private scheduleNext(delay: number): void {
    if (this.stopped) return;
    if (this.loopTimer) clearTimeout(this.loopTimer);
    this.loopTimer = setTimeout(() => {
      this.loopTimer = null;
      this.tick();
    }, delay);
    this.loopTimer.unref?.();
  }

  private tick(): void {
    if (this.stopped) return;
    if (this.running >= this.options.concurrency) {
      this.scheduleNext(this.options.pollMs);
      return;
    }
    this.draining = this.drainOnce()
      .catch((err) => {
        this.log?.('warn', 'task worker error', { error: String(err) });
      })
      .finally(() => {
        this.scheduleNext(this.options.pollMs);
      });
  }

  private async drainOnce(): Promise<void> {
    const slots = this.options.concurrency - this.running;
    if (slots <= 0) return;
    let claimed: TaskRow[];
    try {
      claimed = await this.claim(slots);
    } catch (err) {
      this.log?.('warn', 'task claim failed', { error: String(err) });
      return;
    }
    for (const task of claimed) {
      this.running += 1;
      void this.execute(task).finally(() => {
        this.running -= 1;
      });
    }
  }

  private async execute(task: TaskRow): Promise<void> {
    const handler = this.handlers.get(task.type);
    if (!handler) {
      await this.fail(task.id, `no handler registered for task type: ${task.type}`, false);
      return;
    }
    const ctx: TaskContext = {
      id: task.id,
      type: task.type,
      attempt: task.attempts,
      progress: (pct) => this.progress(task.id, pct),
      log: (level, message, meta) => this.log?.(level === 'info' ? 'info' : 'warn', message, meta),
      isCanceled: async () => {
        const row = await this.get(task.id);
        return !row || row.state === 'canceled';
      },
    };

    try {
      const payload = task.payload ? JSON.parse(task.payload) : null;
      const result = await handler(payload, ctx);
      await this.complete(task.id);
      this.log?.('info', 'task done', { id: task.id, type: task.type, attempt: task.attempts, result });
    } catch (err) {
      const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      await this.fail(task.id, message.slice(0, 500));
      this.log?.('warn', 'task failed', { id: task.id, type: task.type, attempt: task.attempts, error: message });
    }
  }

  // ------------------------------------------------------------ 状态迁移

  async claim(limit = 1): Promise<TaskRow[]> {
    const now = Date.now();
    const rows = (
      await sql`
        select * from tasks
         where state = 'pending' and (next_run_at is null or next_run_at <= ${now})
         order by priority asc, created_at asc limit ${limit}
      `.execute(this.db)
    ).rows as TaskRow[];

    const claimed: TaskRow[] = [];
    const stmt = this.raw.prepare(
      `update tasks set state='running', attempts=attempts+1, started_at=? where id=? and state='pending'`,
    );

    for (const r of rows) {
      const res = stmt.run(now, r.id);
      if (res.changes === 1) {
        claimed.push({ ...r, state: 'running', attempts: r.attempts + 1, started_at: now });
      }
    }
    return claimed;
  }

  async progress(id: string, pct: number): Promise<void> {
    const v = Math.max(0, Math.min(100, pct));
    await sql`update tasks set progress = ${v} where id = ${id}`.execute(this.db);
  }

  async complete(id: string): Promise<void> {
    await sql`
      update tasks set state='done', progress=100, finished_at=${Date.now()}, error=null
      where id=${id} and state='running'
    `.execute(this.db);
  }

  async fail(id: string, error: string, retry = true): Promise<void> {
    const task = await this.get(id);
    if (!task) return;

    if (retry && task.attempts < task.max_attempts) {
      const backoff = Math.min(retryBaseMs() * 2 ** Math.max(0, task.attempts - 1), RETRY_MAX_MS);
      await sql`
        update tasks
           set state='pending', error=${error}, next_run_at=${Date.now() + backoff}, started_at=null
         where id=${id} and state='running'
      `.execute(this.db);
    } else {
      await sql`
        update tasks set state='failed', error=${error}, finished_at=${Date.now()}
        where id=${id} and state='running'
      `.execute(this.db);
    }
  }

  async cancel(id: string): Promise<void> {
    await sql`
      update tasks set state='canceled', finished_at=${Date.now()}
       where id=${id} and state in ('pending','running','paused')
    `.execute(this.db);
  }

  /**
   * 暂停：`pending` → `paused`（worker 只 claim pending，所以立刻不再被取）。
   * 传 `type` 时批量暂停该类型的所有 pending；都不传则暂停全部 pending。
   * running 的任务不会被暂停（无法安全打断），需要时先 `cancel` 再重投。
   */
  async pause(idOrType: { id?: string; type?: string }): Promise<number> {
    if (idOrType.id) {
      const res = await sql`
        update tasks set state='paused' where id=${idOrType.id} and state='pending'
      `.execute(this.db);
      return Number(res.numAffectedRows ?? 0);
    }
    if (idOrType.type) {
      const res = await sql`
        update tasks set state='paused' where type=${idOrType.type} and state='pending'
      `.execute(this.db);
      return Number(res.numAffectedRows ?? 0);
    }
    const res = await sql`update tasks set state='paused' where state='pending'`.execute(this.db);
    return Number(res.numAffectedRows ?? 0);
  }

  /** 恢复：`paused` → `pending`（worker 下一轮就取） */
  async resume(idOrType: { id?: string; type?: string }): Promise<number> {
    if (idOrType.id) {
      const res = await sql`
        update tasks set state='pending' where id=${idOrType.id} and state='paused'
      `.execute(this.db);
      return Number(res.numAffectedRows ?? 0);
    }
    if (idOrType.type) {
      const res = await sql`
        update tasks set state='pending' where type=${idOrType.type} and state='paused'
      `.execute(this.db);
      return Number(res.numAffectedRows ?? 0);
    }
    const res = await sql`update tasks set state='pending' where state='paused'`.execute(this.db);
    return Number(res.numAffectedRows ?? 0);
  }

  async get(id: string): Promise<TaskRow | null> {
    const rows = (await sql`select * from tasks where id = ${id}`.execute(this.db)).rows as TaskRow[];
    return rows[0] ?? null;
  }

  async list(state?: TaskState, limit = 50): Promise<TaskRow[]> {
    if (state) {
      return (
        await sql`select * from tasks where state = ${state} order by created_at desc limit ${limit}`.execute(
          this.db,
        )
      ).rows as TaskRow[];
    }
    return (await sql`select * from tasks order by created_at desc limit ${limit}`.execute(this.db))
      .rows as TaskRow[];
  }

  async stats(): Promise<Record<TaskState, number>> {
    const rows = (await sql`select state, count(*) as n from tasks group by state`.execute(this.db))
      .rows as Array<{ state: TaskState; n: number }>;

    const out: Record<TaskState, number> = {
      pending: 0,
      running: 0,
      paused: 0,
      done: 0,
      failed: 0,
      canceled: 0,
    };
    for (const r of rows) out[r.state] = Number(r.n);
    return out;
  }

  /** 进程重启：running 回滚为 pending，返回受影响条数 */
  async recover(): Promise<number> {
    const res = this.raw
      .prepare(`update tasks set state='pending', started_at=null where state='running'`)
      .run();
    return res.changes;
  }
}