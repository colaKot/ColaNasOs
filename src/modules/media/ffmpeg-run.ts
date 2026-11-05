import { spawn } from 'node:child_process';
import path from 'node:path';

/**
 * ffmpeg 二进制定位与调用（video / music 共用）。
 *
 * 候选顺序：`COLANAS_FFMPEG` → `vendor/ffmpeg/ffmpeg` → `vendor/ffmpeg/bin/ffmpeg`。
 * 默认**不回落系统 PATH**：系统里的 ffmpeg 常是功能受限的构建（例如 ImageMagick 附带的
 * 版本没有 ffprobe），静默回落到它会掩盖问题；确需时显式设 `COLANAS_FFMPEG_ALLOW_PATH=1`。
 *
 * 约定：二进制由 `node tool/fetch-ffmpeg.js` 拉取 jellyfin-ffmpeg 并校验 sha256，不入仓库。
 */
const FFMPEG_EXE = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';

function candidates(): string[] {
  const list: string[] = [];
  const env = process.env.COLANAS_FFMPEG;
  if (env && env.trim()) list.push(env.trim());

  const vendor = path.join(process.cwd(), 'vendor', 'ffmpeg');
  list.push(path.join(vendor, FFMPEG_EXE));
  list.push(path.join(vendor, 'bin', FFMPEG_EXE));

  if (process.env.COLANAS_FFMPEG_ALLOW_PATH === '1') list.push(FFMPEG_EXE);
  return list;
}

/** 首次成功 spawn 的二进制会被记住，避免每条命令都试一遍 */
let resolvedBin: string | null = null;

export function resolvedFfmpeg(): string | null {
  return resolvedBin;
}

interface AttemptResult {
  spawned: boolean;
  code: number | null;
  stderr: string;
}

function attempt(bin: string, args: string[], timeoutMs: number): Promise<AttemptResult> {
  return new Promise((resolve) => {
    let stderr = '';
    let done = false;
    const child = spawn(bin, args, { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      try {
        child.kill('SIGKILL');
      } catch {
        /* 忽略 */
      }
      resolve({ spawned: true, code: null, stderr });
    }, timeoutMs);

    child.stderr.on('data', (c) => {
      stderr += String(c);
      if (stderr.length > 64_000) stderr = stderr.slice(-32_000);
    });
    child.on('error', () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ spawned: false, code: null, stderr });
    });
    child.on('exit', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ spawned: true, code, stderr });
    });
  });
}

/** 依次尝试候选二进制；只有 spawn 失败（找不到文件）才换下一个 */
export async function runFfmpeg(
  args: string[],
  timeoutMs: number,
): Promise<{ code: number | null; stderr: string }> {
  const bins = resolvedBin ? [resolvedBin] : candidates();
  for (const bin of bins) {
    const r = await attempt(bin, args, timeoutMs);
    if (!r.spawned) continue;
    resolvedBin = bin;
    return { code: r.code, stderr: r.stderr };
  }
  return { code: null, stderr: '' };
}

const FFPROBE_EXE = process.platform === 'win32' ? 'ffprobe.exe' : 'ffprobe';

/**
 * ffprobe：跟 ffmpeg 放同一个目录（jellyfin-ffmpeg 两个都带）。
 *
 * 不用来跑转码，只用来读结构化信息 —— `ffprobe -of json` 比解析
 * `ffmpeg -i` 的 stderr 可靠得多，尤其是「多条音轨各自的语言 / 名字」：
 * stderr 里那点 metadata 是跟着缩进块走的，多轨时极易串行。
 */
export async function runFfprobe(
  args: string[],
  timeoutMs: number,
): Promise<{ code: number | null; stdout: string }> {
  const base = resolvedBin ?? candidates()[0];
  const bin = path.join(path.dirname(base), FFPROBE_EXE);
  return new Promise((resolve) => {
    let stdout = '';
    let done = false;
    const child = spawn(bin, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      try {
        child.kill('SIGKILL');
      } catch {
        /* 忽略 */
      }
      resolve({ code: null, stdout });
    }, timeoutMs);
    child.stdout.on('data', (c) => {
      stdout += String(c);
      if (stdout.length > 512_000) stdout = stdout.slice(-256_000);
    });
    child.on('error', () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code: null, stdout: '' });
    });
    child.on('exit', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code, stdout });
    });
  });
}

/** 并发闸门：抽帧 / 海报不比转码重要，避免占满 CPU */
export function createLimiter(limit: number): <T>(fn: () => Promise<T>) => Promise<T> {
  let active = 0;
  const queue: Array<() => void> = [];
  return async function run<T>(fn: () => Promise<T>): Promise<T> {
    if (active >= limit) {
      await new Promise<void>((resolve) => queue.push(resolve));
    }
    active += 1;
    try {
      return await fn();
    } finally {
      active -= 1;
      const next = queue.shift();
      if (next) next();
    }
  };
}