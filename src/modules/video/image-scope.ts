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
  const raw = String(input || '').replace(/\\/g, '/');
  // UNC 路径的前导 `//` 是语义的一部分（`//host/share`），不能像普通绝对路径
  // 那样剥掉，否则 requireRoot 会把它当成 `host/share` 判越界（SMB 来源 403）。
  const unc = raw.startsWith('//');
  const rel = raw.replace(/^\/+|\/+$/g, '');
  if (!rel) return '';
  for (const seg of rel.split('/')) {
    if (seg === '..' || seg === '.') throw httpError(400, 'invalid folder path');
  }
  return unc ? `//${rel}` : rel;
}

export function rootsOf(sources: VideoSourceRow[]): string[] {
  return sources
    .map((s) => String(s.root_path || '').replace(/\\/g, '/').replace(/\/+$/, ''))
    .filter(Boolean);
}

/** 统一折叠成正斜杠再比较：SMB 的 dir_path 是 `\\host\share/JK/` 这种混合形态。 */
function foldSlashes(input: string): string {
  return String(input || '').replace(/\\/g, '/');
}

export function rootOf(folderPath: string, roots: string[]): string | null {
  const p = foldSlashes(folderPath);
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
  const full = foldSlashes(folderPath);
  if (!full || !root) return [];
  const rel = full.slice(root.length).replace(/^\/+/, '');
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
  const full = foldSlashes(folderPath);
  if (!full || !root) return null;
  if (full === root) return null;
  const parent = full.replace(/\/+$/, '').split('/').slice(0, -1).join('/');
  return parent && parent.length >= root.length ? parent : null;
}

/**
 * 目录前缀（带尾斜杠）：扫描写入 `dir_path` 列与查询共用同一口径。
 * 与旧 SQL `rtrim(rel_path, replace(rel_path,'/',''))` 完全等价。
 */
export function dirPathOf(relPath: string): string {
  const p = String(relPath || '');
  const i = p.lastIndexOf('/');
  return i < 0 ? '' : p.slice(0, i + 1);
}

/** SQL 里的目录列：已经预写进库，可走 (library_id, dir_path) 索引。 */
export function dirExpr(alias: string): ReturnType<typeof sql> {
  return sql`${sql.raw(alias)}.dir_path`;
}

/** SQL 里折叠来源路径的反斜杠（SMB 的 dir_path 是 `\\host\share/JK/` 混合形态） */
function dirSlashExpr(alias: string): ReturnType<typeof sql> {
  return sql`replace(${dirExpr(alias)}, ${'\\'}, '/')`;
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
    // UNC 路径（`//host/share/...`）在 dir_path 列里写成 `\\host\share/...`，
    // 必须在 SQL 里折一次斜杠才比得上；本地盘符路径形态一致，继续走索引。
    const dir = p.startsWith('//') ? dirSlashExpr(alias) : dirExpr(alias);
    return folderMode === 'exact'
      ? sql`${dir} = ${prefix}`
      : sql`substr(${dir}, 1, ${prefix.length}) = ${prefix}`;
  }
  // 库根：exact = 各来源根目录自身；subtree = 整库
  if (folderMode === 'subtree') return sql`1 = 1`;
  const parts = roots.map((r) => {
    const dir = r.startsWith('//') ? dirSlashExpr(alias) : dirExpr(alias);
    return sql`${dir} = ${`${r}/`}`;
  });
  return parts.length > 0 ? sql`(${sql.join(parts, sql` or `)})` : sql`1 = 0`;
}

/**
 * 图片与视频同名时，图片不再单独出现在混合库里。
 *
 * 目录相等判断改用预写的 dir_path 列，配合 idx_video_items_dir 只回查同目录的影片。
 * 名字归一化是**列上的函数**，`(library_id, dir_path)` 只能把范围缩到同目录，
 * 同一目录下的影片仍要逐条现算 —— 混合库整库列表实测 656ms。
 * 迁移 `179_video_same_name_idx` 给这个表达式建了索引，内层变成一次索引点查，
 * 因此下面的表达式必须与那条索引**逐字一致**，改这里要一起改。
 */
export function hideSameNameImageCond(alias = 'i'): ReturnType<typeof sql> {
  return sql`not exists (
    select 1 from video_items v
     where v.library_id = ${sql.raw(alias)}.library_id
       and v.dir_path = ${sql.raw(alias)}.dir_path
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
  const base = String(root || '').replace(/\\/g, '/').replace(/\/+$/, '');
  const suffix = String(rel || '').replace(/\\/g, '/').replace(/^\/+/, '');
  const joined = path.posix.join(base, suffix);
  // path.posix.join 会把 UNC 的前导 `//` 塌成一个 `/`，这里补回来
  return base.startsWith('//') && !joined.startsWith('//') ? `/${joined}` : joined;
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
