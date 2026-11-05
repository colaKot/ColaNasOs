import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { secured } from '../../../../kernel/route';
import { downloadHandler } from '../../files/download';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { writeCover, isAudioFile } from '../ffmpeg';
import { readLyrics } from '../lyrics';
import { ensureTranscoded, needsAudioTranscode } from '../transcode';
import { Err } from '../../../../kernel/errors';
import { TAG } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/** 封面 / 播放 */
export async function registerMusicPlayback(app: FastifyInstance, k: KernelApi, h: MusicHelpers): Promise<void> {
    // ---------------------------------------------------------------- 封面 / 播放

    app.get(
      '/api/v1/music/lyrics',
      secured('music:read', {
        schema: {
          operationId: 'musicLyrics',
          tags: TAG,
          summary: '歌词（旁挂 .lrc 优先，其次内嵌；可选 <base>.<lang>.lrc 双语对照）',
          querystring: h.ref('MusicLyricsQuery'),
          response: {
            200: h.ref('MusicLyricsResponse'),
            400: h.ref('MusicErrorResponse'),
            404: h.ref('MusicErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; lang?: string };
        const row = q.id ? await h.loadTrack(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'track not found' });

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        if (!fs.existsSync(abs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        // 无歌词不是错误：返回 source=none，界面提示「暂无歌词」
        return readLyrics(abs, { lang: q.lang });
      },
    );

    app.get(
      '/api/v1/music/cover',
      secured('music:read', {
        schema: {
          operationId: 'musicCover',
          tags: TAG,
          summary: '内嵌封面（首次访问生成，之后走文件缓存）',
          querystring: h.ref('MusicIdQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadTrack(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'track not found' });
        if (row.has_cover !== 1) {
          return reply.code(404).send({ error: Err.notFound, message: 'no embedded cover' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        if (!fs.existsSync(abs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        const hash = crypto
          .createHash('sha1')
          .update(`${row.rel_path}:${row.mtime}`)
          .digest('hex')
          .slice(0, 32);
        const out = path.join(k.paths.dataDir, 'covers', `${hash}.jpg`);

        const cached = fs.existsSync(out);
        k.cache.record('music.cover', cached);
        if (!cached) {
          fs.mkdirSync(path.dirname(out), { recursive: true });
          const ok = await writeCover(abs, out);
          if (!ok) {
            return reply.code(404).send({ error: Err.notFound, message: 'cover unavailable' });
          }
        }

        reply.type('image/jpeg').header('cache-control', 'public, max-age=86400');
        return reply.send(fs.createReadStream(out));
      },
    );

    app.get(
      '/api/v1/music/stream-url',
      secured('music:read', {
        schema: {
          operationId: 'musicStreamUrl',
          tags: TAG,
          summary: '生成带短期令牌的播放地址（format=auto 时 Web 端按需转 AAC）',
          querystring: h.ref('MusicStreamUrlQuery'),
          response: { 200: h.ref('MusicStreamUrlResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; format?: string };
        const row = q.id ? await h.loadTrack(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'track not found' });

        // 与影视直链同一个口径：12 小时。音乐虽然多半「一首一签」，
        // 但长音频（有声书 / 现场）缓冲超过 5 分钟后 seek 会撞 401。
        const expiresInSec = 12 * 3600;
        const token = k.auth.sign({ sub: 'music-stream', scopes: ['music:read'] }, expiresInSec);
        let transcoded = false;
        if (q.format === 'auto' && needsAudioTranscode(row)) {
          try {
            const abs = resolveAnyPath(filesRoot(), row.rel_path);
            if (fs.existsSync(abs)) transcoded = (await ensureTranscoded(k, abs, row)) !== null;
          } catch {
            // 源文件不可读 / 缺 ffmpeg：回退原始地址，不阻断播放
          }
        }
        return {
          url:
            `/api/v1/music/stream?id=${encodeURIComponent(row.id)}` +
            `&token=${encodeURIComponent(token)}${transcoded ? '&format=transcoded' : ''}`,
          expiresInSec,
          transcoded,
        };
      },
    );

    app.get(
      '/api/v1/music/stream',
      secured('music:read', {
        schema: {
          operationId: 'musicStream',
          tags: TAG,
          summary: '播放 / 下载（支持 Range / ETag；format=transcoded 读 AAC 缓存）',
          querystring: h.ref('MusicStreamQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; format?: string };
        const row = q.id ? await h.loadTrack(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'track not found' });

        if (q.format === 'transcoded') {
          let abs: string;
          try {
            abs = resolveAnyPath(filesRoot(), row.rel_path);
          } catch {
            return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
          }
          if (!fs.existsSync(abs)) {
            return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
          }
          const out = await ensureTranscoded(k, abs, row);
          if (!out) {
            return reply.code(404).send({ error: Err.notFound, message: 'transcode unavailable' });
          }
          return downloadHandler(req, reply, { path: out });
        }
        return downloadHandler(req, reply, { path: row.rel_path });
      },
    );

}
