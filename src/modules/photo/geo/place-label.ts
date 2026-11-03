import { chinaPlacePath } from './china';
import { countryNameZh } from './countries';
import { nearestPlaceInfo } from './places';

/**
 * 统一地点文案：
 *   ① 国内：优先「省 / 市 / 区」（离线行政区划，中文）；
 *   ② 国外：只给国家中文名（GeoNames 的城市名多为英文，用户明确不要英文）；
 *   ③ 都取不到：空串，前端隐藏地点，不回落英文。
 */
export function describePlace(
  geohash: string,
  lat: number | null,
  lng: number | null,
  locale: string | undefined,
): string {
  if (lat != null && lng != null) {
    const path = chinaPlacePath(Number(lat), Number(lng));
    if (path) return path;
  }
  const info = nearestPlaceInfo(geohash, lat, lng, locale);
  if (!info) return '';
  if (info.countryCode === 'CN') return info.name;
  return countryNameZh(info.countryCode);
}