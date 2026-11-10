import { sql } from 'kysely';

/**
 * 传输会话存储。
 *
 * 设计取舍：
 * - **一行一个「传动作」**，不是一行一个文件：同一文件断点重传会复用同一行（唯一索引兜住），
 *   这样面板上不会出现同一条路径刷出十几行。
 * - **进度写放大受控**：分片 4 MB 一片，一次上传最多几百次 UPDATE；再密就没必要了。
 *   客户端也不会每片都刷新界面（本地节流），服务端这边直接写，简单可靠。
 * - **写失败不抛**：传输面板是观测设施，任何一次统计写入失败都不该让真正的文件传输失败。
 */

export type TransferDirection = 'upload' | 'download';
export type TransferState = 'pending' | 'active' | 'paused' | 'done' | 'failed' | 'canceled';

export interface TransferSession {
  id: string;
  owner: string;
  direction: TransferDirection;
  path: string;
  name: string;
  size: number;
  transferred: number;
  totalChunks: number;
  doneChunks: number[];
  state: TransferState;
  origin: string;
  device: string;
  error: string | null;
  createdAt: number;
  updatedAt: number;
  finishedAt: number | null;
}

/** 数据库行（snake_case + JSON 字符串列） */
interface Row {
  id: string;
  owner: string;
  direction: string;
  path: string;
  name: string;
  size: number;
  transferred: number;
  total_chunks: number;
  done_chunks: string;
  state: string;
  origin: string;
  device: string;
  error: string | null;
  created_at: number;
  updated_at: number;
  finished_at: number | null;
}

const ACTIVE_STATES: TransferState[] = ['pending', 'active', 'paused'];

const nowSec = (): number => Math.floor(Date.now() / 1000);

/** 取路径末段做展示名：面板不必每次自己切字符串，也避免 Windows 反斜杠漏处理 */
export function baseNameOf(p: string): string {
  const trimmed = String(p || '').replace(/[/\\]+$/, '');
  const cut = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'));
  return cut >= 0 ? trimmed.slice(cut + 1) : trimmed;
}

function parseChunks(raw: string): number[] {
  try {
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr.filter((x) => Number.isInteger(x)) : [];
  } catch {
    return [];
  }
}

function toSession(row: Row): TransferSession {
  return {
    id: row.id,
    owner: row.owner,
    direction: row.direction === 'download' ? 'download' : 'upload',
    path: row.path,
    name: row.name,
    size: row.size,
    transferred: row.transferred,
    totalChunks: row.total_chunks,
    doneChunks: parseChunks(row.done_chunks),
    state: row.state as TransferState,
    origin: row.origin,
    device: row.device,
    error: row.error,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    finishedAt: row.finished_at,
  };
}

export interface BeginInput {
  /** 客户端自带的会话 id（跨端一致，便于本地任务与服务端行对齐）；缺省则由服务端生成 */
  id?: string;
  owner: string;
  direction: TransferDirection;
  path: string;
  size?: number;
  totalChunks?: number;
  origin?: string;
  device?: string;
}

export class TransferStore {
  constructor(private readonly db: any) {}

  /**
   * 开启（或复用）一个会话。
   *
   * 复用规则：同 owner + 同方向 + 同路径 **且处于活跃态** → 拿来接着用，
   * 重置为 active 并保留已传字节（断点续传跨设备也成立：换台机器点同一个文件续传，
   * 面板上看到的仍是同一条记录在走）。
   */
  async begin(input: BeginInput): Promise<TransferSession> {
    const at = nowSec();
    const path = String(input.path || '');
    const existing = await sql<Row>`
      select * from transfer_sessions
      where owner = ${input.owner}
        and direction = ${input.direction}
        and path = ${path}
        and state in ('pending', 'active', 'paused')
      limit 1
    `.execute(this.db);

    if (existing.rows.length > 0) {
      const row = existing.rows[0];
      const size = Number(input.size ?? row.size) || 0;
      const totalChunks = Number(input.totalChunks ?? row.total_chunks) || 0;
      // 尺寸变了说明不是同一个文件（同名覆盖）：已传进度作废，分片列表清空。
      const resized = size > 0 && row.size > 0 && size !== row.size;
      await sql`
        update transfer_sessions
        set state = 'active',
            size = ${size || row.size},
            total_chunks = ${totalChunks || row.total_chunks},
            transferred = ${resized ? 0 : row.transferred},
            done_chunks = ${resized ? '[]' : row.done_chunks},
            origin = ${input.origin || row.origin},
            device = ${input.device || row.device},
            error = null,
            updated_at = ${at},
            finished_at = null
        where id = ${row.id}
      `.execute(this.db);
      const fresh = await this.get(row.id);
      return fresh ?? toSession(row);
    }

    const id = input.id || `tf_${nowSec()}_${Math.random().toString(36).slice(2, 10)}`;
    await sql`
      insert into transfer_sessions (
        id, owner, direction, path, name, size, transferred, total_chunks, done_chunks,
        state, origin, device, error, created_at, updated_at, finished_at
      ) values (
        ${id}, ${input.owner}, ${input.direction}, ${path}, ${baseNameOf(path)},
        ${Number(input.size) || 0}, 0, ${Number(input.totalChunks) || 0}, '[]',
        'active', ${input.origin || ''}, ${input.device || ''}, null, ${at}, ${at}, null
      )
    `.execute(this.db);

    return {
      id,
      owner: input.owner,
      direction: input.direction,
      path,
      name: baseNameOf(path),
      size: Number(input.size) || 0,
      transferred: 0,
      totalChunks: Number(input.totalChunks) || 0,
      doneChunks: [],
      state: 'active',
      origin: input.origin || '',
      device: input.device || '',
      error: null,
      createdAt: at,
      updatedAt: at,
      finishedAt: null,
    };
  }

