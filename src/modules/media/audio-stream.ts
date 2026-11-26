import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import type { FastifyReply, FastifyRequest } from 'fastify';

import { parseRange } from '../files/download';
import { runFfprobe } from './ffmpeg-run';

/**
 * Web 端「边转码边推流」的音频兜底。
 *
 * 浏览器解码不了 APE / WMA / ALAC / AIFF 这类格式时，如果先整段转码再返回，
 * 长音频（有声书 50 分钟）要等 1 分钟以上，`<audio>` 早就超时报错了；
 * 因此这里改成实时把源解成 PCM WAV 往响应里推：
 * - 首字节延迟 ≈ ffmpeg 启动时间（几百毫秒），播多久转多久；
 * - 保留源采样率 / 声道，16bit 源完全无损，24bit 源按 24bit PCM 输出；
 * - 我们在写响应头前就能算出总字节数，因此能给出准确时长并支持 Range 拖动
 *   （拖动时按字节偏移换算出时间点，重新拉起 ffmpeg 从该处解码）。
 *
 * 搬到一个独立模块是因为音乐与本地博客共用同一套逻辑。
 */

export interface AudioProbe {
  durationMs: number;
  sampleRate: number;
  channels: number;
  /** 16 或 24（bit） */
  bits: 16 | 24;
  /** WAV 文件总字节数（含 44 字节头） */
  totalBytes: number;
}

interface ProbeCacheEntry {
  stamp: string;
  probe: AudioProbe | null;
}

const probeCache = new Map<string, ProbeCacheEntry>();
const PROBE_CACHE_MAX = 300;

function pruneProbeCache(): void {
  if (probeCache.size <= PROBE_CACHE_MAX) return;
  const overflow = probeCache.size - PROBE_CACHE_MAX;
  let i = 0;
  for (const key of probeCache.keys()) {
    if (i >= overflow) break;
    probeCache.delete(key);
    i += 1;
  }
}

/**
 * 读取音频时长 / 采样率 / 声道 / 位深。
 * 结果按「路径 + mtime + size」缓存，拖动重开 ffmpeg 时不必反复探测。
 */
export async function probeAudio(src: string): Promise<AudioProbe | null> {
  let st: fs.Stats;
  try {
    st = fs.statSync(src);
  } catch {
    return null;
  }
  const stamp = `${st.mtimeMs}:${st.size}`;
  const hit = probeCache.get(src);
  if (hit && hit.stamp === stamp) return hit.probe;

  const { code, stdout } = await runFfprobe(
    [
      '-v',
      'error',
      '-select_streams',
      'a:0',
      '-show_entries',
      'stream=sample_rate,channels,bits_per_raw_sample,bits_per_sample:format=duration',
      '-of',
      'json',
      src,
    ],
    8000,
  );
  let probe: AudioProbe | null = null;
  if (code === 0 && stdout) {
    try {
      const json = JSON.parse(stdout) as {
        streams?: Array<{
          sample_rate?: string;
          channels?: number;
          bits_per_raw_sample?: string;
          bits_per_sample?: number;
        }>;
        format?: { duration?: string };
      };
      const s = json.streams?.[0];
      const durationMs = Math.round(Number(json.format?.duration) * 1000);
      const rawRate = Number(s?.sample_rate) || 0;
      const channels = Number(s?.channels) || 0;
      const rawBits = Number(s?.bits_per_raw_sample) || Number(s?.bits_per_sample) || 16;
      if (Number.isFinite(durationMs) && durationMs > 0 && rawRate > 0 && channels > 0) {
        const sampleRate = Math.min(96000, Math.max(8000, rawRate));
        const ch = Math.min(2, Math.max(1, channels));
        const bits: 16 | 24 = rawBits > 16 ? 24 : 16;
        const blockAlign = ch * (bits / 8);
        const totalBytes = 44 + Math.floor((durationMs / 1000) * sampleRate) * blockAlign;
        probe = { durationMs, sampleRate, channels: ch, bits, totalBytes };
      }
    } catch {
      probe = null;
    }
  }
  probeCache.set(src, { stamp, probe });
  pruneProbeCache();
  return probe;
}

/** 44 字节标准 PCM WAV 头（无扩展块，浏览器通用） */
function wavHeader(
  dataBytes: number,
  sampleRate: number,
  channels: number,
  bits: 16 | 24,
): Buffer {
  const blockAlign = channels * (bits / 8);
  const byteRate = sampleRate * blockAlign;
  const h = Buffer.alloc(44);
  h.write('RIFF', 0, 'ascii');
  h.writeUInt32LE(36 + dataBytes, 4);
  h.write('WAVE', 8, 'ascii');
  h.write('fmt ', 12, 'ascii');
  h.writeUInt32LE(16, 16); // fmt chunk size
  h.writeUInt16LE(1, 20); // PCM
  h.writeUInt16LE(channels, 22);
  h.writeUInt32LE(sampleRate, 24);
  h.writeUInt32LE(byteRate, 28);
  h.writeUInt16LE(blockAlign, 32);
  h.writeUInt16LE(bits, 34);
  h.write('data', 36, 'ascii');
  h.writeUInt32LE(dataBytes, 40);
  return h;
}

