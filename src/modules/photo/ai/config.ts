import type { KernelApi } from '../../../../kernel/types';

/** AI 设置（存 config 表 `photo.ai`，内核重启后保留） */
export interface PhotoAiConfig {
  faceEnabled: boolean;
  placeEnabled: boolean;
  activityEnabled: boolean;
  ocrEnabled: boolean;
  similarEnabled: boolean;
  /** 宠物类标签是否参与语义检索（关闭时过滤「宠物特写/宠物店/狗舍」等，避免 CLIP 噪声命中） */
  petEnabled: boolean;
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
  // 默认关：词表里「猫」的最近邻是「地下墓穴 0.97」这类噪声，
  // 宠物类标签放进来会污染语义检索；用户显式打开才召回。
  petEnabled: false,
  // 默认 3：对齐既有实现（1~2 张的碎片组是路人 / 噪声，全部铺出来正是「人脸不好用」的主因）
  faceMinShowCount: 3,
  // 默认 CPU。实测 DirectML 在这几个模型上更慢（全量 1193ms vs 919ms，
  // OCR 尤其 715 vs 394——算子覆盖不全、逐层回落 CPU 再拷回来）。
  // 打开后 sidecar 收到 COLANAS_PHOTO_AI_GPU=1，才真的把 dml 排到 EP 首位。
  gpuPrefer: false,
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
/** 设 0 = 关闭姿态门（既有实现同口径） */
export const FACE_CLAIM_MAX_ABS_YAW = envNum('COLANAS_FACE_CLAIM_MAX_ABS_YAW', 0.4);

/**
 * 大组绝对上限（纯保险丝）。默认 0 = 完全不限制，正常吸纳没有上限。
 *
 * 2026-11-06 定案：不设软冻结、不设大组阈值。
 * 旧实现的两版都试过，都不对：
 *   - 硬冻结（到 1000 就停吸）→ 同一个人被劈成「1000 张主组 + 一堆碎组」；
 *   - 软冻结（过阈值只收高置信）→ 准了但开始丢人（侧脸、糊脸全被推出主组）。
 * 真正的病根不是「组太大」，而是**按票数选簇**：大组人多，近邻 top-K 被它占满，
 * 任何新脸都能凑出票（黑洞），而真人小簇永远抢不到票（丢人）。
 * 改用「簇内最佳成员相似度」选簇后，簇大小不再影响判定，大组能正常长大，
 * 也就没必要用任何冻结去压制它。保险丝只防「万一吞全库」这种病态情况。
 */
export const FACE_MAX_GROUP_FACES_HARD = envNum('COLANAS_FACE_MAX_GROUP_FACES_HARD', 0);

/**
 * 歧义门：最佳簇与次佳簇的「最佳成员相似度」差小于它，就不硬塞给任何人，
 * 先把脸挂起（cluster_id = null），等 sweep 用多张证据裁决。
 * 亲子脸 / 双胞胎最容易卡在这里，硬塞只会污染，直接丢又太浪费。
 */
export const FACE_AMBIGUITY_MARGIN = envNum('COLANAS_FACE_AMBIGUITY_MARGIN', 0.04);

/**
 * 二轮收割门槛（sweep）：挂起脸用「与成型簇成员的最佳相似度」回捞。
 *
 * 为什么要比首轮的中心一致性门（0.58）低：侧脸、不同年龄、新发型会明显偏离组中心，
 * 但总能和组里某几张脸很像。首轮用中心门挡撞脸（保准），二轮用成员门收变化大的脸（保全）。
 */
export const FACE_SWEEP_SIM = envNum('COLANAS_FACE_SWEEP_SIM', 0.52);
/**
 * 歧义门只跟「具名人物」比，不跟未命名簇比。
 *
 * 实测（2026-11-06，3963 张挂起脸）：按「全部簇」判歧义只有 407 张能归到本人，
 * 其中 653 张是被一个几百张的陌生人簇否决掉的 —— 逻辑上站不住：
 * 「这张脸更像你老婆，但也挺像一个不认识的人」不该算歧义。
 * 改成只在具名人物之间比之后，同样阈值下能多归 440 张（847）。
 */
export const FACE_SWEEP_MARGIN = envNum('COLANAS_FACE_SWEEP_MARGIN', 0.03);
/**
 * 簇内多成员支持：除了「最像的那一张」，还要求该人物至少有 3 张成员都在 0.50 以上。
 * 单张高相似容易撞脸（父子、撞衫路人），多张同时像才算实锤 —— 既准又全的那一脚。
 */
export const FACE_SWEEP_THIRD_SIM = envNum('COLANAS_FACE_SWEEP_THIRD_SIM', 0.5);
/** 二轮收割只往「已命名人物」里收；未命名簇交给增量认领自然长大 */
export const FACE_SWEEP_ONLY_NAMED = envNum('COLANAS_FACE_SWEEP_ONLY_NAMED', 1) > 0;
/** 二轮收割允许解绑的碎片簇上限（成员数 ≤ 此值且未命名的簇会被打散重认） */
export const FACE_SWEEP_FRAGMENT_MAX = envNum('COLANAS_FACE_SWEEP_FRAGMENT_MAX', 2);

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
 * 默认 0.015 = 占画面宽度 1.5% 以下视为背景路人（与既有实现同一口径）。
 */
export const FACE_MIN_WIDTH_RATIO =
  Number(process.env.COLANAS_FACE_MIN_WIDTH_RATIO) > 0
    ? Number(process.env.COLANAS_FACE_MIN_WIDTH_RATIO)
    : 0.015;
