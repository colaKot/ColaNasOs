import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { resolveTtsPaths } from './paths';

/**
 * Qwen3-TTS（GGUF）本地合成引擎 —— 直接调用 llama.cpp 的 `llama-tts`。
 *
 * 为什么是「逐块起进程」而不是常驻服务：
 *   `llama-tts` 是一次性 CLI（llama.cpp 的 tools/tts 演示工具），没有 server 模式。
 *   每块加载一次模型约 3~6 秒（Vulkan 首次还要编译着色器），所以块不能切太小：
 *   实测 300 字左右一块，加载开销摊薄到 15% 以内。
 *
 * 为什么不保留 python sidecar：
 *   旧的 Kokoro 方案必须走 python（中文 G2P 只有 misaki 能用），顺带把 300MB 的
 *   python 运行时塞进了安装包。GGUF 方案是纯二进制调用，Node 直接 spawn 就够，
 *   python 运行时可以整个删掉。
 *
 * 实测（Ryzen 7 7840HS / Radeon 780M，Q4_K_M，-ngl 99）：1.2~1.46x 实时。
 * 首批运行会慢一截，那是 Vulkan 着色器编译，之后走缓存。
 */

export interface TtsEngineOptions {
  binPath: string;
  modelPath: string;
  mmprojPath: string;
  ffmpeg: string;
  /** 中间产物目录（每块一个 wav） */
  workDir: string;
  /** 放预热标记的目录 */
  cacheDir: string;
  /** GPU 卸载层数，99 = 全卸载；0 = 纯 CPU */
  ngl?: number;
  threads?: number;
  /** 每块字数上限 */
  chunkChars?: number;
  lang?: string;
  log?: (level: 'debug' | 'info' | 'warn' | 'error', message: string) => void;
}

/**
 * 模型原生语速偏快：实测 `speed=1` 把 7641 字稿件念成 1105.9 秒，
 * 约 348 汉字/分钟，明显快于中文新闻播报常见的 270~290。
 * 这里校准基准 —— UI 上的 1.0 仍是「正常」，只是落到 ffmpeg atempo 时整体放慢；
 * 相对倍速关系不变（1.2 依旧比 1.0 快 20%），已保存的 speed=1 配置不用迁移。
 * atempo 单滤镜有效区间 0.5~2，校准后一并夹住。
 */
export const TEMPO_CALIBRATION = 0.8;

/** UI 倍速 → 实际 ffmpeg atempo；非法值按 1.0（正常速）处理 */
export function effectiveTempo(speed: number): number {
  const raw = Number.isFinite(speed) ? Math.max(0.5, Math.min(speed, 2)) : 1;
  return Math.max(0.5, Math.min(raw * TEMPO_CALIBRATION, 2));
}

export interface SynthParams {
  text: string;
  /** 参考音色文件（24kHz 单声道 wav 最佳） */
  voicePath: string;
  /** 1 = 正常速（已按 TEMPO_CALIBRATION 校准）；0.5~2 之间，用 ffmpeg atempo 实现 */
  speed: number;
  wav: string;
  mp3?: string;
  mp3Bitrate?: string;
  onProgress?: (done: number, total: number) => void;
  /** 中止信号：切换页面 / 服务关闭时用 */
  isCancelled?: () => boolean;
}

export interface SynthResult {
  durationSec: number;
  sampleRate: number;
  parts: number;
  han: number;
  wav: string;
  wavBytes: number;
  mp3: string | null;
  mp3Bytes: number;
}

const SAMPLE_RATE = 24000;
const BYTES_PER_SEC = SAMPLE_RATE * 2; // 16-bit 单声道
const GAP_SEC = 0.18;
const CHUNK_TIMEOUT_MS = 10 * 60 * 1000;

const HAN = /[\u4e00-\u9fff]/g;

export function hanCount(s: string): number {
  return (s.match(HAN) || []).length;
}

/**
 * 切块：按句末标点切，攒到 limit 字；过长的句子再按逗号切，最后硬切。
 * 不切块的后果不是慢，而是**质量差**：一条 2000 字的 prompt 会让模型越读越飘。
 */
