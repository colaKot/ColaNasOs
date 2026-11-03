import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { mountError, type RemoteEntry } from './webdav';

/**
 * rclone 后端：SMB / NFS / 各类网盘统一走 `rclone <remote>:<path>`。
 *
 * 本机没有 rclone 时明确报 501，不静默降级。列表用 `lsjson`，传输用 `copyto` + 临时文件，
 * 参数直接传给子进程（不经 shell），避免命令注入。
 */
const EXE = process.env.COLANAS_RCLONE || (process.platform === 'win32' ? 'rclone.exe' : 'rclone');

interface RunResult {
  spawned: boolean;
  code: number | null;
  stdout: string;
  stderr: string;
}

function run(args: string[], timeoutMs = 60_000): Promise<RunResult> {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let done = false;
    const child = spawn(EXE, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      try {
        child.kill('SIGKILL');
      } catch {
        /* 忽略 */
      }
      resolve({ spawned: true, code: null, stdout, stderr: 'timeout' });
    }, timeoutMs);

    child.stdout.on('data', (c) => {
      stdout += String(c);
      if (stdout.length > 8 * 1024 * 1024) stdout = stdout.slice(-4 * 1024 * 1024);
    });
    child.stderr.on('data', (c) => {
      stderr += String(c);
      if (stderr.length > 8192) stderr = stderr.slice(-4096);
    });
    child.on('error', () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ spawned: false, code: null, stdout, stderr });
    });
    child.on('exit', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ spawned: true, code, stdout, stderr });
    });
  });
}

export async function rcloneAvailable(): Promise<boolean> {
  const r = await run(['version'], 5000);
  return r.spawned && r.code === 0;
}

export function joinRemote(base: string, relPath: string): string {
  let baseSpec = base.trim();
  if (!baseSpec.includes(':')) baseSpec = `${baseSpec}:`;
  const rel = relPath.replace(/^\/+|\/+$/g, '');
  if (!rel) return baseSpec;
  return baseSpec.endsWith(':') || baseSpec.endsWith('/') ? `${baseSpec}${rel}` : `${baseSpec}/${rel}`;
}

export async function rcloneList(spec: string): Promise<RemoteEntry[]> {
  const r = await run(['lsjson', '--max-depth', '1', spec], 60_000);
  if (!r.spawned) throw mountError(501, 'rclone 不可用（安装后设置 COLANAS_RCLONE 或加入 PATH）');
  if (r.code !== 0) throw mountError(502, `rclone lsjson failed: ${r.stderr.slice(-200)}`);

  let parsed: Array<Record<string, unknown>>;
  try {
    parsed = JSON.parse(r.stdout || '[]') as Array<Record<string, unknown>>;
  } catch {
    throw mountError(502, 'rclone lsjson 输出不是 JSON');
  }

  return parsed
    .map((e) => {
      const rel = String(e.Path ?? e.Name ?? '');
      const segs = rel.split('/');
      return {
        name: segs[segs.length - 1],
        path: rel,
        dir: Boolean(e.IsDir),
        size: Number(e.Size) || 0,
        mtime: e.ModTime ? Math.floor(Date.parse(String(e.ModTime)) / 1000) || null : null,
      } as RemoteEntry;
    })
    .filter((e) => e.path && !e.path.endsWith('..'))
    .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1));
}

/** 下载到临时文件；调用方负责读完后删除 */
export async function rcloneDownload(spec: string): Promise<{ file: string; size: number }> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-rclone-'));
  const file = path.join(dir, 'blob');
  const r = await run(['copyto', spec, file], 10 * 60_000);
  if (!r.spawned) throw mountError(501, 'rclone 不可用（安装后设置 COLANAS_RCLONE 或加入 PATH）');
  if (r.code !== 0 || !fs.existsSync(file)) {
    fs.rmSync(dir, { recursive: true, force: true });
    throw mountError(502, `rclone download failed: ${r.stderr.slice(-200)}`);
  }
  return { file, size: fs.statSync(file).size };
}

export async function rcloneMkdir(spec: string): Promise<void> {
  const r = await run(['mkdir', spec], 60_000);
  if (!r.spawned) throw mountError(501, 'rclone 不可用（安装后设置 COLANAS_RCLONE 或加入 PATH）');
  if (r.code !== 0) throw mountError(502, `rclone mkdir failed: ${r.stderr.slice(-200)}`);
}

/** 只删文件（目录不提供删除，避免误 purge） */
export async function rcloneDeleteFile(spec: string): Promise<void> {
  const r = await run(['deletefile', spec], 60_000);
  if (!r.spawned) throw mountError(501, 'rclone 不可用（安装后设置 COLANAS_RCLONE 或加入 PATH）');
  if (r.code !== 0) throw mountError(502, `rclone delete failed: ${r.stderr.slice(-200)}`);
}

/** 上传：先落临时文件再 copyto（rclone 对 stdin 支持因后端而异） */
export async function rcloneUpload(body: Readable, spec: string): Promise<void> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-rclone-'));
  const file = path.join(dir, 'blob');
  try {
    await pipeline(body, fs.createWriteStream(file));
    const r = await run(['copyto', file, spec], 10 * 60_000);
    if (!r.spawned) throw mountError(501, 'rclone 不可用（安装后设置 COLANAS_RCLONE 或加入 PATH）');
    if (r.code !== 0) throw mountError(502, `rclone upload failed: ${r.stderr.slice(-200)}`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}