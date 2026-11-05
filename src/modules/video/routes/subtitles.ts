import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { downloadHandler } from '../../files/download';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { listSubtitles, readSubtitle } from '../subtitles';
import {
  embeddedIndex,
  embeddedSubtitleFiles,
  readEmbeddedSubtitle,
} from '../embedded-subs';
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
        const external = listSubtitles(abs);
        // 内嵌字幕轨（文本类）一并列出，名字用 `#embedded:<index>`。
        // media 不可用 / 解析失败时返回空数组，不影响外挂字幕。
        const embedded = await embeddedSubtitleFiles(k, abs, row.mtime);
        return { items: [...external, ...embedded] };
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
          // 内嵌字幕（`#embedded:<n>`）：按需抽轨到缓存，再走同一套解析
          const emb = q.name ? embeddedIndex(q.name) : null;
          if (emb !== null) {
            const parsed = await readEmbeddedSubtitle(k, abs, row.mtime, emb);
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
          }
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

    // 库级补全字幕：入队 video.subtitle.fetch（任务面板能看到进度，失败也留记录）
    app.post(
      '/api/v1/video/subtitle/fetch-library',
      secured('video:write', {
        schema: {
          operationId: 'videoSubtitleFetchLibrary',
          tags: TAG,
          summary: '按库补全字幕（入队 video.subtitle.fetch）',
          body: Type.Object({
            id: Type.String({ minLength: 1, description: '影视库 id' }),
          }),
          response: {
            200: Type.Object({
              id: Type.String(),
              taskId: Type.String(),
              reused: Type.Boolean({ description: 'true = 已有同库任务在跑，没重复入队' }),
            }),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const id = String(body.id || '');
        if (!id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
        const lib = await h.loadLibrary(id);
        if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
        const r = await k.tasks.enqueueIfIdle(
          'video.subtitle.fetch',
          { libraryId: id },
          { maxAttempts: 2 },
        );
        return { id, taskId: r.id, reused: r.reused };
      },
    );
}