export function splitText(text: string, limit = 300): string[] {
  const clean = text.replace(/[ \t\r\f\v]+/g, ' ').replace(/\n{2,}/g, '\n').trim();
  if (!clean) return [];

  const sentences: string[] = [];
  let buf = '';
  for (const ch of clean) {
    buf += ch;
    if ('。！？!?；;\n'.includes(ch)) {
      sentences.push(buf);
      buf = '';
    }
  }
  if (buf.trim()) sentences.push(buf);

  const pieces: string[] = [];
  for (const raw of sentences) {
    let s = raw.trim();
    while (s.length > limit) {
      let cut = -1;
      for (const c of '，,、：: ') {
        cut = Math.max(cut, s.lastIndexOf(c, limit));
      }
      cut = cut > limit * 0.5 ? cut + 1 : limit;
      pieces.push(s.slice(0, cut).trim());
      s = s.slice(cut).trim();
    }
    if (s) pieces.push(s);
  }

  // 合并过短的块：每块都要付一次模型加载，碎块最亏
  const merged: string[] = [];
  let cur = '';
  for (const p of pieces) {
    if (cur && cur.length + p.length > limit) {
      merged.push(cur);
      cur = p;
    } else {
      cur += p;
    }
  }
  if (cur) merged.push(cur);
  return merged.filter((p) => p.trim().length > 0);
}

/** 读 wav 的 data 块大小：比 ffprobe 快，也不用依赖 ffprobe 是否随包 */
function wavDataBytes(file: string): number {
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(12);
    fs.readSync(fd, head, 0, 12, 0);
    if (head.toString('ascii', 0, 4) !== 'RIFF') throw new Error(`不是 wav：${file}`);
    const size = fs.statSync(file).size;
    let off = 12;
    while (off + 8 <= size) {
      const hdr = Buffer.alloc(8);
      fs.readSync(fd, hdr, 0, 8, off);
      const id = hdr.toString('ascii', 0, 4);
      const len = hdr.readUInt32LE(4);
      if (id === 'data') return Math.min(len, size - off - 8);
      off += 8 + len + (len % 2);
    }
    throw new Error(`wav 里没有 data 块：${file}`);
  } finally {
    fs.closeSync(fd);
  }
}

function exec(
  cmd: string,
  args: string[],
  onSpawn?: (p: ChildProcessWithoutNullStreams) => void,
): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { windowsHide: true });
    onSpawn?.(p);
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      p.kill('SIGKILL');
      stderr += `\n[超时 ${CHUNK_TIMEOUT_MS / 1000}s，已强制结束]`;
    }, CHUNK_TIMEOUT_MS);
    p.stdout?.on('data', (d: Buffer) => {
      stdout += d.toString();
      if (stdout.length > 200_000) stdout = stdout.slice(-100_000);
    });
    p.stderr?.on('data', (d: Buffer) => {
      stderr += d.toString();
      if (stderr.length > 200_000) stderr = stderr.slice(-100_000);
    });
    p.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    p.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}

export class TtsEngine {
  private child: ChildProcessWithoutNullStreams | null = null;
  private closed = false;

  constructor(private opts: TtsEngineOptions) {}

  /**
   * 一键下载完成后重新解析路径。
   *
   * `getTts()` 是进程级单例：第一次进页面时模型往往还没下，`modelPath` 会是空串。
   * 不刷新的话，下载完了引擎仍报「缺模型」，必须重启服务才能用 —— 这与「下完就能用」相悖。
   * 只在解析出**非空**路径时覆盖，避免临时解析失败把本来能用的引擎弄坏；
   * 文件被删时 status() 的 existsSync 仍会如实报错。
   */
  refreshPaths(): void {
    const p = resolveTtsPaths();
    if (p.bin) this.opts.binPath = p.bin;
    if (p.model) this.opts.modelPath = p.model;
    if (p.mmproj) this.opts.mmprojPath = p.mmproj;
    if (p.ffmpeg) this.opts.ffmpeg = p.ffmpeg;
  }

