import os from 'node:os';
import path from 'node:path';

/** 允许访问的根（§5.5 VirtualFS 的临时简化：单根 + 越界拒绝） */
export function filesRoot(): string {
  const env = process.env.COLANAS_FILES_ROOT;
  return path.resolve(env && env.trim() ? env : os.homedir());
}

export function httpError(statusCode: number, message: string): Error & { statusCode: number } {
  const err = new Error(message) as Error & { statusCode: number };
  err.statusCode = statusCode;
  return err;
}

/** 把请求路径解析到 root 内，越界返回 403 */
export function resolveInRoot(root: string, input?: string): string {
  const rel = (input || '.').replace(/^[/\\]+/, '');
  const target = path.resolve(root, rel);
  const back = path.relative(root, target);

  if (back.startsWith('..') || path.isAbsolute(back)) {
    throw httpError(403, 'path outside allowed root');
  }
  return target;
}


/**
 * 额外可读根（相册「来源目录」）。
 *
 * 相册允许把任意本机目录登记为来源（例如 D:/Photos），这些目录不在 filesRoot 内，
 * 但缩略图 / 原图仍要能读。这里维护一份内存白名单，只允许其子路径通过。
 */
const extraRoots = new Set<string>();

export function registerExtraRoot(dir: string): void {
  const abs = path.resolve(dir);
  if (abs) extraRoots.add(abs);
}

export function clearExtraRoots(): void {
  extraRoots.clear();
}

export function extraRootList(): string[] {
  return [...extraRoots];
}

/** 是否 Windows 绝对路径 / UNC */
export function isAbsoluteInput(input?: string): boolean {
  if (!input) return false;
  // 前端 URL 会把 `D:/x` 编码成 `/D:/x`，先剥掉前导斜杠再判断
  const v = input.replace(/^[/\\]+/, '');
  return /^[a-zA-Z]:[\\/]/.test(v) || v.startsWith('\\\\');
}

/** 把请求里的绝对路径还原成系统路径；相对路径原样返回 */
export function absoluteInput(input: string): string {
  const v = input.replace(/^[/\\]+/, '');
  return /^[a-zA-Z]:[\\/]/.test(v) || v.startsWith('\\\\') ? v : input;
}

/**
 * 媒体路径解析：优先按 filesRoot，再尝试已登记的来源根。
 * 越界仍抛 403。
 */
export function resolveAnyPath(root: string, input?: string): string {
  try {
    return resolveInRoot(root, input);
  } catch (err) {
    if (!input) throw err;
    const abs = path.resolve(absoluteInput(input));
    for (const base of extraRoots) {
      const back = path.relative(base, abs);
      if (!back.startsWith('..') && !path.isAbsolute(back)) return abs;
    }
    throw err;
  }
}

/** 解析并返回 POSIX 风格相对路径（用于 uploadId 稳定计算） */
export function relativeInRoot(root: string, input?: string): { abs: string; rel: string } {
  const abs = resolveInRoot(root, input);
  const rel = path.relative(root, abs).split(path.sep).join('/');
  if (!rel || rel === '.') throw httpError(400, 'path must point to a file');
  return { abs, rel };
}

export async function sha256File(file: string): Promise<string> {
  const { createHash } = await import('node:crypto');
  const { createReadStream } = await import('node:fs');
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) {
    hash.update(chunk as Buffer);
  }
  return hash.digest('hex');
}