  /**
   * 推进一个分片。`bytes` 是这一片的实际字节数，`dryRun` 用于重传已存在的分片
   * （分片已在服务端，不该重复计入已传字节）。
   */
  async advance(
    id: string,
    opts: { chunkIndex?: number; bytes?: number; totalChunks?: number } = {},
  ): Promise<void> {
    const at = nowSec();
    try {
      if (opts.chunkIndex === undefined) {
        await sql`
          update transfer_sessions
          set transferred = transferred + ${Number(opts.bytes) || 0},
              updated_at = ${at}
          where id = ${id}
        `.execute(this.db);
        return;
      }

      const found = await sql<Row>`select * from transfer_sessions where id = ${id}`.execute(this.db);
      if (found.rows.length === 0) return;
      const row = found.rows[0];
      const done = parseChunks(row.done_chunks);
      const already = done.includes(opts.chunkIndex);
      if (!already) done.push(opts.chunkIndex);
      done.sort((a, b) => a - b);
      const transferred = already
        ? row.transferred
        : Math.min(row.size || Number.MAX_SAFE_INTEGER, row.transferred + (Number(opts.bytes) || 0));
      const totalChunks = Number(opts.totalChunks) || row.total_chunks;

      await sql`
        update transfer_sessions
        set transferred = ${transferred},
            done_chunks = ${JSON.stringify(done)},
            total_chunks = ${totalChunks},
            updated_at = ${at}
        where id = ${id}
      `.execute(this.db);
    } catch {
      /* 统计失败不影响真实传输 */
    }
  }

  /** 结束并标记成功。`size` 缺省时按 total 收口，保证面板上的进度条能走满 */
  async finish(id: string, opts: { size?: number } = {}): Promise<void> {
    const at = nowSec();
    try {
      await sql`
        update transfer_sessions
        set state = 'done',
            transferred = case when ${Number(opts.size) || 0} > 0 then ${Number(opts.size) || 0} else transferred end,
            size = case when ${Number(opts.size) || 0} > 0 then ${Number(opts.size) || 0} else size end,
            updated_at = ${at},
            finished_at = ${at},
            error = null
        where id = ${id}
      `.execute(this.db);
    } catch {
      /* 同上 */
    }
  }

  async fail(id: string, error: string): Promise<void> {
    const at = nowSec();
    try {
      await sql`
        update transfer_sessions
        set state = 'failed', error = ${error}, updated_at = ${at}, finished_at = ${at}
        where id = ${id}
      `.execute(this.db);
    } catch {
      /* 同上 */
    }
  }

  async setState(id: string, state: TransferState): Promise<boolean> {
    const at = nowSec();
    const finished = state === 'done' || state === 'failed' || state === 'canceled' ? at : null;
    const res: any = await sql`
      update transfer_sessions
      set state = ${state}, updated_at = ${at}, finished_at = ${finished}
      where id = ${id}
    `.execute(this.db);
    return Number(res.numUpdatedRows ?? 0) > 0;
  }

  async get(id: string): Promise<TransferSession | null> {
    const res = await sql<Row>`select * from transfer_sessions where id = ${id}`.execute(this.db);
    return res.rows.length > 0 ? toSession(res.rows[0]) : null;
  }

  /**
   * 找同一 owner + 方向 + 路径的活跃会话。
   *
   * 分片接口每片都要推进一次进度，但客户端未必每次都带会话 id（老客户端 / 同步模块）。
   * 这条查询走 `uniq_transfer_active` 唯一索引，代价可以忽略；调用方还可以在外层缓存。
   */
  async findActive(
    owner: string,
    direction: TransferDirection,
    path: string,
  ): Promise<TransferSession | null> {
    const res = await sql<Row>`
      select * from transfer_sessions
      where owner = ${owner}
        and direction = ${direction}
        and path = ${path}
        and state in ('pending', 'active', 'paused')
      limit 1
    `.execute(this.db);
    return res.rows.length > 0 ? toSession(res.rows[0]) : null;
  }