  /** 只在真正要用的时候才判缺失，启动阶段不报错（模型是可选下载项） */
  status(): { available: boolean; reason?: string } {
    if (this.closed) return { available: false, reason: '引擎已停止' };
    if (process.env.COLANAS_TTS_DISABLED === '1') {
      return { available: false, reason: '已被 COLANAS_TTS_DISABLED=1 关闭' };
    }
    const miss: string[] = [];
    if (!fs.existsSync(this.opts.binPath)) miss.push(`llama-tts（${this.opts.binPath}）`);
    if (!fs.existsSync(this.opts.modelPath)) miss.push(`talker 模型（${this.opts.modelPath}）`);
    if (!fs.existsSync(this.opts.mmprojPath)) miss.push(`mmproj（${this.opts.mmprojPath}）`);
    if (miss.length) {
      // 装机版没有 npm，但页面上有一键下载；源码用户也可以继续用脚本
      const how = '请点页面上的「一键下载」（源码用户也可执行 npm run tts:model）';
      return {
        available: false,
        reason: `缺少 ${miss.join('、')}；${how}`,
      };
    }
    return { available: true };
  }

  private get chunkChars(): number {
    const n = Number(process.env.COLANAS_TTS_CHUNK || this.opts.chunkChars || 300);
    return Number.isFinite(n) ? Math.max(80, Math.min(n, 1200)) : 300;
  }

  private get ngl(): number {
    const n = Number(process.env.COLANAS_TTS_NGL ?? this.opts.ngl ?? 99);
    return Number.isFinite(n) ? n : 99;
  }

  private get threads(): number {
    const n = Number(process.env.COLANAS_TTS_THREADS ?? this.opts.threads ?? 8);
    return Number.isFinite(n) && n > 0 ? n : 8;
  }

  /** 合成一块 */
  private async synthChunk(text: string, voicePath: string, outWav: string): Promise<void> {
    const args = [
      '-m',
      this.opts.modelPath,
      '-mm',
      this.opts.mmprojPath,
      '-p',
      text,
      '--tts-lang',
      this.opts.lang || 'zh',
      '--tts-speaker-file',
      voicePath,
      '-ngl',
      String(this.ngl),
      '-t',
      String(this.threads),
      '-o',
      outWav,
    ];
    const r = await exec(this.opts.binPath, args, (p) => {
      this.child = p;
    });
    this.child = null;
    if (r.code !== 0 || !fs.existsSync(outWav)) {
      const tail = (r.stderr || r.stdout || '').split('\n').filter(Boolean).slice(-6).join('\n');
      throw new Error(`语音合成失败（退出码 ${r.code}）：${tail || '没有输出'}`);
    }
  }

