import fs from 'node:fs';
import path from 'node:path';
import { SidecarSupervisor } from './supervisor';

/**
 * media sidecar 桥（缩略图 / 转码）：
 * 内核不再自己 spawn ffmpeg，而是**按需**拉起 `sidecars/media/main.js`，
 * 之后复用同一进程（心跳 + 僵死重启由 supervisor 负责）。
 *
 * 只有真正有请求时才启动，所以纯 API 的启动耗时不受影响；
 * 关闭内核时由 {@link MediaBridge.stop} 收尾，避免残留子进程。
 */

const FFMPEG_EXE = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';

/**
 * 安装版资源根 `resources/` 下的候选路径。
 *
 * 只有 Electron 进程有 `process.resourcesPath`；纯 node（tsx 调试 / 冒烟脚本）
 * 返回空数组，候选列表自然只剩仓库内路径。装机版把 ffmpeg 与 sidecars 放在
 * `resources/` 下（见 electron-builder.js 的 extraResources），必须显式认这条路，
 * 否则 `available()` 恒 false、所有 `?size=` 缩略图 503。
 */
function resourcePaths(...segments: string[]): string[] {
  const root = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
  return root ? [path.join(root, ...segments)] : [];
}

export class MediaUnavailableError extends Error {
  readonly code = 'E_MEDIA_UNAVAILABLE';

  constructor(message: string) {
    super(message);
    this.name = 'MediaUnavailableError';
  }
}

export interface MediaBridgeOptions {
  /** sidecar 脚本路径（默认按仓库布局 / `COLANAS_MEDIA_SIDECAR` 探测） */
  script?: string;
  /** ffmpeg 绝对路径（默认取 `COLANAS_FFMPEG` 或 `vendor/ffmpeg`） */
  ffmpeg?: string;
  requestTimeoutMs?: number;
  log?: (level: 'debug' | 'info' | 'warn' | 'error', message: string) => void;
}

export interface ThumbResult {
  ms: number;
}

export interface TranscodeResult {
  ms: number;
  reused: boolean;
}

export interface HlsResult {
  segments: number;
  ms: number;
  /** 本段实际产出时长（毫秒）：分段续转时用来推进下一段的起点 */
  durationMs: number;
  /** 实际使用的视频编码（h264 / h265 / av1）；转码降级后以这里为准 */
  codec?: string;
  /** mpegts | fmp4 */
  container?: string;
}

/** 容器内的字幕轨（按 ffmpeg 流信息解析） */
export interface SubtitleTrackInfo {
  /** 第几条字幕流（`-map 0:s:<index>`） */
  index: number;
  lang: string | null;
  codec: string;
  /** 文本字幕（可直接转 WebVTT / SRT）；图形字幕为 false */
  text: boolean;
}

export class MediaBridge {
  private sup: SidecarSupervisor | null = null;
  private starting: Promise<SidecarSupervisor> | null = null;
  private closed = false;

  constructor(private readonly opts: MediaBridgeOptions = {}) {}

  /** 已启动时的进程状态；未启动为 `stopped` */
  get state(): string {
    return this.sup?.state ?? 'stopped';
  }

  /** sidecar 进程号（未启动为 undefined） */
  get pid(): number | undefined {
    return this.sup?.pid;
  }

  /** 依赖是否具备（脚本 + ffmpeg）。不具备时调用方直接降级，不要抛错 */
  available(): boolean {
    if (this.closed) return false;
    if (process.env.COLANAS_MEDIA_SIDECAR_DISABLED === '1') return false;
    return Boolean(this.scriptPath() && this.ffmpegPath());
  }

  /** 生成缩略图：`src` 原文件 → `dst` 目标 JPEG；视频可用 `atSec` 指定抽帧位置 */
  async thumb(src: string, dst: string, size = 256, atSec = 0): Promise<ThumbResult> {
    const sup = await this.ensure();
    const res = await sup.request<{ dst: string; ms: number }>('thumb', {
      src,
      dst,
      size,
      ...(atSec > 0 ? { at: atSec } : {}),
    });
    return { ms: res.ms };
  }

