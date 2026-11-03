import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { filesRoot, httpError, resolveInRoot } from './fs-root';

/**
 * 文件域写操作：新建目录 / 重命名 / 移动（含复制）/ 删除（进回收站）/ 回收站管理。
 *
 * 这一层此前完全不存在 —— 契约里 365 个操作零 DELETE，文件页只能看和传。
 * 一个 NAS 管理界面不能删、不能改名、不能移动，是产品性残缺。
 *
 * 安全约定（三条，全部落在 `resolveInRoot` + `assertSafeTarget` 上）：
 * 1. 一律先 `resolveInRoot`，越界抛 403（与 list / download / thumb 同一套）；
 * 2. 根目录本身、以及回收站目录本身，永远不可删不可移；
 * 3. 删除默认进回收站（`.colanas-trash/<批次>/<原相对路径>`），必须显式
 *    `permanent: true` 才真删 —— 回收站是「删了能找回」，不是藏起来。
 */

/** 回收站目录名（位于 files 根下，不随用户目录结构变化） */
export const TRASH_DIR = '.colanas-trash';

/** 单次批量操作上限：防一次请求删掉半块盘 */
const MAX_BATCH = 500;

export interface OpResult {
  done: string[];
  failed: Array<{ path: string; error: string }>;
  /** 删除时给出落点，便于客户端提示「已移入回收站」 */
  trashedTo?: string;
}

function relOf(root: string, abs: string): string {
  return path.relative(root, abs).split(path.sep).join('/');
}

/** 根目录 / 回收站本身不可删不可移：一次误操作会带走整块盘 */
function assertSafeTarget(root: string, abs: string): string {
  const rel = relOf(root, abs);
  if (!rel || rel === '.' || path.resolve(abs) === path.resolve(root)) {
    throw httpError(400, 'refuse to operate on the files root itself');
  }
  if (rel === TRASH_DIR || rel.startsWith(TRASH_DIR + '/')) {
    throw httpError(400, 'refuse to operate on the trash directory');
  }
  return rel;
}

/** 文件名只允许单段：挡掉 `../x`、`a/b`、空名 */
function assertPlainName(name: string): string {
  const v = String(name || '').trim();
  if (!v) throw httpError(400, 'name required');
  if (v === '.' || v === '..') throw httpError(400, 'invalid name');
  if (/[/\\]/.test(v)) throw httpError(400, 'name must not contain path separators');
  if (v.length > 255) throw httpError(400, 'name too long');
  return v;
}

async function exists(p: string): Promise<boolean> {
  try {
    await fsp.lstat(p);
    return true;
  } catch {
    return false;
  }
}

/**
 * 跨卷 rename 会抛 EXDEV（files 根与回收站在同一盘时不会，但用户可以把
 * 回收站指到别的盘）。回退成 copy + rm，语义等价。
 */
export async function movePath(src: string, dest: string): Promise<void> {
  await fsp.mkdir(path.dirname(dest), { recursive: true });
  try {
    await fsp.rename(src, dest);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EXDEV') throw err;
    await fsp.cp(src, dest, { recursive: true });
    await fsp.rm(src, { recursive: true, force: true });
  }
}

/** 索引表跟着文件走：删掉受影响前缀，避免 /files/search 返回幽灵条目 */
async function forgetIndex(db: any, relPrefixes: string[]): Promise<void> {
  for (const rel of relPrefixes) {
    if (!rel) continue;
    await sql`
      delete from files_meta
       where path = ${rel} or path like ${rel + '/%'}
    `.execute(db);
  }
}

/** POST /files/mkdir —— `{ path }`，中间层自动补齐 */
export async function mkdirHandler(body: { path?: string }): Promise<{ path: string }> {
  const root = filesRoot();
  const target = resolveInRoot(root, body.path);
  assertSafeTarget(root, target);
  if (await exists(target)) throw httpError(409, 'already exists');
  await fsp.mkdir(target, { recursive: true });
  return { path: relOf(root, target) };
}