  /**
   * 完整合成：切块 → 逐块推理 → 拼静音 → 倍速 → 落 wav（可选 mp3）。
   * 进度按「块」回调，前端拿来做进度条。
   */
  async synth(p: SynthParams): Promise<SynthResult> {
    const st = this.status();
    if (!st.available) throw new Error(st.reason || '语音合成不可用');
    if (!fs.existsSync(p.voicePath)) throw new Error(`参考音色不存在：${p.voicePath}`);

    const text = String(p.text || '').trim();
    if (!text) throw new Error('text 不能为空');
    if (!path.isAbsolute(p.wav)) throw new Error('wav 必须是绝对路径');

    const chunks = splitText(text, this.chunkChars);
    if (!chunks.length) throw new Error('没有可合成的文本');

    fs.mkdirSync(path.dirname(p.wav), { recursive: true });
    const partDir = path.join(this.opts.workDir, `p-${Date.now()}`);
    fs.mkdirSync(partDir, { recursive: true });

    const parts: string[] = [];
    let pcmBytes = 0;
    try {
      for (let i = 0; i < chunks.length; i += 1) {
        if (this.closed || p.isCancelled?.()) throw new Error('已取消');
        const out = path.join(partDir, `part${String(i).padStart(4, '0')}.wav`);
        await this.synthChunk(chunks[i], p.voicePath, out);
        parts.push(out);
        pcmBytes += wavDataBytes(out);
        p.onProgress?.(i + 1, chunks.length);
        this.opts.log?.('debug', `[tts] ${i + 1}/${chunks.length} ${chunks[i].length} 字`);
      }

      // 块间补静音：模型自带的首尾留白不足，直接拼会黏在一起
      const silence = path.join(partDir, '_gap.wav');
      await exec(this.opts.ffmpeg, [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        `anullsrc=r=${SAMPLE_RATE}:cl=mono`,
        '-t',
        String(GAP_SEC),
        '-ar',
        String(SAMPLE_RATE),
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        silence,
      ]);

      const listFile = path.join(partDir, 'concat.txt');
      const lines: string[] = [];
      for (const f of parts) {
        lines.push(`file '${f.replace(/\\/g, '/')}'`);
        lines.push(`file '${silence.replace(/\\/g, '/')}'`);
      }
      fs.writeFileSync(listFile, lines.join('\n'), 'utf8');

      const speed = effectiveTempo(p.speed);
      const filters: string[] = [];
      if (Math.abs(speed - 1) > 0.01) filters.push(`atempo=${speed.toFixed(3)}`);

      const wavArgs = [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        listFile,
        ...(filters.length ? ['-filter:a', filters.join(',')] : []),
        '-ar',
        String(SAMPLE_RATE),
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        p.wav,
      ];
      const rw = await exec(this.opts.ffmpeg, wavArgs);
      if (rw.code !== 0) throw new Error(`拼接失败：${(rw.stderr || '').slice(-400)}`);

      const durationSec = pcmBytes / BYTES_PER_SEC / speed;

      let mp3: string | null = null;
      let mp3Bytes = 0;
      if (p.mp3) {
        fs.mkdirSync(path.dirname(p.mp3), { recursive: true });
        const bitrate = p.mp3Bitrate || 'q2';
        const enc = bitrate.endsWith('k')
          ? ['-codec:a', 'libmp3lame', '-b:a', bitrate]
          : ['-codec:a', 'libmp3lame', '-qscale:a', bitrate.replace(/^q/, '')];
        const rm = await exec(this.opts.ffmpeg, [
          '-y',
          '-loglevel',
          'error',
          '-i',
          p.wav,
          ...enc,
          p.mp3,
        ]);
        if (rm.code === 0 && fs.existsSync(p.mp3)) {
          mp3 = p.mp3;
          mp3Bytes = fs.statSync(p.mp3).size;
        } else {
          this.opts.log?.('warn', `mp3 转码失败：${(rm.stderr || '').slice(-300)}`);
        }
      }

      return {
        durationSec: Math.round(durationSec * 1000) / 1000,
        sampleRate: SAMPLE_RATE,
        parts: chunks.length,
        han: hanCount(text),
        wav: p.wav,
        wavBytes: fs.existsSync(p.wav) ? fs.statSync(p.wav).size : 0,
        mp3,
        mp3Bytes,
      };
    } finally {
      // 分块 wav 只是中间产物：10 分钟节目约 55MB，留着没意义
      fs.rmSync(partDir, { recursive: true, force: true });
    }
  }

  /**
   * 预热：跑一句极短的合成，把 Vulkan 着色器编译和模型读盘的开销挪到用户点「试听」之前。
   * 有标记文件就直接返回，避免每次进页面都白烧十几秒 GPU。
   */
  async warmup(voicePath?: string): Promise<boolean> {
    const st = this.status();
    if (!st.available) return false;
    const marker = path.join(this.opts.cacheDir, '.warm');
    if (fs.existsSync(marker)) return true;
    const voice = (voicePath || '').trim();
    if (!voice || !fs.existsSync(voice)) return false;
    try {
      fs.mkdirSync(this.opts.cacheDir, { recursive: true });
      const tmp = path.join(this.opts.cacheDir, 'warm.wav');
      await this.synthChunk('预热', voice, tmp);
      fs.rmSync(tmp, { force: true });
      fs.writeFileSync(marker, String(Date.now()), 'utf8');
      this.opts.log?.('info', '[tts] 模型预热完成（Vulkan 着色器已缓存）');
      return true;
    } catch (e) {
      this.opts.log?.('warn', `[tts] 预热失败：${String((e as Error).message || e)}`);
      return false;
    }
  }

  async stop(): Promise<void> {
    this.closed = true;
    const c = this.child;
    this.child = null;
    if (c && !c.killed) c.kill();
  }
}
