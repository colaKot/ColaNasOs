import fs from 'node:fs';
import net from 'node:net';
import { execFile } from 'node:child_process';
import { isSealed, openSecret, sealSecret } from '../../../kernel/secret-box';

/**
 * SMB 网络目录作为影视来源。
 *
 * 关键设计（每条都是踩过的坑）：
 * 1. **UNC 归一化**：`\\host\share[\sub]`；host/share/sub 分别处理反斜杠与首尾斜杠；
 * 2. **可达性探测**：只探 445 端口，超时 800ms（不通立刻返回，不拖住接口）；
 * 3. **在线状态三值 + 缓存**：同一来源 15s 内不重复探测；
 * 4. **列表接口绝不用 `fs.stat` 判存在**：机器没开机时 stat 会卡十几秒，整页跟着超时——
 *    列表只读库里缓存的 `online_state`，真正的探测交给 `probe`；
 * 5. **密码 AES-256-GCM 密文落库**，读取时解密。
 */
export const SMB_SALT = 'colanas-video-smb-v1';

export const CONN_LOCAL = 'local' as const;
export const CONN_SMB = 'smb' as const;
export type ConnType = typeof CONN_LOCAL | typeof CONN_SMB;

export const ONLINE_UNKNOWN = 0;
export const ONLINE_YES = 1;
export const ONLINE_NO = 2;

export const SMB_PORT = 445;
export const PROBE_TIMEOUT_MS = 800;
export const PROBE_CACHE_MS = 15_000;

export function normalizeConnType(input: unknown): ConnType {
  return String(input || '')
    .trim()
    .toLowerCase() === CONN_SMB
    ? CONN_SMB
    : CONN_LOCAL;
}

export function normalizeHost(host: string): string {
  return String(host || '')
    .trim()
    .replace(/^\\\\+/, '')
    .replace(/\\+$/, '');
}

export function normalizeShare(share: string): string {
  return String(share || '')
    .trim()
    .replace(/^\\+/, '')
    .replace(/\\+$/, '');
}

export function normalizeSubPath(subPath: string): string {
  return String(subPath || '')
    .trim()
    .replace(/\\/g, '/')
    .replace(/^\/+/, '')
    .replace(/\/+$/, '');
}

/** `\\host\share[\sub]` */
export function buildUnc(host: string, share: string, subPath = ''): string {
  const h = normalizeHost(host);
  const s = normalizeShare(share);
  if (!h || !s) throw Object.assign(new Error('host/share required'), { code: 'E_PARAM' });
  const sub = normalizeSubPath(subPath);
  return `\\\\${h}\\${s}${sub ? `\\${sub.split('/').join('\\')}` : ''}`;
}

export function parseUnc(unc: string): { host: string; share: string; subPath: string } {
  const m = /^\\\\+([^\\]+)\\+([^\\]+)(?:\\(.*))?$/.exec(String(unc || '').trim());
  if (!m) throw Object.assign(new Error('invalid unc'), { code: 'E_PARAM' });
  return {
    host: m[1],
    share: m[2],
    subPath: normalizeSubPath(m[3] || ''),
  };
}

/**
 * 扫描路径归一：客户端常传 `\\host\share\`（带尾随反斜杠），自动入队的是无尾斜杠版本，
 * 两个字符串不同 ⇒ 去重失效 ⇒ 同一个源排两条任务、白扫一遍。
 * 但盘符根（`D:\`）**不能**去尾斜杠，否则变成非法路径 `D:`。
 */
export function normalizeScanPath(input: string): string {
  const text = String(input || '').trim();
  if (!text) return '';
  if (/^[A-Za-z]:\\?$/.test(text)) return `${text.slice(0, 2)}\\`;
  const unc = text.replace(/\//g, '\\');
  if (unc.startsWith('\\\\')) return unc.replace(/\\+$/, '');
  return unc.replace(/\\+$/, '') || text;
}

/** TCP 可达性（只探端口，不做 SMB 协商） */
export function probeHost(
  host: string,
  opts: { port?: number; timeoutMs?: number } = {},
): Promise<boolean> {
  const h = normalizeHost(host);
  if (!h) return Promise.resolve(false);
  const port = opts.port ?? SMB_PORT;
  const timeoutMs = opts.timeoutMs ?? PROBE_TIMEOUT_MS;
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let done = false;
    const finish = (ok: boolean) => {
      if (done) return;
      done = true;
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs);
    socket.once('connect', () => finish(true));
    socket.once('timeout', () => finish(false));
    socket.once('error', () => finish(false));
    try {
      socket.connect(port, h);
    } catch {
      finish(false);
    }
  });
}

