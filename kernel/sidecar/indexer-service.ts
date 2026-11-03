import path from 'node:path';
import type BetterSqlite3 from 'better-sqlite3';
import { SidecarSupervisor } from './supervisor';
import { IndexerBridge, type BridgeStats } from './indexer-bridge';

/**
 * 索引器服务（蓝图 §8/§9）：把 `sidecars/indexer` 接进内核。
 *
 * - **按需拉起**：第一次 `scan()` 才 spawn，空闲不占进程
 * - **单写者**：sidecar 只产出 `batch`，落库统一由主进程在单事务里 upsert（`IndexerBridge`）
 * - **断点续传**：`index_progress.last_seq` 记录已应用批次；重扫幂等
 * - **串行**：同一时刻只跑一轮扫描，避免两个遍历同时打盘
 */
export interface ScanResult {
  root: string;
  entries: number;
  batches: number;
  maxTxMs: number;
  ms: number;
}

export interface IndexerOptions {
  dataDir: string;
  log: (level: 'info' | 'warn' | 'error', message: string) => void;
  /** 单轮扫描的硬超时，默认 10 分钟 */
  timeoutMs?: number;
}

export class IndexerService {
  private sup: SidecarSupervisor | null = null;
  private bridge: IndexerBridge | null = null;
  private chain: Promise<unknown> = Promise.resolve();
  private readonly timeoutMs: number;

  constructor(
    private readonly db: BetterSqlite3.Database,
    private readonly opts: IndexerOptions,
  ) {
    this.timeoutMs = opts.timeoutMs ?? 10 * 60_000;
  }

  stats(): BridgeStats {
    return this.bridge ? this.bridge.getStats() : { batches: 0, rows: 0, lastSeq: 0, maxTxMs: 0 };
  }

  get running(): boolean {
    return this.sup?.state === 'ready';
  }

  private ensureStarted(): { sup: SidecarSupervisor; bridge: IndexerBridge } {
    if (this.sup && this.bridge) return { sup: this.sup, bridge: this.bridge };

    const sup = new SidecarSupervisor({
      name: 'indexer',
      command: process.env.COLANAS_SIDECAR_NODE || process.execPath,
      args: [
        process.env.COLANAS_SIDECAR_SCRIPT ||
          path.join(process.cwd(), 'sidecars', 'indexer', 'main.js'),
      ],
      requestTimeoutMs: 5_000,
      heartbeatMs: 2_000,
      maxRestarts: 3,
      startTimeoutMs: 8_000,
      stopGraceMs: 3_000,
      log: (lvl, msg) => this.opts.log(lvl === 'error' ? 'error' : 'info', `[indexer] ${msg}`),
    });

    this.sup = sup;
    this.bridge = new IndexerBridge(this.db, sup);
    return { sup, bridge: this.bridge };
  }

  /** 扫描一个根目录（串行）；返回落库统计 */
  async scan(root: string): Promise<ScanResult> {
    const run = async (): Promise<ScanResult> => {
      const { sup, bridge } = this.ensureStarted();
      if (sup.state !== 'ready') await sup.start();
      bridge.loadCheckpoint(root);
      const started = Date.now();

      const done = new Promise<unknown>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`indexer scan timeout after ${this.timeoutMs}ms`)),
          this.timeoutMs,
        );
        sup.once('event', function onEvent(name: string, data: unknown) {
          if (name !== 'scan_done') {
            sup.once('event', onEvent);
            return;
          }
          clearTimeout(timer);
          resolve(data);
        });
      });

      await sup.request('scan', { root, batchSize: 500, flushMs: 200 });
      await done;

      const s = bridge.getStats();
      return {
        root,
        entries: s.rows,
        batches: s.batches,
        maxTxMs: Number(s.maxTxMs.toFixed(2)),
        ms: Date.now() - started,
      };
    };

    const next = this.chain.then(run, run);
    this.chain = next.catch(() => undefined);
    return next;
  }

  async stop(): Promise<void> {
    if (!this.sup) return;
    const sup = this.sup;
    this.sup = null;
    this.bridge = null;
    try {
      await sup.stop();
    } catch {
      /* 已退出 */
    }
  }
}