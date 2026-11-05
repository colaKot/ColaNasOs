import fs from 'node:fs/promises';

/**
 * 最小图片元数据读取（零依赖）：
 *   - JPEG：APP1 Exif 的 DateTimeOriginal（0x9003）/ DateTimeDigitized（0x9004）+ SOF 宽高
 *   - PNG：IHDR 宽高
 *   - 兜底：从文件名解析日期（IMG_20240102_123456 / 2024-01-02 12.34.56）
 *
 * 只读文件头部（256 KB 上限），不加载整图，避免扫描时把相册拖慢。
 */
export interface ImageMeta {
  width: number | null;
  height: number | null;
  /** 拍摄时间（epoch 秒）；无 EXIF 且文件名无日期时为 null，由调用方回落到 mtime */
  takenAt: number | null;
  mime: string;
  /** GPS 纬度（WGS-84）；无 GPS 或非 JPEG 时为 null */
  latitude: number | null;
  /** GPS 经度（WGS-84） */
  longitude: number | null;
  /** 相机型号（EXIF Model），用于年度报告 */
  camera: string | null;
  /** 品牌（EXIF Make） */
  make: string | null;
  /** 镜头型号（EXIF LensModel） */
  lens: string | null;
  /** 后期软件（EXIF Software） */
  software: string | null;
  /** 方向（EXIF Orientation，1~8） */
  orientation: number | null;
  /** ISO 感光度 */
  iso: number | null;
  /** 光圈 F 值（如 2.8） */
  fNumber: number | null;
  /** 快门时间（秒，如 1/125 会得到 0.008） */
  exposureTime: number | null;
  /** 焦距（毫米） */
  focalLength: number | null;
}

const HEAD_BYTES = 256 * 1024;

const MIME_BY_EXT: Record<string, string> = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  gif: 'image/gif',
  webp: 'image/webp',
  bmp: 'image/bmp',
  tif: 'image/tiff',
  tiff: 'image/tiff',
  heic: 'image/heic',
  heif: 'image/heif',
  avif: 'image/avif',
};

export const IMAGE_EXTENSIONS = new Set(Object.keys(MIME_BY_EXT));

export function extensionOf(file: string): string {
  const base = file.split(/[\\/]/).pop() || '';
  const idx = base.lastIndexOf('.');
  return idx < 0 ? '' : base.slice(idx + 1).toLowerCase();
}

export function isImageFile(file: string): boolean {
  return IMAGE_EXTENSIONS.has(extensionOf(file));
}

export function mimeOf(file: string): string {
  return MIME_BY_EXT[extensionOf(file)] || 'application/octet-stream';
}

function parseExifDate(text: string): number | null {
  const m = /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(text.trim());
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const h = Number(m[4]);
  const mi = Number(m[5]);
  const s = Number(m[6]);
  const date = new Date(y, mo - 1, d, h, mi, s);
  if (Number.isNaN(date.getTime())) return null;
  return Math.floor(date.getTime() / 1000);
}

interface TiffView {
  little: boolean;
  u16(p: number): number;
  u32(p: number): number;
}

function tiffView(buf: Buffer, tiffStart: number): TiffView | null {
  if (tiffStart + 8 > buf.length) return null;
  const order = buf.toString('latin1', tiffStart, tiffStart + 2);
  if (order !== 'II' && order !== 'MM') return null;
  const little = order === 'II';
  return {
    little,
    u16: (p: number) => (little ? buf.readUInt16LE(p) : buf.readUInt16BE(p)),
    u32: (p: number) => (little ? buf.readUInt32LE(p) : buf.readUInt32BE(p)),
  };
}

function asciiValue(buf: Buffer, v: TiffView, entry: number, tiffStart: number): string {
  const count = v.u32(entry + 4);
  if (count <= 0) return '';
  const start = count <= 4 ? entry + 8 : tiffStart + v.u32(entry + 8);
  if (start < 0 || start + count > buf.length) return '';
  return buf
    .toString('latin1', start, start + count)
    .replace(/\0+$/, '')
    .trim();
}

function rationalAt(buf: Buffer, v: TiffView, offset: number): number {
  if (offset < 0 || offset + 8 > buf.length) return 0;
  const num = v.u32(offset);
  const den = v.u32(offset + 4);
  return den === 0 ? 0 : num / den;
}

