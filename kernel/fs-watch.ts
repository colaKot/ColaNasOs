import fs from 'node:fs';
import path from 'node:path';

/**
 * 文件监控与增量扫描（蓝图 §56）。
 *
 * - 本地 FS：`fs.watch` 递归 + **去抖 500 ms** + 合批
 * - 事件模型：`created / modified / deleted`（改名在 FS 层表现为「一删一增」，
 *   下游按 `mtime + size` 幂等处理，等价于 renamed，见 `docs/02-服务端内核.md`）
 * - 风暴保护：单窗口事件数超过阈值时，合并成一条「目录级重扫」
 * - 与全量扫描的关系：监控负责「及时」，扫描负责「正确」
 *
 * 本文件只做「观测 + 合批 + 分发」，不认识任何业务表；扫描由模块订阅后自行触发。
 */

export type FsEventKind = 'created' | 'modified' | 'deleted' | 'rescan';

export interface FsEvent {
  kind: FsEventKind;
  /** 绝对路径；`rescan` 事件为需要重扫的目录 */
  path: string;
  isDir: boolean;
}

export interface FsBatch {
  /** 被监视的根目录（绝对路径） */
  root: string;
  at: number;
  /** true 表示本批已被风暴保护合并为一条 `rescan` */
  storm: boolean;
  events: FsEvent[];
}

export interface WatchOptions {
  /** 去抖窗口，默认 500 ms */
  debounceMs?: number;
  /** 风暴阈值（每秒事件数），默认 200 */
  stormPerSecond?: number;
  /** 风暴判定的条数下限，默认 40（低于它一律按普通合批处理，避免小窗口误判） */
  stormMinEvents?: number;
  /** 窗口内受影响目录数上限，默认 16（超过即整库重扫） */
  stormMinDirs?: number;
  /** 兜底逐目录监视时的深度 / 目录数上限 */
  maxDepth?: number;
  maxDirs?: number;
  /** 自定义忽略规则（返回 true 即忽略） */
  ignore?: (abs: string) => boolean;
}

export interface WatchStats {
  roots: number;
  subscribers: number;
  events: number;
  batches: number;
  storms: number;
}

export const DEFAULT_DEBOUNCE_MS = 500;
export const DEFAULT_STORM_PER_SECOND = 200;
export const DEFAULT_STORM_MIN_EVENTS = 40;
/** 窗口内受影响目录超过它即降级为整库重扫（默认 16） */
export const DEFAULT_STORM_MIN_DIRS = 16;

/** 系统垃圾文件 / 回收站 / 缩略图缓存目录：它们的变化不该触发扫描，也不该被媒体扫描索引 */
const IGNORED_NAMES = new Set(['.ds_store', 'thumbs.db', 'desktop.ini', 'ehthumbs.db']);
export const IGNORED_DIR_NAMES = new Set([
  '@eadir',
  '#recycle',
  '.trash',
  '$recycle.bin',
  'system volume information',
  '.git',
  'node_modules',
  // 压制组 / 下载站附带的 sample 目录不是正片内容；图片库会把它当图片索引
  'sample',
]);
export const IGNORED_FILE_NAMES = IGNORED_NAMES;

export function isIgnoredPath(abs: string): boolean {
  const parts = abs.split(/[\\/]+/).filter(Boolean);
  if (parts.some((p) => IGNORED_DIR_NAMES.has(p.toLowerCase()))) return true;
  const base = path.basename(abs).toLowerCase();
  if (IGNORED_NAMES.has(base)) return true;
  // 半成品：上传分片 / 临时文件 / 编辑器锁文件
  return base.startsWith('~$') || base.endsWith('.part') || base.endsWith('.tmp') || base.endsWith('.crdownload');
}

/**
 * 同一路径的多次事件合并为最终态：
 * - 删 → 建 = 覆盖写入（modified）
 * - 建 → 删 = 临时文件消失（deleted）
 * - 建 → 改 = 仍是新建（created，下游要走的路径不变）
 */
export function mergeKind(prev: FsEventKind, next: FsEventKind): FsEventKind {
  if (prev === next) return prev;
  if (prev === 'rescan' || next === 'rescan') return 'rescan';
  if (prev === 'deleted' && next === 'created') return 'modified';
  if (prev === 'created' && next === 'deleted') return 'deleted';
  if (next === 'deleted') return 'deleted';
  if (prev === 'created') return 'created';
  return next;
}

/**
 * 合批（纯函数，便于单测）：按路径排序，超阈值降级为一条 `rescan`。
 */
