import { createLimiter, runFfprobe } from '../media/ffmpeg-run';
import { extensionOf, isImageFile, isVideoFile, mimeOf, readImageMeta, type ImageMeta } from './exif';
import { findPairedVideo } from './live-photo';

/**
 * 相册的媒体元数据入口：图片走零依赖的 EXIF 解析，视频交给 ffprobe。
 *
 * 为什么不把视频也塞进 exif.ts：那个文件是「零依赖、只读文件头」的，
 * 扫描 1.9 万张图时每个文件多起一次进程会把扫描拖到不可用。
 * 视频只有一千多个，逐个 ffprobe（约 70ms）可以接受。
 */

/** 同时最多 4 个 ffprobe，别把扫描期的 CPU 占满 */
const withProbeSlot = createLimiter(4);

/**
 * 媒体解析逻辑的版本号，写进 photo_items.media_ver。
 * 改动解析口径（新增 live_kind 判定、加扩展名等）就 +1，升级后第一次扫描
 * 会自动把版本落后的行重读一遍。
 */
export const MEDIA_VER = 2;

interface ProbeStream {
  codec_type?: string;
  width?: number;
  height?: number;
  duration?: string;
  tags?: Record<string, string>;
  side_data_list?: Array<{ rotation?: number; side_data_type?: string }>;
}

interface ProbeFormat {
  duration?: string;
  tags?: Record<string, string>;
}

export async function readMediaMeta(
  abs: string,
  size: number,
  paired?: { path: string; size: number } | null,
): Promise<ImageMeta> {
  if (isVideoFile(abs)) return readVideoMeta(abs);
  const meta = await readImageMeta(abs, size);
  // 双文件配对（Live Photo / 鸿蒙双资源资产）：同目录同名视频躺在旁边。
  // exif.ts 只管文件头，不做目录探测；paired 由扫描器预收集后传入，避免重复 readdir。
  if (!meta.liveKind && isImageFile(abs)) {
    const hit = paired === undefined ? await findPairedVideo(abs) : paired;
    if (hit) {
      meta.liveKind = 'apple';
      meta.liveSize = hit.size;
      meta.livePath = hit.path;
    }
  }
  return meta;
}

async function readVideoMeta(abs: string): Promise<ImageMeta> {
  let width: number | null = null;
  let height: number | null = null;
  let durationMs: number | null = null;
  let takenAt: number | null = null;

  let stdout = '';
  try {
    const probe = await withProbeSlot(() =>
      runFfprobe(
        [
          '-v',
          'error',
          '-print_format',
          'json',
          '-show_format',
          '-show_streams',
          '-select_streams',
          'v:0',
          abs,
        ],
        20_000,
      ),
    );
    stdout = probe.stdout;
  } catch {
    // 坏文件 / 不认识的容器：保持空串，照样入库，只是没有宽高时长
    // （不能因此中断整次扫描）
  }
  if (stdout) {
    try {
      const j = JSON.parse(stdout) as { streams?: ProbeStream[]; format?: ProbeFormat };
      const s = j.streams?.[0];
      if (s) {
        width = typeof s.width === 'number' ? s.width : null;
        height = typeof s.height === 'number' ? s.height : null;
        // 竖屏视频常带 90/270 旋转标记，不换宽高的话网格里会当成横的
        const rot = rotationOf(s);
        if (rot === 90 || rot === 270) [width, height] = [height, width];
      }
      const dur = Number(s?.duration ?? j.format?.duration);
      if (Number.isFinite(dur) && dur > 0) durationMs = Math.round(dur * 1000);
      const ct = j.format?.tags?.creation_time ?? s?.tags?.creation_time;
      if (ct) {
        const t = Date.parse(ct);
        if (Number.isFinite(t)) takenAt = Math.floor(t / 1000);
      }
    } catch {
      /* 解析失败就退化成「只有路径和 mtime」 */
    }
  }

  return {
    width,
    height,
    takenAt,
    mime: mimeOf(abs),
    latitude: null,
    longitude: null,
    camera: null,
    make: null,
    lens: null,
    software: null,
    orientation: null,
    iso: null,
    fNumber: null,
    exposureTime: null,
    focalLength: null,
    mediaKind: 'video',
    durationMs,
    liveKind: '',
    liveSize: null,
    liveOffset: null,
    liveVendor: '',
    livePath: '',
  };
}

function rotationOf(s: ProbeStream): number {
  const direct = Number(s.tags?.rotate);
  if (Number.isFinite(direct) && direct !== 0) return Math.abs(direct) % 360;
  for (const d of s.side_data_list ?? []) {
    if (typeof d.rotation === 'number' && d.rotation !== 0) return Math.abs(d.rotation) % 360;
  }
  return 0;
}

/** 供别处判断「这个相对路径是不是视频」用（缩略图 / 播放器） */
export function mediaKindOfPath(rel: string): 'image' | 'video' {
  return isVideoFile(extensionOf(rel)) ? 'video' : 'image';
}
