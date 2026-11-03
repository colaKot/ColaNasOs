import Database from 'better-sqlite3';
import { Kysely, SqliteDialect } from 'kysely';

export interface DbHandle {
  db: Kysely<any>;
  raw: Database.Database;
}

/** 建库即调优（蓝图 §6.4） */
export function createDb(file: string): DbHandle {
  const raw = new Database(file);

  raw.pragma('journal_mode = WAL');
  raw.pragma('synchronous = NORMAL');
  raw.pragma('busy_timeout = 5000');
  raw.pragma('foreign_keys = ON');
  raw.pragma('temp_store = MEMORY');
  // 页缓存 64 MB（负值单位是 KiB）。默认 -2000 即 2 MB，在十万级照片 / 万级影视角色的
  // 多表 join 上会频繁回读磁盘。桌面形态内存不紧张，给足更划算。
  raw.pragma('cache_size = -64000');
  // 只读映射 256 MB：照片 / 影视列表大量顺序扫，走 mmap 少一次内核拷贝。
  // 32 位或受限环境可能失败，失败就退回默认（不影响正确性）。
  try {
    raw.pragma('mmap_size = 268435456');
  } catch {
    /* 环境不支持则忽略 */
  }

  const db = new Kysely<any>({ dialect: new SqliteDialect({ database: raw }) });
  return { db, raw };
}

/**
 * 统计信息刷新：`ANALYZE` 会写 `sqlite_stat1`，优化器据此估计代价。
 *
 * 不跑的话 stat1 是空的，优化器对每个索引都按默认值猜 —— 上面那些多表 join 与
 * 相关子查询很容易选错计划（表现是"有时快有时慢"，很难复现）。
 * 现在只在「本次启动真的跑过迁移」时执行（见 `kernel/index.ts` 的 kernel ready 之前）。
 */
export function analyzeTables(raw: Database.Database): void {
  try {
    raw.exec('ANALYZE');
  } catch {
    /* 分析失败不该阻断启动 */
  }
}

export interface IntegrityResult {
  ok: boolean;
  messages: string[];
}

/** 启动完整性检查（蓝图 §47）：quick_check 必须只有一条 "ok" */
export function checkIntegrity(raw: Database.Database): IntegrityResult {
  const rows = raw.pragma('quick_check') as Array<Record<string, unknown>>;
  const messages = rows.map((r) => String(Object.values(r)[0]));
  return { ok: messages.length === 1 && messages[0] === 'ok', messages };
}

/** 优雅关闭：先结束 Kysely，再关闭底层连接 */
export async function closeDb(handle: DbHandle): Promise<void> {
  await handle.db.destroy();
  try {
    handle.raw.close();
  } catch {
    /* 已关闭 */
  }
}
