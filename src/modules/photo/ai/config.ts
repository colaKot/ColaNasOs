import type { KernelApi } from '../../../../kernel/types';

/** AI 设置（存 config 表 `photo.ai`，内核重启后保留） */
export interface PhotoAiConfig {
  faceEnabled: boolean;
  placeEnabled: boolean;
  activityEnabled: boolean;
  ocrEnabled: boolean;
  similarEnabled: boolean;
  faceMinShowCount: number;
  gpuPrefer: boolean;
  paused: boolean;
  tuning: { matchSim: number; minVotes: number; threads: number };
}

export const AI_CONFIG_KEY = 'photo.ai';

export const AI_DEFAULTS: PhotoAiConfig = {
  faceEnabled: true,
  placeEnabled: true,
  activityEnabled: true,
  ocrEnabled: true,
  similarEnabled: false,
  faceMinShowCount: 10,
  gpuPrefer: true,
  paused: false,
  tuning: { matchSim: 0.45, minVotes: 2, threads: 3 },
};

export function aiConfig(k: KernelApi): PhotoAiConfig {
  const raw = (k.config.get<Partial<PhotoAiConfig>>(AI_CONFIG_KEY) || {}) as Partial<PhotoAiConfig>;
  return {
    ...AI_DEFAULTS,
    ...raw,
    tuning: { ...AI_DEFAULTS.tuning, ...(raw.tuning || {}) },
  };
}

export async function saveAiConfig(k: KernelApi, patch: Partial<PhotoAiConfig>): Promise<PhotoAiConfig> {
  const current = aiConfig(k);
  const next: PhotoAiConfig = {
    ...current,
    ...patch,
    tuning: {
      ...current.tuning,
      ...(patch.tuning || {}),
    },
  };
  await k.config.set(AI_CONFIG_KEY, next);
  return next;
}

export function faceTuning(k: KernelApi): { matchSim: number; minVotes: number; threads: number } {
  return aiConfig(k).tuning;
}

/** 正在运行的 AI 任务（用于任务进度卡的 running 状态） */
const running = new Map<string, number>();

export function noteAiJob(key: string): void {
  running.set(key, Date.now());
}

/** 任务结束（成功或失败）时调用，避免「识别中」一直挂到超时 */
export function clearAiJob(key: string): void {
  running.delete(key);
}

export function aiJobRunning(key: string): boolean {
  const at = running.get(key) || 0;
  // 兜底：异常退出没走到 clear 时，10 分钟后不再显示「识别中」
  return at > 0 && Date.now() - at < 10 * 60_000;
}

/**
 * 小脸门：人脸框宽度 / 原图宽度 低于此值就丢弃。
 *
 * 为什么用「宽度占比」而不是绝对像素：绝对阈值在不同分辨率下行为完全不同
 * （4000px 的合影里 40px 是小脸，800px 的图里 40px 是正常脸）。
 * 默认 0.02 = 占画面宽度 2% 以下视为背景路人。
 */
export const FACE_MIN_WIDTH_RATIO =
  Number(process.env.COLANAS_FACE_MIN_WIDTH_RATIO) > 0
    ? Number(process.env.COLANAS_FACE_MIN_WIDTH_RATIO)
    : 0.02;
