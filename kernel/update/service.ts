import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { Updater, versionId, parseVersionId } from '../updater';
import { DownloadError, downloadAsset, fetchText, type ProgressEvent } from './downloader';
import { assembleVersion, cleanStaging, verifyTree, AssembleError } from './assemble';
import { unpackBundle } from './bundle';
import { SourceMemo } from './sources';
import { writeBoot } from './boot';
import { knownKeyIds } from './pubkey';
import {
  UpdateVerifyError,
  verifyBytes,
  verifySignedFile,
  verifyVersionManifest,
  sha256File,
  sha256,
} from './verify';
import {
  compareSemver,
  semverToVersion,
  validateManifest,
  versionToSemver,
  type AssetRef,
  type ClientAssetKind,
  type ClientComponent,
  type ComponentId,
  type DeltaRef,
  type UpdateManifest,
} from './protocol';

/**
 * 服务端增量更新编排：检查 → 下载 → 校验 → 组装 → 切指针。
 *
 * 内核发起这一切（有网、有磁盘、知道任务队列空不空），**壳只负责最后重启** ——
 * 内核没法替换自己正在跑的文件，切完指针得由外壳重新 fork。
 */

const MB = 1024 * 1024;

export interface UpdateSettings {
  /** 清单地址，顺序即优先级；默认 GitCode → GitHub → Gitee */
  manifestUrls: string[];
  channel: string;
  /** 服务端「主动轮询」开关，默认关（被动检查见 §13.2） */
  autoCheck: boolean;
}

/**
 * 清单地址：**仓库里的 `release/update.json`**（raw 直链），不是 Release 资产。
 *
 * 为什么不用 `releases/latest/download/update.json`：2026-11-21 实测
 * `gitcode.com/.../releases/latest/download/<文件>` 返回的是 **text/html 的页面**
 * （3575 字节），拿不到文件；而 `raw.gitcode.com/<owner>/<repo>/raw/main/<path>`
 * 是真正的 text/plain。raw 直链还天然稳定：地址不随 tag 变，每次发版只提交一次清单。
 *
 * 顺序即优先级：GitCode（国内快，实测 8.6 MB/s）→ GitHub（境外兜底，
 * 国内可能需要设置代理）。
 */
/** GitCode 公开仓库 contents API 根 */
const GITCODE_CONTENTS = 'https://api.gitcode.com/api/v5/repos/cocacola23/ColaNasOs/contents';
const GITCODE_REF = 'main';

export const DEFAULT_MANIFEST_URLS = [
  // GitCode 的 raw 直链**不可用**：请求会被网页预览逻辑接管，返回 403
  // 「暂不支持预览」，而且不同边缘节点行为不一致（偶尔能拿到真文件，
  // 过一会儿又 403），当更新源等于随机失效。
  //
  // 公开仓库的 contents API 反而稳定且**不需要令牌**，返回
  // `{encoding:'base64', content:'…'}`。写法是 `<API 根>@@<仓库内路径>?ref=<分支>`：
  // `@@` 左边是 API 根，右边是要取的文件，签名文件按 `<路径>.sig.json` 派生。
  `${GITCODE_CONTENTS}@@release/update.json?ref=${GITCODE_REF}`,
  'https://raw.githubusercontent.com/colaKot/ColaNasOs/main/release/update.json',
];

/** 老版本内置过的 raw 地址：读到就换掉，否则这些机器永远停在坏源上 */
const LEGACY_MANIFEST_URLS = new Set([
  'https://raw.gitcode.com/cocacola23/ColaNasOs/raw/main/release/update.json',
  'https://raw.gitcode.com/cocacola23/ColaNasOs/raw/main/release/update.json?inline=false',
]);

/**
 * 把设置里存的清单源迁移到当前可用地址。
 *
 * 老版本内置过 GitCode 的 raw 直链（现在稳定 403）。用户的 settings.json 一旦
 * 落过那个地址就会一直用它 —— 表现是「检查更新永远失败」，而程序本身升级了
 * 也不管用。这里按地址精确匹配替换，不认识的地址原样保留（用户自建源）。
 */
function migrateManifestUrls(urls: string[]): string[] {
  const out = urls.map((u) =>
    LEGACY_MANIFEST_URLS.has(u.trim()) ? DEFAULT_MANIFEST_URLS[0] : u,
  );
  return Array.from(new Set(out));
}

/**
 * 按通道换清单地址：正式版读 `update.json`，预发布读 `update-pre.json`。
 *
 * 两份清单都是完整格式（各自带签名），同一份代码按通道选一个源 ——
 * 这样「预发布」不会污染正式版用户的检查结果，也能各自独立回滚。
 * 不认识的地址（用户自建源）原样返回：它没有预发布清单这回事。
 */
