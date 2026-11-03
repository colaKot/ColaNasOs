#!/usr/bin/env node
/**
 * 生成离线行政区划精简库：vendor/geo/china-divisions.json
 *
 * 数据源：阿里 DataV 行政区划 GeoJSON（areas_v3）。
 * 只保留「名称 / 层级 / 上级 / 中心点 / bbox」，不保留边界多边形：
 * 地图与记忆页只需要「这是哪个省、市、区」，最近中心点匹配足够；
 * 保留边界会把 5MB+ 的 GeoJSON 带进包，收益很小。
 *
 * 用法：node tool/build-china-divisions.js [--force]
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const outFile = path.join(root, 'vendor', 'geo', 'china-divisions.json');
const cacheDir = path.join(root, '.devdata', 'datav');
const BASE = 'https://geo.datav.aliyun.com/areas_v3/bound';

function readCache(name) {
  const file = path.join(cacheDir, name);
  if (fs.existsSync(file)) {
    try {
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      /* 坏缓存重下 */
    }
  }
  return null;
}

async function fetchJson(name, url) {
  const cached = readCache(name);
  if (cached) return cached;
  const res = await fetch(url, { signal: globalThis.AbortSignal.timeout(60_000) });
  if (!res.ok) throw new Error(`${url} -> ${res.status}`);
  const text = await res.text();
  fs.writeFileSync(path.join(cacheDir, name), text, 'utf8');
  return JSON.parse(text);
}

function bboxOf(geometry) {
  let minLng = Infinity;
  let minLat = Infinity;
  let maxLng = -Infinity;
  let maxLat = -Infinity;
  const walk = (node) => {
    if (typeof node[0] === 'number') {
      const [lng, lat] = node;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      return;
    }
    for (const child of node) walk(child);
  };
  if (geometry && geometry.coordinates) walk(geometry.coordinates);
  if (!Number.isFinite(minLng)) return null;
  return [minLng, minLat, maxLng, maxLat];
}

function push(list, feature, parentName) {
  const p = feature.properties || {};
  const center = Array.isArray(p.center) ? p.center : null;
  const bbox = bboxOf(feature.geometry);
  if (!p.name || !p.adcode) return;
  const lng = center ? Number(center[0]) : bbox ? (bbox[0] + bbox[2]) / 2 : null;
  const lat = center ? Number(center[1]) : bbox ? (bbox[1] + bbox[3]) / 2 : null;
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) return;
  list.push({
    adcode: Number(p.adcode),
    name: String(p.name),
    level: String(p.level || ''),
    parent: p.parent && p.parent.adcode ? Number(p.parent.adcode) : null,
    parentName: parentName || '',
    lat: Number(lat.toFixed(5)),
    lng: Number(lng.toFixed(5)),
    bbox: bbox ? bbox.map((v) => Number(v.toFixed(4))) : null,
  });
}

async function main() {
  fs.mkdirSync(cacheDir, { recursive: true });
  fs.mkdirSync(path.dirname(outFile), { recursive: true });

  const country = await fetchJson('100000_full.json', `${BASE}/100000_full.json`);
  const provinces = country.features.filter((f) => f.properties && f.properties.level === 'province');
  const rows = [];

  for (const province of provinces) {
    const p = province.properties;
    push(rows, province, '中国');
    if (!p.adcode) continue;
    // 省级 full：一般为「市」；直辖市直接是「区」
    let level2;
    try {
      const file = await fetchJson(`${p.adcode}_full.json`, `${BASE}/${p.adcode}_full.json`);
      level2 = file.features || [];
    } catch {
      continue;
    }
    for (const city of level2) {
      push(rows, city, p.name);
      const cp = city.properties || {};
      if (cp.level !== 'city' || !cp.adcode) continue;
      try {
        const file = await fetchJson(`${cp.adcode}_full.json`, `${BASE}/${cp.adcode}_full.json`);
        for (const district of file.features || []) push(rows, district, cp.name);
      } catch {
        /* 某个市没有下级数据：跳过 */
      }
    }
  }

  // 去重（同一 adcode 只留一条）
  const byCode = new Map();
  for (const row of rows) if (!byCode.has(row.adcode)) byCode.set(row.adcode, row);
  const list = [...byCode.values()].sort((a, b) => a.adcode - b.adcode);

  fs.writeFileSync(
    outFile,
    JSON.stringify({ source: 'DataV areas_v3', count: list.length, items: list }),
    'utf8',
  );
  const size = fs.statSync(outFile).size;
  console.log(`[china-divisions] ${list.length} rows -> ${path.relative(root, outFile)} (${(size / 1024).toFixed(0)} KB)`);
}

main().catch((err) => {
  console.error('[china-divisions] failed:', err);
  process.exit(1);
});