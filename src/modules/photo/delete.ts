import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';

/**
 * 相册永久删除与回收站保留策略。
 *
 * 口径（与现有「清空回收站只删索引、不动磁盘文件」一致）：
 *   - 永久删除 = 删 `photo_items` + 所有派生数据（场景/活动/OCR/向量/人脸/相册成员/集合成员/GPS 候选），
 *     磁盘原图不动；
 *   - 回收站保留 **30 天**，超过后由定时任务按同一套级联逻辑清理。
 */
export const TRASH_RETENTION_DAYS = 30;

/** 以 photo_id 关联的表 */
const PHOTO_ID_TABLES = [
  'photo_scenes',
  'photo_activities',
  'photo_ocr',
  'photo_embeddings',
  'photo_faces',
  'photo_gps_candidates',
];

/** 以 item_id 关联的表 */
const ITEM_ID_TABLES = ['photo_album_items', 'photo_collection_items'];

function idList(ids: string[]) {
  return sql.join(
    ids.map((id) => sql`${id}`),
    sql`, `,
  );
}

async function deleteRows(db: any, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const list = idList(ids);
  for (const table of PHOTO_ID_TABLES) {
    await sql`delete from ${sql.table(table)} where photo_id in (${list})`.execute(db);
  }
  for (const table of ITEM_ID_TABLES) {
    await sql`delete from ${sql.table(table)} where item_id in (${list})`.execute(db);
  }
  await sql`delete from photo_items where id in (${list})`.execute(db);
}

/** 永久删除：只删索引与派生数据，磁盘文件保留 */
export async function deletePhotosPermanently(
  k: KernelApi,
  owner: string,
  ids: string[],
): Promise<number> {
  if (ids.length === 0) return 0;
  return k.db.transaction().execute(async (trx: any) => {
    const rows = (
      await sql<{ id: string }>`
        select id from photo_items
         where id in (${idList(ids)})
           and library_id in (select id from photo_libraries where owner_id = ${owner})
      `.execute(trx)
    ).rows;
    const owned = rows.map((r) => r.id);
    if (owned.length === 0) return 0;
    await deleteRows(trx, owned);
    return owned.length;
  });
}

/** 超过保留期的回收站条目：按 500 一批清理（跨用户，由后台定时任务调用） */
export async function purgeExpiredTrash(
  k: KernelApi,
  days = TRASH_RETENTION_DAYS,
): Promise<number> {
  const cutoff = Math.floor(Date.now() / 1000) - days * 86400;
  let total = 0;
  for (let round = 0; round < 20; round += 1) {
    const rows = (
      await sql<{ id: string }>`
        select id from photo_items
         where in_trash = 1 and deleted_at is not null and deleted_at < ${cutoff}
         limit 500
      `.execute(k.db)
    ).rows;
    if (rows.length === 0) break;
    const ids = rows.map((r) => r.id);
    await k.db.transaction().execute(async (trx: any) => {
      await deleteRows(trx, ids);
    });
    total += ids.length;
  }
  return total;
}