/** 度分秒 → 十进制度 */
function dmsToDeg(buf: Buffer, v: TiffView, entry: number, tiffStart: number): number | null {
  const count = v.u32(entry + 4);
  if (count < 3) return null;
  const base = tiffStart + v.u32(entry + 8);
  const deg = rationalAt(buf, v, base);
  const min = rationalAt(buf, v, base + 8);
  const sec = rationalAt(buf, v, base + 16);
  if (!Number.isFinite(deg) || !Number.isFinite(min) || !Number.isFinite(sec)) return null;
  const value = deg + min / 60 + sec / 3600;
  if (!Number.isFinite(value) || value < 0) return null;
  return value;
}

/**
 * 读 GPS IFD 的经纬度。
 * 经纬度各占 3 个 RATIONAL（度/分/秒），并按 Ref 标签（N/S、E/W）取符号。
 */
function readTiffGps(
  buf: Buffer,
  tiffStart: number,
  ifd0Offset: number,
): { latitude: number; longitude: number } | null {
  const v = tiffView(buf, tiffStart);
  if (!v) return null;
  const ifd0 = tiffStart + ifd0Offset;
  if (ifd0 + 2 > buf.length) return null;

  let gpsIfd = 0;
  const ifd0Count = v.u16(ifd0);
  for (let i = 0; i < ifd0Count; i += 1) {
    const entry = ifd0 + 2 + i * 12;
    if (entry + 12 > buf.length) return null;
    if (v.u16(entry) === 0x8825) {
      gpsIfd = v.u32(entry + 8);
      break;
    }
  }
  if (!gpsIfd) return null;

  const gps = tiffStart + gpsIfd;
  if (gps + 2 > buf.length) return null;
  const gpsCount = v.u16(gps);
  let latRef = '';
  let lngRef = '';
  let latitude: number | null = null;
  let longitude: number | null = null;

  for (let i = 0; i < gpsCount; i += 1) {
    const entry = gps + 2 + i * 12;
    if (entry + 12 > buf.length) break;
    const tag = v.u16(entry);
    if (tag === 0x0001) latRef = asciiValue(buf, v, entry, tiffStart).toUpperCase();
    else if (tag === 0x0003) lngRef = asciiValue(buf, v, entry, tiffStart).toUpperCase();
    else if (tag === 0x0002) latitude = dmsToDeg(buf, v, entry, tiffStart);
    else if (tag === 0x0004) longitude = dmsToDeg(buf, v, entry, tiffStart);
  }

  if (latitude == null || longitude == null) return null;
  if (latRef === 'S') latitude = -latitude;
  if (lngRef === 'W') longitude = -longitude;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  if (latitude === 0 && longitude === 0) return null;
  return { latitude, longitude };
}

/** IFD0 里的 ASCII 标签（相机型号 = 0x0110） */
function readTiffAscii(
  buf: Buffer,
  tiffStart: number,
  ifd0Offset: number,
  tag: number,
): string | null {
  const v = tiffView(buf, tiffStart);
  if (!v) return null;
  const ifd0 = tiffStart + ifd0Offset;
  if (ifd0 + 2 > buf.length) return null;
  const count = v.u16(ifd0);
  for (let i = 0; i < count; i += 1) {
    const entry = ifd0 + 2 + i * 12;
    if (entry + 12 > buf.length) return null;
    if (v.u16(entry) === tag) {
      const text = asciiValue(buf, v, entry, tiffStart);
      return text || null;
    }
  }
  return null;
}

/** 在 TIFF 结构里找 Exif 子 IFD 的 DateTimeOriginal */
function readTiffDate(buf: Buffer, tiffStart: number, ifd0Offset: number): number | null {
  if (tiffStart + 8 > buf.length) return null;
  const order = buf.toString('latin1', tiffStart, tiffStart + 2);
  const little = order === 'II';
  if (!little && order !== 'MM') return null;

  const u16 = (p: number) => (little ? buf.readUInt16LE(p) : buf.readUInt16BE(p));
  const u32 = (p: number) => (little ? buf.readUInt32LE(p) : buf.readUInt32BE(p));

  const ifd0 = tiffStart + ifd0Offset;
  if (ifd0 + 2 > buf.length) return null;

  let exifIfd = 0;
  const count = u16(ifd0);
  for (let i = 0; i < count; i++) {
    const entry = ifd0 + 2 + i * 12;
    if (entry + 12 > buf.length) return null;
    if (u16(entry) === 0x8769) {
      exifIfd = u32(entry + 8);
      break;
    }
  }
  if (!exifIfd) return null;

  const exif = tiffStart + exifIfd;
  if (exif + 2 > buf.length) return null;
  const exifCount = u16(exif);
  for (let i = 0; i < exifCount; i++) {
    const entry = exif + 2 + i * 12;
    if (entry + 12 > buf.length) return null;
    const tag = u16(entry);
    if (tag !== 0x9003 && tag !== 0x9004) continue;
    const valueOffset = tiffStart + u32(entry + 8);
    if (valueOffset + 19 > buf.length) return null;
    return parseExifDate(buf.toString('latin1', valueOffset, valueOffset + 19));
  }
  return null;
}

