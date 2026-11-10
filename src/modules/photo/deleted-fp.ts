import { sql } from 'kysely';

/**
 * 「删过的照片」指纹墓碑。
 *
 * 起因：用户在 NAS 相册里删掉的照片，手机备份不该再传一遍。回收站里的行还在
 * （`in_trash = 1`），判重能命中；但「清空回收站」和「永久删除」是
 * `delete from photo_items`，行一没，判重就完全没有依据了 —— 用户下次备份，
 * 那些照片会被当成新照片重新上传，而且是每天都传一遍。
 *
 * 所以删除发生时把内容指纹单独记一份。这张表**只增不删**：
 * 恢复照片也不会删除墓碑，因为恢复后的行本身就在 `photo_items` 里，
 * 判重先命中主表，墓碑留着不影响任何事。
 */

/** 事务内调用时要传 `trx`：它和 `k.db` 不同型但 `.execute` 接口一致，所以放宽。 */
type Db = any;

/** 判重时墓碑命中的结果。 */
export interface DeletedMatches {
  /** 墓碑里出现过的 size（视作「服务端已有」） */
  sizes: Set<number>;
  /** 直接命中的 md5 */
  md5s: Set<string>;
  /** 只命中 size、墓碑本身没存 md5 的那些 size（删除时还没补码） */
  sizeOnly: Set<number>;
}

/**
 * 把一批照片的指纹写进墓碑。
 *
 * `ownerId` 传空串表示「按记录自己的 owner 写」—— 后台清理任务（回收站 30 天到期）
 * 是跨用户批处理的，拿不到单个 owner。传了 owner 就只写属于他的行。
 *
 * 用 `insert or ignore` + 唯一索引，同一张照片删两次不会堆重复行。
 */
export async function recordDeletedFingerprints(
  db: Db,
  ownerId: string,
  ids: string[],
): Promise<number> {
  const uid = String(ownerId || '').trim();
  if (ids.length === 0) return 0;
  const list = sql.join(
    ids.map((id) => sql`${id}`),
    sql`, `,
  );
  const now = Math.floor(Date.now() / 1000);
  const res = uid
    ? await sql`
        insert or ignore into photo_deleted_fp (owner_id, size, orig_size, content_md5, created_at)
        select l.owner_id, p.size, p.orig_size, coalesce(p.content_md5, ''), ${now}
          from photo_items p join photo_libraries l on l.id = p.library_id
         where l.owner_id = ${uid} and p.id in (${list})
      `.execute(db)
    : await sql`
        insert or ignore into photo_deleted_fp (owner_id, size, orig_size, content_md5, created_at)
        select l.owner_id, p.size, p.orig_size, coalesce(p.content_md5, ''), ${now}
          from photo_items p join photo_libraries l on l.id = p.library_id
         where p.id in (${list})
      `.execute(db);
  return Number(res.numAffectedRows ?? 0);
}

/**
 * 判重时查墓碑。
 *
 * `sizes` 用于粗筛（和 `photo_items` 的 size/orig_size 一起并进 present 集合），
 * `md5s` 用于精确命中。墓碑行没有 md5（删除时还没补码）时退化成按 size 判，
 * 这些 size 会出现在 `sizeOnly` 里 —— 调用方按「客户端报什么 md5 都算已存在」处理，
 * 因为用户本来就已经把这张照片删了，少传比重复上传更符合预期。
 */
export async function findDeletedMatches(
  db: Db,
  ownerId: string,
  sizes: number[],
): Promise<DeletedMatches> {
  const out: DeletedMatches = {
    sizes: new Set<number>(),
    md5s: new Set<string>(),
    sizeOnly: new Set<number>(),
  };
  const uid = String(ownerId || '').trim();
  if (!uid || sizes.length === 0) return out;
  const sizeList = sql.join(
    sizes.map((s) => sql`${s}`),
    sql`, `,
  );
  const rows = (
    await sql<{ size: number; orig_size: number; content_md5: string }>`
      select size, orig_size, content_md5 from photo_deleted_fp
       where owner_id = ${uid}
         and (size in (${sizeList}) or orig_size in (${sizeList}))
       limit 20000
    `.execute(db)
  ).rows;
  for (const r of rows) {
    const md5 = String(r.content_md5 || '').trim().toLowerCase();
    for (const v of [Number(r.size), Number(r.orig_size)]) {
      if (v <= 0) continue;
      out.sizes.add(v);
      if (!/^[0-9a-f]{32}$/.test(md5)) out.sizeOnly.add(v);
    }
    if (/^[0-9a-f]{32}$/.test(md5)) out.md5s.add(md5);
  }
  return out;
}
