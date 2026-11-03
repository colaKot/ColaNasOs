import fs from 'node:fs';
import path from 'node:path';
import { SidecarSupervisor } from '../../../../kernel/sidecar/supervisor';
import type { KernelApi } from '../../../../kernel/types';
import { aiConfig } from './config';

/**
 * photo-ai sidecar 的单例管理。
 *
 * 为什么是「分批同步」而不是后台任务：照片分析是慢推理，但每次只处理 N 张，
 * 调用方（客户端或定时器）自己推进度，比再引入一套任务状态机更好理解。
 *
 * 可用性判定同时看三样：sidecar 脚本、ffmpeg、模型目录（faces / places365）。
 * OCR 与活动是增量能力：缺模型时对应接口返回 503，不影响人脸 / 场景 / 以图搜图。
 */
let sup: SidecarSupervisor | null = null;
let starting: Promise<SidecarSupervisor> | null = null;

export function scriptPath(): string | null {
  const env = process.env.COLANAS_PHOTO_AI_SIDECAR;
  const candidates = [
    env && env.trim() ? env.trim() : '',
    path.join(__dirname, '..', '..', '..', '..', 'sidecars', 'photo-ai', 'main.js'),
    path.join(process.cwd(), 'sidecars', 'photo-ai', 'main.js'),
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p)) ?? null;
}

export function ffmpegPath(): string | null {
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const env = process.env.COLANAS_FFMPEG;
  if (env && env.trim()) return env.trim();
  const vendor = path.join(process.cwd(), 'vendor', 'ffmpeg');
  return (
    [path.join(vendor, exe), path.join(vendor, 'bin', exe)].find((p) => fs.existsSync(p)) ?? null
  );
}

export function modelRoot(): string {
  return process.env.COLANAS_MODEL_DIR || path.join(process.cwd(), 'vendor', 'models');
}

export function aiAvailable(): boolean {
  if (process.env.COLANAS_PHOTO_AI_DISABLED === '1') return false;
  return Boolean(
    scriptPath() &&
      ffmpegPath() &&
      fs.existsSync(path.join(modelRoot(), 'faces', 'edgeface', 'model.onnx')) &&
      fs.existsSync(path.join(modelRoot(), 'places365', 'resnet50_places365.onnx')),
  );
}

export async function ensureSidecar(k: KernelApi): Promise<SidecarSupervisor> {
  if (sup && sup.state === 'ready') return sup;
  if (starting) return starting;
  const script = scriptPath();
  if (!script) throw new Error('找不到 photo-ai sidecar');
  const ffmpeg = ffmpegPath();
  if (!ffmpeg) throw new Error('找不到 ffmpeg');

  starting = (async () => {
    const s = new SidecarSupervisor({
      name: 'photo-ai',
      command: process.execPath,
      args: [script],
      env: {
        COLANAS_FFMPEG: ffmpeg,
        COLANAS_MODEL_DIR: modelRoot(),
        ...(aiConfig(k).gpuPrefer ? {} : { COLANAS_PHOTO_AI_FORCE_CPU: '1' }),
        ...(process.versions.electron && !process.env.COLANAS_SIDECAR_NODE
          ? { ELECTRON_RUN_AS_NODE: '1' }
          : {}),
      },
      requestTimeoutMs: 600_000,
      heartbeatMs: 15_000,
      maxRestarts: 1,
      startTimeoutMs: 60_000,
      stopGraceMs: 3_000,
      log: (level, message) => k.log.debug({ sidecar: 'photo-ai', level }, message),
    });
    await s.start();
    sup = s;
    return s;
  })();

  try {
    return await starting;
  } finally {
    starting = null;
  }
}
/** 改了 GPU 偏好后需要重启 sidecar，新的 execution provider 才会生效 */
export async function stopSidecar(): Promise<void> {
  const cur = sup;
  sup = null;
  if (cur) {
    try {
      await cur.stop();
    } catch {
      /* 停不掉时下次 ensureSidecar 会新建一个 */
    }
  }
}