export function manifestUrlsForChannel(urls: string[], channel: string): string[] {
  if (channel !== 'pre') return urls;
  return urls.map((u) => u.replace(/update\.json(?=$|[?&#])/, 'update-pre.json'));
}

/**
 * 清单签名文件的地址，从清单地址派生。
 *
 * `.sig.json`（内容 `{"keyId":…,"sig":…}`）是主路径：GitCode 上 `.sig` 这类
 * 未知扩展名取不到（403）。这里只在第一个 `.json` 后面插 `.sig.json`，
 * 这样 `update.json?ref=main` 与普通直链两种写法都能正确派生。
 */
function sigSpecOf(spec: string): string {
  const i = spec.indexOf('.json');
  if (i === -1) return `${spec}.sig.json`;
  return `${spec.slice(0, i + 5)}.sig.json${spec.slice(i + 5)}`;
}

/** 老格式签名地址（纯 base64 文本）：`update.json.sig.json` → `update.json.sig` */
function legacySigSpecOf(sigSpec: string): string {
  return sigSpec.replace(/\.sig\.json(?=\?|$)/, '.sig');
}

/** 签名文本统一成 base64：新格式是 JSON，老格式是裸 base64 */
function parseSignature(raw: string): string {
  const t = raw.trim();
  if (!t) return '';
  if (t.startsWith('{')) {
    try {
      return String((JSON.parse(t) as { sig?: string }).sig || '').trim();
    } catch {
      return '';
    }
  }
  return t;
}

/**
 * 取一个仓库文本文件。
 *
 * - 普通 URL：直接 GET。
 * - `<apiRoot>@@<path>?ref=<ref>`：GitCode 公开仓库 contents API，解 base64。
 */
async function fetchRepoText(spec: string, signal?: AbortSignal): Promise<string> {
  const at = spec.indexOf('@@');
  // `@@` 两边都要归一化斜杠：少一个就是 `contentsrelease/update.json`，
  // 平台照样返回 404，而错误信息里只看到「全部更新源失败」。
  const url =
    at === -1
      ? spec
      : `${spec.slice(0, at).replace(/\/+$/, '')}/${spec.slice(at + 2).replace(/^\/+/, '')}`;
  const res = await fetchText([url], { maxBytes: 1024 * 1024, signal });
  if (at === -1) return res.text;
  let body: { encoding?: string; content?: string };
  try {
    body = JSON.parse(res.text) as { encoding?: string; content?: string };
  } catch {
    throw new DownloadError('E_MANIFEST', 'contents API 返回的不是 JSON');
  }
  if (String(body.encoding) !== 'base64' || !body.content) {
    throw new DownloadError('E_MANIFEST', 'contents API 返回格式不符（缺 content）');
  }
  return Buffer.from(body.content, 'base64').toString('utf8');
}

/**
 * 取清单签名。
 *
 * **只在「取不到」时回落到老格式 `.sig`**；取到了但验签失败必须当场报错，
 * 不能换个地址再试 —— 否则等于给攻击者留了「塞个坏签名让我回退到弱校验」的口子。
 */
async function fetchManifestSignature(spec: string, signal?: AbortSignal): Promise<string> {
  const sigSpec = sigSpecOf(spec);
  const errors: string[] = [];
  try {
    const sig = parseSignature(await fetchRepoText(sigSpec, signal));
    if (sig) return sig;
    errors.push('.sig.json 里没有 sig 字段');
  } catch (err) {
    errors.push(`.sig.json: ${(err as Error).message}`);
  }
  try {
    const sig = parseSignature(await fetchRepoText(legacySigSpecOf(sigSpec), signal));
    if (sig) return sig;
    errors.push('.sig 内容为空');
  } catch (err) {
    errors.push(`.sig: ${(err as Error).message}`);
  }
  throw new DownloadError('E_MANIFEST', `取清单签名失败（${errors.join('；')}）`);
}

export type JobPhase =
  | 'idle'
  | 'preparing'
  | 'downloading'
  | 'verifying'
  | 'assembling'
  | 'activating'
  /**
   * 全量包下载完、正在等系统授权并跑安装程序。
   *
   * 单独一档是给界面看的：这一步会弹 UAC，而安装程序一旦拿到授权就会先把本进程
   * 杀掉（installer.nsh 的 STOP_RUNNING_APP），界面来不及显示任何别的状态。
   */
  | 'installing'
  | 'ready'
  | 'failed'
  | 'cancelled';

export interface JobStatus {
  phase: JobPhase;
  /** 0~100（未知总量时按「已下字节」显示，不给假进度） */
  percent: number;
  loaded: number;
  total: number;
  speed: number;
  /** 当前资产名，给界面显示「正在下载 web/main.dart.js」 */
  asset: string;
  source: string;
  message: string;
  error: string;
  /** 失败时能做什么：retry / full / manual */
  hint: string;
  startedAt: number;
  updatedAt: number;
  targetId: string;
  mode: 'delta' | 'full' | '';
  /**
   * 全量下载完成后是否已把安装程序拉起来（界面据此决定说「正在自动安装」
   * 还是「包在这，手动运行」）。增量态恒为 false —— 它靠切指针 + 重启生效。
   */
  autoRun: boolean;
}

export interface CurrentVersion {
  id: string | null;
  semver: string;
  version: number | null;
  dir: string | null;
  /** 版本目录是否可用（false = 还在「未拆壳」状态，只能全量更新） */
  managed: boolean;
}

export interface ServerCheck {
  component: 'server';
  hasUpdate: boolean;
  current: CurrentVersion;
  latest: {
    semver: string;
    version: number;
    notes: Record<string, string>;
    releasedAt: string;
    critical: boolean;
  } | null;
  /** delta = 只下变化文件；full = 下整包；none = 只能手动 */
  mode: 'delta' | 'full' | 'none';
  /** 增量包预计字节数（压缩后），给界面显示「约 3 MB」 */
  deltaBytes: number;
  /** 这次能不能走增量（列表外的情况：基线没有当前版本 = 只能全量） */
  deltaAvailable: boolean;
  /** 全量安装包字节数（0 = 清单里没给全量包） */
  fullBytes: number;
  /** 需要重装服务端（壳版本不足）时的提示 */
  needsReshell: boolean;
  /** 清单要求的最低壳版本（空串 = 没要求） */
  minShell: string;
}

/** 安装方式：auto = 能增量就增量；delta / full = 界面按钮指定的那一种 */
export type InstallMode = 'auto' | 'delta' | 'full';

/**
 * 安卓客户端的构建形态。
 *
 * - `phone`：主客户端手机包（com.colanas.os）
 * - `tv`：主客户端 TV 包（同一个 applicationId，编译入口不同）
 * - `photo`：相册独立端（com.colanas.photo，与主客户端并存）
 *
 * 三份包的 applicationId / 用途都不同，服务器只能靠客户端自报的 `build`
 * 分辨，所以检查更新时一定要带上它 —— 否则相册端会被推成主客户端包，
 * 电视上会被推手机包。
 */
export type AndroidBuildKind = 'phone' | 'tv' | 'photo';

export interface ClientCheck {
  component: 'client_pc' | 'client_android';
  hasUpdate: boolean;
  latest: { semver: string; version: number; versionCode: number; notes: Record<string, string> } | null;
  assets: { kind: ClientAssetKind; size: number; sha256: string; br?: { size?: number; sha256?: string }; urls: string[] }[];
}

export interface UpdateServiceOptions {
  dataDir: string;
  /** 服务端自身的 semver（外壳通过环境变量传进来） */
  currentSemver?: string;
  /** 外壳（Electron）版本，用于 minShell 判定 */
  shellVersion?: string;
  log?: (msg: string, extra?: Record<string, unknown>) => void;
  /** 切指针前给内核一次做 DB 快照的机会（SQLite VACUUM INTO） */
  beforeActivate?: (targetId: string) => Promise<void>;
}

function readJson<T>(file: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')) as T;
  } catch {
    return null;
  }
}

function writeJsonAtomic(file: string, data: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

function dirSize(dir: string): number {
  let total = 0;
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) total += dirSize(abs);
    else {
      try {
        total += fs.statSync(abs).size;
      } catch {
        /* 占用中忽略 */
      }
    }
  }
  return total;
}

export class UpdateService {
  readonly dataDir: string;
  readonly versionsDir: string;
  readonly updateDir: string;
  readonly cacheDir: string;
  readonly workDir: string;
  readonly assetDir: string;
  /**
   * 本地调试包目录：把任意 `.apk` 丢进来，客户端检查更新时就会把它当成
   * 「最新版」并通过局域网分发，不依赖 GitCode / GitHub 清单源。
   *
   * 默认 `<dataDir>/update/local-apk`，可用 `COLANAS_LOCAL_APK_DIR` 覆盖。
   */
  readonly localApkDir: string;
  /**
   * TV 版调试包目录。
   *
   * TV 包与手机包是**同一个 applicationId**（同一个 App，只是编译期 `COLANAS_TV=1`），
   * 没法靠包名区分，只能分目录投放。检查更新时两个一起下发，客户端按
   * `kTvBuild` 选 `apk` / `apk_tv`。
   */
  readonly localTvApkDir: string;
  /**
   * 相册独立端调试包目录。
   *
   * 相册端是**另一个 applicationId**（com.colanas.photo），可以和主客户端并存，
   * 但也意味着不能和手机包共用同一个投放目录（否则相册端会拿到主客户端包）。
   *
   * 默认 `<dataDir>/update/local-apk-photo`，可用 `COLANAS_LOCAL_PHOTO_APK_DIR` 覆盖。
   */
  readonly localPhotoApkDir: string;
  /** 本地 APK 的 sha256 缓存（按 文件名 + size + mtime 失效） */
  private readonly localApkMemo = new Map<string, { key: string; sha256: string }>();
  private readonly memo: SourceMemo;
  private job: JobStatus = UpdateService.idleJob();
  /**
   * 上次拉清单失败的时间与原因。
   *
   * 离线 NAS 上每个源都要等满 8s 首字节超时（3 个源 = 24s），而「登录时检查」
   * 和设置页「检查更新」会反复触发。失败后 5 分钟内直接返回同一个错误，
   * 不再空等 —— 用户点「检查更新」时也能立刻看到「更新源不可达」。
   */
  private lastFailureAt = 0;
  private lastFailure = '';
  private static readonly FAILURE_TTL_MS = 5 * 60 * 1000;
  private busy = false;
  private abort: AbortController | null = null;
  private lastCheckedAt = 0;

  constructor(private readonly opts: UpdateServiceOptions) {
    this.dataDir = opts.dataDir;
    this.versionsDir = path.join(opts.dataDir, 'versions');
    this.updateDir = path.join(opts.dataDir, 'update');
    this.cacheDir = path.join(this.updateDir, 'cache');
    this.workDir = path.join(this.updateDir, 'work');
    this.assetDir = path.join(this.updateDir, 'assets');
    this.localApkDir = process.env.COLANAS_LOCAL_APK_DIR
      ? path.resolve(process.env.COLANAS_LOCAL_APK_DIR)
      : path.join(this.updateDir, 'local-apk');
    this.localTvApkDir = process.env.COLANAS_LOCAL_TV_APK_DIR
      ? path.resolve(process.env.COLANAS_LOCAL_TV_APK_DIR)
      : path.join(this.updateDir, 'local-apk-tv');
    this.localPhotoApkDir = process.env.COLANAS_LOCAL_PHOTO_APK_DIR
      ? path.resolve(process.env.COLANAS_LOCAL_PHOTO_APK_DIR)
      : path.join(this.updateDir, 'local-apk-photo');
    this.memo = new SourceMemo(path.join(this.updateDir, 'source-memo.json'));
  }

  private static idleJob(): JobStatus {
    return {
      phase: 'idle',
      autoRun: false,
      percent: 0,
      loaded: 0,
      total: 0,
      speed: 0,
      asset: '',
      source: '',
      message: '',
      error: '',
      hint: '',
      startedAt: 0,
      updatedAt: 0,
      targetId: '',
      mode: '',
    };
  }

  // ---------------------------------------------------------------- 设置 / 现状

  settings(): UpdateSettings {
    const saved = readJson<Partial<UpdateSettings>>(path.join(this.updateDir, 'settings.json')) ?? {};
    const envUrls = (process.env.COLANAS_UPDATE_MANIFEST || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    return {
      manifestUrls:
        envUrls.length > 0
          ? envUrls
          : Array.isArray(saved.manifestUrls) && saved.manifestUrls.length > 0
            ? migrateManifestUrls(saved.manifestUrls.map(String))
            : DEFAULT_MANIFEST_URLS,
      channel: String(saved.channel || 'stable'),
      autoCheck: saved.autoCheck === true,
    };
  }

  saveSettings(patch: Partial<UpdateSettings>): UpdateSettings {
    const prev = this.settings();
    const next: UpdateSettings = { ...prev, ...patch };
    next.manifestUrls = (next.manifestUrls || []).map((s) => String(s).trim()).filter(Boolean);
    // 换通道 / 换源就清掉失败缓存：否则刚在 stable 上失败一次，
    // 切到 pre 后 5 分钟内都直接抛同一个错误，看起来像「勾了没反应」。
    if (next.channel !== prev.channel || next.manifestUrls.join() !== prev.manifestUrls.join()) {
      this.lastFailureAt = 0;
      this.lastFailure = '';
    }
    writeJsonAtomic(path.join(this.updateDir, 'settings.json'), next);
    return next;
  }

  /** 当前版本：指针 + 版本目录里的 version.json（`managed` 表示已拆壳） */
  current(): CurrentVersion {
    const versions = this.versionsDir;
    const id: string | null = (() => {
      try {
        const ptr = JSON.parse(fs.readFileSync(path.join(versions, 'current.json'), 'utf8')) as { id?: string };
        return ptr?.id ? String(ptr.id) : null;
      } catch {
        return null;
      }
    })();
    const dir = id ? path.join(versions, id) : null;
    const meta = dir ? readJson<{ semver?: string; version?: number }>(path.join(dir, 'version.json')) : null;
    const version = meta?.version ?? (id ? parseVersionId(id) : null);
    const semver =
      meta?.semver ||
      this.opts.currentSemver ||
      (version ? versionToSemver(version) : '') ||
      '';
    return {
      id,
      semver,
      version,
      dir: dir && fs.existsSync(path.join(dir, 'electron', 'kernel-host.js')) ? dir : null,
      managed: Boolean(dir && fs.existsSync(path.join(dir, 'version.json'))),
    };
  }

  jobStatus(): JobStatus {
    return { ...this.job };
  }

  isBusy(): boolean {
    return this.busy;
  }

  // ---------------------------------------------------------------- 清单

  private manifestCachePath(channel = 'stable'): { json: string; sig: string } {
    const name = channel === 'pre' ? 'update-pre' : 'update';
    return {
      json: path.join(this.cacheDir, `${name}.json`),
      sig: path.join(this.cacheDir, `${name}.json.sig`),
    };
  }

  /**
   * 拉清单并验签。`force=false` 且缓存 6 小时内有效时直接用缓存。
   *
   * 缓存也走验签 —— 磁盘上的文件同样可能是被改过的，一致性比省一次 IO 重要。
   *
   * [channel] 缺省用设置里的通道；`pre` 拉不到（还没发过预发布版）时
   * 自动回落 `stable`，勾了预发布却看不到更新比报错友好。
   */
  async loadManifest(
    opts: { force?: boolean; maxAgeMs?: number; channel?: string } = {},
  ): Promise<UpdateManifest> {
    const channel = opts.channel || this.settings().channel;
    try {
      return await this.loadManifestOnce({ ...opts, channel });
    } catch (err) {
      if (channel !== 'pre') throw err;
      this.lastFailureAt = 0;
      this.lastFailure = '';
      return this.loadManifestOnce({ ...opts, channel: 'stable', force: true });
    }
  }

  private async loadManifestOnce(
    opts: { force?: boolean; maxAgeMs?: number; channel?: string } = {},
  ): Promise<UpdateManifest> {
    const channel = opts.channel || 'stable';
    const { json, sig } = this.manifestCachePath(channel);
    // 刚失败过：直接抛同一个错误（`force` 才算「我再试一次」）
    if (
      !opts.force &&
      this.lastFailureAt > 0 &&
      Date.now() - this.lastFailureAt < UpdateService.FAILURE_TTL_MS
    ) {
      throw new DownloadError('E_MANIFEST', this.lastFailure || '拉取更新清单失败');
    }
    const maxAge = opts.maxAgeMs ?? 6 * 60 * 60 * 1000;
    const fresh =
      !opts.force &&
      fs.existsSync(json) &&
      fs.existsSync(sig) &&
      Date.now() - fs.statSync(json).mtimeMs < maxAge;
    if (fresh) {
      try {
        return this.parseManifest({
          data: fs.readFileSync(json),
          sig: fs.readFileSync(sig, 'utf8'),
        });
      } catch {
        /* 缓存坏了：走网络 */
      }
    }

    const urls = manifestUrlsForChannel(this.settings().manifestUrls, channel);
    // 签名与清单必须来自同一个源，所以先按源成对取（而不是两个独立的 fetchText）
    const errors: string[] = [];
    for (const base of urls) {
      try {
        const raw = Buffer.from(await fetchRepoText(base), 'utf8');
        const sigText = await fetchManifestSignature(base);
        const manifest = this.parseManifest({ data: raw, sig: sigText });
        fs.mkdirSync(this.cacheDir, { recursive: true });
        fs.writeFileSync(json, raw);
        fs.writeFileSync(sig, sigText);
        this.lastCheckedAt = Date.now();
        this.lastFailureAt = 0;
        this.lastFailure = '';
        return manifest;
      } catch (err) {
        errors.push(`${base}: ${(err as Error).message}`);
        // 源不给 .sig（老源还没升级）→ 明确报出来，便于判断是缺文件还是验签失败
        if (err instanceof UpdateVerifyError) break;
      }
    }
    this.lastFailureAt = Date.now();
    this.lastFailure = `拉取更新清单失败（${errors.slice(0, 1).join('') || '无可用源'}）`;
    throw new DownloadError('E_MANIFEST', this.lastFailure, { errors });
  }

  private parseManifest(input: { data: Buffer; sig: string }): UpdateManifest {
    // keyId 在清单里，必须先解析再看用哪把公钥。
    // 解析失败或 keyId 缺失 → 视为不可信，不做「先信任再校验」。
    const keyId = (() => {
      try {
        return String((JSON.parse(input.data.toString('utf8')) as { keyId?: string }).keyId || '');
      } catch {
        throw new UpdateVerifyError('E_MANIFEST', 'update.json 不可解析');
      }
    })();
    if (!keyId) throw new UpdateVerifyError('E_MANIFEST', 'update.json 缺 keyId（拒绝未签名清单）');
    // 逐字节验签（签名覆盖文件原文，不做二次序列化）
    verifyBytes(input.data, input.sig, keyId);
    const parsed = validateManifest(JSON.parse(input.data.toString('utf8')));
    if (!parsed.ok || !parsed.manifest) {
      throw new UpdateVerifyError('E_MANIFEST', `清单结构不合法: ${parsed.errors.join('; ')}`);
    }
    return parsed.manifest;
  }

  // ---------------------------------------------------------------- 检查

  async checkServer(opts: { force?: boolean } = {}): Promise<ServerCheck> {
    const current = this.current();
    const manifest = await this.loadManifest({ force: opts.force });
    const server = manifest.components.server ?? null;
    if (!server) {
      return {
        component: 'server',
        hasUpdate: false,
        current,
        latest: null,
        mode: 'none',
        deltaBytes: 0,
        deltaAvailable: false,
        fullBytes: 0,
        needsReshell: false,
        minShell: '',
      };
    }

    const latestVersion = server.version || semverToVersion(server.semver) || 0;
    // 清单写坏了（version 0 / semver 不合法）：当成「没有可用更新」，
    // 绝不能让它走到 versionId(0) 那条会抛异常的路径上
    if (latestVersion < 1) {
      return {
        component: 'server',
        hasUpdate: false,
        current,
        latest: null,
        mode: 'none',
        deltaBytes: 0,
        deltaAvailable: false,
        fullBytes: 0,
        needsReshell: false,
        minShell: String(manifest.minShell || ''),
      };
    }
    const newer =
      compareSemver(server.semver, current.semver) > 0 &&
      (current.version === null || latestVersion > current.version);

    const delta = server.delta ?? null;
    const canDelta =
      newer &&
      Boolean(current.dir) &&
      Boolean(delta) &&
      Boolean(delta!.from.includes(current.semver)) &&
      Boolean(current.managed);
    const mode: ServerCheck['mode'] = !newer ? 'none' : canDelta ? 'delta' : server.full ? 'full' : 'none';

    const needsReshell = Boolean(
      manifest.minShell &&
        this.opts.shellVersion &&
        compareSemver(manifest.minShell, this.opts.shellVersion) > 0,
    );

    return {
      component: 'server',
      hasUpdate: newer,
      current,
      latest: {
        semver: server.semver,
        version: latestVersion,
        notes: manifest.notes ?? {},
        releasedAt: manifest.releasedAt,
        critical: server.critical === true,
      },
      mode: needsReshell ? 'full' : mode,
      deltaBytes: canDelta ? deltaBytes(delta!) : 0,
      deltaAvailable: canDelta,
      fullBytes: server.full?.size ?? 0,
      needsReshell,
      minShell: String(manifest.minShell || ''),
    };
  }

  /**
   * 本地调试包：目录里有 `.apk` 就优先当成客户端最新版。
   *
   * 用途是开发期快速迭代：构建机把 APK 丢到 NAS 的
   * `<dataDir>/update/local-apk/`（或 `COLANAS_LOCAL_APK_DIR` 指定的目录），
   * 手机连着这台 NAS 打开「检查更新」就能直接走局域网下载安装，
   * 不需要等 GitCode / GitHub 发版，也不消耗公网流量。
   *
   * 版本信息可选：放一个同名 `<apk>.json`（或目录里的 `local-update.json`）：
   * `{ "semver": "1.3.23", "versionCode": 1324, "notes": "..." }`；
   * 没有元数据时从文件名里取 semver，取不到就固定报有更新（调试模式自己控制）。
   */
  private localApkCandidate() {
    return this.apkCandidateIn(this.localApkDir);
  }

  private localTvApkCandidate() {
    return this.apkCandidateIn(this.localTvApkDir);
  }

  private localPhotoApkCandidate() {
    return this.apkCandidateIn(this.localPhotoApkDir);
  }

  private apkCandidateIn(dir: string): {
    file: string;
    name: string;
    size: number;
    sha256: string;
    meta: { semver?: string; versionCode?: number; notes?: string };
  } | null {
    let names: string[];
    try {
      names = fs.readdirSync(dir).filter((n) => /\.apk$/i.test(n));
    } catch {
      return null;
    }
    let best: { file: string; name: string; size: number; mtimeMs: number } | null = null;
    for (const name of names) {
      const file = path.join(dir, name);
      try {
        const st = fs.statSync(file);
        if (!st.isFile()) continue;
        if (!best || st.mtimeMs > best.mtimeMs) {
          best = { file, name, size: st.size, mtimeMs: st.mtimeMs };
        }
      } catch {
        /* 正在写入 / 没权限：跳过 */
      }
    }
    if (!best) return null;
    const key = `${best.size}:${best.mtimeMs}`;
    // 按绝对路径缓存：手机包和 TV 包经常同名，按文件名会互相串
    const memo = this.localApkMemo.get(best.file);
    const digest = memo && memo.key === key ? memo.sha256 : sha256File(best.file);
    this.localApkMemo.set(best.file, { key, sha256: digest });
    const meta =
      readJson<{ semver?: string; versionCode?: number; notes?: string }>(`${best.file}.json`) ??
      readJson<{ semver?: string; versionCode?: number; notes?: string }>(
        path.join(dir, 'local-update.json'),
      ) ??
      {};
    return { file: best.file, name: best.name, size: best.size, sha256: digest, meta };
  }

  /**
   * 目录里是否有调试 APK（不做哈希，供路由决定是否跳过清单源）。
   *
   * 传了 `build` 就只看这一种构建形态的目录：相册端目录空着、
   * 手机包目录里有包时，不能因为「有本地包」就跳过清单源 —— 那会让相册端
   * 永远看不到线上更新。
   */
  hasLocalApk(build?: AndroidBuildKind): boolean {
    const dirs =
      build === 'photo'
        ? [this.localPhotoApkDir]
        : build === 'tv'
          ? [this.localTvApkDir]
          : build === 'phone'
            ? [this.localApkDir]
            : [this.localApkDir, this.localTvApkDir, this.localPhotoApkDir];
    for (const dir of dirs) {
      try {
        if (fs.readdirSync(dir).some((n) => /\.apk$/i.test(n))) return true;
      } catch {
        /* 目录不存在：看下一个 */
      }
    }
    return false;
  }

  /** 局域网下载地址的 sha 校验：只允许分发当前目录里真实存在的那个 APK */
  localAssetPath(sha256Hex: string): string | null {
    const want = sha256Hex.toLowerCase();
    for (const cand of [this.localApkCandidate(), this.localTvApkCandidate(), this.localPhotoApkCandidate()]) {
      if (cand && cand.sha256.toLowerCase() === want) return cand.file;
    }
    return null;
  }

  /**
   * 调试目录里的包是否比客户端当前版本新。
   *
   * 这个目录是开发期覆盖源，放在那里不会自动消失，必然会有过期的一天。
   * 过期后如果还报「有更新」，界面就会出现 `v1.3.27 → v1.3.24` 这种倒退的弹窗。
   *
   * 判定顺序：有 versionCode 就只比 versionCode（安卓真正拿来做覆盖安装的闸门）；
   * 否则比 semver；两者都没有（手丢的 APK、没写 `.json`）保持调试语义 —— 恒为「新」。
   */
  private localApkIsNewer(
    cand: { name: string; meta: { semver?: string; versionCode?: number } },
    currentSemver: string,
    currentVersionCode: number,
  ): boolean {
    const vc = Number(cand.meta.versionCode) || 0;
    if (vc > 0 && currentVersionCode > 0) return vc > currentVersionCode;
    const sv = String(cand.meta.semver || /(\d+\.\d+\.\d+)/.exec(cand.name)?.[1] || '').trim();
    if (/^\d+\.\d+\.\d+$/.test(sv) && /^\d+\.\d+\.\d+$/.test(currentSemver)) {
      return compareSemver(sv, currentSemver) > 0;
    }
    return true;
  }

  private localClientCheck(
    component: 'client_pc' | 'client_android',
    opts: {
      lanBase?: string;
      currentSemver?: string;
      currentVersionCode?: number;
      build?: AndroidBuildKind;
    },
  ): ClientCheck | null {
    // 本地调试包只有安卓需要：PC 的安装包不是 APK
    if (component !== 'client_android') return null;
    const phone = this.localApkCandidate();
    const tv = this.localTvApkCandidate();
    const photo = this.localPhotoApkCandidate();
    if (!phone && !tv && !photo) return null;
    // 相册端只认相册调试目录：目录空着就回 null 走清单源，不能因为手机包
    // 存在就判定「没有更新」—— 那会让相册端永远看不到线上版本。
    if (opts.build === 'photo' && !photo) return null;
    const base = (opts.lanBase || '').replace(/\/+$/, '');
    if (!base) return null;

    const currentSemver = String(opts.currentSemver || '').trim();
    const currentVersionCode = Number(opts.currentVersionCode) || 0;
    /**
     * 只下发与自己这一份包匹配的资产。
     *
     * 手机包和 TV 包是**同一个 applicationId**，装错就是把电视端换成手机 UI
     * （遥控器点不动，连退出都难）；相册端是**另一个 applicationId**
     * （com.colanas.photo），装错就是凭空多出一个主客户端。所以三种构建
     * 各自只认自己那一种资产，拿不到匹配的包时宁可回「没有更新」。
     * `build` 缺省（老客户端）才三个都给 —— 那批客户端自己按包身份挑。
     */
    const picked =
      opts.build === 'tv'
        ? tv
          ? [{ cand: tv, kind: 'apk_tv' as ClientAssetKind }]
          : []
        : opts.build === 'photo'
          ? photo
            ? [{ cand: photo, kind: 'apk_photo' as ClientAssetKind }]
            : []
          : opts.build === 'phone'
            ? phone
              ? [{ cand: phone, kind: 'apk' as ClientAssetKind }]
              : []
            : [
                ...(phone ? [{ cand: phone, kind: 'apk' as ClientAssetKind }] : []),
                ...(tv ? [{ cand: tv, kind: 'apk_tv' as ClientAssetKind }] : []),
                ...(photo ? [{ cand: photo, kind: 'apk_photo' as ClientAssetKind }] : []),
              ];
    if (!picked.length) {
      // 明确「没有适用于当前端形态的包」，不要退化成「有更新但下不了」
      this.log('no local apk for this build', { build: opts.build || '' });
      return { component, hasUpdate: false, latest: null, assets: [] };
    }
    const fresh: Array<{
      cand: NonNullable<ReturnType<UpdateService['apkCandidateIn']>>;
      kind: ClientAssetKind;
    }> = [];
    for (const item of picked) {
      if (!this.localApkIsNewer(item.cand, currentSemver, currentVersionCode)) {
        this.log('local apk not newer than client, skipped', {
          name: item.cand.name,
          currentSemver,
          currentVersionCode,
        });
        continue;
      }
      fresh.push({ cand: item.cand, kind: item.kind });
    }
    // 目录里有包但都不比客户端新：明确回「没有更新」，再往下走清单源只会白等
    if (!fresh.length) return { component, hasUpdate: false, latest: null, assets: [] };

    const main = fresh[0].cand;
    const fromName = /(\d+\.\d+\.\d+)/.exec(main.name)?.[1] ?? '';
    const semver = String(main.meta.semver || fromName || 'local').trim() || 'local';
    const versionCode = Number(main.meta.versionCode) || 0;
    const notes = String(main.meta.notes || '').trim() || `本地调试包：${main.name}`;
    const assets: ClientCheck['assets'] = fresh.map(({ cand, kind }) => ({
      kind,
      size: cand.size,
      sha256: cand.sha256,
      urls: [
        `${base}/api/v1/system/update/local-apk/${cand.sha256}/${encodeURIComponent(cand.name)}`,
      ],
    }));
    return {
      component,
      hasUpdate: true,
      latest: { semver, version: 0, versionCode, notes: { zh: notes, en: notes } },
      assets,
    };
  }

  /**
   * 客户端检查（PC / 安卓）。
   *
   * `lanBase` 由路由传入（`http://192.168.x.x:7788`），服务端已缓存的资产会插到
   * URLs 最前面 —— 局域网满速，且不消耗公网流量。
   */
  async checkClient(
    component: 'client_pc' | 'client_android',
    opts: {
      currentSemver?: string;
      currentVersionCode?: number;
      lanBase?: string;
      force?: boolean;
      build?: AndroidBuildKind;
    },
  ): Promise<ClientCheck> {
    // 调试目录里有 APK 就直接走它：完全不碰清单源，离线也能更新
    const local = this.localClientCheck(component, opts);
    if (local) return local;
    const manifest = await this.loadManifest({ force: opts.force });
    const c = manifest.components[component] as ClientComponent | undefined;
    if (!c) {
      return { component, hasUpdate: false, latest: null, assets: [] };
    }
    const currentSemver = String(opts.currentSemver || '');
    const newerSemver = currentSemver ? compareSemver(c.semver, currentSemver) > 0 : true;
    const newerCode =
      typeof opts.currentVersionCode === 'number' && typeof c.versionCode === 'number'
        ? c.versionCode > opts.currentVersionCode
        : true;

    /**
     * 安卓资产按构建形态过滤：TV 只留 `apk_tv`，手机只留 `apk`，
     * 相册端只留 `apk_photo`。
     *
     * 清单里只发了其中一份时（发版漏传 TV / 相册包、或历史版本根本没有该资产），
     * 宁可报「没有适用于本端的包」，也不能把另一份塞给客户端 —— 那会把电视端
     * 直接换成手机 UI，或者给相册端装上一个主客户端。
     */
    const wantKind: ClientAssetKind | '' =
      component !== 'client_android'
        ? ''
        : opts.build === 'tv'
          ? 'apk_tv'
          : opts.build === 'photo'
            ? 'apk_photo'
            : opts.build === 'phone'
              ? 'apk'
              : '';
    const assets = Object.entries(c.assets ?? {})
      .filter(([kind]) => {
        if (!wantKind) return true;
        // 只对齐「另一个 apk 兄弟」，别的 kind（setup / portable）不参与安卓判断
        return kind === wantKind;
      })
      .map(([kind, ref]) => ({
        kind: kind as ClientAssetKind,
        size: Number((ref as AssetRef).size) || 0,
        sha256: String((ref as AssetRef).sha256 || ''),
        br: (ref as AssetRef).br,
        urls: this.withLanUrls(kind as ClientAssetKind, ref as AssetRef, opts.lanBase),
      }));
    const hasOwnApk = !wantKind || assets.some((a) => a.kind === wantKind);
    const hasUpdate =
      component === 'client_android'
        ? (newerCode || newerSemver) && hasOwnApk
        : newerSemver;

    return {
      component,
      hasUpdate,
      latest: {
        semver: c.semver,
        version: c.version || semverToVersion(c.semver) || 0,
        versionCode: Number(c.versionCode) || 0,
        notes: manifest.notes ?? {},
      },
      assets: hasOwnApk ? assets : [],
    };
  }

  /** 本地已缓存的资产插到 URL 列表最前面 */
  private withLanUrls(kind: ClientAssetKind, ref: AssetRef, lanBase?: string): string[] {
    const urls = [...(ref.urls ?? [])];
    if (!lanBase) return urls;
    const file = this.cachedAssetPath(ref.sha256);
    if (!file) return urls;
    const name = path.basename(file);
    return [`${lanBase.replace(/\/+$/, '')}/api/v1/system/update/asset/${ref.sha256}/${encodeURIComponent(name)}`, ...urls];
  }

  /** 资产缓存里按 sha256 找文件（下载过一次就有） */
  cachedAssetPath(sha256Hex: string): string | null {
    if (!sha256Hex) return null;
    try {
      const hit = fs
        .readdirSync(this.assetDir)
        .find((n) => n.startsWith(`${sha256Hex.slice(0, 16)}-`));
      return hit ? path.join(this.assetDir, hit) : null;
    } catch {
      return null;
    }
  }

  // ---------------------------------------------------------------- 安装

  /**
   * 启动一次安装任务。立刻返回，进度用 `jobStatus()` 轮询。
   *
   * 只允许一个任务在跑：并发下载会互相抢带宽，还会抢同一个 staging 目录。
   */
  async install(opts: { force?: boolean; mode?: InstallMode } = {}): Promise<JobStatus> {
    if (this.busy) return this.jobStatus();
    this.busy = true;
    this.abort = new AbortController();
    this.job = {
      ...UpdateService.idleJob(),
      phase: 'preparing',
      message: '正在检查新版本',
      startedAt: Date.now(),
      updatedAt: Date.now(),
    };
    void this.runInstall(opts).finally(() => {
      this.busy = false;
      this.abort = null;
    });
    return this.jobStatus();
  }

  cancel(): JobStatus {
    if (this.abort) this.abort.abort();
    if (this.busy) this.setJob({ phase: 'cancelled', message: '已取消', hint: '' });
    return this.jobStatus();
  }

  private setJob(patch: Partial<JobStatus>): void {
    this.job = { ...this.job, ...patch, updatedAt: Date.now() };
  }

  private fail(err: unknown, hint = 'retry'): void {
    const message = err instanceof Error ? err.message : String(err);
    const detail =
      err instanceof DownloadError && err.detail?.errors
        ? ` (${(err.detail.errors as string[]).slice(0, 2).join('; ')})`
        : '';
    this.setJob({ phase: 'failed', message: '更新失败', error: `${message}${detail}`, hint });
    this.log('update failed', { message, hint });
  }

  private log(msg: string, extra?: Record<string, unknown>): void {
    this.opts.log?.(msg, extra);
  }

  private async runInstall(opts: { force?: boolean; mode?: InstallMode }): Promise<void> {
    const signal = this.abort!.signal;
    try {
      const check = await this.checkServer({ force: opts.force });
      if (!check.hasUpdate || !check.latest) {
        this.setJob({ phase: 'idle', message: '已是最新版本' });
        return;
      }
      /**
       * 用户明确点了哪个按钮就按哪个来（`delta` / `full`）；`auto` 是旧行为：
       * 能增量就增量，不能就全量。界面上「增量 / 全量」两个按钮就是这个参数。
       */
      const want = opts.mode ?? 'auto';
      if (want === 'delta' && !check.deltaAvailable) {
        this.fail(
          new Error('这个版本没有可用的增量包（当前版本不在增量基线里），请用完整安装包'),
          'manual',
        );
        return;
      }
      const useDelta = want === 'delta' || (want === 'auto' && check.mode === 'delta');
      const targetId = versionId(check.latest.version);
      this.setJob({ targetId, mode: useDelta ? 'delta' : 'full' });

      if (check.needsReshell) {
        this.fail(
          new Error(
            `需要重装服务端（当前外壳 ${this.opts.shellVersion || '未知'}，` +
              `该版本要求 ≥ ${check.minShell || '更新的外壳'}）`,
          ),
          'manual',
        );
        return;
      }

      /**
       * 磁盘预检。增量只落变化文件（硬链接不占空间），按「增量体积 x4 + 100 MB」算；
       * 全量要落一份完整安装包 + 解压，按 1.2 GB 算。一律按 1.1 GB 卡，会把
       * 快满的 NAS 直接挡在更新之外，而它其实只差几 MB。
       */
      const need = useDelta
        ? Math.max(300 * MB, check.deltaBytes * 4 + 100 * MB)
        : Math.max(1200 * MB, check.fullBytes * 2 + 200 * MB);
      const free = freeSpace(this.dataDir);
      if (free > 0 && free < need) {
        this.fail(
          new Error(`磁盘空间不足（剩余 ${Math.round(free / MB)} MB，至少需要 ${Math.round(need / MB)} MB）`),
          'manual',
        );
        return;
      }

      if (useDelta) {
        try {
          await this.installDelta(check, targetId, signal);
        } catch (err) {
          if (signal.aborted) throw err;
          /**
           * 增量失败自动降级全量（方案 §9.6）：基线被用户改过、包缺文件、
           * 摘要对不上……都只说明「这份增量用不了」，不代表不能更新。
           * 没有全量包时才把错误抛给用户。
           */
          // 这次读清单失败不能盖掉原始错误（它才是用户需要看的）
          const full = (await this.loadManifest({}).catch(() => null))?.components.server?.full;
          if (!full?.urls?.length) throw err;
          this.log('delta failed, fallback to full', { err: (err as Error).message });
          this.setJob({
            phase: 'preparing',
            percent: 0,
            loaded: 0,
            message: '增量包不可用，改用完整安装包',
            error: '',
            mode: 'full',
          });
          await this.installFull(check, signal);
        }
      } else if (check.fullBytes > 0) {
        await this.installFull(check, signal);
      } else {
        this.fail(new Error('这个版本没有可用的增量包，也没有全量包'), 'manual');
      }
    } catch (err) {
      if ((err as Error)?.name === 'AbortError' || (err instanceof DownloadError && err.code === 'E_ABORTED')) {
        this.setJob({ phase: 'cancelled', message: '已取消' });
        return;
      }
      this.fail(err);
    }
  }

  private async installDelta(check: ServerCheck, targetId: string, signal: AbortSignal): Promise<void> {
    const manifest = await this.loadManifest({ force: true });
    const server = manifest.components.server;
    const delta = server?.delta;
    if (!delta) throw new Error('清单里没有增量描述');

    // 1. 版本目录清单（整体签名，防「悄悄少一个文件」）
    this.setJob({ phase: 'downloading', asset: 'manifest.json', message: '正在获取版本清单' });
    const manifestFiles = await this.downloadVersionManifest(delta, signal);

    // 2. 下载变化文件 + 小文件包
    const payloadDir = path.join(this.workDir, `${targetId}-payload`);
    fs.rmSync(payloadDir, { recursive: true, force: true });
    fs.mkdirSync(payloadDir, { recursive: true });

    const totalBytes =
      delta.files.reduce((s, f) => s + (f.br?.size ?? f.size), 0) +
      delta.bundles.reduce((s, b) => s + b.size, 0);
    this.setJob({ total: totalBytes, loaded: 0, percent: 0, message: '正在下载增量包' });

    // 资产名是扁平的唯一名字（见 tool/release/release.js）：既有显式 urls 就用它，
    // 否则退回 `urlBase + 名字` 的老口径（自建 OSS 按目录摆包时仍然可用）。
    const urlsFor = (asset: { urls?: string[] }, fallbackName: string): string[] =>
      asset.urls && asset.urls.length > 0
        ? asset.urls
        : delta.urlBase.map((b) => `${b.replace(/\/+$/, '')}/${fallbackName}`);

    let doneBytes = 0;
    for (const f of delta.files) {
      if (signal.aborted) throw new DownloadError('E_ABORTED', '已取消');
      const dest = path.join(payloadDir, f.path);
      const name = f.path.split('/').pop() || 'file';
      await downloadAsset({
        urls: urlsFor(f, f.br ? `${path.basename(f.path)}.br` : path.basename(f.path)),
        dest,
        size: f.size,
        sha256: f.sha256,
        br: f.br,
        memo: this.memo,
        memoKey: f.sha256,
        signal,
        onProgress: (p) =>
          this.onDownloadProgress(p, name, doneBytes, totalBytes),
      });
      doneBytes += f.br?.size ?? f.size;
    }

    for (const b of delta.bundles) {
      if (signal.aborted) throw new DownloadError('E_ABORTED', '已取消');
      const bundlePath = path.join(payloadDir, b.name);
      await downloadAsset({
        urls: urlsFor(b, b.name),
        dest: bundlePath,
        size: b.size,
        sha256: b.sha256,
        memo: this.memo,
        memoKey: b.sha256,
        signal,
        onProgress: (p) => this.onDownloadProgress(p, b.name, doneBytes, totalBytes),
      });
      this.setJob({ phase: 'verifying', asset: b.name, message: '正在解包小文件' });
      unpackBundle(bundlePath, payloadDir);
      fs.rmSync(bundlePath, { force: true });
      doneBytes += b.size;
    }

    // 3. 组装
    this.setJob({ phase: 'assembling', message: '正在组装新版本目录' });
    cleanStaging(this.versionsDir);
    const staging = path.join(this.versionsDir, `.staging-${targetId}`);
    fs.rmSync(staging, { recursive: true, force: true });
    const baselineDir = this.current().dir;
    const assembled = assembleVersion({
      baselineDir,
      targetDir: staging,
      payloadDir,
      files: manifestFiles.files,
      manifestText: manifestFiles.text,
      manifestSig: manifestFiles.sig,
      onProgress: (d, t) => this.setJob({ percent: Math.round((d / Math.max(1, t)) * 100), message: `正在组装 ${d}/${t}` }),
    });

    // 4. 全量校验 + 收尾
    this.setJob({ phase: 'verifying', message: '正在校验新版本文件' });
    const verify = verifyTree(staging, manifestFiles.files);
    if (!verify.ok) throw new AssembleError('E_VERIFY', `新版本校验失败: ${verify.errors.slice(0, 3).join('; ')}`);

    this.writeVersionMeta(staging, server!.semver, manifestFiles.version);
    await this.promote(staging, targetId);
    this.log('delta install done', { targetId, ...assembled, verified: verify.ok });
    fs.rmSync(payloadDir, { recursive: true, force: true });
  }

  private onDownloadProgress(p: ProgressEvent, asset: string, baseBytes: number, totalBytes: number): void {
    const loaded = baseBytes + p.loaded;
    this.setJob({
      phase: 'downloading',
      asset,
      source: p.source,
      loaded,
      total: totalBytes || p.total,
      percent: totalBytes > 0 ? Math.min(99, Math.round((loaded / totalBytes) * 100)) : 0,
      speed: p.speed,
      message: `正在下载 ${asset}`,
    });
  }

  private async downloadVersionManifest(
    delta: DeltaRef,
    signal: AbortSignal,
  ): Promise<{ text: Buffer; sig: string; files: Record<string, string>; version: number }> {
    const m = delta.manifest;
    const urls = m.urls.length > 0 ? m.urls : delta.urlBase.map((b) => `${b.replace(/\/+$/, '')}/manifest.json`);
    const jsonRes = await fetchText(urls, { signal, memo: this.memo, memoKey: m.sha256 });
    const text = Buffer.from(jsonRes.text, 'utf8');
    if (m.sha256 && sha256(text) !== m.sha256) throw new Error('版本清单摘要不符');
    // 签名同样走 `.sig.json`：`.sig` 在 GitCode raw 上取不到（见 fetchManifestSignature）。
    // 多镜像里只要有一个能给出签名就用它 —— 签名内容对所有镜像都一样。
    const sigRes = await fetchManifestSignature(urls[0], signal);
    const sig = sigRes.trim();
    // keyId 从 update.json 拿不到（manifest 里没带），按「当前所有已内置公钥」逐个试
    let lastErr: unknown = null;
    for (const keyId of knownKeyIds()) {
      try {
        const parsed = verifyVersionManifest(text, sig, keyId);
        return { text, sig, files: parsed.files, version: parsed.version };
      } catch (err) {
        lastErr = err;
      }
    }
    throw new UpdateVerifyError('E_SIGNATURE', `版本清单验签失败: ${(lastErr as Error)?.message ?? ''}`);
  }

  /** 全量兜底：下载安装包，交给外壳/用户执行 */
  private async installFull(check: ServerCheck, signal: AbortSignal): Promise<void> {
    const manifest = await this.loadManifest({ force: true });
    const full = manifest.components.server?.full;
    if (!full) throw new Error('清单里没有全量包');
    const name = (full.urls[0] || '').split('/').pop() || 'ColaNasOs-Server-Setup.exe';
    const dest = path.join(this.cacheDir, name);
    this.setJob({ phase: 'downloading', total: full.br?.size ?? full.size, asset: name, message: '正在下载完整安装包' });
    await downloadAsset({
      urls: full.urls,
      dest,
      size: full.size,
      sha256: full.sha256,
      br: full.br,
      memo: this.memo,
      memoKey: full.sha256,
      signal,
      onProgress: (p) => this.onDownloadProgress(p, name, 0, full.br?.size ?? full.size),
    });
    /**
     * 全量走安装器：它自己会关掉旧进程（installer.nsh 的 STOP_RUNNING_APP），
     * 装完再把自己拉起来（customInstall 里的 Exec），所以这里下载完就直接跑，
     * 不留一个「请手动双击」的路径给用户。
     *
     * 但**必须先要提权、并且拿得到结果**。服务端多半装在 Program Files
     * （per-machine），而内核跑在普通权限下：直接 `spawn(exe, ['/S'])` 在需要
     * 管理员时不会报错、也不会装 —— 任务停在「正在启动安装程序」，安装目录里
     * 一个字节都没变，用户以为更新完了。所以改成用 PowerShell 的
     * `Start-Process -Verb RunAs` 主动提权，被拒（1223）就当场报错。
     */
    this.setJob({
      phase: 'installing',
      percent: 100,
      mode: 'full',
      message: '正在等待系统授权，请在弹出的窗口点「是」',
    });
    // 兜底先挂上：安装器把本进程杀掉之后，没人再管「装完有没有回来」
    this.spawnRescue();
    const result = await this.runInstaller(dest);
    if (result === 'denied') {
      this.fail(
        new Error('系统授权被取消，安装程序没有运行（服务端仍在运行，可以再点一次）'),
        'retry',
      );
      return;
    }
    if (result === 'failed') {
      this.fail(new Error(`安装程序没能启动，请手动运行：${dest}`), 'manual');
      return;
    }
    this.setJob({
      phase: 'ready',
      percent: 100,
      message:
        result === 'launched'
          ? '安装程序已启动，装完会自动把服务端启回来'
          : '安装包已就绪',
      hint: result === 'launched' ? 'auto' : dest,
      autoRun: result === 'launched',
      mode: 'full',
    });
  }

  /**
   * 拉起服务端安装程序，返回它到底有没有跑起来。
   *
   * 三种结局都是可观测的，这正是重点：
   *   - `launched`：装完了（通常本进程已经被安装器杀掉，走不到这里）；
   *   - `denied`：UAC 被拒（1223）。安装程序**没有**启动，服务端还活着，
   *     必须如实告诉用户「没装」，而不是留一条假的「正在安装」；
   *   - `failed`：启动失败 / 安装程序返回非 0，把包路径交给用户手动跑。
   *
   * 脚本走 `-EncodedCommand`（base64 + UTF-16LE）：路径里有空格和中文，
   * 拼成 `-Command` 字符串一定要和 cmd / PowerShell 的引号规则打架。
   */
  private runInstaller(exe: string): Promise<'launched' | 'denied' | 'failed' | 'skipped'> {
    if (process.platform !== 'win32') return Promise.resolve('skipped');
    // 冒烟夹具的「安装包」只是个 MZ 开头的空壳，真跑起来会去装别的东西
    if (process.env.COLANAS_UPDATE_NO_AUTORUN === '1') return Promise.resolve('skipped');
    if (!isWindowsExecutable(exe)) return Promise.resolve('skipped');

    const script = [
      "$ErrorActionPreference = 'Stop'",
      'try {',
      "  $p = Start-Process -FilePath $env:COLANAS_SETUP -ArgumentList '/S' -Verb RunAs -PassThru -ErrorAction Stop",
      '} catch {',
      '  # 1223 = ERROR_CANCELLED：用户在 UAC 窗口点了「否」',
      '  exit 1223',
      '}',
      '$p.WaitForExit()',
      'exit $p.ExitCode',
    ].join('\n');

    return new Promise((resolve) => {
      let settled = false;
      const done = (r: 'launched' | 'denied' | 'failed'): void => {
        if (settled) return;
        settled = true;
        resolve(r);
      };
      /**
       * 延迟 2 秒再真跑：安装器拿到授权后第一件事就是杀掉本进程，
       * 留一点时间让界面把「正在等待系统授权」这一帧取走。
       */
      const timer = setTimeout(() => {
        let stderr = '';
        const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodePowershell(script)], {
          stdio: ['ignore', 'ignore', 'pipe'],
          windowsHide: true,
          env: { ...process.env, COLANAS_SETUP: exe },
        });
        child.stderr?.on('data', (d: Buffer) => {
          stderr += String(d);
        });
        child.on('error', (err) => {
          this.log('installer spawn failed', { err: String(err) });
          done('failed');
        });
        child.on('exit', (code) => {
          if (code === 0) return done('launched');
          if (code === 1223) {
            this.log('installer elevation denied');
            return done('denied');
          }
          this.log('installer failed', { code, stderr: stderr.slice(0, 400) });
          done('failed');
        });
      }, 2000);
      timer.unref?.();
    });
  }

  /**
   * 「装完没回来」的兜底。
   *
   * 装完靠 installer.nsh 的 customInstall 用 explorer 把服务端拉起来，这条链路
   * 任何一环出问题（提权残留、explorer 被占用、安装中途失败）留下的都是
   * 「包装完了、服务没了、得走到机器跟前点图标」—— NAS 往往不在手边。
   *
   * 所以起一个 detached 陪跑进程，分两段：
   *   1. 等端口**掉下去**（安装器先杀本进程）。120 秒内没掉 = 安装根本没起来
   *      （UAC 被拒 / 安装器提前退出），直接收工，不掺和；
   *   2. 掉下去之后再等它**起来**（最多 4 分钟）。期间有安装程序在跑就继续等
   *      —— 那会儿去拉起只会撞文件占用；一直没有才用安装目录里的外壳启动。
   *
   * 两段判断缺一不可：只看「端口活着」会在我还没被杀掉的那几秒里误判成
   * 「已经回来了」然后退出，等于没有兜底。
   *
   * 它不在 `$INSTDIR` 下，安装器按路径匹配杀进程时不会误伤。
   */
  private spawnRescue(): void {
    if (process.platform !== 'win32') return;
    const shellExe = process.env.COLANAS_SHELL_EXE;
    if (!shellExe || !fs.existsSync(shellExe)) return;
    const port = Number(process.env.PORT || 7788) || 7788;
    const script = [
      `$port = ${port}`,
      '$exe = $env:COLANAS_SHELL_EXE',
      'function Test-Port {',
      '  try {',
      '    $c = New-Object Net.Sockets.TcpClient',
      '    $c.Connect("127.0.0.1", $port)',
      '    $c.Close()',
      '    return $true',
      '  } catch { return $false }',
      '}',
      'function Test-Installer {',
      '  return @(Get-Process | Where-Object { $_.ProcessName -like "*Setup*" }).Count -gt 0',
      '}',
      '# 第一段：等安装器把服务端杀掉（端口掉下去）',
      '$deathline = (Get-Date).AddSeconds(120)',
      'while ((Get-Date) -lt $deathline) {',
      '  if (-not (Test-Port)) { break }',
      '  Start-Sleep -Seconds 2',
      '}',
      'if (Test-Port) { exit 0 }',
      '# 第二段：等它自己回来，回不来就拉起来',
      '$deadline = (Get-Date).AddMinutes(4)',
      'while ((Get-Date) -lt $deadline) {',
      '  Start-Sleep -Seconds 3',
      '  if (Test-Port) { exit 0 }',
      '  if (Test-Installer) { continue }',
      '}',
      'if (Test-Port) { exit 0 }',
      'if (Test-Path $exe) { Start-Process -FilePath $exe }',
    ].join('\n');
    try {
      const child = spawn(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', encodePowershell(script)],
        {
          detached: true,
          stdio: 'ignore',
          windowsHide: true,
          env: { ...process.env, COLANAS_SHELL_EXE: shellExe },
        },
      );
      child.on('error', (err) => this.log('rescue spawn failed', { err: String(err) }));
      child.unref();
      this.log('rescue armed', { shellExe, port });
    } catch (err) {
      this.log('rescue spawn failed', { err: String(err) });
    }
  }

  /**
   * 写 version.json（内核 / 客户端判断新旧都用它）。
   *
   * 已经存在就**不覆盖**：发布产物的 version.json 是清单里的一员，
   * 重新写一遍（字段顺序/内容不同）会让「切指针前的全量校验」对不上。
   */
  private writeVersionMeta(dir: string, semver: string, version: number): void {
    if (fs.existsSync(path.join(dir, 'version.json'))) return;
    writeJsonAtomic(path.join(dir, 'version.json'), {
      semver,
      version,
      buildNumber: version % 100,
      versionCode: version,
    });
  }

  /** staging → 正式目录 → 切指针 → 写 boot.json */
  private async promote(staging: string, targetId: string): Promise<void> {
    const dest = path.join(this.versionsDir, targetId);
    if (fs.existsSync(dest)) fs.rmSync(dest, { recursive: true, force: true });
    fs.renameSync(staging, dest);

    this.setJob({ phase: 'activating', message: '正在切换版本' });
    await this.opts.beforeActivate?.(targetId);

    const versions = new Updater(this.dataDir);
    versions.activate(parseVersionId(targetId) ?? 0, { forceDowngrade: true });
    writeBoot(this.dataDir, { id: targetId, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
    // 只保留当前与上一版：回滚够用，磁盘不会越滚越大（一个版本约 60 MB）
    const pruned = pruneVersions(this.versionsDir, 2);
    if (pruned.length) this.log('pruned versions', { pruned });
    this.setJob({ phase: 'ready', percent: 100, message: '更新完成，重启后生效' });
  }

  // ---------------------------------------------------------------- 回滚 / 离线

  /** 回滚到上一版（允许降级）；返回目标版本 id */
  rollback(): { id: string } {
    const up = new Updater(this.dataDir);
    const entry = up.rollback();
    writeBoot(this.dataDir, { id: entry.id, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
    this.setJob({ phase: 'ready', message: `已回滚到 ${entry.id}`, hint: 'restart' });
    this.log('rolled back', { id: entry.id });
    return { id: entry.id };
  }

  /**
   * 离线包导入（`<dataDir>/update/inbox/<名字>/`）。
   *
   * 断网 NAS 的场景：把整个目录从 U 盘拷进 `inbox`，然后在设置页点导入。
   * 目录结构就是**一个完整的版本目录** + 它自己的签名清单：
   *
   *   colanas-offline-1.3.14/
   *     update.json  update.json.sig      ← 证明「这是官方发的这一版」
   *     files/manifest.json .sig          ← 逐文件摘要 + 整体签名
   *     files/kernel/... web/...
   *
   * 之所以用目录而不是 zip：解 zip 要引依赖，而「拷文件夹」对用户来说一样简单，
   * 而且导入走的校验、组装、切指针与在线路径**完全相同**。
   */
  async importOffline(name: string): Promise<{ targetId: string; files: number }> {
    if (this.busy) throw new Error('有更新任务正在进行');
    const dir = path.join(this.updateDir, 'inbox', path.basename(name));
    const updatePath = path.join(dir, 'update.json');
    const sigPath = `${updatePath}.sig`;
    if (!fs.existsSync(updatePath) || !fs.existsSync(sigPath)) {
      throw new Error(`离线包不完整（缺 update.json / .sig）：${path.basename(name)}`);
    }
    // 与在线路径同一套验签
    const manifest = this.parseManifest({
      data: fs.readFileSync(updatePath),
      sig: fs.readFileSync(sigPath, 'utf8'),
    });
    const server = manifest.components.server;
    if (!server) throw new Error('离线包里没有服务端组件');

    const filesDir = path.join(dir, 'files');
    const mfPath = path.join(filesDir, 'manifest.json');
    const mfSigPath = `${mfPath}.sig`;
    if (!fs.existsSync(mfPath) || !fs.existsSync(mfSigPath)) {
      throw new Error('离线包里缺 files/manifest.json 或其签名');
    }
    const mfText = fs.readFileSync(mfPath);
    const mfSig = fs.readFileSync(mfSigPath, 'utf8').trim();
    let parsed: { version: number; files: Record<string, string> } | null = null;
    let lastErr: unknown = null;
    for (const keyId of knownKeyIds()) {
      try {
        parsed = verifyVersionManifest(mfText, mfSig, keyId);
        break;
      } catch (err) {
        lastErr = err;
      }
    }
    if (!parsed) throw new Error(`离线包清单验签失败: ${(lastErr as Error)?.message ?? ''}`);
    if (parsed.version !== server.version) {
      throw new Error(`离线包版本不一致：update.json=${server.version} manifest=${parsed.version}`);
    }

    const targetId = versionId(server.version);
    const staging = path.join(this.versionsDir, `.staging-${targetId}`);
    fs.rmSync(staging, { recursive: true, force: true });
    const assembled = assembleVersion({
      // 离线包是完整目录，不需要基线
      baselineDir: null,
      targetDir: staging,
      payloadDir: filesDir,
      files: parsed.files,
      manifestText: mfText,
      manifestSig: mfSig,
    });
    const verify = verifyTree(staging, parsed.files);
    if (!verify.ok) {
      fs.rmSync(staging, { recursive: true, force: true });
      throw new Error(`离线包校验失败: ${verify.errors.slice(0, 3).join('; ')}`);
    }
    this.writeVersionMeta(staging, server.semver, server.version);
    const dest = path.join(this.versionsDir, targetId);
    fs.rmSync(dest, { recursive: true, force: true });
    fs.renameSync(staging, dest);
    await this.opts.beforeActivate?.(targetId);
    const up = new Updater(this.dataDir);
    up.activate(server.version, { forceDowngrade: true });
    writeBoot(this.dataDir, { id: targetId, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
    return { targetId, files: assembled.files };
  }

  /** 扫描 inbox，列出可导入的离线包（目录形态） */
  listOffline(): { name: string; size: number; mtime: number }[] {
    const inbox = path.join(this.updateDir, 'inbox');
    try {
      return fs
        .readdirSync(inbox, { withFileTypes: true })
        .filter((e) => e.isDirectory() && fs.existsSync(path.join(inbox, e.name, 'update.json')))
        .map((e) => {
          const abs = path.join(inbox, e.name);
          return { name: e.name, size: dirSize(abs), mtime: fs.statSync(abs).mtimeMs };
        });
    } catch {
      return [];
    }
  }

  /** 缓存占用（设置页「清理」用） */
  cacheUsage(): { bytes: number; files: number } {
    const bytes = dirSize(this.cacheDir) + dirSize(this.assetDir);
    const files = countFiles(this.cacheDir) + countFiles(this.assetDir);
    return { bytes, files };
  }

  clearCache(): { bytes: number; files: number } {
    const before = this.cacheUsage();
    fs.rmSync(this.cacheDir, { recursive: true, force: true });
    fs.rmSync(this.assetDir, { recursive: true, force: true });
    return before;
  }

  /**
   * 把客户端资产下载到本地缓存（客户端来要时走局域网满速）。
   * 失败不算错：公网 URL 仍然可用，只是慢一点。
   */
  async cacheClientAsset(ref: AssetRef): Promise<string | null> {
    const existing = this.cachedAssetPath(ref.sha256);
    if (existing) return existing;
    const name = (ref.urls[0] || '').split('/').pop() || `asset-${ref.sha256.slice(0, 8)}`;
    const dest = path.join(this.assetDir, `${ref.sha256.slice(0, 16)}-${name}`);
    try {
      await downloadAsset({
        urls: ref.urls,
        dest,
        size: ref.size,
        sha256: ref.sha256,
        br: ref.br,
        memo: this.memo,
        memoKey: ref.sha256,
      });
      return dest;
    } catch (err) {
      this.log('asset cache failed', { name, err: (err as Error).message });
      return null;
    }
  }

  /**
   * 预取客户端安装包到本机缓存。
   *
   * 目的：客户端下次来问时，`urls` 的第一条就是局域网地址 —— 内网满速、
   * 不消耗公网流量。失败完全无害（公网 URL 仍然可用），所以静默吞掉错误。
   */
  private readonly prefetching = new Set<string>();

  async prefetchClientAsset(component: 'client_pc' | 'client_android'): Promise<void> {
    try {
      const m = await this.loadManifest({});
      const c = m.components[component];
      if (!c) return;
      const refs = Object.values(c.assets ?? {});
      for (const ref of refs.slice(0, 1)) {
        if (!ref || !ref.urls?.length) continue;
        if (this.cachedAssetPath(ref.sha256)) continue;
        // 同一份资产并发预取会各下一遍（多端同时登录很常见）
        if (this.prefetching.has(ref.sha256)) continue;
        this.prefetching.add(ref.sha256);
        try {
          await this.cacheClientAsset(ref);
        } finally {
          this.prefetching.delete(ref.sha256);
        }
      }
    } catch {
      /* 预取失败不影响任何功能 */
    }
  }

}

function deltaBytes(delta: DeltaRef): number {
  const files = delta.files.reduce((s, f) => s + (f.br?.size ?? f.size), 0);
  const bundles = delta.bundles.reduce((s, b) => s + b.size, 0);
  return files + bundles;
}

function countFiles(dir: string): number {
  let n = 0;
  try {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) n += countFiles(path.join(dir, e.name));
      else n += 1;
    }
  } catch {
    return n;
  }
  return n;
}

/** 递归列目录内文件（POSIX 分隔符，与清单口径一致） */
function listRelFiles(dir: string, rel = ''): string[] {
  const out: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(path.join(dir, rel), { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const child = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...listRelFiles(dir, child));
    else if (e.isFile()) out.push(child);
  }
  return out;
}
/** 数据目录所在卷剩余空间（拿不到返 0，不做拦截） */
export function freeSpace(dir: string): number {
  try {
    const st = fs.statfsSync(dir);
    return Number(st.bavail) * Number(st.bsize);
  } catch {
    return 0;
  }
}

/**
 * 首次启动的「拆壳播种」：把安装目录里的内核/Web 落成一个版本目录。
 *
 * 没有这一步，已装的老版本永远只会走全量 —— 因为它们根本没有 `versions/`。
 * 播种出来的目录不带 manifest（文件来自本次安装，已被信任），第一次增量更新时
 * 会用**网络清单**做全量校验，该有的保证一点不少。
 */
export function seedVersionDir(opts: {
  versionsDir: string;
  seed: {
    kernelDir: string;
    /**
     * **必须**有：`kernel/modules.ts` 编译后是 `require("../src/modules/…")`，
     * 少这一份，版本目录里的内核一启动就 MODULE_NOT_FOUND。
     */
    srcDir: string;
    electronHost: string;
    webDir: string | null;
    contractsDir: string | null;
    sidecarsDir: string | null;
  };
  semver: string;
  version: number;
}): { id: string; files: number } | null {
  const id = versionId(opts.version);
  const dest = path.join(opts.versionsDir, id);
  if (fs.existsSync(path.join(dest, 'version.json'))) return null;

  fs.mkdirSync(dest, { recursive: true });
  let files = 0;
  /**
   * 逐文件复制（不用 `fs.cpSync`）：播种的源在打包态位于 `app.asar` 内，
   * 走 Node 的 `readFileSync` / `writeFileSync` 才能被 Electron 的 asar 补丁接管。
   */
  const copyDir = (src: string | null, rel: string): void => {
    if (!src || !fs.existsSync(src)) return;
    const walk = (from: string, to: string): void => {
      fs.mkdirSync(to, { recursive: true });
      for (const e of fs.readdirSync(from, { withFileTypes: true })) {
        const a = path.join(from, e.name);
        const b = path.join(to, e.name);
        if (e.isDirectory()) walk(a, b);
        else if (e.isFile()) {
          fs.writeFileSync(b, fs.readFileSync(a));
          files += 1;
        }
      }
    };
    walk(src, path.join(dest, rel));
  };

  copyDir(opts.seed.kernelDir, 'kernel');
  copyDir(opts.seed.srcDir, 'src');
  copyDir(opts.seed.webDir, 'web');
  copyDir(opts.seed.contractsDir, 'contracts');
  copyDir(opts.seed.sidecarsDir, 'sidecars');
  fs.mkdirSync(path.join(dest, 'electron'), { recursive: true });
  if (fs.existsSync(opts.seed.electronHost)) {
    fs.copyFileSync(opts.seed.electronHost, path.join(dest, 'electron', 'kernel-host.js'));
    files += 1;
  }
  writeJsonAtomic(path.join(dest, 'version.json'), {
    semver: opts.semver,
    version: opts.version,
    buildNumber: opts.version % 100,
    versionCode: opts.version,
  });
  // 指针只在不存时才写：已有 current.json 说明是升级后的正常启动
  const ptr = path.join(opts.versionsDir, 'current.json');
  if (!fs.existsSync(ptr)) writeJsonAtomic(ptr, { id, at: Date.now() });
  return { id, files };
}

/** 彻底移除一个版本目录（保留当前与上一版，其余按需清理） */
export function pruneVersions(versionsDir: string, keep = 2): string[] {
  const up = new Updater(path.dirname(versionsDir));
  const all = up.list();
  const cur = up.current();
  const removed: string[] = [];
  const keepIds = new Set<string>();
  if (cur) keepIds.add(cur.id);
  // 保留版本号最大的 keep 个（回滚只需要上一版）
  for (const v of [...all].reverse()) {
    if (keepIds.size >= keep && cur && !keepIds.has(v.id)) break;
    keepIds.add(v.id);
  }
  for (const v of all) {
    if (keepIds.has(v.id)) continue;
    try {
      fs.rmSync(v.dir, { recursive: true, force: true });
      removed.push(v.id);
    } catch {
      /* 占用中：下次再清 */
    }
  }
  return removed;
}

export { DownloadError } from './downloader';
export { UpdateVerifyError } from './verify';
export type { AssetRef, ComponentId, UpdateManifest };

/**
 * PowerShell 的 `-Command` 要和 cmd 的引号规则打架，路径里还有空格和中文。
 * 一律编码成 base64（UTF-16LE）走 `-EncodedCommand`，绕开所有转义问题。
 */
function encodePowershell(script: string): string {
  return Buffer.from(script, 'utf16le').toString('base64');
}

/** 是不是一个真的 PE 可执行文件（安装包开头必须是 `MZ`） */
function isWindowsExecutable(file: string): boolean {
  try {
    const fd = fs.openSync(file, 'r');
    const head = Buffer.alloc(2);
    fs.readSync(fd, head, 0, 2, 0);
    fs.closeSync(fd);
    return head.toString('latin1') === 'MZ';
  } catch {
    return false;
  }
}
