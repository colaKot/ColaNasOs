import fs from 'node:fs';
import path from 'node:path';
import { haversineKm } from './geohash';

/**
 * 离线中国行政区划（省 / 市 / 区）。
 *
 * 数据来自阿里 DataV areas_v3，由 `tool/build-china-divisions.js` 生成精简库
 * `vendor/geo/china-divisions.json`（名称 / 层级 / 上级 / 中心点 / bbox）。
 *
 * 匹配策略：先用区县 bbox 预筛，再按中心点球面距离取最近；超过 80km 视为不可信，
 * 交给 GeoNames 最近地名兜底。不做点在多边形，是为了避免把几 MB 边界数据带进包。
 */
export interface ChinaDivision {
  adcode: number;
  name: string;
  level: string;
  parent: number | null;
  parentName: string;
  lat: number;
  lng: number;
  bbox: [number, number, number, number] | null;
}

export interface ChinaLocation {
  province: string;
  city: string;
  district: string;
  adcode: number;
  distanceKm: number;
}

const MAX_DISTANCE_KM = 80;

let loaded: { items: ChinaDivision[]; byCode: Map<number, ChinaDivision> } | null = null;
let loadFailed = false;

function candidates(): string[] {
  const out: string[] = [];
  const env = process.env.COLANAS_CHINA_DIVISIONS;
  if (env && env.trim()) out.push(env.trim());
  out.push(path.join(process.cwd(), 'vendor', 'geo', 'china-divisions.json'));
  out.push(path.join(process.cwd(), 'data', 'china-divisions.json'));
  return out;
}

function open() {
  if (loaded) return loaded;
  if (loadFailed) return null;
  for (const file of candidates()) {
    try {
      if (!fs.existsSync(file)) continue;
      const raw = JSON.parse(fs.readFileSync(file, 'utf8')) as { items?: ChinaDivision[] };
      const items = Array.isArray(raw.items) ? raw.items : [];
      if (items.length === 0) continue;
      const byCode = new Map<number, ChinaDivision>();
      for (const item of items) byCode.set(Number(item.adcode), item);
      loaded = { items, byCode };
      return loaded;
    } catch {
      /* 尝试下一个候选 */
    }
  }
  loadFailed = true;
  return null;
}

export function chinaDivisionsAvailable(): boolean {
  return open() !== null;
}

function inBbox(box: ChinaDivision['bbox'], lat: number, lng: number): boolean {
  if (!box) return false;
  return lng >= box[0] && lng <= box[2] && lat >= box[1] && lat <= box[3];
}

/** 把「区县」补成「省 / 市 / 区」，直辖市去重（北京市 北京市 朝阳区 → 北京市 朝阳区） */
function toLocation(item: ChinaDivision, distanceKm: number): ChinaLocation {
  const parent = item.parent == null ? undefined : open()?.byCode.get(item.parent);
  let province = item.parentName || '';
  let city = item.parentName || '';
  if (parent) {
    if (parent.level === 'city') {
      city = parent.name;
      province = parent.parentName || province;
    } else {
      province = parent.name;
      city = parent.name;
    }
  }
  const district = item.level === 'district' ? item.name : '';
  return {
    province,
    city,
    district,
    adcode: item.adcode,
    distanceKm: Number(distanceKm.toFixed(1)),
  };
}

export function locateInChina(lat: number, lng: number): ChinaLocation | null {
  const data = open();
  if (!data) return null;
  if (
    !Number.isFinite(lat) ||
    !Number.isFinite(lng) ||
    Math.abs(lat) > 90 ||
    Math.abs(lng) > 180 ||
    (lat === 0 && lng === 0)
  ) {
    return null;
  }

  const districts = data.items.filter((i) => i.level === 'district');
  let best: ChinaDivision | null = null;
  let bestKm = Infinity;
  // 区县优先：命中多个时取中心点最近
  for (const item of districts) {
    if (!inBbox(item.bbox, lat, lng)) continue;
    const km = haversineKm(lat, lng, item.lat, item.lng);
    if (km < bestKm) {
      best = item;
      bestKm = km;
    }
  }
  if (!best) {
    // 边界/海外邻区没有区县 bbox 命中：退到「市」级中心点，避免只剩省名
    for (const item of data.items.filter((i) => i.level === 'city')) {
      const km = haversineKm(lat, lng, item.lat, item.lng);
      if (km < bestKm) {
        best = item;
        bestKm = km;
      }
    }
  }
  if (!best && districts.length > 0) {
    for (const item of districts) {
      const km = haversineKm(lat, lng, item.lat, item.lng);
      if (km < bestKm) {
        best = item;
        bestKm = km;
      }
    }
  }
  if (!best || bestKm > MAX_DISTANCE_KM) return null;
  return toLocation(best, bestKm);
}

/** 「广东省 深圳市 南山区」；直辖市自动去重 */
export function chinaPlacePath(lat: number, lng: number): string {
  const loc = locateInChina(lat, lng);
  if (!loc) return '';
  const parts: string[] = [];
  for (const part of [loc.province, loc.city, loc.district]) {
    if (!part) continue;
    if (parts[parts.length - 1] === part) continue;
    parts.push(part);
  }
  return parts.join(' ');
}