/** POST /files/rename —— `{ path, name }`，同目录改名 */
export async function renameHandler(body: {
  path?: string;
  name?: string;
}, db: any): Promise<{ path: string; from: string }> {
  const root = filesRoot();
  const src = resolveInRoot(root, body.path);
  const from = assertSafeTarget(root, src);
  const name = assertPlainName(String(body.name || ''));
  const dest = path.join(path.dirname(src), name);
  // name 已挡掉分隔符，这里再兜一层：dest 必须仍在根内
  assertSafeTarget(root, dest);
  if (!(await exists(src))) throw httpError(404, 'path not found');
  if (await exists(dest)) throw httpError(409, 'target already exists');
  await fsp.rename(src, dest);
  const to = relOf(root, dest);
  await forgetIndex(db, [from, to]);
  return { path: to, from };
}

/**
 * POST /files/move —— `{ paths: string[], to: string, copy?: boolean }`
 * `to` 是目标目录（相对根）。批量；单条失败不影响其它条，逐条回结果。
 */
export async function moveHandler(
  body: { paths?: string[]; to?: string; copy?: boolean },
  db: any,
): Promise<OpResult> {
  const root = filesRoot();
  const paths = (body.paths || []).filter((p) => typeof p === 'string' && p.trim() !== '');
  if (paths.length === 0) throw httpError(400, 'paths required');
  if (paths.length > MAX_BATCH) throw httpError(400, `too many paths (max ${MAX_BATCH})`);
  const destDir = resolveInRoot(root, body.to);
  const destRel = relOf(root, destDir);
  if (destRel === TRASH_DIR || destRel.startsWith(TRASH_DIR + '/')) {
    throw httpError(400, 'refuse to move into the trash directory');
  }
  const stat = await fsp.stat(destDir).catch(() => null);
  if (!stat || !stat.isDirectory()) throw httpError(400, 'target must be an existing directory');

  const done: string[] = [];
  const failed: Array<{ path: string; error: string }> = [];
  const touched: string[] = [];

  for (const input of paths) {
    try {
      const src = resolveInRoot(root, input);
      const srcRel = assertSafeTarget(root, src);
      if (!(await exists(src))) throw httpError(404, 'path not found');

      // 目录不能移进自己的子目录（否则 rename 会 EINVAL，copy 会无限递归）
      const relBack = path.relative(src, destDir);
      if (!relBack.startsWith('..') && !path.isAbsolute(relBack)) {
        throw httpError(400, 'cannot move a directory into itself');
      }

      const dest = path.join(destDir, path.basename(src));
      if (await exists(dest)) throw httpError(409, 'target already exists');

      if (body.copy) {
        await fsp.cp(src, dest, { recursive: true, errorOnExist: true });
      } else {
        await movePath(src, dest);
      }
      done.push(input);
      touched.push(srcRel, relOf(root, dest));
    } catch (err) {
      const e = err as Error & { statusCode?: number };
      failed.push({ path: input, error: e.message || String(err) });
    }
  }

  await forgetIndex(db, touched);
  return { done, failed };
}

/**
 * POST /files/delete —— `{ paths: string[], permanent?: boolean }`
 * 默认移入 `.colanas-trash/<批次>/<原相对路径>`；`permanent: true` 才真删。
 */
export async function deleteHandler(
  body: { paths?: string[]; permanent?: boolean },
  db: any,
): Promise<OpResult> {
  const root = filesRoot();
  const paths = (body.paths || []).filter((p) => typeof p === 'string' && p.trim() !== '');
  if (paths.length === 0) throw httpError(400, 'paths required');
  if (paths.length > MAX_BATCH) throw httpError(400, `too many paths (max ${MAX_BATCH})`);

  const permanent = body.permanent === true;
  const batch = new Date()
    .toISOString()
    .replace(/[-:]/g, '')
    .replace(/\..+$/, '')
    .replace('T', '-');
  const batchDir = path.join(root, TRASH_DIR, batch);

  const done: string[] = [];
  const failed: Array<{ path: string; error: string }> = [];

  for (const input of paths) {
    try {
      const src = resolveInRoot(root, input);
      const rel = assertSafeTarget(root, src);
      if (!(await exists(src))) throw httpError(404, 'path not found');

      if (permanent) {
        await fsp.rm(src, { recursive: true, force: false });
      } else {
        await movePath(src, path.join(batchDir, rel));
      }
      done.push(input);
    } catch (err) {
      const e = err as Error;
      failed.push({ path: input, error: e.message || String(err) });
    }
  }

  await forgetIndex(db, paths.map((p) => String(p).replace(/^[/\\]+/, '')));
  // trashedTo 给的是**批次名**（不是带 `.colanas-trash/` 前缀的路径）：
  // 它要原样喂回 /files/trash/restore 与 /files/trash/empty 的 `batch`。
  return permanent ? { done, failed } : { done, failed, trashedTo: batch };
}

