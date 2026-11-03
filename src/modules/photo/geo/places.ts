import fs from 'node:fs';
import path from 'node:path';
import Database from 'better-sqlite3';
import { haversineKm, decodeCenter } from './geohash';

/**
 * 最近地名反查（GeoNames 只读库）。
 *
 * 规则（踩坑经验）：
 *   ① 不按 geonameid 取第一条 —— 那是「谁先录入谁赢」，市区常常没有点位，
 *      于是退到 geohash4 后永远命中 10km 外的错地名。
 *   ② 按「与查询点的真实球面距离」升序取最近一条，并加 30km 闸门；
 *      这一级最近的一条都超闸 ⇒ 更粗的格只会更远，直接放弃回退。
 *   ③ 只显示一种语言：有本地名（如中文）就不拼英文；没有才退回英文名。
 *
 * 地名库属于 GeoNames（CC-BY 4.0）；缺失时全部接口降级为空地名，
 * 不影响地图本身。
 */
const MAX_DISTANCE_KM = 30;

const GEO_COLUMN: Record<number, string> = {
  3: 'geohash3',
  4: 'geohash4',
  5: 'geohash5',
  6: 'geohash6',
  7: 'geohash7',
  8: 'geohash',
};

let db: Database.Database | null = null;
let dbFailed = false;

function candidates(): string[] {
  const out: string[] = [];
  const env = process.env.COLANAS_GEONAMES;
  if (env && env.trim()) out.push(env.trim());
  out.push(path.join(process.cwd(), 'vendor', 'geo', 'geonames.sqlite'));
  out.push(path.join(process.cwd(), 'data', 'geonames.sqlite'));
  return out;
}

function open(): Database.Database | null {
  if (db) return db;
  if (dbFailed) return null;
  for (const file of candidates()) {
    try {
      if (!fs.existsSync(file)) continue;
      db = new Database(file, { readonly: true, fileMustExist: true });
      db.pragma('busy_timeout = 2000');
      return db;
    } catch {
      db = null;
    }
  }
  dbFailed = true;
  return null;
}

export function placesAvailable(): boolean {
  return open() !== null;
}

function langOf(locale: string | undefined): string {
  const text = String(locale || '').trim();
  if (!text) return 'zh';
  return text.split(/[-_]/)[0].toLowerCase() || 'zh';
}

interface Row {
  local_name: string | null;
  en_name: string | null;
  country_code: string | null;
  latitude: number;
  longitude: number;
}

const HAN = /[\u4e00-\u9fa5]/;

export interface NearestPlace {
  name: string;
  countryCode: string;
  distanceKm: number;
}

const statements = new Map<string, Database.Statement>();

function statement(column: string): Database.Statement | null {
  const conn = open();
  if (!conn) return null;
  const key = column;
  const cached = statements.get(key);
  if (cached) return cached;
  const sql = `
    SELECT COALESCE(i_req.name, i_def.name) AS local_name,
           COALESCE(i_en.name, i_def.name, i_req.name) AS en_name,
           g.country_code AS country_code,
           g.latitude AS latitude,
           g.longitude AS longitude
      FROM geonames g
      LEFT JOIN geoname_i18n i_req ON i_req.geonameid = g.geonameid AND i_req.lang = ?
      LEFT JOIN geoname_i18n i_en  ON i_en.geonameid  = g.geonameid AND i_en.lang  = 'en'
      LEFT JOIN geoname_i18n i_def ON i_def.geonameid = g.geonameid AND i_def.lang = 'und'
     WHERE g.${column} = ?
     ORDER BY (g.latitude - ?) * (g.latitude - ?)
            + (g.longitude - ?) * (g.longitude - ?) * ?
     LIMIT 5`;
  const stmt = conn.prepare(sql);
  statements.set(key, stmt);
  return stmt;
}

/**
 * 取离 (lat,lng) 最近的单一语言地名。
 * `zh` 下只接受含汉字的名字：没有中文名就继续找更粗的格，最后返回空，
 * 绝不把英文名混进中文界面（国外位置由 `describePlace` 收敛成国家中文名）。
 */
export function nearestPlaceInfo(
  geohash: string,
  lat: number | null,
  lng: number | null,
  locale: string | undefined,
): NearestPlace | null {
  const hash = String(geohash || '').trim().toLowerCase().slice(0, 8);
  if (!hash) return null;

  const hasPoint =
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    Math.abs(Number(lat)) <= 90 &&
    Math.abs(Number(lng)) <= 180 &&
    !(Number(lat) === 0 && Number(lng) === 0);

  const lang = langOf(locale);

  for (let len = Math.min(8, hash.length); len >= 3; len -= 1) {
    const column = GEO_COLUMN[len];
    if (!column) continue;
    const prefix = hash.slice(0, len);

    let tLat: number;
    let tLng: number;
    if (hasPoint) {
      tLat = Number(lat);
      tLng = Number(lng);
    } else {
      const center = decodeCenter(prefix);
      if (!center) continue;
      tLat = center.lat;
      tLng = center.lng;
    }

    const stmt = statement(column);
    if (!stmt) return null;
    const lngWeight = Math.cos((tLat * Math.PI) / 180) ** 2;
    let rows: Row[];
    try {
      rows = stmt.all(lang, prefix, tLat, tLat, tLng, tLng, lngWeight) as Row[];
    } catch {
      return null;
    }
    if (rows.length === 0) continue;

    let rejected = false;
    for (const row of rows) {
      const localName = row.local_name ? String(row.local_name).trim() : '';
      const enName = row.en_name ? String(row.en_name).trim() : '';
      if (!localName && !enName) continue;
      const dKm = haversineKm(tLat, tLng, Number(row.latitude), Number(row.longitude));
      if (Number.isFinite(dKm) && dKm > MAX_DISTANCE_KM) {
        rejected = true;
        break;
      }
      const name = lang === 'zh' ? (HAN.test(localName) ? localName : '') : localName || enName;
      if (!name) continue;
      return {
        name,
        countryCode: String(row.country_code || '').toUpperCase(),
        distanceKm: Number.isFinite(dKm) ? Number(dKm.toFixed(1)) : MAX_DISTANCE_KM,
      };
    }
    if (rejected) break;
  }
  return null;
}

export function nearestPlaceName(
  geohash: string,
  lat: number | null,
  lng: number | null,
  locale: string | undefined,
): string {
  return nearestPlaceInfo(geohash, lat, lng, locale)?.name || '';
}