function tiffShort(_buf: Buffer, v: TiffView, entry: number): number | null {
  // SHORT 的 count=1 时值直接放在 entry+8 的低 2 字节
  if (v.u16(entry + 2) !== 3) return null;
  return v.u16(entry + 8);
}

function tiffRational(buf: Buffer, v: TiffView, entry: number, tiffStart: number): number | null {
  if (v.u16(entry + 2) !== 5) return null;
  const value = rationalAt(buf, v, tiffStart + v.u32(entry + 8));
  return Number.isFinite(value) && value > 0 ? value : null;
}

/** 照片属性面板需要的扩展 EXIF（品牌 / 镜头 / 软件 / 方向 / ISO / 光圈 / 快门 / 焦距） */
function readTiffDetails(
  buf: Buffer,
  tiffStart: number,
  ifd0Offset: number,
): Omit<ImageMeta, 'width' | 'height' | 'takenAt' | 'mime' | 'latitude' | 'longitude' | 'camera'> | null {
  const v = tiffView(buf, tiffStart);
  if (!v) return null;
  const ifd0 = tiffStart + ifd0Offset;
  if (ifd0 + 2 > buf.length) return null;

  const out = {
    make: null as string | null,
    lens: null as string | null,
    software: null as string | null,
    orientation: null as number | null,
    iso: null as number | null,
    fNumber: null as number | null,
    exposureTime: null as number | null,
    focalLength: null as number | null,
  };

  let exifIfd = 0;
  const count = v.u16(ifd0);
  for (let i = 0; i < count; i += 1) {
    const entry = ifd0 + 2 + i * 12;
    if (entry + 12 > buf.length) break;
    const tag = v.u16(entry);
    if (tag === 0x010f) out.make = asciiValue(buf, v, entry, tiffStart) || null;
    else if (tag === 0x0131) out.software = asciiValue(buf, v, entry, tiffStart) || null;
    else if (tag === 0x0112) out.orientation = tiffShort(buf, v, entry);
    else if (tag === 0x8769) exifIfd = v.u32(entry + 8);
  }

  if (!exifIfd) return out;
  const exif = tiffStart + exifIfd;
  if (exif + 2 > buf.length) return out;
  const exifCount = v.u16(exif);
  for (let i = 0; i < exifCount; i += 1) {
    const entry = exif + 2 + i * 12;
    if (entry + 12 > buf.length) break;
    const tag = v.u16(entry);
    if (tag === 0x829d) out.fNumber = tiffRational(buf, v, entry, tiffStart);
    else if (tag === 0x829a) out.exposureTime = tiffRational(buf, v, entry, tiffStart);
    else if (tag === 0x8827) out.iso = tiffShort(buf, v, entry);
    else if (tag === 0x920a) out.focalLength = tiffRational(buf, v, entry, tiffStart);
    else if (tag === 0xa434) out.lens = asciiValue(buf, v, entry, tiffStart) || null;
  }
  return out;
}