/** GET /files/trash —— 列出回收站批次与条目（一层，供客户端还原） */
export async function trashListHandler(): Promise<{
  batches: Array<{ batch: string; items: Array<{ name: string; dir: boolean; size: number }> }>;
}> {
  const root = filesRoot();
  const base = path.join(root, TRASH_DIR);
  const batches: Array<{ batch: string; items: Array<{ name: string; dir: boolean; size: number }> }> = [];
  let dirs: string[];
  try {
    dirs = (await fsp.readdir(base, { withFileTypes: true }))
      .filter((d) => d.isDirectory())
      .map((d) => d.name)
      .sort()
      .reverse();
  } catch {
    return { batches: [] };
  }
  for (const batch of dirs) {
    const items: Array<{ name: string; dir: boolean; size: number }> = [];
    const walk = async (abs: string, rel: string) => {
      const entries = await fsp.readdir(abs, { withFileTypes: true }).catch(() => []);
      for (const e of entries) {
        const childRel = rel ? `${rel}/${e.name}` : e.name;
        if (e.isDirectory()) {
          items.push({ name: childRel, dir: true, size: 0 });
          await walk(path.join(abs, e.name), childRel);
        } else {
          const st = await fsp.stat(path.join(abs, e.name)).catch(() => null);
          items.push({ name: childRel, dir: false, size: st ? Number(st.size) : 0 });
        }
      }
    };
    await walk(path.join(base, batch), '');
    batches.push({ batch, items });
  }
  return { batches };
}

/** POST /files/trash/restore —— `{ batch, paths: string[] }` 还原到原相对路径 */
export async function trashRestoreHandler(body: {
  batch?: string;
  paths?: string[];
}): Promise<OpResult> {
  const root = filesRoot();
  const batch = assertPlainName(String(body.batch || ''));
  const paths = (body.paths || []).filter((p) => typeof p === 'string' && p.trim() !== '');
  if (paths.length === 0) throw httpError(400, 'paths required');
  const done: string[] = [];
  const failed: Array<{ path: string; error: string }> = [];
  for (const rel of paths) {
    try {
      const clean = rel.replace(/^[/\\]+/, '');
      const src = path.join(root, TRASH_DIR, batch, clean);
      const dest = path.join(root, clean);
      if (!(await exists(src))) throw httpError(404, 'trash item not found');
      if (await exists(dest)) throw httpError(409, 'target already exists');
      await movePath(src, dest);
      done.push(clean);
    } catch (err) {
      failed.push({ path: rel, error: (err as Error).message || String(err) });
    }
  }
  return { done, failed };
}

/** POST /files/trash/empty —— 清空回收站（可指定批次；不指定就全清） */
export async function trashEmptyHandler(body: { batch?: string }): Promise<{ removed: number }> {
  const root = filesRoot();
  const base = path.join(root, TRASH_DIR);
  const target = body.batch ? path.join(base, assertPlainName(body.batch)) : base;
  // 只允许清回收站内部：assertSafeTarget 的反向检查在这里不适用，
  // 但要挡住 batch 里的分隔符（assertPlainName 已挡）
  const rel = path.relative(base, target);
  if (rel.startsWith('..') || path.isAbsolute(rel)) throw httpError(400, 'invalid batch');
  const entries = await fsp.readdir(target).catch(() => [] as string[]);
  await fsp.rm(target, { recursive: true, force: true });
  if (!body.batch) await fsp.mkdir(base, { recursive: true }).catch(() => undefined);
  return { removed: entries.length };
}
