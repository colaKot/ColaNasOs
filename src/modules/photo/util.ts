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
  // 148_photo_media_kind 起（老查询可能没 select 这几列，故为可选）
  media_kind?: string | null;
  duration_ms?: number | null;
  live_kind?: string | null;
  live_size?: number | null;
  live_ms?: number | null;
  // 150_photo_live_span 起（老查询可能没 select 这几列，故为可选）
  live_offset?: number | null;
  live_vendor?: string | null;
  live_path?: string | null;
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
  // 169 起：规则相册的命中条件（JSON 文本，缺列时为 undefined）
  rules_json?: string | null;
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
    mediaKind: r.media_kind === 'video' ? ('video' as const) : ('image' as const),
    durationMs: r.duration_ms == null ? null : Number(r.duration_ms),
    liveKind: (r.live_kind === 'motion' || r.live_kind === 'apple' ? r.live_kind : '') as
      | 'motion'
      | 'apple'
      | '',
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
  // 规则解析失败一律当空数组（脏 JSON 不该让整个相册列表打不开）
  let rules: Array<Record<string, unknown>> = [];
  if (typeof r.rules_json === 'string' && r.rules_json.trim() !== '') {
    try {
      const parsed = JSON.parse(r.rules_json);
      if (Array.isArray(parsed)) rules = parsed;
    } catch {
      rules = [];
    }
  }
  return {
    id: r.id,
    name: r.name,
    items: Number(r.items) || 0,
    coverPath: r.cover_path,
    createdAt: r.created_at,
    description: r.description ?? null,
    coverItemId: r.cover_item_id ?? null,
    sortOrder: Number(r.sort_order) || 0,
    rules,
    ruleCount: rules.length,
  };
}
