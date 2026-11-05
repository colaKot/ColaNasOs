import { sql } from 'kysely';
import { scanBookLibrary, type BookLibraryRow } from './scan';
import type { KernelApi } from '../../../kernel/types';

/**
 * 来源级扫描调度（对齐参考实现的三项开关）：
 * - `scan_when_start`：内核启动后补扫一次；
 * - `scan_when_change`：文件监控是否自动重扫（由 library-watch 读取同一字段）；
 * - `scan_interval_hours`：每 N 小时整库校验一次（0 = 关闭）。
 */
const timers = new Map<string, NodeJS.Timeout>();
let running = false;

const loadLibs = async (k: KernelApi): Promise<BookLibraryRow[]> =>
  (await sql<BookLibraryRow>`select * from book_libraries`.execute(k.db)).rows;

async function scanOne(k: KernelApi, lib: BookLibraryRow, scope: string): Promise<void> {
  if (running) return;
  running = true;
  try {
    const result = await scanBookLibrary(k.db, lib);
    k.events.emit('scan.done', {
      domain: 'book',
      libraryId: lib.id,
      scope,
      result,
      at: Date.now(),
    });
  } catch (err) {
    k.log.warn({ library: lib.name, error: String(err) }, 'book: scheduled scan failed');
  } finally {
    running = false;
  }
}

/** 按当前库设置重建定时器（库增删改后调用） */
export async function applyBookScanSchedule(k: KernelApi): Promise<void> {
  for (const t of timers.values()) clearInterval(t);
  timers.clear();
  const libs = await loadLibs(k);
  for (const lib of libs) {
    const hours = Number(lib.scan_interval_hours) || 0;
    if (hours <= 0) continue;
    const timer = setInterval(
      () => void scanOne(k, lib, 'timer'),
      Math.min(24, Math.max(1, hours)) * 3600 * 1000,
    );
    timer.unref?.();
    timers.set(lib.id, timer);
  }
}

/** 启动扫描：延迟一点，别和内核启动 / 迁移抢 IO */
export function scheduleStartupScan(k: KernelApi): void {
  const timer = setTimeout(() => {
    void (async () => {
      try {
        const libs = await loadLibs(k);
        for (const lib of libs) {
          if (Number(lib.scan_when_start) === 1) await scanOne(k, lib, 'startup');
        }
      } catch {
        /* 内核已关闭 / DB 驱动销毁：忽略，别让定时器把进程带崩 */
      }
    })();
  }, 10_000);
  timer.unref?.();
}

export function stopBookScanSchedule(): void {
  for (const t of timers.values()) clearInterval(t);
  timers.clear();
}