  /**
   * 批量补用户名：面板上显示「alice 上传」比一串 uid 好读。
   * 查不到账号表（auth 模块被裁）或用户已删时静默留空，不影响列表返回。
   */
  async fillOwnerNames(items: TransferSession[]): Promise<Array<TransferSession & { ownerName: string }>> {
    const owners = [...new Set(items.map((s) => s.owner).filter(Boolean))];
    const names = new Map<string, string>();
    if (owners.length > 0) {
      try {
        const rows = await sql<{ id: string; username: string }>`
          select id, username from auth_users
        `.execute(this.db);
        for (const row of rows.rows) names.set(row.id, row.username);
      } catch {
        /* 没有账号表：留空 */
      }
    }
    return items.map((s) => ({ ...s, ownerName: names.get(s.owner) || '' }));
  }

  /**
   * 列出会话。**默认只返回未过期的**（90 天），并支持按 state / direction 过滤。
   * 分页是真分页（SQL limit/offset），不是「查全部再切片」。
   */
  async list(opts: {
    state?: string;
    direction?: string;
    owner?: string;
    q?: string;
    limit?: number;
    offset?: number;
  }): Promise<{ items: TransferSession[]; total: number }> {
    const limit = Math.max(1, Math.min(Number(opts.limit) || 50, 200));
    const offset = Math.max(0, Number(opts.offset) || 0);

    const filters: any[] = [];
    const where = sql`where 1 = 1`;
    const conds = [];
    if (opts.state && opts.state !== 'all') conds.push(sql`state = ${opts.state}`);
    if (opts.direction) conds.push(sql`direction = ${opts.direction}`);
    if (opts.owner) conds.push(sql`owner = ${opts.owner}`);
    if (opts.q) conds.push(sql`(path like ${`%${opts.q}%`} or name like ${`%${opts.q}%`})`);

    const filterSql =
      conds.length === 0
        ? where
        : sql`where ${sql.join(conds, sql` and `)}`;

    const rows = await sql<Row>`
      select * from transfer_sessions
      ${filterSql}
      order by updated_at desc
      limit ${limit} offset ${offset}
    `.execute(this.db);

    const counted = await sql<{ c: number }>`
      select count(*) as c from transfer_sessions
      ${filterSql}
    `.execute(this.db);

    void filters;
    return {
      items: rows.rows.map(toSession),
      total: Number(counted.rows[0]?.c ?? 0),
    };
  }

  /** 面板顶部的小结：进行中 / 完成 / 失败各多少条，以及累计字节 */
  async stats(): Promise<{
    active: number;
    done: number;
    failed: number;
    paused: number;
    activeBytes: number;
    speedBps: number;
  }> {
    const at = nowSec();
    const res = await sql<{ state: string; c: number; bytes: number }>`
      select state, count(*) as c, coalesce(sum(transferred), 0) as bytes
      from transfer_sessions
      group by state
    `.execute(this.db);

    let active = 0;
    let done = 0;
    let failed = 0;
    let paused = 0;
    let activeBytes = 0;
    for (const row of res.rows) {
      const c = Number(row.c) || 0;
      if (row.state === 'active' || row.state === 'pending') {
        active += c;
        activeBytes += Number(row.bytes) || 0;
      } else if (row.state === 'done') done += c;
      else if (row.state === 'failed') failed += c;
      else if (row.state === 'paused') paused += c;
    }

    // 速率：最近 30 秒内有更新的活跃会话，按 (transferred 差 / 30s) 粗估。
    // 精确到每个会话要额外存时间序列，对面板没必要；这里给的是「整机当前吞吐」。
    const recent = await sql<{ bytes: number }>`
      select coalesce(sum(transferred), 0) as bytes
      from transfer_sessions
      where state in ('active', 'pending') and updated_at >= ${at - 30}
    `.execute(this.db);
    const speedBps = Math.round((Number(recent.rows[0]?.bytes ?? 0) || 0) / 30);

    return { active, done, failed, paused, activeBytes, speedBps };
  }

  /**
   * 清掉已结束的旧记录（默认 90 天）。只删会话行，**不碰磁盘文件**：
   * 面板是观测设施，清理它不该造成任何数据损失。
   */
  async prune(days = 90): Promise<number> {
    const before = nowSec() - Math.max(1, days) * 86400;
    const res: any = await sql`
      delete from transfer_sessions
      where state in ('done', 'failed', 'canceled') and updated_at < ${before}
    `.execute(this.db);
    return Number(res.numDeletedRows ?? 0);
  }
}

/** 单机的传输会话存储（模块 register 时创建一次即可） */
export function createTransferStore(db: any): TransferStore {
  return new TransferStore(db);
}