export function coalesceEvents(
  pending: ReadonlyMap<string, FsEvent>,
  opts: {
    root: string;
    debounceMs?: number;
    stormPerSecond?: number;
    stormMinEvents?: number;
    stormMinDirs?: number;
    at?: number;
  },
): FsBatch {
  const at = opts.at ?? Date.now();
  const debounceMs = opts.debounceMs ?? DEFAULT_DEBOUNCE_MS;
  const perSecond = opts.stormPerSecond ?? DEFAULT_STORM_PER_SECOND;
  const events = [...pending.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  // 窗口越短，能容纳的事件越少；下限避免小窗口把正常写入误判为风暴
  const threshold = Math.max(
    opts.stormMinEvents ?? DEFAULT_STORM_MIN_EVENTS,
    Math.round((perSecond * Math.max(debounceMs, 1)) / 1000),
  );
  // Windows 的 recursive watcher 会把同一目录的连续变更合并上报，
  // 所以「事件条数」不足以识别风暴；再用「受影响目录数」兜底（解压 / 大批量导入的典型特征）。
  const dirs = new Set(events.map((e) => path.dirname(e.path)));
  const dirLimit = opts.stormMinDirs ?? DEFAULT_STORM_MIN_DIRS;
  if (events.length > threshold || dirs.size > dirLimit) {
    return { root: opts.root, at, storm: true, events: [{ kind: 'rescan', path: opts.root, isDir: true }] };
  }
  return { root: opts.root, at, storm: false, events };
}

interface RootEntry {
  root: string;
  watchers: fs.FSWatcher[];
  pending: Map<string, FsEvent>;
  timer: NodeJS.Timeout | null;
  handlers: Set<(batch: FsBatch) => void>;
  refs: number;
  running: boolean;
  queued: FsBatch | null;
  stats: { events: number; batches: number; storms: number };
  opts: {
    debounceMs: number;
    stormPerSecond: number;
    stormMinEvents: number;
    stormMinDirs: number;
    maxDepth: number;
    maxDirs: number;
    ignore: (abs: string) => boolean;
  };
  dirsWatched: number;
}

export class WatchService {
  private readonly entries = new Map<string, RootEntry>();

  constructor(private readonly log?: (level: 'warn' | 'info', msg: string, meta?: unknown) => void) {}

  /**
   * 订阅一个目录树；返回取消函数。同一 root 共享底层 watcher（引用计数）。
   * handler 串行执行：同一 root 的前一批没跑完时，后一批会合并排队，避免扫描互相踩踏。
   */
  subscribe(root: string, handler: (batch: FsBatch) => void | Promise<void>, opts: WatchOptions = {}): () => void {
    const abs = path.resolve(root);
    let entry = this.entries.get(abs);
    if (!entry) {
      entry = {
        root: abs,
        watchers: [],
        pending: new Map(),
        timer: null,
        handlers: new Set(),
        refs: 0,
        running: false,
        queued: null,
        stats: { events: 0, batches: 0, storms: 0 },
        opts: {
          debounceMs: opts.debounceMs ?? DEFAULT_DEBOUNCE_MS,
          stormPerSecond: opts.stormPerSecond ?? DEFAULT_STORM_PER_SECOND,
          stormMinEvents: opts.stormMinEvents ?? DEFAULT_STORM_MIN_EVENTS,
          stormMinDirs: opts.stormMinDirs ?? DEFAULT_STORM_MIN_DIRS,
          maxDepth: opts.maxDepth ?? 32,
          maxDirs: opts.maxDirs ?? 512,
          ignore: opts.ignore ?? isIgnoredPath,
        },
        dirsWatched: 0,
      };
      this.entries.set(abs, entry);
      this.start(entry);
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

  stats(): WatchStats {
    let subscribers = 0;
    let events = 0;
    let batches = 0;
    let storms = 0;
    for (const e of this.entries.values()) {
      subscribers += e.handlers.size;
      events += e.stats.events;
      batches += e.stats.batches;
      storms += e.stats.storms;
    }
    return { roots: this.entries.size, subscribers, events, batches, storms };
  }

  /** 关闭全部 watcher（内核 onClose 调用） */
  stopAll(): void {
    for (const e of [...this.entries.values()]) this.dispose(e);
  }

  // ------------------------------------------------------------ 内部实现

  private start(entry: RootEntry): void {
    try {
      entry.watchers.push(
        fs.watch(entry.root, { recursive: true, persistent: false }, (type, filename) =>
          this.onRaw(entry, type, filename),
        ),
      );
      entry.dirsWatched = 1;
      return;
    } catch (err) {
      // Linux 老内核 / 部分网络盘不支持 recursive，逐目录兜底
      this.log?.('warn', 'fs.watch recursive unsupported, fallback to per-directory', {
        root: entry.root,
        error: String(err),
      });
    }
    this.watchDirs(entry, entry.root, 0);
    if (entry.watchers.length === 0) {
      this.log?.('warn', 'fs.watch failed, directory is not monitored', { root: entry.root });
    }
  }

  private watchDirs(entry: RootEntry, dir: string, depth: number): void {
    if (depth > entry.opts.maxDepth || entry.watchers.length >= entry.opts.maxDirs) return;
    try {
      const watcher = fs.watch(dir, { persistent: false }, (type, filename) => {
        if (!filename) return;
        const abs = path.join(dir, String(filename));
        this.onRaw(entry, type, path.relative(entry.root, abs));
        // 新建目录要补挂 watcher（兜底模式没有递归能力）
        if (type === 'rename') {
          try {
            if (fs.statSync(abs).isDirectory() && !entry.opts.ignore(abs)) {
              this.watchDirs(entry, abs, depth + 1);
            }
          } catch {
            /* 已删除 */
          }
        }
      });
      entry.watchers.push(watcher);
      entry.dirsWatched += 1;
    } catch {
      return;
    }
    let children: fs.Dirent[];
    try {
      children = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const child of children) {
      if (!child.isDirectory() || child.isSymbolicLink()) continue;
      const abs = path.join(dir, child.name);
      if (entry.opts.ignore(abs)) continue;
      this.watchDirs(entry, abs, depth + 1);
    }
  }

  private onRaw(entry: RootEntry, type: 'rename' | 'change', filename: string | Buffer | null): void {
    if (!filename) {
      this.record(entry, { kind: 'modified', path: entry.root, isDir: true });
      return;
    }
    const relText = String(filename).split(/[\\/]+/).filter(Boolean).join(path.sep);
    if (!relText) return;
    const abs = path.join(entry.root, relText);
    if (entry.opts.ignore(abs)) return;

    let isDir = false;
    let exists = true;
    try {
      isDir = fs.statSync(abs).isDirectory();
    } catch {
      exists = false;
    }
    const kind: FsEventKind = type === 'change' ? 'modified' : exists ? 'created' : 'deleted';
    this.record(entry, { kind, path: abs, isDir });
  }

  private record(entry: RootEntry, ev: FsEvent): void {
    const prev = entry.pending.get(ev.path);
    entry.pending.set(ev.path, prev ? { ...ev, kind: mergeKind(prev.kind, ev.kind) } : ev);
    if (entry.timer) return;
    entry.timer = setTimeout(() => {
      entry.timer = null;
      this.flush(entry);
    }, entry.opts.debounceMs);
    // 内核退出时不被去抖定时器拖住
    entry.timer.unref?.();
  }

  private flush(entry: RootEntry): void {
    if (entry.pending.size === 0) return;
    const batch = coalesceEvents(entry.pending, {
      root: entry.root,
      debounceMs: entry.opts.debounceMs,
      stormPerSecond: entry.opts.stormPerSecond,
      stormMinEvents: entry.opts.stormMinEvents,
      stormMinDirs: entry.opts.stormMinDirs,
    });
    entry.pending.clear();
    entry.stats.events += batch.events.length;
    entry.stats.batches += 1;
    if (batch.storm) entry.stats.storms += 1;
    void this.dispatch(entry, batch);
  }

  private async dispatch(entry: RootEntry, batch: FsBatch): Promise<void> {
    if (entry.running) {
      entry.queued = entry.queued ? mergeBatches(entry.queued, batch) : batch;
      return;
    }
    entry.running = true;
    try {
      for (const handler of [...entry.handlers]) {
        try {
          await handler(batch);
        } catch (err) {
          this.log?.('warn', 'watch handler failed', { root: entry.root, error: String(err) });
        }
      }
    } finally {
      entry.running = false;
      const queued = entry.queued;
      entry.queued = null;
      if (queued) void this.dispatch(entry, queued);
    }
  }

  private dispose(entry: RootEntry): void {
    if (entry.timer) {
      clearTimeout(entry.timer);
      entry.timer = null;
    }
    entry.handlers.clear();
    for (const w of entry.watchers) {
      try {
        w.close();
      } catch {
        /* 已关闭 */
      }
    }
    entry.watchers = [];
    entry.pending.clear();
    this.entries.delete(entry.root);
  }
}

/** 排队批合并：任一批是风暴 → 合并后仍按「目录级重扫」处理 */
export function mergeBatches(a: FsBatch, b: FsBatch): FsBatch {
  if (a.storm || b.storm) {
    return { root: a.root, at: b.at, storm: true, events: [{ kind: 'rescan', path: a.root, isDir: true }] };
  }
  const merged = new Map<string, FsEvent>();
  for (const ev of [...a.events, ...b.events]) {
    const prev = merged.get(ev.path);
    merged.set(ev.path, prev ? { ...ev, kind: mergeKind(prev.kind, ev.kind) } : ev);
  }
  return { root: a.root, at: b.at, storm: false, events: [...merged.values()] };
}