import path from 'node:path';
import { sql } from 'kysely';
import { httpError } from '../files/fs-root';
import type { VideoSourceRow } from './sources';

/**
 * 图片库 / 混合库的文件夹范围。
 *
 * `rel_path` 里带来源根（例如 `D:/down/mt/move/a.jpg` 或 `\\nas\share\a.jpg`），
 * 所以文件夹路径也用**带来源根的完整 rel_path**，前端面包屑 / 文件夹卡片都直接传回。
 */
export type FolderMode = 'exact' | 'subtree' | '';

export function normalizeRelPath(input?: string | null): string {
  const rel = String(input || '')
    .replace(/\\/g, '/')
    .replace(/^\/+|\/+$/g, '');
  if (!rel) return '';
  for (const seg of rel.split('/')) {
    if (seg === '..' || seg === '.') throw httpError(400, 'invalid folder path');
  }
  return rel;
}

export function rootsOf(sources: VideoSourceRow[]): string[] {
  return sources
    .map((s) => String(s.root_path || '').replace(/\\/g, '/').replace(/\/+$/, ''))
    .filter(Boolean);
}

export function rootOf(folderPath: string, roots: string[]): string | null {
  const p = String(folderPath || '');
  if (!p) return null;
  for (const root of roots) {
    if (p === root || p.startsWith(`${root}/`)) return root;
  }
  return null;
}

/** 校验 folderPath 必须落在某个来源根内；返回命中的根 */
export function requireRoot(folderPath: string, roots: string[]): string | null {
  if (!folderPath) return null;
  const root = rootOf(folderPath, roots);
  if (!root) throw httpError(403, 'folder outside library');
  return root;
}

/** 面包屑：来源根 → 当前目录逐级路径 */
export function folderSegments(folderPath: string, root: string | null): Array<{ name: string; path: string }> {
  if (!folderPath || !root) return [];
  const rel = folderPath.slice(root.length).replace(/^\/+/, '');
  if (!rel) return [];
  const out: Array<{ name: string; path: string }> = [];
  let acc = root;
  for (const seg of rel.split('/').filter(Boolean)) {
    acc = `${acc}/${seg}`;
    out.push({ name: seg, path: acc });
  }
  return out;
}

export function parentFolderOf(folderPath: string, root: string | null): string | null {
  if (!folderPath || !root) return null;
  if (folderPath === root) return null;
  const parent = folderPath.replace(/\/+$/, '').split('/').slice(0, -1).join('/');
  return parent && parent.length >= root.length ? parent : null;
}

/** SQL 里的目录表达式（带尾斜杠），用于 exact 范围 / 文件夹聚合 */
export function dirExpr(alias: string): ReturnType<typeof sql> {
  return sql`rtrim(${sql.raw(alias)}.rel_path, replace(${sql.raw(alias)}.rel_path, '/', ''))`;
}

/** 图片库 / 混合库列表的文件夹范围条件 */
export function scopeCond(
  alias: string,
  folderPath: string,
  folderMode: FolderMode,
  roots: string[],
): ReturnType<typeof sql> {
  if (folderMode !== 'exact' && folderMode !== 'subtree') return sql`1 = 1`;
  const p = String(folderPath || '');
  if (p) {
    const prefix = `${p}/`;
    return folderMode === 'exact'
      ? sql`${dirExpr(alias)} = ${prefix}`
      : sql`substr(${sql.raw(alias)}.rel_path, 1, ${prefix.length}) = ${prefix}`;
  }
  // 库根：exact = 各来源根目录自身；subtree = 整库
  if (folderMode === 'subtree') return sql`1 = 1`;
  const parts = roots.map((r) => sql`${dirExpr(alias)} = ${`${r}/`}`);
  return parts.length > 0 ? sql`(${sql.join(parts, sql` or `)})` : sql`1 = 0`;
}

/** 图片与视频同名时，图片不再单独出现在混合库里 */
export function hideSameNameImageCond(alias = 'i'): ReturnType<typeof sql> {
  const dir = dirExpr(alias);
  const vdir = dirExpr('v');
  return sql`not exists (
    select 1 from video_items v
     where v.library_id = ${sql.raw(alias)}.library_id
       and ${vdir} = ${dir}
       and lower(replace(replace(v.title, ' ', ''), '_', ''))
         = lower(replace(replace(${sql.raw(alias)}.title, ' ', ''), '_', ''))
  )`;
}

/** 首字母筛选（# / A-Z） */
export function letterCond(alias: string, letter: string): ReturnType<typeof sql> {
  const l = String(letter || '').trim().toUpperCase();
  if (!l) return sql`1 = 1`;
  const first = sql`case when upper(substr(${sql.raw(alias)}.title, 1, 1)) between 'A' and 'Z'
                        then upper(substr(${sql.raw(alias)}.title, 1, 1)) else '#' end`;
  return sql`${first} = ${l}`;
}

/** 图片名自然序（img2 < img10）；没有专门列时用「名字 + 数字补零」的近似表达式 */
export function naturalNameExpr(alias: string): ReturnType<typeof sql> {
  return sql`coalesce(${sql.raw(alias)}.natural_name, lower(${sql.raw(alias)}.title))`;
}

/** 图片查询排序表达式（必须与游标里的 sort_key 完全一致） */
export function imageSortExpr(
  alias: string,
  by: string,
): ReturnType<typeof sql> {
  if (by === 'createTime') return sql`${sql.raw(alias)}.created_at`;
  if (by === 'takenTime') return sql`coalesce(${sql.raw(alias)}.taken_at, 0)`;
  if (by === 'viewTime') return sql`coalesce(${sql.raw(alias)}.view_at, 0)`;
  return naturalNameExpr(alias);
}

/** 视频查询排序表达式（混合库里时间口径与图片统一到入库时间） */
export function videoMediaSortExpr(
  alias: string,
  by: string,
  owner: string,
): ReturnType<typeof sql> {
  if (by === 'createTime' || by === 'takenTime') return sql`${sql.raw(alias)}.created_at`;
  if (by === 'viewTime') {
    return sql`coalesce((select max(p.updated_at) from video_progress p
                          where p.item_id = ${sql.raw(alias)}.id and p.owner_id = ${owner}), 0)`;
  }
  return sql`lower(coalesce(nullif(${sql.raw(alias)}.nfo_name, ''), ${sql.raw(alias)}.title))`;
}

/** 兼容旧数据：把 Windows 分隔符的 folderPath 转成 rel_path 里的 POSIX 形式 */
export function folderPathOf(input?: string | null): string {
  return normalizeRelPath(input);
}

export function joinRel(root: string, rel: string): string {
  return path.posix.join(root.replace(/\\/g, '/'), rel.replace(/\\/g, '/'));
}

/** 数字补零后的名字，供 SQL 自然排序 */
export function naturalKeyOf(title: string): string {
  return String(title || '')
    .toLowerCase()
    .replace(/\d+/g, (m) => m.padStart(6, '0'));
}

/** 首字母（A-Z），其它归到 # */
export function firstLetterOf(title: string): string {
  const first = String(title || '').trim().charAt(0).toUpperCase();
  return /^[A-Z]$/.test(first) ? first : '#';
}
