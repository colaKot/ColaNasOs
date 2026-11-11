import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { TRASH_DIR, movePath } from '../../files/ops';
import { effectiveSources, offlineCond, offlineSmbPrefixes } from '../sources';
import { libTypeOf } from '../media-type';
import {
  dirExpr,
  folderPathOf,
  folderSegments,
  hideSameNameImageCond,
  parentFolderOf,
  requireRoot,
  rootsOf,
  scopeCond,
} from '../image-scope';
import { TAG, imageToMediaRow, toItem, type MediaRow } from '../util';
import {
  bindVideoListCacheInvalidation,
  videoListCacheClear,
  videoListCacheGet,
  videoListCacheKey,
  videoListCacheSet,
} from '../list-cache';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/**
 * 图片库 / 混合库的文件夹层级。
 *
 * 只列**直接子文件夹** + 本级文件数；封面取每个目录的第一张图 / 第一个视频。
 * 路径使用带来源根的完整 rel_path，天然支持多来源。
 */
export function registerVideoImageFolders(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): void {
  bindVideoListCacheInvalidation(k);
  app.get(
    '/api/v1/video/image/folders',
    secured('video:read', {
      schema: {
        operationId: 'videoImageFolders',
        tags: TAG,
        summary: '图片库 / 混合库的文件夹层级（子文件夹 / 封面 / 数量）',
        querystring: h.ref('VideoImageFolderQuery'),
        response: { 200: h.ref('VideoImageFolderResponse'), 403: h.ref('VideoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { libraryId?: string; folderPath?: string };
      const lib = q.libraryId ? await h.loadLibrary(String(q.libraryId)) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
      const libType = libTypeOf(lib);

      let currentPath: string;
      try {
        currentPath = folderPathOf(q.folderPath);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid folder path' });
      }
      const sources = await effectiveSources(k.db, lib);
      const roots = rootsOf(sources);
      if (currentPath) {
        try {
          requireRoot(currentPath, roots);
        } catch {
          return reply.code(403).send({ error: Err.forbidden, message: 'folder outside library' });
        }
      }

      const empty = {
        path: currentPath,
        parentPath: null,
        segments: [],
        folders: [],
        selfCount: 0,
        selfImageCount: 0,
        selfVideoCount: 0,
        hasSubFolders: false,
      };
      if (libType !== 'image' && libType !== 'mixed') return empty;
      if (roots.length === 0) return empty;

      const scopeRoots = currentPath ? [currentPath] : roots;
      const offline = await offlineSmbPrefixes(k.db);
      // 文件夹聚合是整库 group by（最重的一条），同样按「库 + 当前目录 + 离线前缀」缓存。
      const cacheKey = videoListCacheKey('folders', {
        libraryId: lib.id,
        folderPath: currentPath,
        offline: offline.join(','),
      });
      const cached = videoListCacheGet(cacheKey);
      if (cached) return cached as any;
      const imgDir = dirExpr('i');
      const imgRows = (
        await sql<{ dir: string; cnt: number; cover_id: string | null }>`
          select ${imgDir} as dir, count(*) as cnt, min(i.id) as cover_id
            from image_items i
           where i.library_id = ${lib.id}
             and ${scopeCond('i', currentPath, 'subtree', roots)}
             ${libType === 'mixed' ? sql`and ${hideSameNameImageCond('i')}` : sql``}
             ${offline.length > 0 ? sql`and ${offlineCond(offline, 'i.rel_path')}` : sql``}
           group by ${imgDir}
           order by dir asc
        `.execute(k.db)
      ).rows;

      const vidRows =
        libType === 'mixed'
          ? (
              await sql<{ dir: string; cnt: number; cover_id: string | null }>`
                select ${dirExpr('v')} as dir, count(*) as cnt, min(v.id) as cover_id
                  from video_items v
                 where v.library_id = ${lib.id}
                   and v.media_type = 'video'
                   and ${scopeCond('v', currentPath, 'subtree', roots)}
                   ${offline.length > 0 ? sql`and ${offlineCond(offline, 'v.rel_path')}` : sql``}
                 group by ${dirExpr('v')}
                 order by dir asc
              `.execute(k.db)
            ).rows
          : [];

      type Entry = {
        name: string;
        path: string;
        imageCount: number;
        videoCount: number;
        coverId: string;
        coverKind: 'image' | 'video';
      };
      const map = new Map<string, Entry>();
      let selfImageCount = 0;
      let selfVideoCount = 0;

      const fold = (
        rows: Array<{ dir: string; cnt: number; cover_id: string | null }>,
        kind: 'image' | 'video',
      ) => {
        for (const r of rows) {
          const dir = String(r.dir || '').replace(/\/+$/, '');
          const count = Number(r.cnt) || 0;
          if (!dir || count <= 0) continue;
          const root = scopeRoots.find((x) => dir === x || dir.startsWith(`${x}/`));
          if (!root) continue;
          const rel = dir === root ? '' : dir.slice(root.length + 1);
          if (!rel) {
            if (kind === 'image') selfImageCount += count;
            else selfVideoCount += count;
            continue;
          }
          const seg = rel.split('/')[0];
          if (!seg) continue;
          const childPath = `${root}/${seg}`;
          let e = map.get(childPath);
          if (!e) {
            e = {
              name: seg,
              path: childPath,
              imageCount: 0,
              videoCount: 0,
              coverId: '',
              coverKind: kind,
            };
            map.set(childPath, e);
          }
          if (kind === 'image') e.imageCount += count;
          else e.videoCount += count;
          const coverId = String(r.cover_id || '');
          if (!e.coverId && coverId) {
            e.coverId = coverId;
            e.coverKind = kind;
          }
        }
      };
      fold(imgRows, 'image');
      fold(vidRows, 'video');

      const imageCoverIds = [...map.values()]
        .filter((e) => e.coverKind === 'image' && e.coverId)
        .map((e) => e.coverId);
      const videoCoverIds = [...map.values()]
        .filter((e) => e.coverKind === 'video' && e.coverId)
        .map((e) => e.coverId);
      const covers = new Map<string, MediaRow>();
      if (imageCoverIds.length > 0) {
        const rows = (
          await sql<{
            id: string;
            library_id: string;
            rel_path: string;
            title: string;
            size: number;
            mtime: number;
            width: number | null;
            height: number | null;
            taken_at: number | null;
            mime: string | null;
          }>`
            select * from image_items
             where id in (${sql.join(imageCoverIds.map((id) => sql`${id}`), sql`, `)})
          `.execute(k.db)
        ).rows;
        for (const r of rows) covers.set(r.id, imageToMediaRow(r));
      }
      if (videoCoverIds.length > 0) {
        const rows = (
          await sql<MediaRow>`
            select * from video_items
             where id in (${sql.join(videoCoverIds.map((id) => sql`${id}`), sql`, `)})
          `.execute(k.db)
        ).rows;
        for (const r of rows) covers.set(r.id, r);
      }

      const folders = [...map.values()]
        .map((e) => {
          const cover = covers.get(e.coverId);
          return {
            name: e.name,
            path: e.path,
            count: e.imageCount + e.videoCount,
            imageCount: e.imageCount,
            videoCount: e.videoCount,
            cover: cover ? toItem(cover) : null,
          };
        })
        .sort((a, b) => String(a.name).localeCompare(String(b.name), 'zh'));

      const root = currentPath ? requireRoot(currentPath, roots) : null;
      const result = {
        path: currentPath,
        parentPath: parentFolderOf(currentPath, root),
        segments: folderSegments(currentPath, root),
        folders,
        selfCount: selfImageCount + selfVideoCount,
        selfImageCount,
        selfVideoCount,
        hasSubFolders: folders.length > 0,
      };
      videoListCacheSet(cacheKey, result);
      return result;
    },
  );

  // 文件夹删除：整个目录移入回收站，并清掉该前缀下的图片 / 视频索引
  app.post(
    '/api/v1/video/image/folders/delete',
    secured('video:write', {
      schema: {
        operationId: 'videoImageFolderDelete',
        tags: TAG,
        summary: '删除图片库 / 混合库的一个文件夹（移入回收站）',
        body: h.ref('VideoImageFolderDeleteBody'),
        response: { 200: h.ref('VideoImageFolderDeleteResponse'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req: any, reply: any) => {
      const body = (req.body || {}) as { libraryId?: string; path?: string };
      const lib = body.libraryId ? await h.loadLibrary(String(body.libraryId)) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
      const sources = await effectiveSources(k.db, lib);
      const roots = rootsOf(sources);
      let target: string;
      let root: string | null;
      try {
        target = folderPathOf(body.path);
        if (!target) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });
        root = requireRoot(target, roots);
      } catch {
        return reply.code(403).send({ error: Err.forbidden, message: 'folder outside library' });
      }
      if (transportTarget(target, root)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'cannot delete library root' });
      }

      const abs = resolveAnyPath(filesRoot(), target);
      const batch = new Date()
        .toISOString()
        .replace(/[-:]/g, '')
        .replace(/\..+$/, '')
        .replace('T', '-');
      const destDir = path.join(filesRoot(), TRASH_DIR, batch);
      fs.mkdirSync(destDir, { recursive: true });
      let dest = path.join(destDir, path.basename(abs));
      let n = 1;
      while (fs.existsSync(dest)) {
        dest = path.join(destDir, `${path.basename(abs)}-${n}`);
        n += 1;
      }
      await movePath(abs, dest);

      const prefix = `${target}/`;
      const res = await k.db.transaction().execute(async (trx: any) => {
        const img = await sql`
          delete from image_items
           where library_id = ${lib.id}
             and (rel_path = ${target} or substr(rel_path, 1, ${prefix.length}) = ${prefix})
        `.execute(trx);
        const vid = await sql`
          delete from video_items
           where library_id = ${lib.id}
             and (rel_path = ${target} or substr(rel_path, 1, ${prefix.length}) = ${prefix})
        `.execute(trx);
        await sql`
          update video_libraries
             set items = (select count(*) from video_items where library_id = video_libraries.id)
                       + (select count(*) from image_items where library_id = video_libraries.id)
           where id = ${lib.id}
        `.execute(trx);
        return Number(img.numAffectedRows ?? 0) + Number(vid.numAffectedRows ?? 0);
      });
      // 删了整个目录，列表 / 文件夹缓存都得作废
      videoListCacheClear();
      return { removed: res, trashedTo: batch };
    },
  );
}

/** 当前目录不能等于来源根（删根会把整个库搬走） */
function transportTarget(target: string, root: string | null): boolean {
  return !root || target === root;
}
