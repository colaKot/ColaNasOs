import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

/**
 * 参考音色库。
 *
 * Qwen3-TTS-1.7B-Base 是**声音克隆**模型：音色不是一组固定的 speaker id，而是一段参考音频
 * （`--tts-speaker-file`）。官方 README 明确写了「不给参考音，效果会明显下降」，所以音色
 * 在这里就是 wav 文件本身。
 *
 * 两个来源：
 *   - 内置：`vendor/voices/*.wav`（随仓库，3 段 10 秒，约 1.4MB）
 *   - 用户：`<dataDir>/tts/voices/*.wav`（页面上传，自动转成 24kHz 单声道）
 *
 * 模型只吃 24kHz 单声道，其它格式（mp3 / 44.1kHz / 立体声）一律先用 ffmpeg 归一化，
 * 否则推理出来的音色会变调。
 */

export interface TtsVoice {
  id: string;
  gender: 'female' | 'male' | 'unknown';
  builtin: boolean;
  /** 内置音色的显示名交给前端 i18n；用户上传的直接用文件名 */
  label: string;
}

const VOICE_EXT = '.wav';

/** 上传大小上限：10 秒 24kHz 单声道约 470KB，给到 12MB 足够容下用户的高采样率原文件 */
export const MAX_VOICE_BYTES = 12 * 1024 * 1024;

function safeId(raw: string): string {
  return raw
    .replace(/[\\/:*?"<>|\s]+/g, '_')
    .replace(/\.wav$/i, '')
    .slice(0, 40);
}

function listDir(dir: string | null): string[] {
  if (!dir) return [];
  try {
    return fs
      .readdirSync(dir)
      .filter((n) => n.toLowerCase().endsWith(VOICE_EXT))
      .sort();
  } catch {
    return [];
  }
}

/** 内置音色的性别标注（文件名 → 性别），没标注的按 unknown 处理 */
const BUILTIN_GENDER: Record<string, 'female' | 'male'> = {
  default: 'female',
  warm: 'female',
  deep: 'male',
};

export function listVoices(builtinDir: string | null, userDir: string | null): TtsVoice[] {
  const out: TtsVoice[] = [];
  for (const name of listDir(builtinDir)) {
    const id = safeId(name);
    out.push({
      id,
      gender: BUILTIN_GENDER[id] ?? 'unknown',
      builtin: true,
      label: '',
    });
  }
  const builtinIds = new Set(out.map((v) => v.id));
  for (const name of listDir(userDir)) {
    const id = safeId(name);
    // 同名的用户音色不覆盖内置（内置 id 保留原义），加前缀区分
    const finalId = builtinIds.has(id) ? `u_${id}` : id;
    out.push({ id: finalId, gender: 'unknown', builtin: false, label: id });
  }
  return out;
}

export function resolveVoice(
  builtinDir: string | null,
  userDir: string | null,
  id: string,
): { voice: TtsVoice; file: string } | null {
  const want = safeId(id || '');
  if (!want) return null;
  for (const v of listVoices(builtinDir, userDir)) {
    if (v.id !== want) continue;
    const file = v.builtin
      ? path.join(builtinDir as string, `${v.id}${VOICE_EXT}`)
      : path.join(userDir as string, `${v.id.replace(/^u_/, '')}${VOICE_EXT}`);
    if (fs.existsSync(file)) return { voice: v, file };
  }
  return null;
}

export function defaultVoiceId(): string {
  return 'default';
}

function runFfmpeg(ffmpeg: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, args, { windowsHide: true });
    let err = '';
    p.stderr?.on('data', (d: Buffer) => {
      err += d.toString();
    });
    p.on('error', reject);
    p.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg 失败（${code}）：${err.slice(-400)}`));
    });
  });
}

/**
 * 保存用户上传的参考音色：源文件可以是 wav / mp3 / m4a，统一转成 24kHz 单声道
 * （模型输出就是这个格式，参考音对齐能减少音色漂移）。
 */
export async function saveUserVoice(
  ffmpeg: string,
  userDir: string,
  rawName: string,
  inputPath: string,
): Promise<TtsVoice> {
  const id = safeId(rawName || `voice_${Date.now()}`);
  if (!id) throw new Error('音色名不合法');
  fs.mkdirSync(userDir, { recursive: true });
  const dst = path.join(userDir, `${id}${VOICE_EXT}`);
  await runFfmpeg(ffmpeg, [
    '-y',
    '-loglevel',
    'error',
    '-i',
    inputPath,
    '-t',
    '30', // 参考音越长 prompt 处理越慢，30 秒封顶
    '-ar',
    '24000',
    '-ac',
    '1',
    '-c:a',
    'pcm_s16le',
    dst,
  ]);
  const size = fs.statSync(dst).size;
  if (size < 8 * 1024) {
    fs.rmSync(dst, { force: true });
    throw new Error('参考音太短（至少 2 秒），模型学不到音色');
  }
  return { id, gender: 'unknown', builtin: false, label: id };
}

export function removeUserVoice(userDir: string, id: string): boolean {
  const name = `${safeId(id).replace(/^u_/, '')}${VOICE_EXT}`;
  const file = path.join(userDir, name);
  if (!fs.existsSync(file)) return false;
  fs.rmSync(file, { force: true });
  return true;
}
