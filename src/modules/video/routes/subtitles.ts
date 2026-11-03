import path from 'node:path';
import { secured } from '../../../../kernel/route';
import { downloadHandler } from '../../files/download';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { listSubtitles, readSubtitle } from '../subtitles';
import { isOfflinePath, offlineSmbPrefixes } from '../sources';
import { Err } from '../../../../kernel/errors';
import { TAG } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/** 外挂字幕 */
export async function registerVideoSubtitles(app: FastifyInstance, k: KernelApi, h: VideoHelpers): Promise<void> {
    // ---------------------------------------------------------------- 外挂字幕

    app.get(
      '/api/v1/video/subtitles',
      secured('video:read', {
        schema: {
          operationId: 'videoSubtitles',
          tags: TAG,
          summary: '外挂字幕列表（与影片同目录、同主名）',
          querystring: h.ref('VideoIdQuery'),
          response: { 200: h.ref('VideoSubtitleListResponse'), 404: h.ref('VideoErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });
        if (isOfflinePath(row.rel_path, await offlineSmbPrefixes(k.db))) {
          return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        return { items: listSubtitles(abs) };
      },
    );

    app.get(
      '/api/v1/video/subtitle',
      secured('video:read', {
        schema: {
          operationId: 'videoSubtitle',
          tags: TAG,
          summary: '读取一条外挂字幕（srt / ass / ssa / vtt → WebVTT）',
          querystring: h.ref('VideoSubtitleQuery'),
          response: {
            200: h.ref('VideoSubtitleResponse'),
            404: h.ref('VideoErrorResponse'),
            413: h.ref('VideoErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; name?: string };
        const row = q.id ? await h.loadItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });
        if (isOfflinePath(row.rel_path, await offlineSmbPrefixes(k.db))) {
          return reply.code(404).send({ error: Err.notFound, message: 'source offline' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        try {
          const parsed = q.name ? readSubtitle(abs, q.name) : null;
          if (!parsed) {
            return reply.code(404).send({ error: Err.notFound, message: 'subtitle not found' });
          }
          return {
            name: parsed.file.name,
            lang: parsed.file.lang,
            format: parsed.file.format,
            cues: parsed.cues,
            vtt: parsed.vtt,
          };
        } catch (err) {
          if ((err as { code?: string }).code === 'tooLarge') {
            return reply.code(413).send({ error: Err.tooLarge, message: 'subtitle exceeds 5 MB' });
          }
          return reply.code(404).send({ error: Err.notFound, message: 'subtitle unreadable' });
        }
      },
    );

    app.get(
      '/api/v1/video/stream',
      secured('video:read', {
        schema: {
          operationId: 'videoStream',
          tags: TAG,
          summary: '播放 / 下载（支持 Range / ETag）',
          querystring: h.ref('VideoIdQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadItem(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'video not found' });
        // 来源离线：播放/下载立刻返回 503，不要交给下载处理器去等网络盘
        if (isOfflinePath(row.rel_path, await offlineSmbPrefixes(k.db))) {
          return reply.code(503).send({ error: Err.unavailable, message: 'smb source offline' });
        }
        return downloadHandler(req, reply, { path: row.rel_path });
      },
    );
}
