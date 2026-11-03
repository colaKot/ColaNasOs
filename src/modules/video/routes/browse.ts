import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { isVideoFile } from '../ffmpeg';
import { isImageFile } from '../../photo/exif';
import { uncPathOf, ONLINE_NO } from '../smb';
import { TAG } from '../util';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/** 归一化库内相对路径：拒绝绝对路径与 `..`（阻断目录穿越） */
function normalizeBrowsePath(input: string | undefined): string {
  const rel = String(input || '')
    .replace(/\\/g, '/')
    .replace(/^\/+/, '')
    .replace(/\/+$/, '');
  if (!rel) return '';
  for (const seg of rel.split('/')) {
    if (seg === '..' || seg === '.') {
      throw Object.assign(new Error('invalid path'), { code: 'E_PARAM' });
    }
  }
  return rel;
}

/**
 * 媒体浏览：
 * 按影视库目录逐级浏览，文件夹 + 图片 + 视频混合返回；视频带条目 id，可直接开详情 / 海报。
 *
 * 只列一层（不做递归），避免大库一次扫全盘；SMB 源离线时直接 503，
 * 不让 readdir 在不可达共享上卡住整个请求。
 */
export async function registerVideoBrowse(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  app.get(
    '/api/v1/video/browse',
    secured('video:read', {
      schema: {
        operationId: 'videoBrowse',
        tags: TAG,
        summary: '按库目录浏览（文件夹 / 图片 / 视频）',
        querystring: h.ref('VideoBrowseQuery'),
        response: {
          200: h.ref('VideoBrowseResponse'),
          400: h.ref('VideoErrorResponse'),
          404: h.ref('VideoErrorResponse'),
          503: h.ref('VideoErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const q = (req.query || {}) as { libraryId?: string; path?: string };
      const lib = q.libraryId ? await h.loadLibrary(String(q.libraryId)) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

      let rel: string;
      try {
        rel = normalizeBrowsePath(q.path);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid path' });
      }

      const unc = uncPathOf(lib);
      if (unc && Number(lib.online_state) === ONLINE_NO) {
        return reply
          .code(503)
          .send({ error: Err.unavailable, message: 'smb source offline' });
      }

      let absDir: string;
      try {
        absDir = unc
          ? path.join(unc, ...(rel ? rel.split('/') : []))
          : resolveAnyPath(filesRoot(), rel ? `${lib.root_path}/${rel}` : lib.root_path);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'path escapes library' });
      }

      let entries;
      try {
        entries = await fsp.readdir(absDir, { withFileTypes: true });
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code;
        if (code === 'ENOENT' || code === 'ENOTDIR') {
          return reply.code(404).send({ error: Err.notFound, message: 'path not found' });
        }
        if (code === 'EACCES') {
          return reply.code(403).send({ error: Err.forbidden, message: 'permission denied' });
        }
        return reply.code(503).send({ error: Err.unavailable, message: 'read failed' });
      }

      // 视频 id 映射：只查当前目录前缀下的条目（避免整库回表）
      const prefix = `${lib.root_path}/${rel}`.replace(/\/+$/, '');
      const ids = new Map<string, string>();
      try {
        const rows = (
          await sql<{ id: string; rel_path: string }>`
            select id, rel_path from video_items
             where library_id = ${lib.id} and rel_path like ${`${prefix}/%`}
             limit 5000
          `.execute(k.db)
        ).rows;
        for (const r of rows) ids.set(r.rel_path, r.id);
      } catch {
        // 映射失败只影响视频 id，不影响浏览
      }

      const items = [];
      for (const e of entries) {
        if (e.isSymbolicLink()) continue;
        const childRel = rel ? `${rel}/${e.name}` : e.name;
        if (e.isDirectory()) {
          items.push({
            name: e.name,
            path: childRel,
            dir: true,
            mediaType: 'dir',
            id: null,
            size: null,
            mtime: null,
          });
          continue;
        }
        if (!e.isFile()) continue;
        const mediaType = isVideoFile(e.name) ? 'video' : isImageFile(e.name) ? 'image' : 'other';
        const fullRel = `${lib.root_path}/${childRel}`.replace(/^\/+/, '');
        let size: number | null = null;
        let mtime: number | null = null;
        try {
          const st = await fsp.stat(path.join(absDir, e.name));
          size = st.size;
          mtime = Math.floor(st.mtimeMs);
        } catch {
          // 扫描期间被删除：仍返回名字，详情交给下一层
        }
        items.push({
          name: e.name,
          path: childRel,
          dir: false,
          mediaType,
          id: mediaType === 'video' ? ids.get(fullRel) ?? null : null,
          size,
          mtime,
        });
      }

      items.sort((a, b) => {
        if (a.dir !== b.dir) return a.dir ? -1 : 1;
        return a.name.localeCompare(b.name);
      });

      return {
        libraryId: lib.id,
        path: rel,
        rootPath: lib.root_path,
        items,
      };
    },
  );
}