  /**
   * 转码：`preset` = `audio`（AAC 192k）/ `web720`（H.264 720p）/ `copy`（只转封装）。
   * `options` 为参数化编码（mode/format/vcodec/resolution/bitrate/fps/threads…），
   * 同一 (src,dst,preset,options) 的并发请求由 sidecar 合并，后到者拿 `reused: true`。
   */
  async transcode(
    src: string,
    dst: string,
    preset = 'copy',
    options?: Record<string, unknown>,
  ): Promise<TranscodeResult> {
    const sup = await this.ensure();
    const res = await sup.request<{ dst: string; ms: number; reused?: boolean }>('transcode', {
      src,
      dst,
      preset,
      ...(options ? { options } : {}),
    });
    return { ms: res.ms, reused: res.reused === true };
  }

  /**
   * HLS 转码：在 `dir` 下产出 `index.m3u8` + `seg%05d.ts`（6 s 一片）。
   * `subtitle` 传入外挂字幕绝对路径时用 `subtitles` 滤镜**烧录**进画面。
   */
  async hls(
    src: string,
    dir: string,
    opts: {
      preset?: string;
      codec?: string;
      subtitle?: string;
      audioFilter?: string;
      timeoutMs?: number;
      /** 选第几条音轨转码（默认 0） */
      audioIndex?: number;
      /** 强制/自动 HDR→SDR 色彩转换 */
      hdrToSdr?: boolean;
      /** 片源视频编码（h264 / hevc / av1）：决定「原画」能否直接 copy */
      srcVideoCodec?: string;
      /** 分段续转：从片源第 seekMs 毫秒起转，只转 limitMs 毫秒（0 = 整片） */
      seekMs?: number;
      limitMs?: number;
    } = {},
  ): Promise<HlsResult> {
    const sup = await this.ensure();
    // HLS 转码要跑一次完整编码：默认 60 s 的 RPC 超时不够，这里给 30 分钟
    const timeoutMs = opts.timeoutMs ?? 30 * 60 * 1000;
    const res = await sup.request<{
      segments: number;
      ms: number;
      durationMs: number;
      codec?: string;
      container?: string;
    }>('hls', { src, dir, ...opts }, timeoutMs);
    return {
      segments: res.segments,
      ms: res.ms,
      durationMs: Number(res.durationMs) || 0,
      codec: res.codec,
      container: res.container,
    };
  }

  /**
   * 取消某个会话目录下正在跑的 HLS 转码。
   * 用于「用户换档 / 重新点播放」时抢占旧会话，避免一条转不动的片把队列堵死。
   */
  async cancel(dir: string): Promise<boolean> {
    if (!this.sup) return false;
    try {
      const res = await this.sup.request<{ canceled?: boolean }>('cancel', { dir }, 5_000);
      return res?.canceled === true;
    } catch {
      return false;
    }
  }

  /** 列出容器内字幕轨；文件不可解析时返回空数组（不抛错，调用方按「没有」处理） */
  async subtitleTracks(src: string): Promise<SubtitleTrackInfo[]> {
    const sup = await this.ensure();
    try {
      const res = await sup.request<{ tracks?: SubtitleTrackInfo[] }>('subtitleTracks', { src }, 30_000);
      return Array.isArray(res?.tracks) ? res.tracks : [];
    } catch {
      return [];
    }
  }

  /** 抽取一条字幕轨到 `dst`（默认 srt）；图形字幕 / 轨道不存在时抛错 */
  async extractSubtitle(src: string, index: number, dst: string, format = 'srt'): Promise<void> {
    const sup = await this.ensure();
    await sup.request('extractSubtitle', { src, index, dst, format }, 120_000);
  }

  async stop(): Promise<void> {
    this.closed = true;
    const sup = this.sup;
    this.sup = null;
    if (sup) await sup.stop();
  }

  // ---------------------------------------------------------------- 内部

