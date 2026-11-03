import crypto from 'node:crypto';
import path from 'node:path';

export const TAG = ['book'];
export const COVER_EXTENSIONS = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'];
export interface BookRow {
  id: string;
  library_id: string;
  rel_path: string;
  title: string;
  author: string | null;
  language: string | null;
  publisher: string | null;
  format: string;
  page_count: number | null;
  has_cover: number;
  size: number;
  mtime: number;
  favorite: number;
  progress_percent: number | null;
  collection: string | null;
  collection_index: number | null;
  archived: number;
}
export function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}
export function toBook(r: BookRow) {
  return {
    id: r.id,
    libraryId: r.library_id,
    path: r.rel_path,
    title: r.title,
    author: r.author,
    language: r.language,
    publisher: r.publisher,
    format: r.format,
    pageCount: r.page_count,
    hasCover: r.has_cover === 1,
    size: r.size,
    favorite: r.favorite === 1,
    progressPercent: r.progress_percent,
    collection: r.collection,
    collectionIndex: r.collection_index,
    archived: r.archived === 1,
  };
}
export function encodeCursor(title: string, id: string): string {
  return Buffer.from(JSON.stringify({ t: title, i: id })).toString('base64url');
}
export function decodeCursor(cursor?: string): { title: string; id: string } | null {
  if (!cursor) return null;
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')) as {
      t?: unknown;
      i?: unknown;
    };
    if (typeof parsed.t !== 'string' || typeof parsed.i !== 'string') return null;
    return { title: parsed.t, id: parsed.i };
  } catch {
    return null;
  }
}
export function likePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}
