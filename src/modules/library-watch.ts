import path from 'node:path';
import type { FsBatch } from '../../kernel/fs-watch';
import type { KernelApi } from '../../kernel/types';
import { filesRoot, resolveAnyPath } from './files/fs-root';

/**
 * 媒体库 + 文件监控/轮询的接线（蓝图 §56）。
 *
 * 约定：
 * - **只订阅库根目录**，不订阅整个 files 根 —— files 根默认是用户主目录，递归监视它等于监视整台机器。
 * - 本地库走 `fs.watch`（`k.watch`）；SMB 等非本地根走**轮询快照 diff**（`k.poll`）。
 * - 事件落到某库 → 只重扫**受影响的那一层目录**（`subDir`）；一串小目录超过阈值则退化为整库一次扫描。
 * - 扫描**全局串行**：媒体索引是 CPU/IO 密集型，交错跑只会互相拖慢，也避免同一批文件重复探测。
 * - 库的增删由模块在 CRUD 后调用 `refresh()` 重新对齐订阅关系。
 * - 扫描完成后 `k.events.emit('scan.done', …)`，客户端据此做局部刷新。
 * - 周期性**全量校验**（默认 6 小时）：网络盘断开重连、外部删除这类「没事件」的漂移，
 *   靠一次整库扫描补齐 —— 只统计 `missing`，不自动删索引（见各模块 `scan` 的 `prune` 选项）。
 *
 * 监控负责「及时」，全量扫描负责「正确」：两者都用 `mtime + size` 做幂等判断。
 */

export interface WatchableLibrary {
  id: string;
  name: string;
  root_path: string;
  /** 可选：1 目录变化时自动重扫；0 / 缺省按旧行为（自动） */
  scan_when_change?: number | null;
}

export interface LibraryWatchSpec<T extends WatchableLibrary> {
  k: KernelApi;
  /** 日志前缀（photo / video / music / book） */
  domain: string;
  /** 读取当前库列表（每次 refresh 调用） */
  load: () => Promise<T[]>;
  /** 扫描：`subDir` 为库内相对目录（POSIX 分隔符），缺省表示整个库 */
  scan: (lib: T, subDir?: string) => Promise<unknown>;
  /** 文件白名单，用于丢弃与媒体无关的事件 */
  accept: (name: string) => boolean;
  /** 非本地根（UNC / 挂载点）：返回后改用轮询；返回 null 表示走本地 fs.watch */
  remoteRootOf?: (lib: T) => string | null;
  /** 受影响的目录数超过它就改为一整库扫描，默认 4 */
  maxSubDirs?: number;
  /** 周期性全量校验间隔，默认 6 小时；0 关闭 */
  verifyIntervalMs?: number;
  /**
   * 每库独立的扫描周期（毫秒）。返回 0 / 不传表示该库跟随 `verifyIntervalMs`。
   *
   * 音乐来源页有「间隔扫描 N 小时」开关，是**按库**配置的；只有全局定时器表达不了。
   */
  intervalOf?: (lib: T) => number;
  /**
   * 运行时策略（可选；不传即保持「自动监视 + 固定校验间隔」的旧行为）。
   * photo 用它接「自动监视 / 周期校验 / 跳过隐藏文件」三个开关。
   */
  policy?: () => { watch: boolean; verifyIntervalMs: number };
  /**
   * 订阅键（默认 `lib.id`）。
   *
   * 一个库可以有多个来源（影视多来源），每个来源要单独订阅一个根目录，
   * 于是同一个库会在 `load()` 里出现多份记录 —— 用复合键区分，
   * 而事件里的 `libraryId` 仍走 `idOf` 回到真实库 id。
   */
  keyOf?: (lib: T) => string;
  /** 事件里上报的库 id（默认 `lib.id`） */
  idOf?: (lib: T) => string;
}

export interface LibraryWatch {
  /** 库增删后重新对齐订阅关系 */
  refresh(): Promise<void>;
  /** 内核关闭 / 模块卸载时调用 */
  stop(): void;
}

export const DEFAULT_VERIFY_INTERVAL_MS = 6 * 60 * 60 * 1000;

/** `COLANAS_VERIFY_INTERVAL_MS`（0 = 关闭周期全量校验） */
function verifyIntervalFromEnv(): number | null {
  const raw = Number(process.env.COLANAS_VERIFY_INTERVAL_MS);
  if (!Number.isFinite(raw) || raw < 0) return null;
  return raw;
}

