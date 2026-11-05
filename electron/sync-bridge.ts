import { app, BrowserWindow, dialog, ipcMain } from 'electron';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

/**
 * 同步的本地文件能力（主进程侧）。
 *
 * 渲染进程是 Flutter Web 产物，拿不到 `dart:io`，所以本地目录的
 * 扫描 / 分块读 / 下载落盘 / 删除全部转到这里执行，结果以 JSON 回传。
 * 协议刻意保持「一个入口 + 字符串 JSON」：Dart 侧只写一次 js_interop 调用，
 * 不做结构化对象映射，出错面最小。
 */
interface ScanEntry {
  path: string;
  size: number;
  mtimeMs: number;
}

interface DownloadJob {
  received: number;
  total: number;
  done: boolean;
  cancelled: boolean;
  error?: string;
}

const jobs = new Map<string, DownloadJob>();

/**
 * 托盘状态上报（`{op:'trayState'}`）：Dart 侧把「自动同步是否暂停 / 本机任务数」
 * 交给主进程，主进程据此重画托盘菜单。用注入回调而不是直接 import main.ts，
 * 避免 main ⇄ bridge 互相 import 的循环。
 */
let trayStateHandler: ((state: { paused: boolean; taskCount: number }) => void) | null = null;

export function onTrayState(
  handler: (state: { paused: boolean; taskCount: number }) => void,
): void {
  trayStateHandler = handler;
}

export function registerSyncBridge(): void {
  ipcMain.handle('colanas:sync', async (_event, raw: unknown) => {
    try {
      const req = JSON.parse(String(raw ?? '{}')) as Record<string, unknown>;
      const data = await handle(req);
      return JSON.stringify({ ok: true, data });
    } catch (err) {
      return JSON.stringify({ ok: false, error: String((err as Error)?.message ?? err) });
    }
  });
}

async function handle(req: Record<string, unknown>): Promise<unknown> {
  switch (String(req.op ?? '')) {
    case 'device':
      return deviceInfo();
    case 'pickDirectory':
      return pickDirectory();
    case 'scan':
      return scan(String(req.root ?? ''));
    case 'sizeOf':
      return sizeOf(String(req.path ?? ''));
    case 'readChunk':
      return readChunk(String(req.path ?? ''), Number(req.start ?? 0), Number(req.end ?? 0));
    case 'exists':
      return { exists: await exists(String(req.path ?? '')) };
    case 'deleteLocal':
      return deleteLocal(String(req.path ?? ''));
    case 'download':
      return startDownload(req);
    case 'progress':
      return progressOf(String(req.jobId ?? ''));
    case 'cancel':
      return cancelJob(String(req.jobId ?? ''));
    case 'trayState':
      trayStateHandler?.({
        paused: req.paused === true,
        taskCount: Number(req.taskCount ?? 0),
      });
      return {};
    default:
      throw new Error(`unknown sync op: ${String(req.op)}`);
  }
}

/** 机器级设备标识：同一台机器上主客户端与同步端解析出同一个值 */
function deviceInfo(): { id: string; name: string } {
  const file = path.join(app.getPath('userData'), 'sync-device-id');
  let id = '';
  try {
    id = fs.readFileSync(file, 'utf-8').trim();
  } catch {
    /* 首次运行 */
  }
  const name = os.hostname() || 'windows';
  if (!id) {
    id = crypto.createHash('sha1').update(`${name}-${os.userInfo().username}`).digest('hex').slice(0, 16);
    try {
      fs.writeFileSync(file, id, 'utf-8');
    } catch {
      /* 写不了就每次现算，不影响同步 */
    }
  }
  return { id, name };
}

async function pickDirectory(): Promise<{ path: string | null }> {
  const win = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0];
  const options = { properties: ['openDirectory', 'createDirectory'] as const };
  const res = win
    ? await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] })
    : await dialog.showOpenDialog({ properties: [...options.properties] });
  if (res.canceled || res.filePaths.length === 0) return { path: null };
  return { path: res.filePaths[0] };
}

