import type BetterSqlite3 from 'better-sqlite3';
import type { SidecarSupervisor } from './supervisor';

export interface IndexEntry {
  path: string;
  size: number;
  mtime: number;
}

export interface IndexBatch {
  seq: number;
  entries: IndexEntry[];
  done: boolean;
}

export interface BridgeStats {
  batches: number;
  rows: number;
  lastSeq: number;
  maxTxMs: number;
}

const UPSERT = `
  insert into files_meta (path, size, mtime, updated_at)
  values (?, ?, ?, ?)
  on conflict(path) do update set
    size = excluded.size,
    mtime = excluded.mtime,
    updated_at = excluded.updated_at
`;

const PROGRESS = `
  insert into index_progress (root, last_seq, entries, updated_at)
  values (?, ?, ?, ?)
  on conflict(root) do update set
    last_seq = excluded.last_seq,
    entries = excluded.entries,
    updated_at = excluded.updated_at
`;

/**
 * 批量写协议（§6.1）：indexer 推 `batch` 事件，内核在**单个事务**内 upsert 整批，
 * 主进程是唯一写者；事务耗时逐批记录（验收要求 ≤ 50 ms）。
 */
export class IndexerBridge {
  private root = '';
  private stats: BridgeStats = { batches: 0, rows: 0, lastSeq: 0, maxTxMs: 0 };
  private ready = false;

  private readonly upsertStmt: BetterSqlite3.Statement;
  private readonly progressStmt: BetterSqlite3.Statement;
  private readonly tx: (rows: IndexEntry[]) => number;

  constructor(
    private readonly db: BetterSqlite3.Database,
    private readonly sup: SidecarSupervisor,
    private readonly now: () => number = Date.now,
  ) {
    this.upsertStmt = db.prepare(UPSERT);
    this.progressStmt = db.prepare(PROGRESS);
    this.tx = db.transaction((rows: IndexEntry[]) => {
      let n = 0;
      for (const r of rows) {
        this.upsertStmt.run(r.path, r.size, r.mtime, now());
        n += 1;
      }
      return n;
    });

    sup.on('event', (name: string, data: unknown) => {
      if (name !== 'batch') return;
      try {
        this.apply(data as IndexBatch);
      } catch (err) {
        sup.emit('log', 'error', `indexer batch failed: ${(err as Error).message}`);
      }
    });
  }

  getStats(): BridgeStats {
    return { ...this.stats };
  }

  /** 读取断点：上次已应用的批次序号 */
  loadCheckpoint(root: string): number {
    this.root = root;
    const row = this.db
      .prepare('select last_seq, entries from index_progress where root = ?')
      .get(root) as { last_seq: number; entries: number } | undefined;
    this.stats.lastSeq = row?.last_seq ?? 0;
    this.stats.rows = row?.entries ?? 0;
    this.ready = true;
    return this.stats.lastSeq;
  }

  /** 应用一批；乱序/重复批次直接丢弃（幂等） */
  apply(batch: IndexBatch): void {
    if (!this.ready) throw new Error('loadCheckpoint() 必须先调用');
    if (!batch || typeof batch.seq !== 'number') throw new Error('invalid batch');
    if (batch.seq <= this.stats.lastSeq) return;

    const start = process.hrtime.bigint();
    const applied = batch.entries.length > 0 ? this.tx(batch.entries) : 0;
    const ms = Number(process.hrtime.bigint() - start) / 1e6;

    this.stats.maxTxMs = Math.max(this.stats.maxTxMs, ms);
    this.stats.batches += 1;
    this.stats.rows += applied;
    this.stats.lastSeq = batch.seq;

    this.progressStmt.run(this.root, batch.seq, this.stats.rows, this.now());
  }
}