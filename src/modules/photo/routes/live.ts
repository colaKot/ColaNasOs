import { createReadStream } from 'node:fs';
import fsp from 'node:fs/promises';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { etagOf, matchesEtag, parseRange } from '../../files/download';
import { TAG, type PhotoItemRow } from '../util';
import { findPairedVideo } from '../live-photo';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { PhotoHelpers } from '../helpers';

/**
 * 动态照片（Live Photo / Motion Photo）的那段视频。
 *
 * 两种来源都在这里出：
 *   motion —— 视频嵌在图片容器里。**不落盘**，直接按「虚拟文件」发：
 *             对外尺寸 = live_size，起点优先用 live_offset，缺省回落到 文件大小 - live_size。
 *             为此自己处理 Range/206（不能借 download.ts，它的尺寸是真实文件大小）。
 *             复制一份到 dataDir 也能播，但每张多几 MB，一万张就是几十 GB，不值得。
 *   apple  —— 配对视频躺在旁边（live_path 优先、同名探测回退），直接按普通文件发。
 */
export async function registerPhotoLive(
  app: FastifyInstance,
  k: KernelApi,
  h: PhotoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/photo/live',
    secured('photo:read', {
      schema: {
        operationId: 'photoLive',
        tags: TAG,
        summary: '动态照片里的那段视频（支持 Range；非动态照片 404）',
        querystring: h.ref('PhotoItemQuery'),
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { id?: string };
      const uid = String((req as any).user?.sub || '');
      const res = await sql<PhotoItemRow>`
        select id, rel_path, size, mime, live_kind, live_size, live_ms,
               live_offset, live_vendor, live_path from photo_items
         where id = ${q.id || ''}
           and library_id in (select id from photo_libraries where owner_id = ${uid})
      `.execute(k.db);
      const row = res.rows[0];
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'photo not found' });
      if (!row.live_kind) {
        return reply.code(404).send({ error: Err.notFound, message: 'not a live photo' });
      }

      let abs: string;
      try {
        abs = resolveAnyPath(filesRoot(), row.rel_path);
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
      }

      /** 对外暴露的字节区间：`base` 是原文件里的起点，`size` 是对外长度 */
      let base = 0;
      let size: number;
      let mime = 'video/mp4';
      let mtime: Date;
      try {
        let st = await fsp.stat(abs);
        if (row.live_kind === 'apple') {
          // 优先用入库时记下的配对视频绝对路径，文件不在了再按同名探测回退
          let moviePath: string | null = row.live_path ? String(row.live_path) : null;
          if (moviePath) {
            try {
              const s = await fsp.stat(moviePath);
              if (!s.isFile()) moviePath = null;
            } catch {
              moviePath = null;
            }
          }
          if (!moviePath) {
            const hit = await findPairedVideo(abs);
            moviePath = hit ? hit.path : null;
          }
          if (!moviePath) {
            return reply.code(404).send({ error: Err.notFound, message: 'live mov missing' });
          }
          abs = moviePath;
          st = await fsp.stat(abs);
          if (!st.isFile()) {
            return reply.code(404).send({ error: Err.notFound, message: 'live mov missing' });
          }
          size = st.size;
          mime = 'video/quicktime';
        } else {
          const live = Number(row.live_size) || 0;
          if (live <= 0 || live >= st.size) {
            return reply
              .code(404)
              .send({ error: Err.notFound, message: 'motion photo payload unreadable' });
          }
          // 视频未必贴在末尾（HEIF mpvd 等）：有 live_offset 就用它，否则回落到末尾
          const off = row.live_offset == null ? null : Number(row.live_offset);
          base =
            off != null && Number.isFinite(off) && off >= 0 && off + live <= st.size
              ? off
              : st.size - live;
          if (base < 0 || base + live > st.size) {
            return reply
              .code(404)
              .send({ error: Err.notFound, message: 'motion photo payload unreadable' });
          }
          size = live;
        }
        mtime = st.mtime;
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'source unreadable' });
      }

      const etag = etagOf(size, mtime.getTime());
      reply
        .header('ETag', etag)
        .header('Last-Modified', mtime.toUTCString())
        .header('Accept-Ranges', 'bytes')
        .header('Cache-Control', 'private, max-age=86400')
        .header('Content-Type', mime)
        .header('Content-Disposition', 'inline');

      const ifNoneMatch = req.headers['if-none-match'];
      if (typeof ifNoneMatch === 'string' && matchesEtag(ifNoneMatch, etag)) {
        return reply.code(304).send();
      }

      let rangeHeader = req.headers.range;
      const ifRange = req.headers['if-range'];
      if (rangeHeader && typeof ifRange === 'string' && ifRange !== etag) rangeHeader = undefined;

      const range = rangeHeader ? parseRange(rangeHeader, size) : null;
      if (range === 'unsatisfiable') {
        return reply.code(416).header('Content-Range', `bytes */${size}`).send();
      }
      if (!range) {
        reply.header('Content-Length', String(size));
        return reply.code(200).send(createReadStream(abs, { start: base, end: base + size - 1 }));
      }
      reply
        .code(206)
        .header('Content-Range', `bytes ${range.start}-${range.end}/${size}`)
        .header('Content-Length', String(range.end - range.start + 1));
      return reply.send(
        createReadStream(abs, { start: base + range.start, end: base + range.end }),
      );
    },
  );
}
