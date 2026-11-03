/**
 * geohash 与地理网格（零依赖）。
 *
 * 为什么自己写而不引 ngeohash：本项目服务端不引入第三方 geo 依赖，
 * 只需要「编码 / 解码格心 / 覆盖格列表 / 精度解析」四件事，标准算法即可。
 *
 * 位序与标准 geohash 一致：第 0 位是经度，奇偶交替 ⇒ 精度 p 时
 *   经度位 = ceil(5p/2)，纬度位 = floor(5p/2)。
 */

const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

export function latBitsOf(precision: number): number {
  return Math.floor((5 * precision) / 2);
}

export function lngBitsOf(precision: number): number {
  return Math.ceil((5 * precision) / 2);
}

/** 精度 p 的格子尺寸（度） */
export function cellSizeOf(precision: number): { lat: number; lng: number } {
  return {
    lat: 180 / 2 ** latBitsOf(precision),
    lng: 360 / 2 ** lngBitsOf(precision),
  };
}

/** 由格索引直接拼出 geohash 串（避免「格心 encode 落到邻格」的边界误差） */
function encodeIndices(latIdx: number, lngIdx: number, precision: number): string {
  const latBits = latBitsOf(precision);
  const lngBits = lngBitsOf(precision);
  const total = 5 * precision;
  let out = '';
  let acc = 0;
  let used = 0;
  for (let i = 0; i < total; i += 1) {
    let bit: number;
    if (i % 2 === 0) {
      const pos = lngBits - 1 - Math.floor(i / 2);
      bit = (lngIdx >> pos) & 1;
    } else {
      const pos = latBits - 1 - Math.floor(i / 2);
      bit = (latIdx >> pos) & 1;
    }
    acc = (acc << 1) | bit;
    used += 1;
    if (used === 5) {
      out += BASE32[acc];
      acc = 0;
      used = 0;
    }
  }
  return out;
}

export function encode(lat: number, lng: number, precision: number): string {
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || precision < 1 || precision > 12) return '';
  const latBits = latBitsOf(precision);
  const lngBits = lngBitsOf(precision);
  const { lat: cellLat, lng: cellLng } = cellSizeOf(precision);
  const latIdx = Math.min(2 ** latBits - 1, Math.max(0, Math.floor((lat + 90) / cellLat)));
  const lngIdx = Math.min(2 ** lngBits - 1, Math.max(0, Math.floor((lng + 180) / cellLng)));
  return encodeIndices(latIdx, lngIdx, precision);
}

/** 前缀格的几何中心（前缀非法时返回 null） */
export function decodeCenter(hash: string): { lat: number; lng: number } | null {
  const text = String(hash || '').trim().toLowerCase();
  if (!text) return null;
  let minLat = -90;
  let maxLat = 90;
  let minLng = -180;
  let maxLng = 180;
  for (let i = 0; i < text.length; i += 1) {
    const idx = BASE32.indexOf(text[i]);
    if (idx < 0) return null;
    for (let bit = 4; bit >= 0; bit -= 1) {
      const on = (idx >> bit) & 1;
      if ((i * 5 + (4 - bit)) % 2 === 0) {
        const mid = (minLng + maxLng) / 2;
        if (on) minLng = mid;
        else maxLng = mid;
      } else {
        const mid = (minLat + maxLat) / 2;
        if (on) minLat = mid;
        else maxLat = mid;
      }
    }
  }
  return { lat: (minLat + maxLat) / 2, lng: (minLng + maxLng) / 2 };
}

/**
 * 解析式选精度：取「覆盖格子数 <= cellTarget」的**最细**精度。
 *
 * ⚠️ 不要改成「先枚举格再判断」：视野大时 p=6 会生成几十万个串，直接打爆内存。
 * 这里只做四则运算，真正枚举只发生在最终精度上。
 */
export function precisionForBounds(
  latSpan: number,
  lngSpan: number,
  cellTarget: number,
): number {
  const target = Math.max(1, Math.trunc(cellTarget) || 600);
  if (!Number.isFinite(latSpan) || !Number.isFinite(lngSpan)) return 2;
  for (let p = 7; p > 2; p -= 1) {
    const { lat: cellLat, lng: cellLng } = cellSizeOf(p);
    const cells = Math.ceil(latSpan / cellLat + 1) * Math.ceil(lngSpan / cellLng + 1);
    if (cells <= target) return p;
  }
  return 2;
}

/** 点开一个 marker 时该看多大范围：让「格宽」≈ marker 覆盖的经纬跨度 */
export function precisionForSpanDeg(spanDeg: number): number {
  if (!Number.isFinite(spanDeg) || spanDeg <= 0) return 6;
  for (let p = 7; p > 2; p -= 1) {
    const { lng } = cellSizeOf(p);
    if (lng >= spanDeg) return p;
  }
  return 2;
}

/**
 * 覆盖矩形范围的 geohash 格列表（精度由调用方先用 precisionForBounds 选好）。
 *
 * 行列上限 4096：超了就抛错而不是静默返回半张图 —— 让调用方回去降精度。
 */
export function coveringCells(
  minLat: number,
  minLng: number,
  maxLat: number,
  maxLng: number,
  precision: number,
): string[] {
  if (precision < 1 || precision > 7) throw new Error('invalid precision');
  const { lat: cellLat, lng: cellLng } = cellSizeOf(precision);
  const latBits = latBitsOf(precision);
  const lngBits = lngBitsOf(precision);
  const maxLatIdx = 2 ** latBits - 1;
  const maxLngIdx = 2 ** lngBits - 1;

  const latStart = Math.min(maxLatIdx, Math.max(0, Math.floor((minLat + 90) / cellLat)));
  const latEnd = Math.min(maxLatIdx, Math.max(0, Math.floor((maxLat + 90) / cellLat)));
  const lngStart = Math.min(maxLngIdx, Math.max(0, Math.floor((minLng + 180) / cellLng)));
  const lngEnd = Math.min(maxLngIdx, Math.max(0, Math.floor((maxLng + 180) / cellLng)));

  const rows = latEnd - latStart + 1;
  const cols = lngEnd - lngStart + 1;
  if (rows * cols > 1_000_000) throw new Error('too many cells');

  const out: string[] = [];
  for (let li = latStart; li <= latEnd; li += 1) {
    for (let gi = lngStart; gi <= lngEnd; gi += 1) out.push(encodeIndices(li, gi, precision));
  }
  return out;
}

/** 球面距离（km）。地名反查用它比「谁离照片更近」。 */
export function haversineKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLng = ((lng2 - lng1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) * Math.cos((lat2 * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}