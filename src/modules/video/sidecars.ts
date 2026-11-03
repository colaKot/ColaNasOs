import fs from 'node:fs';
import path from 'node:path';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { findNfoFile } from './nfo';

/**
 * 与一个视频条目绑定的侧车文件（字幕 / NFO / 海报 / 剧照 / 缩略图）。
 *
 * 删除重复项时只删**属于它自己**的侧车：
 *   * 同名字幕（`Movie.srt` / `Movie.zh.srt`）
 *   * 同名前缀的图（`Movie-poster.jpg` / `Movie-fanart.jpg` / `Movie.jpg`）
 *   * `findNfoFile` 找到的 NFO（含目录级 `movie.nfo`）
 *   * NFO 里显式登记的 `nfo_poster` / `nfo_fanart` / `nfo_thumb`
 *
 * 保护规则在删除路由里做：只要保留下来的任何条目也引用同一个文件，就不删。
 */
const SIDE_EXT = new Set([
  '.nfo',
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.avif',
]);

export interface ArtRefRow {
  rel_path: string;
  nfo_poster?: string | null;
  nfo_fanart?: string | null;
  nfo_thumb?: string | null;
}

function absOfRel(rel: string): string | null {
  try {
    return resolveAnyPath(filesRoot(), rel);
  } catch {
    return null;
  }
}

/** NFO 里登记的图片可能是相对 filesRoot / 绝对路径 / 远端 URL */
export function resolveArtRef(ref: string | null | undefined): string | null {
  const raw = String(ref || '').trim();
  if (!raw || /^https?:\/\//i.test(raw)) return null;
  if (path.isAbsolute(raw)) return fs.existsSync(raw) ? raw : null;
  return absOfRel(raw);
}

/** 同目录下与视频同名的侧车（不递归，避免碰到子目录） */
export async function sidecarsOf(row: ArtRefRow): Promise<string[]> {
  const abs = absOfRel(row.rel_path);
  if (!abs) return [];
  const out = new Set<string>();
  const dir = path.dirname(abs);
  const stem = path.parse(abs).name;
  try {
    for (const name of fs.readdirSync(dir)) {
      const ext = path.extname(name).toLowerCase();
      if (!SIDE_EXT.has(ext)) continue;
      const base = path.basename(name, path.extname(name));
      if (
        base === stem ||
        base.startsWith(`${stem}.`) ||
        base.startsWith(`${stem}-`)
      ) {
        out.add(path.join(dir, name));
      }
    }
  } catch {
    /* 目录不可读：只靠 NFO 显式引用 */
  }
  for (const ref of [row.nfo_poster, row.nfo_fanart, row.nfo_thumb]) {
    const p = resolveArtRef(ref);
    if (p) out.add(p);
  }
  try {
    const nfo = await findNfoFile(abs);
    if (nfo?.file) out.add(nfo.file);
  } catch {
    /* 忽略 */
  }
  // NFO 自己可能被 findNfoFile 识别成 movie.nfo；上面的目录扫描也可能命中
  out.delete(abs);
  return [...out];
}

/** Windows 路径大小写不敏感；保护集合统一用小写绝对路径比较 */
export function normAbs(p: string): string {
  return path.resolve(p).replace(/\\/g, '/').toLowerCase();
}
