import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { secured } from '../../../../kernel/route';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { writePoster } from '../ffmpeg';
import { isOfflinePath, offlineSmbPrefixes } from '../sources';
import { Err } from '../../../../kernel/errors';
import { TAG } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/** 海报 / 播放 */
export async function registerVideoPlayback(app: FastifyInstance, k: KernelApi, h: VideoHelpers): Promise<void> {
    // ---------------------------------------------------------------- 海报 / 播放

    app.get(
      '/api/v1/video/poster',
      secured('video:read', {
        schema: {
          operationId: 'videoPoster',
          tags: TAG,
          summary: '影片海报（首次访问生成，之后走文件缓存）',
          querystring: h.ref('VideoIdQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadAnyItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'item not found' });
        // SMB 离线：直接 404，不碰网络盘（同步 stat 死机会把整个内核拖住）
        if (isOfflinePath(row.rel_path, await offlineSmbPrefixes(k.db))) {
          return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        // 异步存在性检查：网络盘挂掉时不会阻塞事件循环
        try {
          await fsp.access(abs);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        // 图片条目：海报就是原图（前端网格通常还会走 /files/thumb 缩略图）
        if (String(row.media_type || '') === 'image') {
          reply
            .type(String(row.container || 'application/octet-stream'))
            .header('cache-control', 'public, max-age=86400');
          return reply.send(fs.createReadStream(abs));
        }

        const hash = crypto
          .createHash('sha1')
          .update(`${row.rel_path}:${row.mtime}`)
          .digest('hex')
          .slice(0, 32);
        const out = path.join(k.paths.dataDir, 'posters', `${hash}.jpg`);

        if (!fs.existsSync(out)) {
          fs.mkdirSync(path.dirname(out), { recursive: true });
          const ok = await writePoster(abs, out, row.duration);
          if (!ok) {
            return reply.code(404).send({ error: Err.notFound, message: 'poster unavailable' });
          }
        }

        reply.type('image/jpeg').header('cache-control', 'public, max-age=86400');
        return reply.send(fs.createReadStream(out));
      },
    );

    app.get(
      '/api/v1/video/stream-url',
      secured('video:read', {
        schema: {
          operationId: 'videoStreamUrl',
          tags: TAG,
          summary: '生成带短期令牌的播放地址（可直接交给外部播放器）',
          querystring: h.ref('VideoIdQuery'),
          response: { 200: h.ref('VideoStreamUrlResponse'), 404: h.ref('VideoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });

        // 外部播放器无法带 Authorization 头：签一个 5 分钟、只含 video:read 的令牌
        const expiresInSec = 300;
        const token = k.auth.sign({ sub: 'video-stream', scopes: ['video:read'] }, expiresInSec);
        return {
          url: `/api/v1/video/stream?id=${encodeURIComponent(row.id)}&token=${encodeURIComponent(token)}`,
          expiresInSec,
        };
      },
    );

}