  private scriptPath(): string | null {
    if (this.opts.script) return fs.existsSync(this.opts.script) ? this.opts.script : null;

    const env = process.env.COLANAS_MEDIA_SIDECAR;
    if (env && env.trim()) {
      return fs.existsSync(env.trim()) ? env.trim() : null;
    }

    // dist/kernel/sidecar → 仓库根；tsx 直跑 src 时同样是两跳。
    // 安装版里 sidecar 由 electron-builder 送到 `resources/sidecars`（在 asar 外），
    // 既不在 __dirname 的相对路径上、也不在 cwd 下 —— 漏了它就会「装机版缩略图全 503」。
    const candidates = [
      path.join(__dirname, '..', '..', 'sidecars', 'media', 'main.js'),
      path.join(process.cwd(), 'sidecars', 'media', 'main.js'),
      ...resourcePaths('sidecars', 'media', 'main.js'),
    ];
    return candidates.find((p) => fs.existsSync(p)) ?? null;
  }

  private ffmpegPath(): string | null {
    if (this.opts.ffmpeg) return fs.existsSync(this.opts.ffmpeg) ? this.opts.ffmpeg : null;

    const env = process.env.COLANAS_FFMPEG;
    // 环境变量可能指向不存在的路径（换机器 / 手滑），存在性检查通过再认，
    // 否则不如让下面的候选继续找。
    if (env && env.trim() && fs.existsSync(env.trim())) return env.trim();

    const vendor = path.join(process.cwd(), 'vendor', 'ffmpeg');
    const candidates = [
      path.join(vendor, FFMPEG_EXE),
      path.join(vendor, 'bin', FFMPEG_EXE),
      ...resourcePaths('ffmpeg', FFMPEG_EXE),
      ...resourcePaths('ffmpeg', 'bin', FFMPEG_EXE),
    ];
    return candidates.find((p) => fs.existsSync(p)) ?? null;
  }

  private async ensure(): Promise<SidecarSupervisor> {
    if (this.closed) throw new MediaUnavailableError('media sidecar 已停止');
    if (this.sup?.state === 'ready') return this.sup;
    if (this.starting) return this.starting;

    if (process.env.COLANAS_MEDIA_SIDECAR_DISABLED === '1') {
      throw new MediaUnavailableError('media sidecar 已被 COLANAS_MEDIA_SIDECAR_DISABLED=1 关闭');
    }
    const script = this.scriptPath();
    if (!script)
      throw new MediaUnavailableError('未找到 media sidecar 脚本（sidecars/media/main.js）');
    const ffmpeg = this.ffmpegPath();
    if (!ffmpeg) {
      throw new MediaUnavailableError(
        '未找到 ffmpeg（设置 COLANAS_FFMPEG 或 npm run ffmpeg:fetch）',
      );
    }

    const env: Record<string, string> = { COLANAS_FFMPEG: ffmpeg };
    // Electron 主进程的 execPath 是 electron 本体，需要该变量才按 node 跑脚本
    if (process.versions.electron && !process.env.COLANAS_SIDECAR_NODE) {
      env.ELECTRON_RUN_AS_NODE = '1';
    }

    this.starting = (async () => {
      const sup = new SidecarSupervisor({
        name: 'media',
        command: process.env.COLANAS_SIDECAR_NODE || process.execPath,
        args: [script],
        env,
        requestTimeoutMs: this.opts.requestTimeoutMs ?? 60_000,
        heartbeatMs: 10_000,
        maxRestarts: 2,
        startTimeoutMs: 15_000,
        stopGraceMs: 3_000,
        log: (level, message) => (this.opts.log ? this.opts.log(level, message) : undefined),
      });
      await sup.start();
      if (this.closed) {
        await sup.stop();
        throw new MediaUnavailableError('media sidecar 已停止');
      }
      this.sup = sup;
      return sup;
    })();

    try {
      return await this.starting;
    } finally {
      this.starting = null;
    }
  }
}
