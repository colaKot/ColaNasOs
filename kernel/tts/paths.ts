import fs from 'node:fs';
import path from 'node:path';

/**
 * 语音合成（Qwen3-TTS GGUF + llama.cpp）的路径解析。
 *
 * 三样东西各自独立，缺一个就整体不可用：
 *   1. `llama-tts` 可执行文件（含 ggml-vulkan.dll）
 *   2. Qwen3-TTS 的 talker GGUF + mmproj GGUF
 *   3. 一段参考音色 wav（模型是声音克隆，没参考音会明显掉质量）
 *
 * 开发态在 `vendor/` 下，装机态在 `resources/` 下（extraResources 会把 `vendor/models`
 * 摊平到 `models`），所以两边都要找。**模型不进 git**：1.4GB，由 `npm run tts:model` 下载。
 */

export interface TtsPaths {
  bin: string | null;
  modelDir: string | null;
  model: string | null;
  mmproj: string | null;
  voicesDir: string | null;
  ffmpeg: string | null;
}

const BIN_NAME = process.platform === 'win32' ? 'llama-tts.exe' : 'llama-tts';
const FFMPEG_NAME = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';

/** `win32-x64` / `darwin-arm64` / `linux-x64`：预编译包按平台分目录放 */
export function platformTag(): string {
  return `${process.platform}-${process.arch}`;
}

function resourcesPath(): string | undefined {
  return (process as unknown as { resourcesPath?: string }).resourcesPath;
}

/**
 * 一键下载的目标目录（`<dataDir>/tts`）。
 * 装机版不能往 `resources/` 或安装目录写（Program Files 多半只读），所以下载器把
 * 二进制和权重统一写到用户数据目录；这里把它加进搜索路径的最前面。
 * 源码用户若 `vendor/` 里已有模型，两条路径都能命中，不会重复下载。
 */
let homeDir: string | null = null;

export function setTtsHome(dir: string): void {
  homeDir = dir;
}

function roots(): string[] {
  const out: string[] = [];
  const home = homeDir || (process.env.COLANAS_TTS_HOME || '').trim();
  if (home) out.push(home);
  const res = resourcesPath();
  if (res) out.push(res);
  out.push(process.cwd());
  // dist/kernel/tts → 仓库根
  out.push(path.join(__dirname, '..', '..'));
  out.push(path.join(__dirname, '..', '..', '..'));
  return [...new Set(out)];
}

function firstFile(candidates: string[]): string | null {
  for (const p of candidates) {
    try {
      if (fs.statSync(p).isFile()) return p;
    } catch {
      // 不存在就下一个
    }
  }
  return null;
}

function firstDir(candidates: string[]): string | null {
  for (const p of candidates) {
    try {
      if (fs.statSync(p).isDirectory()) return p;
    } catch {
      // 同上
    }
  }
  return null;
}

/** llama-tts 可执行文件。`COLANAS_TTS_BIN` 可直指文件，跨平台调试时最省事 */
export function ttsBinPath(): string | null {
  const env = (process.env.COLANAS_TTS_BIN || '').trim();
  if (env) return firstFile([env]);
  const cands: string[] = [];
  for (const root of roots()) {
    cands.push(path.join(root, 'llama', platformTag(), BIN_NAME));
    cands.push(path.join(root, 'llama', BIN_NAME));
    cands.push(path.join(root, 'vendor', 'llama', platformTag(), BIN_NAME));
  }
  return firstFile(cands);
}

/** 模型目录：talker 与 mmproj 同一个目录，文件名按 `npm run tts:model` 的约定 */
export function ttsModelDir(): string | null {
  const env = (process.env.COLANAS_TTS_MODEL_DIR || '').trim();
  if (env) return firstDir([env]);
  const cands: string[] = [];
  for (const root of roots()) {
    cands.push(path.join(root, 'models', 'qwen3-tts'));
    cands.push(path.join(root, 'vendor', 'models', 'qwen3-tts'));
  }
  return firstDir(cands);
}

/** 目录里按前缀找唯一一个 .gguf（用户可能下 Q4_K_M / Q8_0 不同量化，不写死文件名） */
function pickGguf(dir: string, prefix: string, exclude?: string): string | null {
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return null;
  }
  const hits = names
    .filter((n) => n.toLowerCase().endsWith('.gguf'))
    .filter((n) => n.toLowerCase().startsWith(prefix.toLowerCase()))
    .filter((n) => !exclude || !n.includes(exclude))
    .sort((a, b) => {
      // 量化偏好：Q4_K_M 速度最好，其次 Q5/Q6/Q8，bf16 最慢
      const score = (n: string) =>
        /q4_k_m/i.test(n) ? 0 : /q5_k_m/i.test(n) ? 1 : /q4_k_s/i.test(n) ? 2 : /q8_0/i.test(n) ? 3 : 4;
      return score(a) - score(b);
    });
  return hits.length ? path.join(dir, hits[0]) : null;
}

/** 内置音色（随仓库，3 段 10 秒参考音，约 1.4MB） */
export function builtinVoicesDir(): string | null {
  const env = (process.env.COLANAS_TTS_VOICES_DIR || '').trim();
  if (env) return firstDir([env]);
  const cands: string[] = [];
  for (const root of roots()) {
    cands.push(path.join(root, 'voices'));
    cands.push(path.join(root, 'vendor', 'voices'));
  }
  return firstDir(cands);
}

export function ffmpegPath(): string | null {
  const env = (process.env.COLANAS_FFMPEG || '').trim();
  if (env && fs.existsSync(env)) return env;
  const cands: string[] = [];
  for (const root of roots()) {
    cands.push(path.join(root, 'ffmpeg', FFMPEG_NAME));
    cands.push(path.join(root, 'ffmpeg', 'bin', FFMPEG_NAME));
    cands.push(path.join(root, 'vendor', 'ffmpeg', FFMPEG_NAME));
    cands.push(path.join(root, 'vendor', 'ffmpeg', 'bin', FFMPEG_NAME));
  }
  const hit = firstFile(cands);
  if (hit) return hit;
  // 最后交给 PATH（本机装了 ffmpeg 就能用）
  return FFMPEG_NAME;
}

export function resolveTtsPaths(): TtsPaths {
  const modelDir = ttsModelDir();
  return {
    bin: ttsBinPath(),
    modelDir,
    model: modelDir ? pickGguf(modelDir, 'Qwen3-TTS', 'mmproj') : null,
    mmproj: modelDir ? pickGguf(modelDir, 'mmproj') : null,
    voicesDir: builtinVoicesDir(),
    ffmpeg: ffmpegPath(),
  };
}