function parseJpeg(buf: Buffer): Partial<ImageMeta> {
  const out: Partial<ImageMeta> = {};
  let off = 2;
  while (off + 4 <= buf.length) {
    if (buf[off] !== 0xff) {
      off += 1;
      continue;
    }
    const marker = buf[off + 1];
    // 独立标记：SOI / TEM / RSTn
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      off += 2;
      continue;
    }
    const length = buf.readUInt16BE(off + 2);
    if (length < 2) break;
    const seg = off + 4;

    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      if (seg + 7 <= buf.length) {
        out.height = buf.readUInt16BE(seg + 1);
        out.width = buf.readUInt16BE(seg + 3);
      }
    }

    if (marker === 0xe1 && seg + 6 <= buf.length && buf.toString('latin1', seg, seg + 4) === 'Exif') {
      const tiffStart = seg + 6;
      if (tiffStart + 8 <= buf.length) {
        const little = buf.toString('latin1', tiffStart, tiffStart + 2) === 'II';
        const ifd0 = little ? buf.readUInt32LE(tiffStart + 4) : buf.readUInt32BE(tiffStart + 4);
        const taken = readTiffDate(buf, tiffStart, ifd0);
        if (taken) out.takenAt = taken;
        const gps = readTiffGps(buf, tiffStart, ifd0);
        if (gps) {
          out.latitude = gps.latitude;
          out.longitude = gps.longitude;
        }
        const camera = readTiffAscii(buf, tiffStart, ifd0, 0x0110);
        if (camera) out.camera = camera;
        const details = readTiffDetails(buf, tiffStart, ifd0);
        if (details) {
          out.make = details.make;
          out.lens = details.lens;
          out.software = details.software;
          out.orientation = details.orientation;
          out.iso = details.iso;
          out.fNumber = details.fNumber;
          out.exposureTime = details.exposureTime;
          out.focalLength = details.focalLength;
        }
      }
    }

    if (marker === 0xda) break; // 图像数据开始，元数据已读完
    off += 2 + length;
  }
  return out;
}

function parsePng(buf: Buffer): Partial<ImageMeta> {
  if (buf.length < 24) return {};
  if (buf.readUInt32BE(0) !== 0x89504e47) return {};
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

/** 文件名里的日期：IMG_20240102_123456 / 2024-01-02 12.34.56 / 20240102 */
export function parseFileNameDate(file: string): number | null {
  const base = (file.split(/[\\/]/).pop() || '').replace(/\.[^.]+$/, '');
  const m = /(19|20)\d{2}[-_.]?\d{2}[-_.]?\d{2}(?:[-_ T.]?\d{2}[-_.:]?\d{2}[-_.:]?\d{2})?/.exec(base);
  if (!m) return null;
  const digits = m[0].replace(/[^0-9]/g, '');
  if (digits.length !== 8 && digits.length !== 14) return null;
  const y = Number(digits.slice(0, 4));
  const mo = Number(digits.slice(4, 6));
  const d = Number(digits.slice(6, 8));
  const h = digits.length === 14 ? Number(digits.slice(8, 10)) : 0;
  const mi = digits.length === 14 ? Number(digits.slice(10, 12)) : 0;
  const s = digits.length === 14 ? Number(digits.slice(12, 14)) : 0;
  const date = new Date(y, mo - 1, d, h, mi, s);
  if (Number.isNaN(date.getTime())) return null;
  if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d) return null;
  return Math.floor(date.getTime() / 1000);
}

/** 读取图片元数据；解析失败只降级，不抛错（扫描不能因此中断） */
export async function readImageMeta(file: string): Promise<ImageMeta> {
  let head: Buffer;
  try {
    const handle = await fs.open(file, 'r');
    try {
      const buf = Buffer.alloc(HEAD_BYTES);
      const { bytesRead } = await handle.read(buf, 0, HEAD_BYTES, 0);
      head = buf.subarray(0, bytesRead);
    } finally {
      await handle.close();
    }
  } catch {
    return {
      width: null,
      height: null,
      takenAt: parseFileNameDate(file),
      mime: mimeOf(file),
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
    };
  }

  const ext = extensionOf(file);
  const isJpeg = ext === 'jpg' || ext === 'jpeg' || (head[0] === 0xff && head[1] === 0xd8);
  const isPng = ext === 'png' || (head.length >= 8 && head.readUInt32BE(0) === 0x89504e47);
  let parsed: Partial<ImageMeta> = {};
  if (isJpeg) {
    parsed = parseJpeg(head);
  } else if (isPng) {
    parsed = parsePng(head);
  }

  return {
    width: parsed.width ?? null,
    height: parsed.height ?? null,
    takenAt: parsed.takenAt ?? parseFileNameDate(file),
    mime: mimeOf(file),
    latitude: parsed.latitude ?? null,
    longitude: parsed.longitude ?? null,
    camera: parsed.camera ?? null,
    make: parsed.make ?? null,
    lens: parsed.lens ?? null,
    software: parsed.software ?? null,
    orientation: parsed.orientation ?? null,
    iso: parsed.iso ?? null,
    fNumber: parsed.fNumber ?? null,
    exposureTime: parsed.exposureTime ?? null,
    focalLength: parsed.focalLength ?? null,
  };
}