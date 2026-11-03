import type { CacheSnapshotItem } from './types';

/**
 * 缓存命中计数器（只为**测量**存在，不决定缓存策略）。
 *
 * - 命中判定交给各 handler（它们是唯一知道「缓存文件在不在」的地方）；
 * - 这里只累加 hits / misses，重启即清零 —— 长期指标应该看日志与指标系统，
 *   进程内计数器的作用是「开发与冒烟时可断言」。
 * - 名字约定 `<域>.<对象>`，例如 `files.thumb` / `book.cover` / `music.cover`。
 */
export class CacheStats {
  private readonly counters = new Map<string, { hits: number; misses: number }>();

  record(name: string, hit: boolean): void {
    const cur = this.counters.get(name) ?? { hits: 0, misses: 0 };
    if (hit) cur.hits += 1;
    else cur.misses += 1;
    this.counters.set(name, cur);
  }

  snapshot(): CacheSnapshotItem[] {
    return [...this.counters.entries()]
      .map(([name, c]) => {
        const total = c.hits + c.misses;
        return {
          name,
          hits: c.hits,
          misses: c.misses,
          hitRate: total === 0 ? 0 : Math.round((c.hits / total) * 1000) / 1000,
        };
      })
      .sort((a, b) => b.hits + b.misses - (a.hits + a.misses));
  }

  reset(): void {
    this.counters.clear();
  }
}