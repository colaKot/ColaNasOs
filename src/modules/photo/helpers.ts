import { sql } from 'kysely';
import { scanLibrary, type LibraryRow } from './scan';
import { AlbumRow } from './util';
import type { KernelApi } from '../../../kernel/types';

/** 相册 register 作用域内的闭包辅助函数（原样抽出，工厂化） */
export function makePhotoHelpers(k: KernelApi, libWatch: { refresh(): Promise<void> | void }) {
    const ref = (id: string) => ({ $ref: `${id}#` });

    const limitOf = (raw: unknown, def: number, max: number) =>
      Math.max(1, Math.min(Number(raw ?? def) || def, max));

    const loadLibrary = async (id: string): Promise<LibraryRow | null> => {
      const res = await sql<LibraryRow>`select * from photo_libraries where id = ${id}`.execute(k.db);
      return res.rows[0] ?? null;
    };

    const loadAlbum = async (id: string, owner: string): Promise<AlbumRow | null> => {
      const res = await sql<AlbumRow>`
        select a.id, a.name, a.owner_id, a.created_at,
          a.description, a.cover_item_id, a.sort_order,
          (select count(*) from photo_album_items m where m.album_id = a.id) as items,
          coalesce(
            (select i.rel_path from photo_album_items m
               join photo_items i on i.id = m.item_id
              where m.album_id = a.id and i.id = a.cover_item_id),
            (select i.rel_path from photo_album_items m
               join photo_items i on i.id = m.item_id
              where m.album_id = a.id order by m.added_at, i.id limit 1)
          ) as cover_path
          from photo_albums a
         where a.id = ${id} and a.owner_id = ${owner}
      `.execute(k.db);
      return res.rows[0] ?? null;
    };
  return { ref, limitOf, loadLibrary, loadAlbum, libWatch };
}

export type PhotoHelpers = ReturnType<typeof makePhotoHelpers>;
