import { sql } from 'kysely';
import { scanBookLibrary, type BookLibraryRow } from './scan';
import { BookRow } from './util';
import type { KernelApi } from '../../../kernel/types';

/** 书库 register 作用域内的闭包辅助函数（原样抽出，工厂化） */
export function makeBookHelpers(k: KernelApi, libWatch: { refresh(): Promise<void> | void }) {
    const ref = (id: string) => ({ $ref: `${id}#` });

    const limitOf = (raw: unknown, def: number, max: number) =>
      Math.max(1, Math.min(Number(raw ?? def) || def, max));

    const loadLibrary = async (id: string): Promise<BookLibraryRow | null> => {
      const res = await sql<BookLibraryRow>`select * from book_libraries where id = ${id}`.execute(
        k.db,
      );
      return res.rows[0] ?? null;
    };

    const loadBook = async (id: string, owner: string): Promise<BookRow | null> => {
      const res = await sql<BookRow>`
        select b.*,
               case when f.book_id is null then 0 else 1 end as favorite,
               p.percent as progress_percent,
               case when a.book_id is null then 0 else 1 end as archived
          from books b
          left join book_favorites f on f.book_id = b.id and f.owner_id = ${owner}
          left join book_progress p on p.book_id = b.id and p.owner_id = ${owner}
          left join book_archived a on a.book_id = b.id and a.owner_id = ${owner}
         where b.id = ${id}
      `.execute(k.db);
      return res.rows[0] ?? null;
    };

    const encodeNameCursor = (name: string) =>
      Buffer.from(JSON.stringify({ n: name })).toString('base64url');

    const decodeNameCursor = (raw?: string): { name: string } | null => {
      if (!raw) return null;
      try {
        const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as {
          n?: unknown;
        };
        return typeof parsed.n === 'string' ? { name: parsed.n } : null;
      } catch {
        return null;
      }
    };

    const encodeCollectionCursor = (index: number | null, title: string, id: string) =>
      Buffer.from(JSON.stringify({ x: index, t: title, i: id })).toString('base64url');

    const decodeCollectionCursor = (
      raw?: string,
    ): { index: number | null; title: string; id: string } | null => {
      if (!raw) return null;
      try {
        const parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as {
          x?: unknown;
          t?: unknown;
          i?: unknown;
        };
        if (typeof parsed.t !== 'string' || typeof parsed.i !== 'string') return null;
        const index = typeof parsed.x === 'number' && Number.isFinite(parsed.x) ? parsed.x : null;
        return { index, title: parsed.t, id: parsed.i };
      } catch {
        return null;
      }
    };
  return { ref, limitOf, loadLibrary, loadBook, encodeNameCursor, decodeNameCursor, encodeCollectionCursor, decodeCollectionCursor, libWatch };
}

export type BookHelpers = ReturnType<typeof makeBookHelpers>;
