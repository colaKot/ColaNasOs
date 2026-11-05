import crypto from 'node:crypto';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { httpError, resolveWriteTarget, sha256File } from './fs-root';
import type { Logger } from './list';

/** 单分片请求体上限 */
export const CHUNK_BODY_LIMIT = 64 * 1024 * 1024;
/** 建议分片大小（客户端可自定，仅作提示） */
export const DEFAULT_CHUNK_SIZE = 4 * 1024 * 1024;

export interface CheckBody {
  path?: string;
  size?: number;
  hash?: string;
}

export interface ChunkQuery {
  path?: string;
  index?: string;
  total?: string;
}

export interface MergeBody {
  path?: string;
  total?: number;
  size?: number;
  hash?: string;
  /** 写入后的修改时间（毫秒）；同步业务用它让两端 mtime 对齐 */
  mtimeMs?: number;
}

function uploadsRoot(dataDir: string): string {
  return path.join(dataDir, 'tmp', 'uploads');
}

/**
 * 上传会话 id：只依赖目标相对路径。
 * 同一路径同时只允许一个上传会话（桌面单写者场景足够；多用户并发在 SP2 换成 uid 前缀）。
 */
export function uploadIdFor(rel: string): string {
  return crypto.createHash('sha256').update(rel).digest('hex').slice(0, 32);
}

async function uploadedIndexes(dir: string): Promise<number[]> {
  try {
    const names = await fsp.readdir(dir);
    return names
      .filter((n) => /^\d+\.part$/.test(n))
      .map((n) => Number(n.slice(0, -'.part'.length)))
      .sort((a, b) => a - b);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw err;
  }
}

/** POST /api/v1/files/check：秒传判定 + 已上传分片列表（断点续传） */
export async function checkHandler(dataDir: string, body: CheckBody) {
  const { abs, rel } = resolveWriteTarget(body.path);

  let exists: boolean;
  try {
    const st = await fsp.stat(abs);
    exists = !st.isDirectory() && st.size === (body.size ?? st.size);
  } catch {
    exists = false;
  }

  const id = uploadIdFor(rel);
  const uploaded = exists ? [] : await uploadedIndexes(path.join(uploadsRoot(dataDir), id));

  return {
    path: rel,
    exists,
    uploadId: id,
    uploaded,
    chunkSize: DEFAULT_CHUNK_SIZE,
  };
}

/** POST /api/v1/files/chunk：落单分片（先写 .tmp 再 rename，避免半片） */
export async function chunkHandler(dataDir: string, q: ChunkQuery, payload: unknown) {
  const { rel } = resolveWriteTarget(q.path);

  const index = Number(q.index);
  const total = q.total === undefined ? undefined : Number(q.total);

  if (!Number.isInteger(index) || index < 0) throw httpError(400, 'invalid chunk index');
  if (total !== undefined && (!Number.isInteger(total) || total <= 0 || index >= total)) {
    throw httpError(400, 'chunk index out of range');
  }
  if (!Buffer.isBuffer(payload) || payload.length === 0) throw httpError(400, 'empty chunk');

  const id = uploadIdFor(rel);
  const dir = path.join(uploadsRoot(dataDir), id);
  await fsp.mkdir(dir, { recursive: true });

  const final = path.join(dir, `${index}.part`);
  const tmp = `${final}.tmp`;
  await fsp.writeFile(tmp, payload);
  await fsp.rename(tmp, final);

  return { ok: true, uploadId: id, index, size: payload.length };
}

/**
 * 写入后统一对齐修改时间。
 *
 * 同步业务上传时必须把「客户端 mtime」带回来：服务端此刻写入的 mtime 是 now，
 * 下一轮三向比对会把它判成「远端变了」⇒ 每轮重复上传。
 */
async function applyMtime(abs: string, mtimeMs?: number): Promise<void> {
  if (mtimeMs === undefined || !Number.isFinite(mtimeMs) || mtimeMs <= 0) return;
  try {
    const st = await fsp.stat(abs);
    const atime = st.atimeMs > 0 ? st.atimeMs : mtimeMs;
    await fsp.utimes(abs, atime / 1000, mtimeMs / 1000);
  } catch {
    /* 时间戳对齐失败不阻断上传（下一轮最多多传一次） */
  }
}

/** POST /api/v1/files/merge：按序拼接 → 校验 → 原子落盘（幂等） */
export async function mergeHandler(dataDir: string, body: MergeBody, log: Logger) {
  const { abs, rel } = resolveWriteTarget(body.path);

  const total = Number(body.total);
  if (!Number.isInteger(total) || total < 0) throw httpError(400, 'invalid total');
  if (total === 0 && (body.size ?? 0) !== 0) throw httpError(400, 'invalid total');

  // 空文件：没有分片，直接落盘空文件（否则同步里的 0 字节文件永远传不过去）
  if (total === 0) {
    await fsp.mkdir(path.dirname(abs), { recursive: true });
    await fsp.writeFile(abs, '');
    await applyMtime(abs, body.mtimeMs);
    return { ok: true, path: rel, size: 0, skipped: false };
  }

  const id = uploadIdFor(rel);
  const dir = path.join(uploadsRoot(dataDir), id);

  // 幂等：目标已存在且尺寸/hash 一致 → 直接成功（不依赖残留分片，重复 merge 安全）
  try {
    const st = await fsp.stat(abs);
    if (!st.isDirectory() && st.size === (body.size ?? st.size)) {
      const hashOk = !body.hash || (await sha256File(abs)) === body.hash.toLowerCase();
      if (hashOk) {
        await fsp.rm(dir, { recursive: true, force: true });
        await applyMtime(abs, body.mtimeMs);
        return { ok: true, path: rel, size: st.size, skipped: true };
      }
    }
  } catch {
    /* 目标不存在：走正常合并路径 */
  }

  const have = await uploadedIndexes(dir);
  const missing: number[] = [];
  for (let i = 0; i < total; i++) if (!have.includes(i)) missing.push(i);
  if (missing.length > 0) {
    throw httpError(409, `missing chunks: ${missing.join(',')}`);
  }

  const merged = path.join(dir, 'merged.bin');
  const out = await fsp.open(merged, 'w');
  try {
    for (let i = 0; i < total; i++) {
      await out.write(await fsp.readFile(path.join(dir, `${i}.part`)));
    }
  } finally {
    await out.close();
  }

  const st = await fsp.stat(merged);
  if (body.size !== undefined && st.size !== body.size) {
    await fsp.rm(merged, { force: true });
    throw httpError(422, `size mismatch: expected ${body.size}, got ${st.size}`);
  }
  if (body.hash) {
    const actual = await sha256File(merged);
    if (actual !== body.hash.toLowerCase()) {
      await fsp.rm(merged, { force: true });
      throw httpError(422, `hash mismatch: expected ${body.hash}, got ${actual}`);
    }
  }

  await fsp.mkdir(path.dirname(abs), { recursive: true });
  try {
    await fsp.rename(merged, abs);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'EXDEV') throw err;
    await fsp.copyFile(merged, abs);
    await fsp.rm(merged, { force: true });
  }

  await fsp.rm(dir, { recursive: true, force: true });
  await applyMtime(abs, body.mtimeMs);
  log.debug({ rel, size: st.size, chunks: total }, 'files.merge');

  return { ok: true, path: rel, size: st.size, skipped: false };
}
