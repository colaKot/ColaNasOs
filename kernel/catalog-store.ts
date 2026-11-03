import { sql } from 'kysely';

/**
 * 榜单快照存储（TMDB 发现页 / 日系榜单共用）。
 *
 * 为什么要有这张表：两处榜单此前都只有**进程内缓存**，重启即失效；断网或站点抽风时
 * 直接返回空列表。落库后可以做到两件进程内缓存做不到的事：
 *   1. 重启后仍然有榜单（用户感知：打开发现页不再空白）；
 *   2. 上游失败时回退到最近一次成功的快照（有旧数据好过没有）。
 *
 * 为什么两类榜单共用一张表：它们的形状完全一致 ——「一个 key 对应一份 JSON + 抓取时间」。
 * 分成两张表只会让「过期清理」写两遍，然后两边阈值不一致。
 *
 * 保留策略：`retainSec`（默认 7 天空窗期）。超过保留期的行在写入时顺手清掉，
 * 并在模块启动时再扫一次 —— 只靠写入触发的清理，在「用户再也不打开发现页」时会永远不跑。
 */

/** 榜单类型；新增来源时加在这里，清理与列表接口不用改 */
export const CATALOG_TYPES = ['tmdb', 'jp_rank'] as const;
export type CatalogType = (typeof CATALOG_TYPES)[number];

/** 默认保留期：7 天 */
export const DEFAULT_RETAIN_SEC = 7 * 24 * 60 * 60;

export interface CatalogSnapshotRow {
  catalogType: string;
  key: string;
  itemCount: number;
  snapshotAt: number;
}

export interface CatalogSnapshot extends CatalogSnapshotRow {
  payload: unknown;
}

interface RawRow {
  catalog_type: string;
  key: string;
  payload: string;
  item_count: number | null;
  snapshot_at: number;
}

const nowSec = () => Math.floor(Date.now() / 1000);

/** 读一份快照（不判断新鲜度 —— 调用方比 snapshotAt 自己决定是"用"还是"仅当兜底"） */
export async function readSnapshot(
  db: any,
  catalogType: CatalogType,
  key: string,
): Promise<CatalogSnapshot | null> {
  const row = (
    await sql<RawRow>`
      select catalog_type, key, payload, item_count, snapshot_at
        from media_catalog
       where catalog_type = ${catalogType} and key = ${key}
    `.execute(db)
  ).rows[0];
  if (!row) return null;
  try {
    return {
      catalogType: row.catalog_type,
      key: row.key,
      payload: JSON.parse(row.payload),
      itemCount: Number(row.item_count) || 0,
      snapshotAt: Number(row.snapshot_at) || 0,
    };
  } catch {
    // payload 损坏：当作没有，下一次抓取会覆盖它
    return null;
  }
}

export interface WriteSnapshotOptions {
  itemCount?: number;
  /** 保留期，默认 7 天；写入时顺便清理过期行 */
  retainSec?: number;
}

/** 写一份快照（UPSERT），并顺手清理过期行 */
export async function writeSnapshot(
  db: any,
  catalogType: CatalogType,
  key: string,
  payload: unknown,
  opts: WriteSnapshotOptions = {},
): Promise<void> {
  const ts = nowSec();
  const body = JSON.stringify(payload ?? null);
  await sql`
    insert into media_catalog (catalog_type, key, payload, item_count, snapshot_at)
    values (${catalogType}, ${key}, ${body}, ${Number(opts.itemCount) || 0}, ${ts})
    on conflict(catalog_type, key) do update set
      payload = excluded.payload,
      item_count = excluded.item_count,
      snapshot_at = excluded.snapshot_at
  `.execute(db);
  await pruneSnapshots(db, { catalogType, retainSec: opts.retainSec });
}

/** 清理超过保留期的快照；返回删除行数 */
export async function pruneSnapshots(
  db: any,
  opts: { catalogType?: CatalogType; retainSec?: number } = {},
): Promise<number> {
  const retain = Math.max(3600, Number(opts.retainSec) || DEFAULT_RETAIN_SEC);
  const before = nowSec() - retain;
  const res = await sql`
    delete from media_catalog
     where snapshot_at < ${before}
       ${opts.catalogType ? sql`and catalog_type = ${opts.catalogType}` : sql``}
  `.execute(db);
  return Number(res.numAffectedRows || 0);
}

/** 快照清单（给状态接口与冒烟用；不含 payload，避免一页几百 KB） */
export async function listSnapshots(
  db: any,
  catalogType?: CatalogType,
): Promise<CatalogSnapshotRow[]> {
  const rows = (
    await sql<Omit<RawRow, 'payload'>>`
      select catalog_type, key, item_count, snapshot_at
        from media_catalog
       ${catalogType ? sql`where catalog_type = ${catalogType}` : sql``}
       order by snapshot_at desc, key asc
       limit 500
    `.execute(db)
  ).rows;
  return rows.map((r) => ({
    catalogType: r.catalog_type,
    key: r.key,
    itemCount: Number(r.item_count) || 0,
    snapshotAt: Number(r.snapshot_at) || 0,
  }));
}

/** 是否算「新鲜」（给调用方与状态接口共用同一套判断） */
export function isFresh(snapshotAt: number, ttlSec: number): boolean {
  if (!snapshotAt) return false;
  return nowSec() - snapshotAt <= Math.max(1, ttlSec);
}
