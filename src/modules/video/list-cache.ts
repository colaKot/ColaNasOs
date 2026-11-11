import type { KernelApi } from '../../../kernel/types';

/**
 * 图片 / 混合库列表的短 TTL 结果缓存。
 *
 * 为什么需要：`image_items` 的目录表达式（`rtrim`）、`scopeCond` 的 `substr` 前缀
 * 和 `hideSameNameImageCond` 的 `NOT EXISTS` 都走不了索引，混合库一次 list /
 * folders 聚合就是整库扫描；`better-sqlite3` 是同步驱动，重查询期间整个事件循环
 * 被占住，用户切文件夹时后续请求只能排队等（表现为「切了很久才换列表」）。
 *
 * 这里按「接口 + 用户 + 完整查询参数」缓存 200 响应，扫描完成 / SMB 上线 /
 * 删除文件夹时整体失效；TTL 兜底观看状态等低频变更。
 */

type Entry = { at: number; value: unknown };

const CACHE_TTL_MS = 20 * 1000;
const MAX_ENTRIES = 256;
const cache = new Map<string, Entry>();
const bound = new WeakSet<object>();

export function videoListCacheGet(key: string): unknown | null {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at >= CACHE_TTL_MS) {
    cache.delete(key);
    return null;
  }
  return hit.value;
}

export function videoListCacheSet(key: string, value: unknown): void {
  cache.set(key, { at: Date.now(), value });
  if (cache.size > MAX_ENTRIES) {
    const oldest = [...cache.entries()].sort((a, b) => a[1].at - b[1].at)[0];
    if (oldest) cache.delete(oldest[0]);
  }
}

export function videoListCacheClear(): void {
  cache.clear();
}

/** 扫描完成 / SMB 上线都会改变索引内容或离线过滤，旧结果必须作废。 */
export function bindVideoListCacheInvalidation(k: KernelApi): void {
  if (bound.has(k)) return;
  bound.add(k);
  k.events.on('scan.done', () => videoListCacheClear());
  k.events.on('video.smb.online', () => videoListCacheClear());
}

/**
 * 缓存键：接口前缀 + 用户 + 排序后的全部查询参数。
 * `req.user.sub` 必须进来 —— `watched` / 进度是用户维度的，不能跨用户串数据。
 */
export function videoListCacheKey(
  prefix: string,
  query: unknown,
  owner = '',
): string {
  const q = (query || {}) as Record<string, unknown>;
  const parts = Object.keys(q)
    .sort()
    .map((name) => `${name}=${String(q[name] ?? '')}`);
  return `${prefix}\u0000${owner}\u0000${parts.join('\u0001')}`;
}
