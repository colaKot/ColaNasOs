import fsp from 'node:fs/promises';
import path from 'node:path';
import { IGNORED_DIR_NAMES, IGNORED_FILE_NAMES, type FsBatch, type FsEvent } from './fs-watch';

/**
 * 远程目录轮询（蓝图 §56「挂载后端走轮询」）。
 *
 * SMB / WebDAV / rclone 这类后端没有可靠的 inotify，只能周期性地取一次快照，
 * 与上次快照做 `mtime + size` 比对，产出与 `fs.watch` 同构的 `FsBatch`。
 *
 * - **首次 tick 只建快照、不发事件**：否则每次启动都会把整库重扫一遍。
 * - **串行 + 退避**：一轮没跑完不会叠下一轮；连续失败按 2 倍退避，最长退到 30 分钟。
 * - **规模上限**：单次最多 `maxEntries` 个文件、`maxDepth` 层；超限只取前 N 个并记日志，
 *   避免把网络盘拖死（这也意味着超大库需要调大上限或改用本地库）。
 */

export interface SnapshotEntry {
  size: number;
  mtime: number;
}

export const DEFAULT_POLL_INTERVAL_MS = 5 * 60 * 1000;
/**
 * 单轮最多统计的文件数。默认 8000 而不是 2 万：远程目录每个文件都要一次 `stat`，
 * SMB 上是实打实的网络往返，2 万文件可能一轮就几十秒，反而阻塞下一轮（大库应改本地库或调大该值）。
 */
export const DEFAULT_POLL_MAX_ENTRIES = 8000;
export const DEFAULT_POLL_MAX_DEPTH = 16;
/** 单轮差异超过它就退化为一条「目录级重扫」 */
export const POLL_STORM_EVENTS = 2000;

export interface PollOptions {
  /** 轮询间隔，默认 5 分钟 */
  intervalMs?: number;
  maxEntries?: number;
  maxDepth?: number;
}

/**
 * 快照差异（纯函数）：新增 / 变更 / 消失。
 */
export function diffSnapshot(prev: ReadonlyMap<string, SnapshotEntry>, next: ReadonlyMap<string, SnapshotEntry>): FsEvent[] {
  const out: FsEvent[] = [];
  for (const [rel, cur] of next) {
    const old = prev.get(rel);
    if (!old) out.push({ kind: 'created', path: rel, isDir: false });
    else if (old.size !== cur.size || old.mtime !== cur.mtime) {
      out.push({ kind: 'modified', path: rel, isDir: false });
    }
  }
  for (const rel of prev.keys()) {
    if (!next.has(rel)) out.push({ kind: 'deleted', path: rel, isDir: false });
  }
  return out;
}

export interface PollStats {
  roots: number;
  subscribers: number;
  polls: number;
  events: number;
  batches: number;
  failures: number;
}

interface PollEntry {
  root: string;
  handlers: Set<(b: FsBatch) => void | Promise<void>>;
  refs: number;
  snapshot: Map<string, SnapshotEntry> | null;
  timer: NodeJS.Timeout | null;
  running: boolean;
  failures: number;
  intervalMs: number;
  opts: { maxEntries: number; maxDepth: number };
  stats: { polls: number; events: number; batches: number; failures: number };
}

export class PollService {
  private readonly entries = new Map<string, PollEntry>();

  constructor(
    private readonly log?: (level: 'warn' | 'info', msg: string, meta?: unknown) => void,
    private readonly defaults: PollOptions = {},
  ) {}

  subscribe(root: string, handler: (b: FsBatch) => void | Promise<void>, opts: PollOptions = {}): () => void {
    const abs = path.resolve(root);
    let entry = this.entries.get(abs);
    if (!entry) {
      entry = {
        root: abs,
        handlers: new Set(),
        refs: 0,
        snapshot: null,
        timer: null,
        running: false,
        failures: 0,
        intervalMs: opts.intervalMs ?? this.defaults.intervalMs ?? DEFAULT_POLL_INTERVAL_MS,
        opts: {
          maxEntries: opts.maxEntries ?? this.defaults.maxEntries ?? DEFAULT_POLL_MAX_ENTRIES,
          maxDepth: opts.maxDepth ?? this.defaults.maxDepth ?? DEFAULT_POLL_MAX_DEPTH,
        },
        stats: { polls: 0, events: 0, batches: 0, failures: 0 },
      };
      this.entries.set(abs, entry);
      this.schedule(entry, 0);
    }
    entry.handlers.add(handler);
    entry.refs += 1;

    let closed = false;
    return () => {
      if (closed) return;
      closed = true;
      entry!.handlers.delete(handler);
      entry!.refs -= 1;
      if (entry!.refs <= 0) this.dispose(entry!);
    };
  }

