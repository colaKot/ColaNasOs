import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { coveringCells, precisionForBounds } from './geo/geohash';
import { placesAvailable } from './geo/places';
import { describePlace } from './geo/place-label';
import { Err } from '../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * photo 足迹地图（服务端只做「粗定位 + 精确取数」两件事）。
 *
 * 设计要点（代码按本项目重写）：
 *   ① 可视范围 → 精度：用解析式取「格数 ≤ cellTarget」的最细精度，不枚举候选格；
 *   ② 每个格给「代表照片（最密那张所在格内 id 最大者）+ 本格张数」；
 *      落点用代表照片**真实经纬度**，不吸附格心（吸格心会整体平移）；
 *   ③ 重叠由**客户端**按世界像素距离聚簇（平移不重算，缩放才重算）；
 *   ④ 点开一个簇：把簇覆盖的 geohash 格集合原样下发，服务端 `WHERE IN` 一次取回，
 *      角标数字与该集合的 COUNT(*) 同源 ⇒ 角标多少、点开就多少；
 *   ⑤ 地名按真实球面距离取最近一条，30km 闸门，只显示一种语言。
 */
const TAG = ['photo'];
const GEO_COLUMN: Record<number, string> = {
  2: 'geohash2',
  3: 'geohash3',
  4: 'geohash4',
  5: 'geohash5',
  6: 'geohash6',
  7: 'geohash7',
};

interface TileServer {
  id: string;
  name: string;
  url: string;
  coordinate: string;
  maxLevel: number;
}

/**
 * 内置底图源。默认不用 OSM：国内多数网络直连 tile.openstreetmap.org 会超时，
 * 地图会显示成空白（实测 8s 无响应）；Esri 卫星图实测 0.17s 可达。
 */
const BUILTIN_TILE_SERVERS: TileServer[] = [
  {
    id: 'esri',
    name: 'Esri 卫星',
    url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    coordinate: 'WGS-84',
    maxLevel: 19,
  },
  {
    id: 'carto-dark',
    name: 'CARTO 深色',
    url: 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    coordinate: 'WGS-84',
    maxLevel: 19,
  },
  {
    id: 'amap-vec',
    name: '高德中文标注',
    url: 'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
    coordinate: 'GCJ-02',
    maxLevel: 18,
  },
  {
    id: 'amap-sat',
    name: '高德卫星',
    url: 'https://webst01.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}',
    coordinate: 'GCJ-02',
    maxLevel: 18,
  },
  {
    id: 'osm',
    name: 'OpenStreetMap',
    url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    coordinate: 'WGS-84',
    maxLevel: 19,
  },
];
/**
 * 默认底图：高德中文标注。
 *
 * 不能取列表第一个 —— 那是 Esri 卫星图，卫星影像没有行政边界和地名，
 * 打开就是「一片地貌，没有省份和城市」（2026-11-04 反馈）。
 * 高德矢量图自带省界 / 市名 / 区名，且随 zoom 自动切换颗粒度（省→市→区）。
 */
const DEFAULT_TILE_SERVER: TileServer =
  BUILTIN_TILE_SERVERS.find((server) => server.id === 'amap-vec') ??
  BUILTIN_TILE_SERVERS[0];

const Marker = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    latitude: Type.Number(),
    longitude: Type.Number(),
    takenAt: Type.Integer(),
    photoCount: Type.Integer({ description: '本格照片数（角标）' }),
    geohash: Type.String({ description: '代表照片的 8 位 geohash' }),
    cellKey: Type.String({ description: '代表照片所在格（cellPrecision 位）' }),
    cellPrecision: Type.Integer(),
  },
  { $id: 'PhotoMapMarker' },
);

const BoundsQuery = Type.Object(
  {
    minLat: Type.Number(),
    minLng: Type.Number(),
    maxLat: Type.Number(),
    maxLng: Type.Number(),
    zoom: Type.Optional(Type.Number()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 2000, default: 150 })),
    libraryId: Type.Optional(Type.String()),
  },
  { $id: 'PhotoMapBoundsQuery' },
);

const BoundsResponse = Type.Object(
  {
    precision: Type.Integer(),
    cells: Type.Integer({ description: '本次枚举的格数（候选）' }),
    items: Type.Array(Type.Ref(Marker)),
  },
  { $id: 'PhotoMapBoundsResponse' },
);

