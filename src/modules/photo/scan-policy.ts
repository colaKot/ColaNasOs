import type { KernelApi } from '../../../kernel/types';

/**
 * 相册扫描策略（三个开关）：来源页截图里的「自动监视 / 周期校验 / 跳过隐藏文件」。
 *
 * 存 `config`（非按用户：扫描是库级行为），由 `bindLibraryWatch` 的 `policy`
 * 回调实时读取，改完调用 `libWatch.refresh()` 立即生效。
 */
export interface PhotoScanPolicy {
  /** 自动监视新文件（本地 fs.watch / 远程轮询） */
  autoWatch: boolean;
  /** 周期全量校验间隔（小时；0 = 关闭） */
  verifyHours: number;
  /** 跳过隐藏文件与系统目录（. 开头 / @eaDir / #recycle 等） */
  skipHidden: boolean;
}

export const PHOTO_SCAN_POLICY_KEY = 'photo.scanPolicy';

export const DEFAULT_PHOTO_SCAN_POLICY: PhotoScanPolicy = {
  autoWatch: true,
  verifyHours: 6,
  skipHidden: true,
};

export function readPhotoScanPolicy(k: KernelApi): PhotoScanPolicy {
  const raw = k.config.get<Partial<PhotoScanPolicy>>(PHOTO_SCAN_POLICY_KEY) ?? {};
  const autoWatch =
    typeof raw.autoWatch === 'boolean' ? raw.autoWatch : DEFAULT_PHOTO_SCAN_POLICY.autoWatch;
  const hours = Number(raw.verifyHours);
  const verifyHours =
    Number.isFinite(hours) && hours >= 0 && hours <= 168
      ? Math.trunc(hours)
      : DEFAULT_PHOTO_SCAN_POLICY.verifyHours;
  const skipHidden =
    typeof raw.skipHidden === 'boolean' ? raw.skipHidden : DEFAULT_PHOTO_SCAN_POLICY.skipHidden;
  return { autoWatch, verifyHours, skipHidden };
}

/** 给 `bindLibraryWatch` 的运行时策略：`watch` + 校验间隔（毫秒，0 关闭） */
export function watchPolicyOf(k: KernelApi): { watch: boolean; verifyIntervalMs: number } {
  const policy = readPhotoScanPolicy(k);
  return {
    watch: policy.autoWatch,
    verifyIntervalMs: policy.verifyHours > 0 ? policy.verifyHours * 3_600_000 : 0,
  };
}

const HIDDEN_NAMES = new Set(['@eaDir', '#recycle', '#snapshot', 'Thumbs.db', 'desktop.ini']);

/** 隐藏 / 系统文件：`.` 开头、常见 NAS 目录、临时文件后缀 */
export function isHiddenName(name: string): boolean {
  if (!name) return true;
  if (name.startsWith('.')) return true;
  if (HIDDEN_NAMES.has(name)) return true;
  const lower = name.toLowerCase();
  return lower.endsWith('.tmp') || lower.endsWith('.part') || lower.endsWith('.crdownload');
}

export function shouldSkipName(k: KernelApi, name: string): boolean {
  return readPhotoScanPolicy(k).skipHidden && isHiddenName(name);
}