  stats(): PollStats {
    let subscribers = 0;
    let polls = 0;
    let events = 0;
    let batches = 0;
    let failures = 0;
    for (const e of this.entries.values()) {
      subscribers += e.handlers.size;
      polls += e.stats.polls;
      events += e.stats.events;
      batches += e.stats.batches;
      failures += e.stats.failures;
    }
    return { roots: this.entries.size, subscribers, polls, events, batches, failures };
  }

  stopAll(): void {
    for (const e of [...this.entries.values()]) this.dispose(e);
  }

  // -------------------------------------------------------------- 内部

  private schedule(entry: PollEntry, delayMs: number): void {
    if (entry.timer) clearTimeout(entry.timer);
    entry.timer = setTimeout(() => {
      entry.timer = null;
      void this.tick(entry);
    }, Math.max(0, delayMs));
    entry.timer.unref?.();
  }

  private async tick(entry: PollEntry): Promise<void> {
    if (entry.running || entry.handlers.size === 0) return;
    entry.running = true;
    try {
      const next = await this.snapshot(entry.root, entry.opts.maxEntries, entry.opts.maxDepth);
      entry.stats.polls += 1;
      entry.failures = 0;
      const prev = entry.snapshot;
      entry.snapshot = next;
      if (!prev) {
        // 首次只建基线
        this.log?.('info', 'poll: baseline built', { root: entry.root, entries: next.size });
        return;
      }
      const diff = diffSnapshot(prev, next);
      if (diff.length === 0) return;

      const batch: FsBatch =
        diff.length > POLL_STORM_EVENTS
          ? { root: entry.root, at: Date.now(), storm: true, events: [{ kind: 'rescan', path: entry.root, isDir: true }] }
          : {
              root: entry.root,
              at: Date.now(),
              storm: false,
              events: diff.map((e) => ({ ...e, path: path.join(entry.root, e.path) })),
            };
      entry.stats.events += batch.events.length;
      entry.stats.batches += 1;
      for (const handler of [...entry.handlers]) {
        try {
          await handler(batch);
        } catch (err) {
          this.log?.('warn', 'poll handler failed', { root: entry.root, error: String(err) });
        }
      }
    } catch (err) {
      entry.failures += 1;
      entry.stats.failures += 1;
      this.log?.('warn', 'poll failed', { root: entry.root, error: String(err), failures: entry.failures });
    } finally {
      entry.running = false;
      if (entry.handlers.size > 0) {
        // 连续失败按 2 倍退避，最长 30 分钟
        const backoff = Math.min(entry.intervalMs * 2 ** Math.min(entry.failures, 6), 30 * 60 * 1000);
        this.schedule(entry, entry.failures > 0 ? backoff : entry.intervalMs);
      }
    }
  }

  private async snapshot(
    root: string,
    maxEntries: number,
    maxDepth: number,
  ): Promise<Map<string, SnapshotEntry>> {
    const out = new Map<string, SnapshotEntry>();
    const stack: Array<{ abs: string; rel: string; depth: number }> = [{ abs: root, rel: '', depth: 0 }];
    while (stack.length > 0 && out.size < maxEntries) {
      const cur = stack.pop()!;
      let entries;
      try {
        entries = await fsp.readdir(cur.abs, { withFileTypes: true });
      } catch (err) {
        throw err instanceof Error ? err : new Error(String(err));
      }
      for (const e of entries) {
        if (out.size >= maxEntries) break;
        if (e.isSymbolicLink()) continue;
        const rel = cur.rel ? `${cur.rel}/${e.name}` : e.name;
        if (e.isDirectory()) {
          if (IGNORED_DIR_NAMES.has(e.name.toLowerCase())) continue;
          if (cur.depth + 1 <= maxDepth) {
            stack.push({ abs: path.join(cur.abs, e.name), rel, depth: cur.depth + 1 });
          }
          continue;
        }
        if (!e.isFile() || IGNORED_FILE_NAMES.has(e.name.toLowerCase())) continue;
        try {
          const st = await fsp.stat(path.join(cur.abs, e.name));
          out.set(rel, { size: st.size, mtime: Math.floor(st.mtimeMs) });
        } catch {
          /* 读的过程中消失：当作没看到 */
        }
      }
    }
    if (out.size >= maxEntries) {
      this.log?.('warn', 'poll: entry limit reached', { root, maxEntries });
    }
    return out;
  }

  private dispose(entry: PollEntry): void {
    if (entry.timer) {
      clearTimeout(entry.timer);
      entry.timer = null;
    }
    entry.handlers.clear();
    entry.snapshot = null;
    this.entries.delete(entry.root);
  }
}