export function bindLibraryWatch<T extends WatchableLibrary>(spec: LibraryWatchSpec<T>): LibraryWatch {
  // 开发版重叠实例守卫：另一个实例在跑时，监控 / 周期校验 / 间隔扫描全部跳过
  if (!spec.k.background.enabled) {
    spec.k.log.info({ domain: spec.domain }, '[dev] 重叠模式：文件监控与周期扫描已跳过');
    return { refresh: async () => {}, stop: () => {} };
  }
  const root = filesRoot();
  const maxSubDirs = spec.maxSubDirs ?? 4;
  const defaultVerifyIntervalMs =
    spec.verifyIntervalMs ?? verifyIntervalFromEnv() ?? DEFAULT_VERIFY_INTERVAL_MS;
  /** 当前策略：没传 policy 时等价于「总是监视 + 默认校验间隔」 */
  const currentPolicy = () =>
    spec.policy?.() ?? { watch: true, verifyIntervalMs: defaultVerifyIntervalMs };
  const watching = () => currentPolicy().watch;
  const libs = new Map<string, T>();
  const subs = new Map<string, () => void>();
  /** 每个库的事件基准路径（本地库是库绝对路径，远程库是 UNC） */
  const eventRoots = new Map<string, string>();
  const pending = new Map<string, { dirs: Set<string>; full: boolean }>();
  let chain: Promise<void> = Promise.resolve();
  let verifyTimer: NodeJS.Timeout | null = null;
  /** 每库独立周期（`intervalOf` 有返回值时才填） */
  const perLibTimers = new Map<string, NodeJS.Timeout>();
  let stopped = false;

  const keyOf = (lib: T) => spec.keyOf?.(lib) ?? lib.id;
  const idOf = (lib: T) => spec.idOf?.(lib) ?? lib.id;

  const localAbsOf = (lib: T): string | null => {
    try {
      // 库根允许在 files 根之外（`D:/Photos` 这类绝对来源），
      // 只认 files 根会让这些库**永远没有文件监控** —— 加了文件界面不刷新。
      return resolveAnyPath(root, lib.root_path);
    } catch {
      return null;
    }
  };

  const eventRootOf = (lib: T): string | null => {
    const remote = spec.remoteRootOf?.(lib) ?? null;
    if (remote) return remote;
    return localAbsOf(lib);
  };

  const emitScanDone = (lib: T, scope: string, ms: number, result: unknown) => {
    // 事件流是全局的：只放域 / 库 id / 计数，不放库名与路径（否则跨用户可见）
    spec.k.events.emit('scan.done', {
      domain: spec.domain,
      libraryId: idOf(lib),
      scope,
      ms,
      result,
      at: Date.now(),
    });
  };

  const scanOne = async (lib: T, task: { dirs: Set<string>; full: boolean }) => {
    const started = Date.now();
    const dirs = [...task.dirs];
    try {
      if (task.full || dirs.length > maxSubDirs) {
        if (dirs.length > 0 && !task.full) {
          spec.k.log.info(
            { domain: spec.domain, library: lib.name, dirs: dirs.length },
            'watch: too many dirs, fallback to full library scan',
          );
        }
        const result = await spec.scan(lib);
        const ms = Date.now() - started;
        spec.k.log.info({ domain: spec.domain, library: lib.name, ms, result }, 'watch: library rescanned');
        emitScanDone(lib, 'full', ms, result);
        return;
      }
      for (const dir of dirs) {
        const result = await spec.scan(lib, dir);
        const ms = Date.now() - started;
        spec.k.log.info(
          { domain: spec.domain, library: lib.name, dir, ms, result },
          'watch: directory rescanned',
        );
        emitScanDone(lib, dir === '' ? 'full' : 'dir', ms, result);
      }
    } catch (err) {
      spec.k.log.warn(
        { domain: spec.domain, library: lib.name, error: String(err) },
        'watch: incremental scan failed',
      );
    }
  };

  const drain = async () => {
    while (!stopped) {
      const next = pending.entries().next();
      if (next.done) return;
      const [key, task] = next.value;
      pending.delete(key);
      const lib = libs.get(key);
      if (!lib) continue;
      await scanOne(lib, task);
    }
  };

  const schedule = (lib: T, dir: string | null) => {
    if (stopped || !watching()) return;
    const key = keyOf(lib);
    const cur = pending.get(key) ?? { dirs: new Set<string>(), full: false };
    if (dir === null) cur.full = true;
    else cur.dirs.add(dir);
    pending.set(key, cur);
    chain = chain.then(drain);
  };

  const onBatch = (batch: FsBatch) => {
    if (stopped || !watching()) return;
    // 来源级「变更自动扫描」开关：只有显式 0 才跳过；其它模块没有该字段 → 保持自动
    const all = [...libs.values()].filter((l) => l.scan_when_change !== 0);
    for (const ev of batch.events) {
      if (ev.kind === 'rescan') {
        for (const lib of all) schedule(lib, null);
        continue;
      }
      for (const lib of all) {
        const base = eventRoots.get(keyOf(lib));
        if (!base) continue;
        const rel = path.relative(base, ev.path);
        if (rel === '') {
          // 库根本身被创建 / 删除 / 改名
          schedule(lib, null);
          continue;
        }
        if (rel.startsWith('..') || path.isAbsolute(rel)) continue;
        const relPosix = rel.split(path.sep).join('/');
        if (ev.isDir) {
          schedule(lib, relPosix);
          continue;
        }
        if (!spec.accept(path.basename(ev.path))) continue;
        const dir = path.posix.dirname(relPosix);
        schedule(lib, dir === '.' ? '' : dir);
      }
    }
  };

  const refresh = async (): Promise<void> => {
    if (stopped) return;
    let list: T[];
    try {
      list = await spec.load();
    } catch (err) {
      spec.k.log.warn({ domain: spec.domain, error: String(err) }, 'watch: load libraries failed');
      return;
    }
    const alive = new Set(list.map((l) => keyOf(l)));
    for (const lib of list) libs.set(keyOf(lib), lib);
    for (const [key, off] of [...subs]) {
      if (alive.has(key)) continue;
      off();
      subs.delete(key);
      eventRoots.delete(key);
      libs.delete(key);
      pending.delete(key);
    }
    // 关闭自动监视：退订全部库（手动扫描仍可用），并同步周期校验
    if (!watching()) {
      for (const off of subs.values()) off();
      subs.clear();
      eventRoots.clear();
      applyVerifyTimer();
      applyPerLibTimers();
      return;
    }
    for (const lib of list) {
      const key = keyOf(lib);
      if (subs.has(key)) continue;
      const base = eventRootOf(lib);
      if (!base) continue;
      const remote = spec.remoteRootOf?.(lib) ?? null;
      subs.set(
        key,
        remote ? spec.k.poll.subscribe(base, onBatch) : spec.k.watch.subscribe(base, onBatch),
      );
      eventRoots.set(key, base);
    }
    applyVerifyTimer();
    applyPerLibTimers();
  };

  /** 周期性全量校验：补齐「没有事件」的漂移（外部删除 / 网络盘重连） */
  const verifyAll = () => {
    if (stopped) return;
    // 错峰：多个库同时全量 walk 会互相拖慢，也会和用户请求抢 IO；0~60 s 随机散开
    for (const lib of libs.values()) {
      if (lib.scan_when_change === 0) continue;
      // 配了自己的间隔就别跟着全局校验再扫一遍
      if ((spec.intervalOf?.(lib) ?? 0) > 0) continue;
      // 错峰：多个库同时全量 walk 会互相拖慢，也会和用户请求抢 IO；0~60 s 随机散开
      const timer = setTimeout(
        () => {
          if (!stopped) schedule(lib, null);
        },
        Math.floor(Math.random() * 60_000),
      );
      timer.unref?.();
    }
  };

  /** 按当前策略重建周期校验定时器（幂等；策略变更后调用） */
  const applyVerifyTimer = () => {
    if (verifyTimer) {
      clearInterval(verifyTimer);
      verifyTimer = null;
    }
    const want = currentPolicy().verifyIntervalMs;
    if (!stopped && want > 0) {
      verifyTimer = setInterval(verifyAll, want);
      verifyTimer.unref?.();
    }
  };

  applyVerifyTimer();

  /** 按每库 `intervalOf` 重建「间隔扫描」定时器（幂等；库增删/开关变更后调用） */
  const applyPerLibTimers = () => {
    for (const t of perLibTimers.values()) clearInterval(t);
    perLibTimers.clear();
    if (stopped || !spec.intervalOf) return;
    for (const lib of libs.values()) {
      const raw = Math.trunc(Number(spec.intervalOf(lib)) || 0);
      if (!(raw > 0)) continue;
      const timer = setInterval(
        () => {
          if (stopped || lib.scan_when_change === 0) return;
          schedule(lib, null);
        },
        // 少于 1 分钟的周期没有意义，只会把 IO 打满
        Math.max(60_000, raw),
      );
      timer.unref?.();
      perLibTimers.set(keyOf(lib), timer);
    }
  };

  const stop = () => {
    stopped = true;
    if (verifyTimer) {
      clearInterval(verifyTimer);
      verifyTimer = null;
    }
    for (const t of perLibTimers.values()) clearInterval(t);
    perLibTimers.clear();
    for (const off of subs.values()) off();
    subs.clear();
    eventRoots.clear();
    libs.clear();
    pending.clear();
  };

  return { refresh, stop };
}