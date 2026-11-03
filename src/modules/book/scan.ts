import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { walkFiles } from '../files/walk';
import { mapLimit } from '../media/concurrency';
import { extensionOf, isBookFile, readBookMeta, titleOf } from './metadata';

/**
 * 书库扫描：库目录 → books。
 *
 * - 增量：size/mtime 未变直接跳过
 * - epub/cbz 解析内嵌元数据（标题/作者/语言/页数/封面标记），其余格式只用文件名
 * - 封面不在扫描阶段落盘，由 `/book/cover` 首次访问时提取并缓存
 */
export interface BookLibraryRow {
  id: string;
  name: string;
  root_path: string;
  created_at: number;
  last_scan_at: number | null;
  items: number;
}

interface ExistingRow {
  rel_path: string;
  size: number;
  mtime: number;
}

export interface BookScanResult {
  books: number;
  added: number;
  updated: number;
  skipped: number;
  parsed: number;
  /** 索引里有、磁盘上已不存在（仅整库扫描时统计） */
  missing: number;
  /** 本次实际清掉的缺失行（仅 prune 时） */
  pruned: number;
}

const UPSERT_BATCH = 100;
const PARSE_CONCURRENCY = 4;

interface Candidate {
  rel: string;
  fullRel: string;
  abs: string;
  size: number;
  mtime: number;
}

export async function scanBookLibrary(
  db: any,
  lib: BookLibraryRow,
  limit = 20000,
  subDir?: string,
  opts: { prune?: boolean } = {},
): Promise<BookScanResult> {
  const root = filesRoot();
  let rootAbs: string;
  try {
    rootAbs = resolveInRoot(root, lib.root_path);
  } catch {
    return { books: 0, added: 0, updated: 0, skipped: 0, parsed: 0, missing: 0, pruned: 0 };
  }

  // 增量重扫：`subDir` 为库内相对目录（文件监控按受影响目录触发），缺省扫整库
  const prefix = (subDir ?? '').replace(/^[/\\]+|[/\\]+$/g, '');
  let baseAbs = rootAbs;
  if (prefix) {
    try {
      baseAbs = resolveInRoot(rootAbs, prefix);
    } catch {
      return { books: 0, added: 0, updated: 0, skipped: 0, parsed: 0, missing: 0, pruned: 0 };
    }
  }

  const files = await walkFiles(baseAbs, Math.max(1, Math.min(limit, 20000)), isBookFile);

  const existing = new Map<string, ExistingRow>();
  const rows = await sql<ExistingRow>`
    select rel_path, size, mtime from books where library_id = ${lib.id}
  `.execute(db);
  for (const r of rows.rows) existing.set(r.rel_path, r);

  const result: BookScanResult = {
    books: files.length,
    added: 0,
    updated: 0,
    skipped: 0,
    parsed: 0,
    missing: 0,
    pruned: 0,
  };
  const nowSec = Math.floor(Date.now() / 1000);
  const seen = new Set<string>();

  const needs: Candidate[] = [];
  for (const scanned of files) {
    const rel = prefix ? `${prefix}/${scanned}` : scanned;
    const abs = path.join(rootAbs, rel.split('/').join(path.sep));
    let st;
    try {
      st = await fsp.stat(abs);
    } catch {
      continue;
    }
    const mtime = Math.floor(st.mtimeMs);
    const fullRel = `${lib.root_path}/${rel}`.replace(/^\/+/, '');
    seen.add(fullRel);
    const prev = existing.get(fullRel);
    if (prev && prev.size === st.size && prev.mtime === mtime) {
      result.skipped += 1;
      continue;
    }
    if (prev) result.updated += 1;
    else result.added += 1;
    needs.push({ rel, fullRel, abs, size: st.size, mtime });
  }

  const parsed = await mapLimit(needs, PARSE_CONCURRENCY, async (c) => {
    const meta = await readBookMeta(c.abs);
    return { ...c, meta };
  });
  for (const p of parsed) {
    if (p.meta.title || p.meta.author || p.meta.pageCount !== null) result.parsed += 1;
  }

  for (let i = 0; i < parsed.length; i += UPSERT_BATCH) {
    const chunk = parsed.slice(i, i + UPSERT_BATCH);
    await db.transaction().execute(async (trx: any) => {
      for (const p of chunk) {
        const m = p.meta;
        await sql`
          insert into books
            (id, library_id, rel_path, title, author, language, publisher, format,
             page_count, has_cover, size, mtime, created_at)
          values
            (${`${lib.id}_${Buffer.from(p.rel).toString('base64url')}`}, ${lib.id}, ${p.fullRel},
             ${m.title || titleOf(p.rel)}, ${m.author}, ${m.language}, ${m.publisher},
             ${extensionOf(p.rel)}, ${m.pageCount}, ${m.hasCover ? 1 : 0},
             ${p.size}, ${p.mtime}, ${nowSec})
          on conflict(library_id, rel_path) do update set
            title = excluded.title,
            author = excluded.author,
            language = excluded.language,
            publisher = excluded.publisher,
            format = excluded.format,
            page_count = excluded.page_count,
            has_cover = excluded.has_cover,
            size = excluded.size,
            mtime = excluded.mtime
        `.execute(trx);
      }
    });
  }

  // 只有整库扫描才能判定「索引里有、磁盘上已经没有」；子目录扫描的数据不完整，不能据此删行
  const missing = prefix ? [] : [...existing.keys()].filter((p) => !seen.has(p));
  result.missing = missing.length;
  if (missing.length > 0 && opts.prune && !prefix) {
    result.pruned = await pruneMissingBook(db, lib.id, missing);
  }

  await sql`
    update book_libraries
       set last_scan_at = ${nowSec},
           items = (select count(*) from books where library_id = ${lib.id})
     where id = ${lib.id}
  `.execute(db);

  return result;
}

/** 清理「磁盘上已不存在」的书（显式 prune 才走这里）；先清收藏 / 进度 / 归档 / 列表成员再删主行 */
async function pruneMissingBook(db: any, libraryId: string, relPaths: string[]): Promise<number> {
  const BATCH = 400;
  let removed = 0;
  for (let i = 0; i < relPaths.length; i += BATCH) {
    const chunk = relPaths.slice(i, i + BATCH);
    const list = sql.join(
      chunk.map((p) => sql`${p}`),
      sql`, `,
    );
    const ids = sql`select id from books where library_id = ${libraryId} and rel_path in (${list})`;
    await sql`delete from book_favorites where book_id in (${ids})`.execute(db);
    await sql`delete from book_progress where book_id in (${ids})`.execute(db);
    await sql`delete from book_archived where book_id in (${ids})`.execute(db);
    await sql`delete from book_list_items where book_id in (${ids})`.execute(db);
    const res = await sql`
      delete from books where library_id = ${libraryId} and rel_path in (${list})
    `.execute(db);
    removed += Number(res.numAffectedRows ?? 0);
  }
  return removed;
}