const PhotoRef = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    latitude: Type.Union([Type.Number(), Type.Null()]),
    longitude: Type.Union([Type.Number(), Type.Null()]),
    geohash: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoMapPhoto' },
);

const CellsQuery = Type.Object(
  {
    keys: Type.String({ minLength: 1, description: '逗号分隔的 geohash 格（与簇同精度）' }),
    precision: Type.Integer({ minimum: 2, maximum: 7 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 120 })),
    cursor: Type.Optional(Type.String()),
  },
  { $id: 'PhotoMapCellsQuery' },
);

const CellsResponse = Type.Object(
  {
    total: Type.Integer({ description: '这些格里的照片总数 = 角标' }),
    items: Type.Array(Type.Ref(PhotoRef)),
    nextCursor: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoMapCellsResponse' },
);

const PlaceQuery = Type.Object(
  {
    geohash: Type.String({ minLength: 1 }),
    lat: Type.Optional(Type.Number()),
    lng: Type.Optional(Type.Number()),
    locale: Type.Optional(Type.String()),
  },
  { $id: 'PhotoMapPlaceQuery' },
);

const PlaceResponse = Type.Object(
  {
    name: Type.String(),
    available: Type.Boolean({ description: '地名库是否可用' }),
  },
  { $id: 'PhotoMapPlaceResponse' },
);

const TileServer = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    url: Type.String({ description: '瓦片 URL 模板，含 {z}/{x}/{y}' }),
    coordinate: Type.String({ description: 'WGS-84 / GCJ-02' }),
    maxLevel: Type.Integer(),
    isDefault: Type.Boolean(),
    isCurrent: Type.Boolean(),
  },
  { $id: 'PhotoMapTileServer' },
);

const TileServerList = Type.Object(
  { items: Type.Array(Type.Ref(TileServer)) },
  { $id: 'PhotoMapTileServerList' },
);

const TileServerBody = Type.Object(
  {
    id: Type.Optional(Type.String()),
    name: Type.Optional(Type.String()),
    url: Type.Optional(Type.String({ minLength: 1 })),
    coordinate: Type.Optional(Type.String()),
    maxLevel: Type.Optional(Type.Integer({ minimum: 1, maximum: 22 })),
  },
  { $id: 'PhotoMapTileServerBody' },
);

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'PhotoMapError' },
);

/**
 * 行程连线：按拍摄时间串起有 GPS 的照片。
 *
 * 为什么在服务端切段：段与段的判据是「时间间隔」，与服务端保留期/时区同一套口径；
 * 客户端只负责画线，不再各自猜。
 */
const JourneyPoint = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    latitude: Type.Number(),
    longitude: Type.Number(),
    takenAt: Type.Integer(),
  },
  { $id: 'PhotoMapJourneyPoint' },
);

const JourneySegment = Type.Object(
  {
    startAt: Type.Integer(),
    endAt: Type.Integer(),
    distanceKm: Type.Number(),
    points: Type.Array(Type.Ref(JourneyPoint)),
  },
  { $id: 'PhotoMapJourneySegment' },
);

const JourneyQuery = Type.Object(
  {
    from: Type.Optional(Type.Integer({ description: '起始秒（含）' })),
    to: Type.Optional(Type.Integer({ description: '结束秒（含）' })),
    libraryId: Type.Optional(Type.String()),
    gapHours: Type.Optional(
      Type.Integer({ minimum: 1, maximum: 720, default: 12, description: '超过这个间隔另起一段' }),
    ),
    maxPoints: Type.Optional(Type.Integer({ minimum: 2, maximum: 5000, default: 600 })),
  },
  { $id: 'PhotoMapJourneyQuery' },
);

const JourneyResponse = Type.Object(
  {
    segments: Type.Array(Type.Ref(JourneySegment)),
    points: Type.Integer(),
    distanceKm: Type.Number(),
    days: Type.Integer(),
  },
  { $id: 'PhotoMapJourneyResponse' },
);

export const PHOTO_MAP_SCHEMAS = [
  Marker,
  BoundsQuery,
  BoundsResponse,
  PhotoRef,
  CellsQuery,
  CellsResponse,
  PlaceQuery,
  PlaceResponse,
  TileServer,
  TileServerList,
  TileServerBody,
  JourneyPoint,
  JourneySegment,
  JourneyQuery,
  JourneyResponse,
  ErrorResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });

function encodeCursor(takenAt: number, id: string): string {
  return Buffer.from(`${takenAt}|${id}`).toString('base64url');
}

function decodeCursor(cursor?: string): { takenAt: number; id: string } | null {
  if (!cursor) return null;
  try {
    const text = Buffer.from(cursor, 'base64url').toString('utf8');
    const [taken, id] = text.split('|');
    const takenAt = Number(taken);
    if (!Number.isFinite(takenAt) || !id) return null;
    return { takenAt, id };
  } catch {
    return null;
  }
}

function pickEvenly<T>(list: T[], maxCount: number): T[] {
  if (list.length <= maxCount) return list.slice();
  const step = list.length / maxCount;
  const out: T[] = [];
  for (let i = 0; i < maxCount; i += 1) out.push(list[Math.min(list.length - 1, Math.floor(i * step))]);
  return out;
}

interface PickRow {
  cell: string;
  n: number;
  pick: string;
}

/** 行程抽稀：均匀取样，但**强制保留首尾**（画线断头会比稀疏更难看） */
function thinEvenly<T>(list: T[], maxCount: number): T[] {
  if (list.length <= maxCount) return list.slice();
  const out: T[] = [];
  const step = (list.length - 1) / (maxCount - 1);
  for (let i = 0; i < maxCount; i += 1) out.push(list[Math.round(i * step)]);
  return out;
}

/** 当前底图源（默认或管理员保存的自定义模板） */
export function currentTileServerOf(k: KernelApi): TileServer {
  const saved = k.config.get<Partial<TileServer>>('photo.map.tileServer');
  if (saved && saved.url) {
    return {
      ...DEFAULT_TILE_SERVER,
      ...saved,
      id: String(saved.id || 'custom'),
      name: String(saved.name || '自定义底图'),
    };
  }
  return DEFAULT_TILE_SERVER;
}

/** 按 id 解析底图源（内置 / 自定义）；id 缺省返回当前源，未知返回 null */
export function tileServerById(k: KernelApi, id?: string): TileServer | null {
  if (!id) return currentTileServerOf(k);
  const builtin = BUILTIN_TILE_SERVERS.find((server) => server.id === id);
  if (builtin) return builtin;
  const custom = k.config.get<Partial<TileServer>>('photo.map.tileServerCustom');
  if (custom && custom.url && String(custom.id || 'custom') === id) {
    return {
      ...DEFAULT_TILE_SERVER,
      ...custom,
      id: String(custom.id || 'custom'),
      name: String(custom.name || '自定义底图'),
    };
  }
  return null;
}