function ffmpegBin(): string | null {
  const env = (process.env.COLANAS_FFMPEG || '').trim();
  if (env) return env;
  const vendor = path.join(process.cwd(), 'vendor', 'ffmpeg');
  for (const p of [
    path.join(vendor, 'ffmpeg.exe'),
    path.join(vendor, 'bin', 'ffmpeg.exe'),
    path.join(vendor, 'ffmpeg'),
    path.join(vendor, 'bin', 'ffmpeg'),
  ]) {
    if (fs.existsSync(p)) return p;
  }
  if (process.env.COLANAS_FFMPEG_ALLOW_PATH === '1') return 'ffmpeg';
  return null;
}

/**
 * 把音频实时解成 PCM WAV 推给客户端（支持 Range 拖动）。
 *
 * 返回 `false` 表示没有接管响应（探测失败 / 找不到 ffmpeg），调用方应回退原始文件；
 * 返回 `true` 表示已经 `hijack` 并开始写流。
 */
export async function streamWav(
  req: FastifyRequest,
  reply: FastifyReply,
  src: string,
): Promise<boolean> {
  const probe = await probeAudio(src);
  if (!probe) return false;
  const bin = ffmpegBin();
  if (!bin) return false;

  const total = probe.totalBytes;
  let start = 0;
  let end = total - 1;
  const range = parseRange(req.headers.range, total);
  if (range === 'unsatisfiable') {
    reply.code(416).header('Content-Range', `bytes */${total}`).send();
    return true;
  }
  if (range) {
    start = range.start;
    end = range.end;
  }

  const bytesPerSec = probe.sampleRate * probe.channels * (probe.bits / 8);
  const isRange = range !== null;
  reply.hijack();
  reply.raw.writeHead(isRange ? 206 : 200, {
    'Content-Type': 'audio/wav',
    'Accept-Ranges': 'bytes',
    'Content-Length': String(end - start + 1),
    'Cache-Control': 'private, max-age=0',
    ...(isRange ? { 'Content-Range': `bytes ${start}-${end}/${total}` } : {}),
  });

  const limit = end - start + 1;
  let sent = 0;

  // 请求的是文件头区域：先把 WAV 头对应片段写出去
  if (start < 44) {
    const header = wavHeader(total - 44, probe.sampleRate, probe.channels, probe.bits);
    const part = header.subarray(start, Math.min(44, end + 1));
    if (part.length > 0) {
      reply.raw.write(part);
      sent += part.length;
    }
    if (sent >= limit) {
      reply.raw.end();
      return true;
    }
  }

  // PCM 从哪个时间点开始：跳过 WAV 头后的字节偏移换算成秒
  const dataOffset = Math.max(0, start - 44);
  const seekSec = dataOffset / bytesPerSec;
  const pcmFormat = probe.bits === 24 ? 's24le' : 's16le';
  const args = [
    '-v',
    'error',
    ...(seekSec > 0 ? ['-ss', seekSec.toFixed(3)] : []),
    '-i',
    src,
    '-vn',
    '-ac',
    String(probe.channels),
    '-ar',
    String(probe.sampleRate),
    '-f',
    pcmFormat,
    '-acodec',
    probe.bits === 24 ? 'pcm_s24le' : 'pcm_s16le',
    'pipe:1',
  ];

  let finished = false;
  const finishSilence = () => {
    // 源比探测时长略短（或 ffmpeg 提前退出）时补静音，尽量把长度对齐。
    // 最多补 4MB：真失败时宁可连接异常，也不要往网络里灌几百 MB 静音。
    let left = Math.min(Math.max(0, limit - sent), 4 * 1024 * 1024);
    const zero = Buffer.alloc(256 * 1024);
    while (left > 0) {
      const n = Math.min(left, zero.length);
      reply.raw.write(zero.subarray(0, n));
      left -= n;
    }
    reply.raw.end();
  };

  let child: ReturnType<typeof spawn> | null = null;
  try {
    child = spawn(bin, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    child = null;
  }
  if (!child || !child.stdout) {
    // 头已经发出去了，只能补静音把长度对齐，避免浏览器收到半截响应
    finished = true;
    finishSilence();
    return true;
  }

  const stdout = child.stdout;
  const closeChild = () => {
    if (!child || finished) return;
    finished = true;
    try {
      child.kill('SIGKILL');
    } catch {
      /* 已退出 */
    }
  };

  reply.raw.on('close', closeChild);
  stdout.on('data', (chunk: Buffer) => {
    if (sent >= limit) return;
    const remain = limit - sent;
    const slice = chunk.length > remain ? chunk.subarray(0, remain) : chunk;
    sent += slice.length;
    if (!reply.raw.write(slice)) stdout.pause();
    if (sent >= limit) {
      closeChild();
      reply.raw.end();
    }
  });
  reply.raw.on('drain', () => stdout.resume());
  stdout.on('end', () => {
    // 源比探测时长略短时补静音，保证 Content-Length 一致
    if (!finished) {
      finished = true;
      if (sent < limit) finishSilence();
      else reply.raw.end();
    }
  });
  child.on('error', () => {
    if (finished) return;
    finished = true;
    if (sent < limit) finishSilence();
    else reply.raw.end();
  });
  child.on('exit', () => {
    // stdout 'end' 通常先到；这里兜住异常退出
    if (!finished) {
      finished = true;
      if (sent < limit) finishSilence();
      else reply.raw.end();
    }
  });
  return true;
}
