import crypto from 'node:crypto';
import path from 'node:path';

export const TAG = ['photo'];
export interface PhotoItemRow {
  id: string;
  library_id: string;
  rel_path: string;
  taken_at: number;
  size: number;
  width: number | null;
  height: number | null;
  mime: string;
  favorite: number | null;
}
export interface AlbumRow {
  id: string;
  name: string;
  owner_id: string;
  created_at: number;
  items: number;
  cover_path: string | null;
  // 084_photo_p2 起：用户自己挑的封面 / 简介 / 手排顺序（缺列时为 undefined）
  description?: string | null;
  cover_item_id?: string | null;
  sort_order?: number | null;
}
export function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}
export function toItem(r: PhotoItemRow) {
  return {
    id: r.id,
    libraryId: r.library_id,
    path: r.rel_path,
    takenAt: r.taken_at,
    size: r.size,
    width: r.width,
    height: r.height,
    mime: r.mime,
    favorite: Number(r.favorite) === 1,
  };
}
/** 排序键 cursor：`taken_at|id`（禁止 offset 深翻，见 03-契约与接口 §58） */
export function encodeCursor(takenAt: number, id: string): string {
  return Buffer.from(`${takenAt}|${id}`).toString('base64url');
}
export function decodeCursor(cursor?: string): { takenAt: number; id: string } | null {
  if (!cursor) return null;
  let text: string;
  try {
    text = Buffer.from(cursor, 'base64url').toString('utf8');
  } catch {
    return null;
  }
  const [taken, id] = text.split('|');
  const takenAt = Number(taken);
  if (!Number.isFinite(takenAt) || !id) return null;
  return { takenAt, id };
}
export function likePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}
export function albumFrom(r: AlbumRow) {
  return {
    id: r.id,
    name: r.name,
    items: Number(r.items) || 0,
    coverPath: r.cover_path,
    createdAt: r.created_at,
    description: r.description ?? null,
    coverItemId: r.cover_item_id ?? null,
    sortOrder: Number(r.sort_order) || 0,
  };
}
