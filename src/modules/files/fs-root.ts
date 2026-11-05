import fs from 'node:fs';
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
  const raw = (input || '.').trim();
  // 绝对路径（`D:/x`、`\\host\share\x`、被 URL 编码成 `/D:/x` 的盘符路径）
  // 不能当相对路径拼到 root 下：旧实现会把 `\\host\share\a.jpg` 剥成
  // `host\share\a.jpg` 再拼到 root 里，随后 stat ENOENT —— 表现就是
  // 「SMB 共享里的海报明明在，页面却 404 / 显示占位图」（2026-11-04）。
  // 这里直接判越界，让 resolveAnyPath 的 catch 分支去走 extraRoots 白名单。
  if (isAbsoluteInput(raw)) {
    throw httpError(403, 'path outside allowed root');
  }
  const rel = raw.replace(/^[/\\]+/, '');
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
  const t = input.trim();
  // UNC 必须在剥前导斜杠**之前**判断：`\\host\share\x` 剥完只剩 `host\share\x`，
  // 再判 `startsWith('\\\\')` 永远不会成立 —— 旧实现就是这个 bug，导致
  // SMB 来源根从不登记进 extraRoots，所有 SMB 图片都解析不到。
  if (/^\\\\[^\\]/.test(t)) return true;
  // POSIX 化后的 UNC（`list` 返回 `//host/share`，前端再传回来）
  if (/^\/\/[^/]/.test(t)) return true;
  // 前端 URL 会把 `D:/x` 编码成 `/D:/x`，先剥掉前导斜杠再判断
  const v = t.replace(/^[/\\]+/, '');
  return /^[a-zA-Z]:[\\/]/.test(v);
}

/** 把请求里的绝对路径还原成系统路径；相对路径原样返回 */
export function absoluteInput(input: string): string {
  const t = String(input ?? '').trim();
  // UNC 原样返回（剥前导斜杠会毁掉 `\\host\share`）
  if (/^\\\\[^\\]/.test(t)) return t;
  // POSIX 风格的 UNC 换回反斜杠：`//host/share/x` → `\\host\share\x`
  if (/^\/\/[^/]/.test(t)) return t.replace(/\//g, '\\');
  const v = t.replace(/^[/\\]+/, '');
  return /^[a-zA-Z]:[\\/]/.test(v) ? v : input;
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

/** 可浏览的根（盘符 / 文件根 / 已登记来源根） */
export interface BrowsableRoot {
  /** POSIX 风格绝对路径，如 `C:/`、`\\\\host\\share` */
  path: string;
  /** 展示名，如 `C:`、`共享名` */
  label: string;
  /** drive = 本机盘符，home = 文件根，share = 已登记的来源根（SMB 等） */
  kind: 'drive' | 'home' | 'share';
}

/**
 * Windows 盘符探测（C~Z）。
 *
 * 不用 `wmic` / `fsutil`（前者已弃用、后者要外部进程），直接 `existsSync('X:\\')`
 * —— 26 次 stat 在毫秒级。A/B 跳过：没装软驱的机器上探测会卡住。
 */
export function listDrives(): BrowsableRoot[] {
  if (process.platform !== 'win32') {
    return [{ path: '/', label: '/', kind: 'drive' }];
  }
  const out: BrowsableRoot[] = [];
  for (let code = 67; code <= 90; code += 1) {
    const letter = String.fromCharCode(code);
    const probe = `${letter}:\\`;
    try {
      if (fs.existsSync(probe)) {
        out.push({ path: `${letter}:/`, label: `${letter}:`, kind: 'drive' });
      }
    } catch {
      /* 没权限 / 未挂载：跳过 */
    }
  }
  return out;
}

/** 可浏览的根列表：盘符 + 文件根 + 已登记的来源根（相册 / SMB 共享） */
export function listBrowsableRoots(): BrowsableRoot[] {
  const out = listDrives();
  const seen = new Set(out.map((r) => toPosix(r.path).toLowerCase()));

  const push = (abs: string, kind: 'home' | 'share'): void => {
    const posix = toPosix(abs);
    const key = posix.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ path: posix, label: posix.replace(/\/$/, ''), kind });
  };

  push(filesRoot(), 'home');
  for (const dir of extraRoots) push(dir, 'share');
  return out;
}

/** Windows 反斜杠路径转成前端好用的 POSIX 风格（`D:\\a` → `D:/a`） */
export function toPosix(abs: string): string {
  return abs.split(path.sep).join('/');
}

/**
 * 同步 / 目录浏览用的路径解析：相对路径按 files 根展开，**绝对路径直通**。
 *
 * 和 [resolveInRoot] 的区别：后者是安全边界（越界一律 403），文件管理页那种
 * 「锁死在根里」的场景该用它；而同步的远端目录允许指向整机任意盘
 * （NAS 上 `D:/Photos`、`F:/media` 都是常态），所以这条链路要放行绝对路径。
 * 前提是调用方已经过 `secured('sync:write')` / `files:read` 这类权限校验。
 */
export function resolveRemoteDir(input?: string): string {
  const raw = (input ?? '').trim();
  if (!raw || raw === '.' || raw === '/') return filesRoot();
  if (isAbsoluteInput(raw)) return path.resolve(absoluteInput(raw));
  return resolveInRoot(filesRoot(), raw);
}

/**
 * 上传目标解析：相对路径按文件根展开，**绝对路径（盘符 / UNC）直通**。
 *
 * 同步的上传走的是 files 的 check / chunk / merge，而远端目录允许是
 * `D:/Photos` 这种绝对路径 —— 只放行 sync 自己的接口不够：plan 能扫 D 盘，
 * 上传却撞 `resolveInRoot` 报 `Bad state: http 403`（2026-11-04）。
 * 返回的 `rel` 只用于 uploadId（要求稳定唯一），绝对路径取 POSIX 形式即可。
 */
export function resolveWriteTarget(input?: string): { abs: string; rel: string } {
  const raw = (input ?? '').trim();
  if (isAbsoluteInput(raw)) {
    const abs = path.resolve(absoluteInput(raw));
    return { abs, rel: toPosix(abs) };
  }
  return relativeInRoot(filesRoot(), raw);
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