const cache = new Map<string, { at: number; state: number }>();

/** 探测并缓存：返回 ONLINE_YES / ONLINE_NO */
export async function probeSmb(
  host: string,
  opts: { timeoutMs?: number; cacheMs?: number } = {},
): Promise<number> {
  const h = normalizeHost(host);
  if (!h) return ONLINE_NO;
  const cacheMs = opts.cacheMs ?? PROBE_CACHE_MS;
  const hit = cache.get(h);
  if (hit && Date.now() - hit.at <= cacheMs) return hit.state;
  const ok = await probeHost(h, { timeoutMs: opts.timeoutMs });
  const state = ok ? ONLINE_YES : ONLINE_NO;
  cache.set(h, { at: Date.now(), state });
  return state;
}

export function clearProbeCache(host?: string): void {
  if (!host) cache.clear();
  else cache.delete(normalizeHost(host));
}

export function sealSmbPassword(password: string): string {
  return sealSecret(String(password || ''), SMB_SALT);
}

/**
 * Windows 下建立 SMB 会话（等价 `net use \\host\share <password> /user:<user>`）。
 *
 * 445 端口可达 ≠ 有权限读：没建会话时 `readdir` 会直接 EACCES，扫描结果 0 条，
 * 用户看到的是「在线但没内容」。非 Windows 或无密码（走系统已保存凭据）直接返回 true。
 * 错误 1219（同主机已有另一套凭据）先断开再重连一次，避免把旧会话带进新库。
 */
export async function ensureSmbSession(
  unc: string,
  username?: string | null,
  password?: string | null,
): Promise<boolean> {
  if (process.platform !== 'win32') return true;
  const pw = String(password ?? '');
  if (!pw) return true;
  const root = String(unc || '').replace(/\/+$/, '');
  if (!root) return false;

  const run = (args: string[]) =>
    new Promise<{ code: number; stderr: string }>((resolve) => {
      execFile('net', args, { windowsHide: true, timeout: 8000 }, (err, _stdout, stderr) => {
        resolve({
          code: err ? Number((err as NodeJS.ErrnoException & { code?: number }).code) || 1 : 0,
          stderr: String(stderr || ''),
        });
      });
    });

  const args = ['use', root, pw, ...(username ? [`/user:${String(username)}`] : []), '/persistent:no'];
  const first = await run(args);
  if (first.code === 0) return true;
  if (/1219/.test(first.stderr)) {
    await run(['use', root, '/delete', '/y']);
    return (await run(args)).code === 0;
  }
  return false;
}

/**
 * 「共享真的能读吗」：445 端口通**不代表**共享可用 —— 服务在、但共享没挂 / 凭据过期 /
 * 会话被踢掉时，端口探测照样返回 YES，而一访问就会挂住几秒。
 *
 * 这里用真实凭据建一次会话 + 读一次根目录，读不到就判离线：内容不该继续显示，
 * 用户也不用等超时才发现「这个库打不开」。
 */
export async function verifySmbShare(
  rootAbs: string,
  username?: string | null,
  password?: string | null,
  timeoutMs = 3000,
): Promise<boolean> {
  const root = String(rootAbs || '').trim();
  if (!root) return false;
  const sessionOk = await ensureSmbSession(root, username, password);
  if (!sessionOk) return false;
  try {
    await Promise.race([
      fs.promises.access(root, fs.constants.R_OK),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('smb share read timeout')), timeoutMs),
      ),
    ]);
    return true;
  } catch {
    return false;
  }
}

export function openSmbPassword(stored: string | null): string {
  if (!stored) return '';
  return isSealed(stored) ? openSecret(stored, SMB_SALT) ?? '' : stored;
}

export interface SmbSourceLike {
  conn_type?: string | null;
  host?: string | null;
  share?: string | null;
  sub_path?: string | null;
  unc_path?: string | null;
}

/** 库的远端根路径（SMB）；非 SMB 返回 null */
export function uncPathOf(lib: SmbSourceLike): string | null {
  if (normalizeConnType(lib.conn_type) !== CONN_SMB) return null;
  if (lib.unc_path) return String(lib.unc_path);
  if (!lib.host || !lib.share) return null;
  return buildUnc(String(lib.host), String(lib.share), String(lib.sub_path || ''));
}
