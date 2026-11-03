import fsp from 'node:fs/promises';
import path from 'node:path';
import { IGNORED_DIR_NAMES, IGNORED_FILE_NAMES } from '../../../kernel/fs-watch';

/**
 * 媒体库目录遍历（photo / video / music / book 共用）：
 *   - 只返回普通文件，不跟随符号链接（防环）
 *   - 跳过系统垃圾目录 / 文件（`@eaDir`、`#recycle`、`Thumbs.db` 等），与文件监控同一份规则
 *   - 深度上限 32，结果数上限 `limit`（到量即停，避免超大库卡死）
 *   - 返回相对路径统一用 POSIX 分隔符
 */
const MAX_DEPTH = 32;

export async function walkFiles(
  rootAbs: string,
  limit: number,
  accept: (name: string) => boolean,
): Promise<string[]> {
  const out: string[] = [];
  const stack: Array<{ abs: string; rel: string; depth: number }> = [
    { abs: rootAbs, rel: '', depth: 0 },
  ];

  while (stack.length > 0 && out.length < limit) {
    const cur = stack.pop()!;
    let entries;
    try {
      entries = await fsp.readdir(cur.abs, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const e of entries) {
      if (out.length >= limit) break;
      const rel = cur.rel ? `${cur.rel}/${e.name}` : e.name;
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) {
        if (IGNORED_DIR_NAMES.has(e.name.toLowerCase())) continue;
        if (cur.depth + 1 <= MAX_DEPTH) {
          stack.push({ abs: path.join(cur.abs, e.name), rel, depth: cur.depth + 1 });
        }
      } else if (e.isFile() && !IGNORED_FILE_NAMES.has(e.name.toLowerCase()) && accept(e.name)) {
        out.push(rel);
      }
    }
  }

  return out;
}