/** 递归扫描（不跟随符号链接）；过滤规则在客户端做，这里只吐原始条目 */
async function scan(root: string): Promise<{ entries: ScanEntry[] }> {
  const rootAbs = path.resolve(root);
  const out: ScanEntry[] = [];
  const stack: string[] = [rootAbs];
  while (stack.length > 0) {
    const dir = stack.pop() as string;
    let items: fs.Dirent[];
    try {
      items = await fsp.readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const it of items) {
      const abs = path.join(dir, it.name);
      if (it.isSymbolicLink()) continue;
      if (it.isDirectory()) {
        stack.push(abs);
        continue;
      }
      if (!it.isFile()) continue;
      try {
        const st = await fsp.stat(abs);
        if (st.size <= 0) continue;
        out.push({
          path: path.relative(rootAbs, abs).split(path.sep).join('/'),
          size: st.size,
          mtimeMs: Math.round(st.mtimeMs),
        });
      } catch {
        /* 单个文件读不到不中断整趟扫描 */
      }
    }
  }
  return { entries: out };
}

async function sizeOf(file: string): Promise<{ size: number }> {
  const st = await fsp.stat(file);
  return { size: st.size };
}

async function readChunk(file: string, start: number, end: number): Promise<{ data: string }> {
  const fh = await fsp.open(file, 'r');
  try {
    const len = Math.max(0, Math.floor(end) - Math.floor(start));
    const buf = Buffer.alloc(len);
    const { bytesRead } = await fh.read(buf, 0, len, Math.floor(start));
    return { data: buf.subarray(0, bytesRead).toString('base64') };
  } finally {
    await fh.close();
  }
}

async function exists(target: string): Promise<boolean> {
  try {
    await fsp.access(target);
    return true;
  } catch {
    return false;
  }
}

async function deleteLocal(target: string): Promise<{ ok: true }> {
  await fsp.rm(target, { force: true, recursive: false });
  return { ok: true };
}

/**
 * 下载：立刻返回 jobId，由客户端轮询 `progress`。
 * 不在这里等整段下载，避免一个几 GB 的文件把 IPC 请求挂住。
 */
async function startDownload(req: Record<string, unknown>): Promise<{ jobId: string }> {
  const jobId = String(req.jobId ?? crypto.randomUUID());
  const localPath = String(req.localPath ?? '');
  const uri = String(req.uri ?? '');
  const mtimeMs = Number(req.mtimeMs ?? 0);
  if (!localPath || !uri) throw new Error('localPath / uri required');

  const job: DownloadJob = {
    received: 0,
    total: Number(req.total ?? 0) || 0,
    done: false,
    cancelled: false,
  };
  jobs.set(jobId, job);

  void (async () => {
    const tmp = `${localPath}.part`;
    try {
      await fsp.mkdir(path.dirname(localPath), { recursive: true });
      const headers = (req.headers as Record<string, string>) ?? {};
      const res = await fetch(uri, { headers });
      if (!res.ok || !res.body) throw new Error(`http ${res.status}`);
      const total = Number(res.headers.get('content-length') ?? 0);
      if (total > 0) job.total = total;

      const out = fs.createWriteStream(tmp);
      const reader = res.body.getReader();
      for (;;) {
        if (job.cancelled) {
          await reader.cancel().catch(() => undefined);
          throw new Error('cancelled');
        }
        const { done, value } = await reader.read();
        if (done) break;
        if (value) {
          out.write(Buffer.from(value));
          job.received += value.length;
        }
      }
      await new Promise<void>((resolve, reject) => {
        out.on('error', reject);
        out.end(() => resolve());
      });
      await fsp.rename(tmp, localPath);
      if (mtimeMs > 0) {
        // 对齐 mtime：不做的话下一轮比对会认为「远端又变了」，无限重传
        const t = new Date(mtimeMs);
        await fsp.utimes(localPath, t, t).catch(() => undefined);
      }
      job.done = true;
    } catch (err) {
      job.error = String((err as Error)?.message ?? err);
      job.done = true;
      await fsp.rm(tmp, { force: true }).catch(() => undefined);
    }
  })();

  return { jobId };
}

function progressOf(jobId: string): DownloadJob {
  const job = jobs.get(jobId);
  if (!job) return { received: 0, total: 0, done: true, cancelled: false, error: 'job not found' };
  if (job.done) {
    // 完成后再留一小会儿，让客户端取到最终进度；由 cancel/下一次下载清理
    setTimeout(() => jobs.delete(jobId), 60_000).unref?.();
  }
  return { ...job };
}

function cancelJob(jobId: string): { ok: true } {
  const job = jobs.get(jobId);
  if (job) job.cancelled = true;
  return { ok: true };
}
