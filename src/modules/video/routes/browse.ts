import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { TRASH_DIR, movePath } from '../../files/ops';
import { pathVisible, visibilityOf } from '../../files/visibility';
import { effectiveSources, sourceLabelOf } from '../sources';
import { isVideoFile } from '../ffmpeg';
import { isImageFile } from '../../photo/exif';
import { uncPathOf, ONLINE_NO } from '../smb';
import { TAG, toItem, type MediaRow } from '../util';
import { deleteVideoItems } from './duplicates';
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

/** 路径是否存在（lstat：不跟随软链，删的是链接本身） */
async function exists(abs: string): Promise<boolean> {
  try {
    await fsp.lstat(abs);
    return true;
  } catch {
    return false;
  }
}

/**
 * 把一条路径（文件或整个目录）移进回收站；`permanent` 时直接删。
 *
 * 回收站放**同一个卷**上（`<卷根>/.colanas-trash/<批次>/<名字>`），同卷 rename
 * 瞬时完成、不占额外空间；卷根不可写时退回 files 根下的回收站，`movePath`
 * 会自己退化成「复制 + 删源」。这套口径与 `deleteVideoItems` 保持一致。
 */
async function trashLocal(abs: string, permanent: boolean): Promise<string | null> {
  if (permanent) {
    await fsp.rm(abs, { recursive: true, force: true });
    return null;
  }
  const root = filesRoot();
  const underRoot = abs === root || abs.startsWith(root + path.sep);
  const vol = underRoot ? root : path.parse(abs).root || root;
  const batch = new Date()
    .toISOString()
    .replace(/[-:]/g, '')
    .replace(/\..+$/, '')
    .replace('T', '-');
  let dir = path.join(vol, TRASH_DIR, batch);
  try {
    await fsp.mkdir(dir, { recursive: true });
  } catch {
    dir = path.join(root, TRASH_DIR, batch);
    await fsp.mkdir(dir, { recursive: true });
  }
  const base = path.basename(abs);
  let dest = path.join(dir, base);
  let n = 1;
  while (await exists(dest)) {
    const ext = path.extname(base);
    dest = path.join(dir, `${path.basename(base, ext)}-${n}${ext}`);
    n += 1;
  }
  await movePath(abs, dest);
  return dest;
}

