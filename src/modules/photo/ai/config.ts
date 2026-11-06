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

/** photo_items.ai_done_mask 的位：这张照片「做过」哪些识别（不是「有没有检出结果」） */
export const AI_DONE_BASE = 1; // 人脸 / 场景 / embedding（一次 analyze 一起产出）
export const AI_DONE_OCR = 2;
export const AI_DONE_ACTIVITY = 4;

/**
 * 当前开关下，一张照片需要集齐哪些位才算识别完成。
 * 基础位永远要（embedding 是以图搜图的原料）；OCR / 活动只在开关打开时算。
 * 开关从关变开时 needMask 会变大，以前「已有 embedding 就跳过」的照片会自动被补做。
 */
export function aiNeededMask(cfg: PhotoAiConfig): number {
  return (
    AI_DONE_BASE |
    (cfg.ocrEnabled ? AI_DONE_OCR : 0) |
    (cfg.activityEnabled ? AI_DONE_ACTIVITY : 0)
  );
}

export const AI_DEFAULTS: PhotoAiConfig = {
  faceEnabled: true,
  placeEnabled: true,
  activityEnabled: true,
  ocrEnabled: true,
  similarEnabled: false,
  // 默认 3：对齐参考实现（1~2 张的碎片组是路人 / 噪声，全部铺出来正是「人脸不好用」的主因）
  faceMinShowCount: 3,
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

/**
 * 人脸「认领护栏」（低质量脸与极端侧脸不参与认领投票）。
 *
 * 只有模型、阈值、KNN 参数照抄是不够的：低质量脸 / 极端侧脸互相之间反而更像，
 * 不加这几道门就会滚成几百张的假人物组，同时干净的人被拆成一堆单张碎片。
 * - MIN_QUALITY：低于此分的人脸不入库（sidecar 已按 0.55 检测门，这里是二次确认）
 * - CLAIM_MIN_QUALITY：低于此分只独立成组，不参与投票认领，也不给别人投票
 * - CLAIM_MAX_ABS_YAW：|yaw| 超阈值的极端侧脸同样只独立成组（yaw 缺失时按参考放行）
 */
function envNum(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}
export const FACE_MIN_QUALITY = envNum('COLANAS_FACE_MIN_QUALITY', 55);
export const FACE_CLAIM_MIN_QUALITY = envNum('COLANAS_FACE_CLAIM_MIN_QUALITY', 70);
/** 设 0 = 关闭姿态门（参考实现同口径） */
export const FACE_CLAIM_MAX_ABS_YAW = envNum('COLANAS_FACE_CLAIM_MAX_ABS_YAW', 0.4);

/**
 * 单个簇最多认领多少张脸。超过就冻结（不再吸新脸），对应参考实现的「组体检冻结」简化版。
 * 一个组一旦滚到上千张，它的成员覆盖了各种长相，任何新脸都能在里面找到「相似」的邻居，
 * 于是变成黑洞；真有上千张照片的同一个人被拆成两个干净组，也远好过一个混进全库的大杂烩。
 */
export const FACE_MAX_GROUP_FACES = envNum('COLANAS_FACE_MAX_GROUP_FACES', 1000);

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
 * 默认 0.015 = 占画面宽度 1.5% 以下视为背景路人（与参考实现同一口径）。
 */
export const FACE_MIN_WIDTH_RATIO =
  Number(process.env.COLANAS_FACE_MIN_WIDTH_RATIO) > 0
    ? Number(process.env.COLANAS_FACE_MIN_WIDTH_RATIO)
    : 0.015;
