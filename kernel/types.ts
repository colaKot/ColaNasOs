import type { FastifyInstance } from 'fastify';
import type { ConfigStore } from './config';
import type { EventBus } from './bus';
import type { FsBatch, WatchOptions, WatchStats } from './fs-watch';
import type { PollOptions, PollStats } from './poll';
import type { TaskHandler } from './queue';
import type { ScanResult } from './sidecar/indexer-service';
import type { BridgeStats } from './sidecar/indexer-bridge';
import type { I18nRegistry } from './i18n';
import type { ContractRegistry } from './contract';
import type { Migration } from './migrator';
import type { TokenPayload } from './auth';

/** 缓存命中快照（`GET /api/v1/system/cache/stats` 的条目） */
export interface CacheSnapshotItem {
  /** 计数器名，约定 `<域>.<对象>`：files.thumb / book.cover / music.cover */
  name: string;
  hits: number;
  misses: number;
  /** 命中率 0~1（保留 3 位小数）；总数为 0 时为 0 */
  hitRate: number;
}

/** 内核暴露给模块的能力（语义化版本 v1） */
export interface KernelApi {
  db: any;
  log: any;
  events: EventBus;
  tasks: {
    enqueue(
      type: string,
      payload?: unknown,
      opts?: { priority?: number; maxAttempts?: number },
    ): Promise<string>;
    /** 同类型 + 同 payload 已有 pending/running 时复用（避免扫描风暴堆任务） */
    enqueueIfIdle(
      type: string,
      payload?: unknown,
      opts?: { priority?: number; maxAttempts?: number },
    ): Promise<{ id: string; reused: boolean }>;
    /** 注册任务处理器；同名重复注册直接抛错（启动期暴露，而不是运行期静默丢任务） */
    register(type: string, handler: TaskHandler): void;
    registered(): string[];
    stats(): Promise<Record<string, number>>;
  };
  config: ConfigStore;
  i18n: I18nRegistry;
  contract: ContractRegistry;
  /** 内核路径约定（数据目录等），供模块存放临时文件 */
  paths: { dataDir: string };
  /**
   * 缓存命中计数（**只测量，不定策略**）：handler 判断缓存文件在不在时调用 `record(name, hit)`，
   * `snapshot()` 供 `GET /api/v1/system/cache/stats` 读；进程内累加，重启清零。
   */
  cache: {
    record(name: string, hit: boolean): void;
    snapshot(): CacheSnapshotItem[];
    /** 清空进程内命中计数（设置页「清缓存」） */
    reset(): void;
  };
  /**
   * 媒体能力：经 media sidecar 生成缩略图 / 转码。
   * `available()` 为 false 表示本机缺 ffmpeg 或 sidecar 脚本，调用方应降级而不是报错；
   * `thumb()` 在不可用或生成失败时抛错（`MediaUnavailableError.code = 'E_MEDIA_UNAVAILABLE'`）。
   */
  media: {
    /**
     * `atSec` 只对视频有意义：从第几秒抽帧当封面（缺省 0 = 首帧）。
     * 相册里长视频的首帧常是黑屏，海报图要指定位置。
     */
    thumb(src: string, dst: string, size?: number, atSec?: number): Promise<{ ms: number }>;
    /** 转码：`preset` = audio / web720 / copy（缺省 copy）；`options` 为参数化编码 */
    transcode(
      src: string,
      dst: string,
      preset?: string,
      options?: Record<string, unknown>,
    ): Promise<{ ms: number; reused: boolean }>;
    /** HLS 转码会话：`dir` 下产出 index.m3u8 + 分片；`subtitle` 为字幕绝对路径（烧录） */
    hls(
      src: string,
      dir: string,
      opts?: {
        preset?: string;
        codec?: string;
        subtitle?: string;
        /** 音频滤镜（如 dynaudnorm）；库级「响度归一」开关决定是否传 */
        audioFilter?: string;
        /** 首选硬件编码器：auto / nvenc / qsv / amf / cpu（影视设置的「首选解码器」） */
        hwaccel?: string;
        /** 选第几条音轨转码（默认 0） */
        audioIndex?: number;
        /** 强制 / 自动 HDR→SDR 色彩转换 */
        hdrToSdr?: boolean;
        /** 片源视频编码（h264 / hevc / av1）：决定「原画」能否直接 copy */
        srcVideoCodec?: string;
        /** 分段续转：从片源第 seekMs 毫秒起转，只转 limitMs 毫秒（0 = 整片） */
        seekMs?: number;
        limitMs?: number;
        timeoutMs?: number;
      },
    ): Promise<{
      segments: number;
      ms: number;
      /** 本段实际产出时长（毫秒） */
      durationMs: number;
      codec?: string;
      container?: string;
      /** 实际用的编码器 / 解码链路（排障日志） */
      encoder?: string;
      decoder?: string;
      pipeline?: string;
      /** 硬件链路所属厂商：amd / nvidia / intel / cpu */
      vendor?: string;
      /** 探测到的片源能力，用于确认 DV / Hi10P 是否走了正确链路 */
      source?: {
        codec?: string;
        pixFmt?: string;
        dvProfile?: number;
        hi10p?: boolean;
        hdrKind?: string;
        hasHdrMeta?: boolean;
      };
    }>;
    /** 取消某个目录下正在跑的 HLS 转码（新会话抢占旧会话时用）；未在跑返回 false */
    cancel(dir: string): Promise<boolean>;
    /** 列出容器内字幕轨（文本 / 图形都返回，`text` 标记能否转字幕文件） */
    subtitleTracks(src: string): Promise<
      Array<{ index: number; lang: string | null; codec: string; text: boolean }>
    >;
    /** 抽取一条字幕轨到 `dst`（默认 srt）；图形字幕 / 轨道不存在时抛错 */
    extractSubtitle(src: string, index: number, dst: string, format?: string): Promise<void>;
    available(): boolean;
  };
  /** 认证：用内核同一 secret 签发 token（模块登录用） */
  auth: {
    sign(payload: { sub: string; scopes: string[] }, ttlSec?: number): string;
  };
  /**
   * 文件监控（蓝图 §56）：已去抖合批，handler 串行执行。
   * 同一 root 共享底层 watcher（引用计数），返回的函数用于退订。
   */
  /** 索引器（蓝图 §8/§9）：按需拉起 sidecar，批次落 files_meta，断点续传 */
  indexer: {
    scan(root: string): Promise<ScanResult>;
    stats(): BridgeStats;
    readonly running: boolean;
  };
  watch: {
    subscribe(
      root: string,
      handler: (batch: FsBatch) => void | Promise<void>,
      opts?: WatchOptions,
    ): () => void;
    stats(): WatchStats;
  };
  /**
   * 远程目录轮询（蓝图 §56）：SMB / WebDAV / rclone 没有可靠事件，
   * 按周期取快照做 `mtime + size` 比对，产出与 `watch` 同构的批次。
   */
  poll: {
    subscribe(
      root: string,
      handler: (batch: FsBatch) => void | Promise<void>,
      opts?: PollOptions,
    ): () => void;
    stats(): PollStats;
  };
}

/** 域模块描述符（约定式，非插件） */
export interface ServerModule {
  id: string;
  prefix: string;
  /** 依赖的模块 id（只允许"上游依赖下游"，禁止反向与环形） */
  dependsOn?: string[];
  permissions?: string[];
  /** 该模块的迁移，按 id 排序由内核统一执行 */
  migrations?: Migration[];
  register(app: FastifyInstance, k: KernelApi): Promise<void> | void;
}

/** Fastify 请求上的认证用户 */
export type AuthUser = TokenPayload;

declare module 'fastify' {
  interface FastifyRequest {
    user?: AuthUser;
  }
  interface FastifyContextConfig {
    /** 该路由要求的 scope；缺省表示公开路由 */
    scope?: string;
    /** 路径级 ACL 所需的权限：设置后对该请求的 path 参数做 `checkPathAccess` */
    pathScope?: 'read' | 'write';
  }
}