/**
 * 媒体浏览：
 * 按「库 → 来源 → 目录」逐级浏览，文件夹 + 图片 + 视频混合返回；
 * 视频带条目 id，可直接开详情 / 海报。
 * 只列一层（不做递归），避免大库一次扫全盘；SMB 来源离线时直接 503，
 * 不让 readdir 在不可达共享上卡住整个请求。
 *
 * 多来源库必须按 `sourceId` 落到具体来源根：一个库的片源分散在几个盘 /
 * 几台 NAS 上，只认 `library.root_path` 会让第二、第三个来源永远打不开。
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
        summary: '按库来源目录浏览（文件夹 / 图片 / 视频）',
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
      const q = (req.query || {}) as { libraryId?: string; sourceId?: string; path?: string };
      const lib = q.libraryId ? await h.loadLibrary(String(q.libraryId)) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

      const sources = await effectiveSources(k.db, lib);
      const src = q.sourceId
        ? sources.find((s) => s.id === String(q.sourceId))
        : sources[0];
      if (!src) {
        return reply.code(404).send({ error: Err.notFound, message: 'source not found' });
      }

      // 库列表已经按授权过滤，按 id / 来源直接浏览同样要拦：否则小号拿着库 id
      // 就能翻到没授权的库（用户 2026-11-14 反馈「只给了一个影视文件夹」）。
      // 多来源库里可能只授权了其中一个来源，判定要落在**来源根**上。
      const vis = visibilityOf(k.config, req.user);
      if (!vis.unrestricted && !pathVisible(vis, src.root_path)) {
        return reply.code(404).send({ error: Err.notFound, message: 'source not found' });
      }

      let rel: string;
      try {
        rel = normalizeBrowsePath(q.path);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid path' });
      }

      const unc = uncPathOf(src);
      if (unc && Number(src.online_state) === ONLINE_NO) {
        return reply
          .code(503)
          .send({ error: Err.unavailable, message: 'smb source offline' });
      }

      let absDir: string;
      try {
        absDir = unc
          ? path.join(unc, ...(rel ? rel.split('/') : []))
          : resolveAnyPath(filesRoot(), rel ? `${src.root_path}/${rel}` : src.root_path);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'path escapes library' });
      }

      // 多来源库里可能只有部分来源被授权（如只授权了 UNC 共享），
      // 真正要读的绝对目录也必须落在授权范围内，不能借「库可见」翻别的来源。
      if (!vis.unrestricted && !pathVisible(vis, absDir)) {
        return reply.code(404).send({ error: Err.notFound, message: 'path not found' });
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

      // 已索引条目的完整信息：浏览页直接用影视列表那张封面卡渲染，
      // 所以这里一次把当前目录的条目取全（含刮削名 / 封面标记 / 已看状态），
      // 不再让前端拿着 id 一条条回表。
      const prefix = `${src.root_path}/${rel}`.replace(/\/+$/, '');
      const byPath = new Map<string, ReturnType<typeof toItem>>();
      try {
        const uid = String(req.user?.sub || '');
        const rows = (
          await sql<MediaRow & { watched: number; taken_at: number | null }>`
            select v.*, cast(v.mtime / 1000 as integer) as taken_at,
                   exists(select 1 from video_watch w
                           where w.item_id = v.id and w.owner_id = ${uid}) as watched
              from video_items v
             where v.library_id = ${lib.id} and v.rel_path like ${`${prefix}/%`}
             limit 5000
          `.execute(k.db)
        ).rows;
        for (const r of rows) byPath.set(r.rel_path, toItem(r));
      } catch {
        // 映射失败只影响封面卡，不影响浏览
      }

      // 子目录里的影片计数：某个文件夹（子树）里只放了一条影片时（一人一片那种
      // 「番号目录」），浏览页直接显示这条影片本身 —— 让人为一部片多点两下没意义。
      // 只数已索引的影片，不再逐个 readdir 子目录：SMB 上那是几十次网络往返。
      const singleVideoOf = new Map<string, ReturnType<typeof toItem>>();
      {
        const counts = new Map<string, number>();
        for (const [relPath, item] of byPath) {
          if (String(item.mediaType) !== 'video') continue;
          const rest = relPath.startsWith(`${prefix}/`) ? relPath.slice(prefix.length + 1) : '';
          const seg = rest.split('/')[0];
          // 直接躺在当前目录里的文件不算子目录
          if (!seg || seg === rest) continue;
          const n = (counts.get(seg) ?? 0) + 1;
          counts.set(seg, n);
          if (n === 1) singleVideoOf.set(seg, item);
          else singleVideoOf.delete(seg);
        }
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
            item: null,
            singleVideo: singleVideoOf.get(e.name) ?? null,
          });
          continue;
        }
        if (!e.isFile()) continue;
        const mediaType = isVideoFile(e.name) ? 'video' : isImageFile(e.name) ? 'image' : 'other';
        const fullRel = `${src.root_path}/${childRel}`.replace(/^\/+/, '');
        const row = mediaType === 'other' ? undefined : byPath.get(fullRel);
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
          id: mediaType === 'video' ? row?.id ?? null : null,
          size,
          mtime,
          item: row ?? null,
          singleVideo: null,
        });
      }

      items.sort((a, b) => {
        if (a.dir !== b.dir) return a.dir ? -1 : 1;
        return a.name.localeCompare(b.name);
      });

      return {
        libraryId: lib.id,
        path: rel,
        rootPath: src.root_path,
        sourceId: src.id,
        sourceName: sourceLabelOf(src),
        items,
      };
    },
  );

  // ---------------------------------------------------------------- 删除
  //
  // 浏览页的右键删除：文件、文件夹都能删。语义三条：
  //   1. 已索引的条目走 `deleteVideoItems`：文件移入回收站，索引 / 观看进度 /
  //      收藏一起清，库条目数重算（与查重页的删除是同一套账）；
  //   2. 文件夹里剩下的（没索引的文件、只有侧车的目录）整条移入回收站，
  //      不留一个空壳让人以为「没删掉」；
  //   3. 来源根本身不许删 —— 一次误点会带走整块盘。
  app.post(
    '/api/v1/video/browse/delete',
    secured('video:write', {
      schema: {
        operationId: 'videoBrowseDelete',
        tags: TAG,
        summary: '删除浏览目录里的文件 / 文件夹（默认进回收站，索引一起清）',
        body: h.ref('VideoBrowseDeleteBody'),
        response: {
          200: h.ref('VideoBrowseDeleteResponse'),
          400: h.ref('VideoErrorResponse'),
          404: h.ref('VideoErrorResponse'),
          503: h.ref('VideoErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as {
        libraryId?: string;
        sourceId?: string;
        path?: string;
        permanent?: boolean;
      };
      const lib = body.libraryId ? await h.loadLibrary(String(body.libraryId)) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

      const sources = await effectiveSources(k.db, lib);
      const src = body.sourceId
        ? sources.find((s) => s.id === String(body.sourceId))
        : sources[0];
      if (!src) return reply.code(404).send({ error: Err.notFound, message: 'source not found' });

      const vis = visibilityOf(k.config, req.user);
      if (!vis.unrestricted && !pathVisible(vis, src.root_path)) {
        return reply.code(404).send({ error: Err.notFound, message: 'source not found' });
      }

      let rel: string;
      try {
        rel = normalizeBrowsePath(body.path);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid path' });
      }
      if (!rel) {
        return reply
          .code(400)
          .send({ error: Err.badRequest, message: 'refuse to delete source root' });
      }

      const unc = uncPathOf(src);
      if (unc && Number(src.online_state) === ONLINE_NO) {
        return reply
          .code(503)
          .send({ error: Err.unavailable, message: 'smb source offline' });
      }

      let abs: string;
      try {
        abs = unc
          ? path.join(unc, ...rel.split('/'))
          : resolveAnyPath(filesRoot(), `${src.root_path}/${rel}`);
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'path escapes library' });
      }
      if (!vis.unrestricted && !pathVisible(vis, abs)) {
        return reply.code(404).send({ error: Err.notFound, message: 'path not found' });
      }

      let isDir: boolean;
      try {
        isDir = (await fsp.lstat(abs)).isDirectory();
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'path not found' });
      }

      const permanent = body.permanent === true;
      const relPrefix = `${src.root_path}/${rel}`.replace(/\/+$/, '');
      let ids: string[] = [];
      try {
        const [vids, iids] = await Promise.all([
          sql<{ id: string }>`
            select id from video_items
             where library_id = ${lib.id}
               and (rel_path = ${relPrefix} or rel_path like ${`${relPrefix}/%`})
          `.execute(k.db),
          sql<{ id: string }>`
            select id from image_items
             where library_id = ${lib.id}
               and (rel_path = ${relPrefix} or rel_path like ${`${relPrefix}/%`})
          `.execute(k.db),
        ]);
        ids = [...vids.rows.map((r) => r.id), ...iids.rows.map((r) => r.id)];
      } catch {
        // 索引查询失败也照样删文件：剩下的幽灵条目下一次扫描会清掉
      }

      let removed = 0;
      let failed = 0;
      let trashedTo: string | null = null;
      if (ids.length > 0) {
        const res = await deleteVideoItems(k, ids, { permanent });
        removed = res.done.length;
        failed += res.failed.length;
        trashedTo = res.trashedTo || null;
      }

      // 文件夹 / 没索引的文件：整条进回收站
      if (await exists(abs)) {
        try {
          const dest = await trashLocal(abs, permanent);
          trashedTo = trashedTo ?? dest;
        } catch (err) {
          failed += 1;
          k.log.warn({ path: abs, err: String(err) }, 'video.browse.delete: trash failed');
        }
      }

      return { removed, folder: isDir, trashedTo, failed };
    },
  );
}
