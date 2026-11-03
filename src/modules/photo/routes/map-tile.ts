
import fsp from 'node:fs/promises';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import { TAG } from '../util';
import { tileServerById } from '../map';

/**
 * 底图瓦片本地缓存代理（SP3-02 二期）。
 *
 * 客户端地图改为请求 `GET /photo/map/tile?z&x&y&server=`：
 *   - 命中 `dataDir/photo-tiles/<server>/<z>/<x>/<y>.png`（30 天内）直接回；
 *   - 未命中时服务端拉外部模板（8s 超时、≤2 MB），落盘后返回；
 *   - 外部失败时若有旧缓存就回旧的（地图不至于整片空白）。
 *
 * 为什么不让客户端直连：内网 NAS 多数网络到 OSM 超时，且每次打开地图都重复下载。
 * 鉴权用普通 header（flutter_map 的 TileLayer 支持 headers），无需 query token。
 */
const TILE_TTL_MS = 30 * 24 * 3_600_000;
const FETCH_TIMEOUT_MS = 8000;
const MAX_TILE_BYTES = 2 * 1024 * 1024;

const TileQuery = Type.Object({
  z: Type.Integer({ minimum: 0, maximum: 19 }),
  x: Type.Integer({ minimum: 0 }),
  y: Type.Integer({ minimum: 0 }),
  server: Type.Optional(Type.String({ maxLength: 64 })),
});

function safeSegment(value: string): string {
  return value.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64) || 'custom';
}

function tileUrl(template: string, z: number, x: number, y: number): string {
  return template
    .replaceAll('{z}', String(z))
    .replaceAll('{x}', String(x))
    .replaceAll('{y}', String(y));
}

export async function registerPhotoMapTile(app: FastifyInstance, k: KernelApi): Promise<void> {
  app.get(
    '/api/v1/photo/map/tile',
    secured('photo:read', {
      schema: {
        operationId: 'photoMapTile',
        tags: TAG,
        summary: '底图瓦片（本地缓存代理，30 天）',
        querystring: TileQuery,
        response: {
          200: Type.Unsafe({ type: 'string', format: 'binary' }),
          400: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
          404: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
          502: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
        },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { z?: number; x?: number; y?: number; server?: string };
      const z = Number(q.z);
      const x = Number(q.x);
      const y = Number(q.y);
      if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'z/x/y required' });
      }
      const maxIndex = 2 ** z;
      if (z < 0 || z > 19 || x < 0 || y < 0 || x >= maxIndex || y >= maxIndex) {
        return reply.code(400).send({ error: Err.badRequest, message: 'tile index out of range' });
      }

      const server = tileServerById(k, q.server);
      if (!server) {
        return reply.code(404).send({ error: Err.notFound, message: 'tile server not found' });
      }

      const file = path.join(
        k.paths.dataDir,
        'photo-tiles',
        safeSegment(server.id),
        String(z),
        String(x),
        `${y}.png`,
      );
      const sendFile = async (buf: Buffer) =>
        reply
          .header('cache-control', 'public, max-age=86400')
          .type('image/png')
          .send(buf);

      let stale: Buffer | null = null;
      try {
        const stat = await fsp.stat(file);
        const buf = await fsp.readFile(file);
        if (Date.now() - stat.mtimeMs < TILE_TTL_MS) return sendFile(buf);
        stale = buf;
      } catch {
        /* 未命中 */
      }

      try {
        const res = await fetch(tileUrl(server.url, z, x, y), {
          signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
          headers: { 'user-agent': 'ColaNasOs/1.0 (+tile-cache)' },
        });
        if (!res.ok) throw new Error(`upstream HTTP ${res.status}`);
        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.length > MAX_TILE_BYTES) throw new Error('tile too large');
        await fsp.mkdir(path.dirname(file), { recursive: true });
        await fsp.writeFile(file, buf);
        return sendFile(buf);
      } catch (err) {
        if (stale) {
          k.log.warn({ err, server: server.id, z, x, y }, 'photo tile: upstream failed, serve stale');
          return sendFile(stale);
        }
        k.log.warn({ err, server: server.id, z, x, y }, 'photo tile: upstream failed');
        return reply
          .code(502)
          .send({ error: Err.unavailable, message: 'tile upstream unavailable' });
      }
    },
  );
}

/** 仅用于冒烟/运维：瓦片缓存路径（不保证存在） */
export function tileCachePath(dataDir: string, serverId: string, z: number, x: number, y: number): string {
  return path.join(
    dataDir,
    'photo-tiles',
    safeSegment(serverId),
    String(z),
    String(x),
    `${y}.png`,
  );
}
