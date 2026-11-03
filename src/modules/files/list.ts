import fsp from 'node:fs/promises';
import path from 'node:path';
import { filesRoot, httpError, resolveInRoot } from './fs-root';

export interface ListQuery {
  path?: string;
  cursor?: string;
  limit?: string;
}

export interface Logger {
  debug(obj: unknown, msg: string): void;
}

/** GET /api/v1/files/list：单层列目录，目录优先、名称升序 */
export async function listHandler(q: ListQuery, log: Logger) {
  const root = filesRoot();
  const target = resolveInRoot(root, q.path);

  let entries;
  try {
    entries = await fsp.readdir(target, { withFileTypes: true });
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') throw httpError(404, 'path not found');
    if (code === 'ENOTDIR') throw httpError(400, 'not a directory');
    if (code === 'EACCES') throw httpError(403, 'permission denied');
    throw err;
  }

  const limit = Math.max(1, Math.min(Number(q.limit || 200) || 200, 200));
  const sorted = entries.sort((a, b) => {
    if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  const items = sorted.slice(0, limit).map((e) => ({
    name: e.name,
    dir: e.isDirectory(),
  }));

  log.debug({ root, target, count: items.length }, 'files.list');

  return {
    path: path.relative(root, target).split(path.sep).join('/') || '.',
    items,
    nextCursor: null,
  };
}
