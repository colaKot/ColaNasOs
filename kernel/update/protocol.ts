/**
 * 更新清单协议（`update.json`）。
 *
 * 一份清单覆盖四类更新对象：服务端内核（增量）、PC 客户端、安卓客户端、壳版本下限。
 * 清单本身由 `update.json.sig` 逐字节签名（ed25519），公钥编译进程序，见 `pubkey.ts`。
 *
 * 版本号有两套，别混：
 *   - `semver`  X.Y.Z，给人看、给客户端比较；
 *   - `version` 整数 major*10000+minor*100+patch（1.3.13 → 10313），给版本目录名
 *               `D10313` 用；`versionId()` 只补零到 3 位，5 位也照样能用。
 */

export const UPDATE_SCHEMA = 1;

/** 传输层的资产引用：原文件 or brotli 压缩形态 */
export interface AssetRef {
  size: number;
  sha256: string;
  /** 下载地址，顺序 = 优先级 */
  urls: string[];
  /** 有 br 就优先下压缩形态（体积小 4~5 倍），下完解压再校验原文件 sha256 */
  br?: { size?: number; sha256?: string };
}

/** 增量描述：从 `from[]` 里的任一基线升到本版本需要哪些文件 */
export interface DeltaRef {
  /** **白名单**，不是「相邻版本」：不在列表里的基线走全量 */
  from: string[];
  files: DeltaFile[];
  bundles: DeltaBundle[];
  /** 相对路径前缀，与 files[].path / bundles[].name 拼接 */
  urlBase: string[];
  /** 版本目录级清单（整体签名，防「悄悄少一个文件」） */
  manifest: AssetRef;
}

export interface DeltaFile {
  path: string;
  size: number;
  sha256: string;
  br?: { size?: number; sha256?: string };
  /**
   * 显式下载地址。发布平台（GitCode / GitHub / Gitee）的 Release 资产是**扁平**的，
   * 带目录的路径没法当资产名，所以每个文件自带 URL，不再靠 `urlBase + path` 拼。
   */
  urls?: string[];
}

/**
 * 小文件包：`dist/` 里 543 个文件有 542 个 < 256 KB，
 * 逐个下载在弱网必挂，所以打成一个小包（内部已用 brotli 压过，无需再套 br）。
 */
export interface DeltaBundle {
  name: string;
  size: number;
  sha256: string;
  /** 包内文件相对路径（发布侧生成，客户端可用它做进度展示与校验提示） */
  members: string[];
  urls?: string[];
}

export interface ServerComponent {
  semver: string;
  version: number;
  /** 需要重装服务端（Electron ABI 变了）时的壳版本下限 */
  minShell?: string;
  full?: AssetRef;
  delta?: DeltaRef;
  /** `critical` 只做界面提示（强制更新见方案 §13.4，默认不启用） */
  critical?: boolean;
}

/**
 * 客户端资产种类。
 *
 * 安卓三份包是**三个不同的 applicationId / 用途**，绝不能互相代替：
 *   - `apk`        主客户端手机包（com.colanas.os）
 *   - `apk_tv`     主客户端 TV 包（同一个 applicationId，编译入口不同）
 *   - `apk_photo`  相册独立端包（com.colanas.photo，可与主客户端并存）
 */
export type ClientAssetKind = 'setup' | 'portable' | 'apk' | 'apk_tv' | 'apk_photo';

export interface ClientComponent {
  semver: string;
  version: number;
  /** 安卓比较用（Flutter 的 `version: X.Y.Z+B` 里 B） */
  versionCode?: number;
  /** 客户端要求的最低服务端版本 */
  minServer?: string;
  assets: Partial<Record<ClientAssetKind, AssetRef>>;
}

export interface UpdateManifest {
  schema: number;
  channel: string;
  releasedAt: string;
  keyId: string;
  /** 发版说明，按语言给 */
  notes?: Record<string, string>;
  minShell?: string;
  components: {
    server?: ServerComponent;
    client_pc?: ClientComponent;
    client_android?: ClientComponent;
  };
}

export const COMPONENT_IDS = ['server', 'client_pc', 'client_android'] as const;
export type ComponentId = (typeof COMPONENT_IDS)[number];

/** semver → 整数（与 `tool/version.js` 的 versionCode 口径一致：major*10000+minor*100+patch） */
export function semverToVersion(semver: string): number | null {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(semver || '').trim());
  if (!m) return null;
  return Number(m[1]) * 10_000 + Number(m[2]) * 100 + Number(m[3]);
}

export function versionToSemver(version: number): string {
  const major = Math.floor(version / 10_000);
  const minor = Math.floor((version % 10_000) / 100);
  const patch = version % 100;
  return `${major}.${minor}.${patch}`;
}

/** 严格三段比较；任一侧不合法按 0 处理（宁可「没更新」也不误升） */
export function compareSemver(a: string, b: string): number {
  const pa = (a || '').split('.').map((n) => Number(n) || 0);
  const pb = (b || '').split('.').map((n) => Number(n) || 0);
  for (let i = 0; i < 3; i += 1) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

/** 清单结构自检：解析成功不等于能用，这里把明显不对的清单挡在门外 */
export function validateManifest(raw: unknown): { ok: boolean; errors: string[]; manifest?: UpdateManifest } {
  const errors: string[] = [];
  const m = raw as UpdateManifest | null;
  if (!m || typeof m !== 'object') return { ok: false, errors: ['清单不是对象'] };
  if (m.schema !== UPDATE_SCHEMA) errors.push(`不支持的 schema: ${String(m.schema)}`);
  if (!m.releasedAt) errors.push('缺 releasedAt');
  if (!m.keyId) errors.push('缺 keyId');
  const comps = m.components ?? {};
  if (!comps || typeof comps !== 'object') errors.push('缺 components');
  for (const [id, c] of Object.entries(comps)) {
    if (!c || typeof c !== 'object') {
      errors.push(`components.${id} 不是对象`);
      continue;
    }
    const anyC = c as { semver?: string; version?: number };
    if (!anyC.semver && typeof anyC.version !== 'number') errors.push(`components.${id} 缺版本`);
    if (anyC.semver && semverToVersion(anyC.semver) === null) {
      errors.push(`components.${id}.semver 不合法: ${anyC.semver}`);
    }
  }
  return { ok: errors.length === 0, errors, manifest: m };
}