export async function registerPhotoMap(app: any, k: KernelApi): Promise<void> {
  for (const schema of PHOTO_MAP_SCHEMAS) app.addSchema(schema);

  const currentTileServer = (): TileServer => currentTileServerOf(k);

  app.get(
    '/api/v1/photo/map/bounds',
    secured('photo:read', {
      schema: {
        operationId: 'photoMapBounds',
        tags: TAG,
        summary: '可视范围内的 geohash 格代表点（客户端按世界像素聚簇）',
        querystring: ref('PhotoMapBoundsQuery'),
        response: { 200: ref('PhotoMapBoundsResponse'), 400: ref('PhotoMapError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as Record<string, unknown>;
      const nums = [q.minLat, q.minLng, q.maxLat, q.maxLng].map(Number);
      if (!nums.every((n) => Number.isFinite(n))) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid bounds' });
      }
      const minLat = Math.min(nums[0], nums[2]);
      const maxLat = Math.max(nums[0], nums[2]);
      const minLng = Math.min(nums[1], nums[3]);
      const maxLng = Math.max(nums[1], nums[3]);

      const limit = Math.max(1, Math.min(Number(q.limit) || 150, 2000));
      const latSpan = Math.max(0.000001, maxLat - minLat);
      const lngSpan = Math.max(0.000001, maxLng - minLng);
      // 允许的格数比返回条数宽一个量级：先拿够细的格子，再由客户端聚簇 / 服务端抽稀
      const cellTarget = Math.max(limit * 14, 2000);
      const precision = precisionForBounds(latSpan, lngSpan, cellTarget);
      const column = GEO_COLUMN[precision] || GEO_COLUMN[2];

      let cells: string[];
      try {
        cells = coveringCells(minLat, minLng, maxLat, maxLng, precision);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'bounds too large' });
      }
      const maxQueryCells = Math.min(Math.max(limit * 20, 800), 6000);
      const queryCells = cells.length > maxQueryCells ? pickEvenly(cells, maxQueryCells) : cells;

      const libId = typeof q.libraryId === 'string' ? q.libraryId : '';
      const uid = String(req.user?.sub || '');
      const picks: PickRow[] = [];
      const CHUNK = 500;
      for (let i = 0; i < queryCells.length; i += CHUNK) {
        const chunk = queryCells.slice(i, i + CHUNK);
        const inList = sql.join(
          chunk.map((c) => sql`${c}`),
          sql`, `,
        );
        const rows = await sql<PickRow>`
          select cell, n, pick from (
            select ${sql.raw(column)} as cell,
                   count(*) over (partition by ${sql.raw(column)}) as n,
                   id as pick,
                   row_number() over (
                     partition by ${sql.raw(column)}
                     order by taken_at desc, id desc
                   ) as rn
              from photo_items
             where in_trash = 0
               and library_id in (select id from photo_libraries where owner_id = ${uid})
               and ${sql.raw(column)} in (${inList})
               ${libId ? sql`and library_id = ${libId}` : sql``}
          )
          where rn = 1
        `.execute(k.db);
        picks.push(...(rows.rows as PickRow[]));
      }

      if (picks.length === 0) return { precision, cells: queryCells.length, items: [] };

      const ids = picks.map((p) => String(p.pick));
      const photoRows = await sql<{
        id: string;
        rel_path: string;
        latitude: number | null;
        longitude: number | null;
        taken_at: number;
        geohash: string | null;
      }>`
        select id, rel_path, latitude, longitude, taken_at, geohash
          from photo_items
         where id in (${sql.join(
           ids.map((id) => sql`${id}`),
           sql`, `,
         )})
      `.execute(k.db);
      const byId = new Map(photoRows.rows.map((r) => [r.id, r]));

      const markers = picks
        .map((p) => {
          const row = byId.get(String(p.pick));
          if (!row || row.latitude == null || row.longitude == null) return null;
          const hash = String(row.geohash || '');
          return {
            id: row.id,
            path: row.rel_path,
            latitude: Number(row.latitude),
            longitude: Number(row.longitude),
            takenAt: Number(row.taken_at),
            photoCount: Number(p.n) || 1,
            geohash: hash,
            cellKey: hash.slice(0, precision),
            cellPrecision: precision,
          };
        })
        .filter(Boolean) as Array<Record<string, unknown>>;

      markers.sort((a, b) => Number(b.photoCount) - Number(a.photoCount));
      return {
        precision,
        cells: queryCells.length,
        items: markers.length > limit ? pickEvenly(markers, limit) : markers,
      };
    },
  );

  app.get(
    '/api/v1/photo/map/journey',
    secured('photo:read', {
      schema: {
        operationId: 'photoMapJourney',
        tags: TAG,
        summary: '行程连线（有 GPS 的照片按拍摄时间串成若干段）',
        querystring: ref('PhotoMapJourneyQuery'),
        response: { 200: ref('PhotoMapJourneyResponse'), 400: ref('PhotoMapError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as Record<string, unknown>;
      const from = q.from == null ? null : Number(q.from);
      const to = q.to == null ? null : Number(q.to);
      if ((from != null && !Number.isFinite(from)) || (to != null && !Number.isFinite(to))) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid from/to' });
      }
      const gapSec = Math.max(1, Math.min(Number(q.gapHours) || 12, 720)) * 3600;
      const maxPoints = Math.max(2, Math.min(Number(q.maxPoints) || 600, 5000));
      const libId = typeof q.libraryId === 'string' ? q.libraryId : '';
      const uid = String(req.user?.sub || '');

      let where = sql`in_trash = 0
        and latitude is not null and longitude is not null
        and library_id in (select id from photo_libraries where owner_id = ${uid})`;
      if (from != null) where = sql`${where} and taken_at >= ${from}`;
      if (to != null) where = sql`${where} and taken_at <= ${to}`;
      if (libId) where = sql`${where} and library_id = ${libId}`;

      // 上限 8 倍再抽稀：先按时间序取全，抽稀时保留首尾（画线最怕断头断尾）
      const hardCap = maxPoints * 8;
      const rows = (
        await sql<{
          id: string;
          rel_path: string;
          latitude: number;
          longitude: number;
          taken_at: number;
        }>`
          select id, rel_path, latitude, longitude, taken_at
            from photo_items
           where ${where}
           order by taken_at asc, id asc
           limit ${hardCap}
        `.execute(k.db)
      ).rows;

      const picked = thinEvenly(rows, maxPoints);
      const distanceOf = (aLat: number, aLng: number, bLat: number, bLng: number) => {
        const R = 6371;
        const dLat = ((bLat - aLat) * Math.PI) / 180;
        const dLng = ((bLng - aLng) * Math.PI) / 180;
        const s =
          Math.sin(dLat / 2) ** 2 +
          Math.cos((aLat * Math.PI) / 180) * Math.cos((bLat * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
        return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
      };

      const segments: Array<{
        startAt: number;
        endAt: number;
        distanceKm: number;
        points: Array<Record<string, unknown>>;
      }> = [];
      let cur: (typeof segments)[number] | null = null;
      let lastAt = 0;
      let lastLat = 0;
      let lastLng = 0;
      let totalKm = 0;
      for (const r of picked) {
        const p = {
          id: r.id,
          path: r.rel_path,
          latitude: Number(r.latitude),
          longitude: Number(r.longitude),
          takenAt: Number(r.taken_at),
        };
        const gap = p.takenAt - lastAt;
        if (!cur || gap > gapSec) {
          cur = { startAt: p.takenAt, endAt: p.takenAt, distanceKm: 0, points: [] };
          segments.push(cur);
        } else {
          const km = distanceOf(lastLat, lastLng, p.latitude, p.longitude);
          cur.distanceKm += km;
          totalKm += km;
        }
        cur.points.push(p);
        cur.endAt = p.takenAt;
        lastAt = p.takenAt;
        lastLat = p.latitude;
        lastLng = p.longitude;
      }

      const round = (n: number) => Math.round(n * 10) / 10;
      return {
        segments: segments.map((s) => ({ ...s, distanceKm: round(s.distanceKm) })),
        points: picked.length,
        distanceKm: round(totalKm),
        days: segments.length,
      };
    },
  );

  app.get(
    '/api/v1/photo/map/cells',
    secured('photo:read', {
      schema: {
        operationId: 'photoMapCells',
        tags: TAG,
        summary: '点开一个簇：按格集合精确取回照片（total 与角标同源）',
        querystring: ref('PhotoMapCellsQuery'),
        response: { 200: ref('PhotoMapCellsResponse'), 400: ref('PhotoMapError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const q = (req.query || {}) as { keys?: string; precision?: number; limit?: number; cursor?: string };
      const precision = Math.max(2, Math.min(Number(q.precision) || 5, 7));
      const column = GEO_COLUMN[precision];
      const keys = String(q.keys || '')
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
        .slice(0, 4000);
      if (keys.length === 0) {
        return reply.code(400).send({ error: Err.badRequest, message: 'keys required' });
      }
      const cur = decodeCursor(q.cursor);
      if (q.cursor && !cur) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid cursor' });
      }
      const limit = Math.max(1, Math.min(Number(q.limit) || 120, 500));

      const inList = sql.join(
        keys.map((key) => sql`${key}`),
        sql`, `,
      );
      const uid = String(req.user?.sub || '');
      const base = sql`in_trash = 0
        and library_id in (select id from photo_libraries where owner_id = ${uid} or owner_id = '')
        and ${sql.raw(column)} in (${inList})`;

      const totalRow = await sql<{ n: number }>`
        select count(*) as n from photo_items where ${base}
      `.execute(k.db);
      const total = Number(totalRow.rows[0]?.n) || 0;

      const pageWhere = cur
        ? sql`${base} and (taken_at < ${cur.takenAt} or (taken_at = ${cur.takenAt} and id > ${cur.id}))`
        : base;

      const rows = await sql<{
        id: string;
        rel_path: string;
        taken_at: number;
        latitude: number | null;
        longitude: number | null;
        geohash: string | null;
      }>`
        select id, rel_path, taken_at, latitude, longitude, geohash
          from photo_items
         where ${pageWhere}
         order by taken_at desc, id asc
         limit ${limit + 1}
      `.execute(k.db);

      const page = rows.rows.slice(0, limit);
      const next = rows.rows.length > limit && page.length > 0 ? page[page.length - 1] : null;
      return {
        total,
        items: page.map((r) => ({
          id: r.id,
          path: r.rel_path,
          takenAt: Number(r.taken_at),
          latitude: r.latitude == null ? null : Number(r.latitude),
          longitude: r.longitude == null ? null : Number(r.longitude),
          geohash: r.geohash,
        })),
        nextCursor: next ? encodeCursor(Number(next.taken_at), next.id) : null,
      };
    },
  );

  app.get(
    '/api/v1/photo/map/place',
    secured('photo:read', {
      schema: {
        operationId: 'photoMapPlace',
        tags: TAG,
        summary: '按真实距离取最近地名（30km 闸门，单语言）',
        querystring: ref('PhotoMapPlaceQuery'),
        response: { 200: ref('PhotoMapPlaceResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const q = (req.query || {}) as { geohash?: string; lat?: number; lng?: number; locale?: string };
      const name = describePlace(
        String(q.geohash || ''),
        q.lat == null ? null : Number(q.lat),
        q.lng == null ? null : Number(q.lng),
        q.locale,
      );
      return { name, available: placesAvailable() };
    },
  );

  app.get(
    '/api/v1/photo/map/tile-servers',
    secured('photo:read', {
      schema: {
        operationId: 'photoMapTileServers',
        tags: TAG,
        summary: '可用底图源（默认 + 自定义）',
        response: { 200: ref('PhotoMapTileServerList') },
      },
    }),
    async () => {
      const current = currentTileServer();
      const custom = k.config.get<Record<string, unknown>>('photo.map.tileServerCustom');
      const items = [
        ...BUILTIN_TILE_SERVERS.map((server, i) => ({
          ...server,
          isDefault: i === 0,
          isCurrent: current.id === server.id,
        })),
        ...(custom && custom.url
          ? [
              {
                id: String(custom.id || 'custom'),
                name: String(custom.name || '自定义底图'),
                url: String(custom.url),
                coordinate: String(custom.coordinate || 'WGS-84'),
                maxLevel: Number(custom.maxLevel) || 18,
                isDefault: false,
                isCurrent: current.id === String(custom.id || 'custom'),
              },
            ]
          : []),
      ];
      return { items };
    },
  );

  app.post(
    '/api/v1/photo/map/tile-servers/current',
    secured('photo:write', {
      schema: {
        operationId: 'photoMapTileServerSet',
        tags: TAG,
        summary: '切换底图源（内置或自定义 URL 模板）',
        body: ref('PhotoMapTileServerBody'),
        response: { 200: ref('PhotoMapTileServer'), 400: ref('PhotoMapError') },
      },
    }),
    async (req: FastifyRequest, reply: FastifyReply) => {
      const body = (req.body || {}) as {
        id?: string;
        name?: string;
        url?: string;
        coordinate?: string;
        maxLevel?: number;
      };
      const id = String(body.id || '').trim();

      const builtin = BUILTIN_TILE_SERVERS.find((server) => server.id === id);
      if (builtin) {
        await k.config.set('photo.map.tileServer', builtin);
        return {
          ...builtin,
          isDefault: id === DEFAULT_TILE_SERVER.id,
          isCurrent: true,
        };
      }

      if (!body.url || !body.url.includes('{z}')) {
        return reply.code(400).send({ error: Err.badRequest, message: 'url template required' });
      }
      const server = {
        id: id || `custom-${crypto.randomBytes(4).toString('hex')}`,
        name: String(body.name || '自定义底图').slice(0, 64),
        url: String(body.url),
        coordinate: String(body.coordinate || 'WGS-84'),
        maxLevel: Math.max(1, Math.min(Number(body.maxLevel) || 18, 22)),
      };
      await k.config.set('photo.map.tileServer', server);
      await k.config.set('photo.map.tileServerCustom', server);
      return { ...server, isDefault: false, isCurrent: true };
    },
  );
}