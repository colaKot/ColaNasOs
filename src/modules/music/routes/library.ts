import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import {
  absoluteInput,
  filesRoot,
  isAbsoluteInput,
  registerExtraRoot,
  resolveInRoot,
} from '../../files/fs-root';
import { pathVisible, visibilityOf } from '../../files/visibility';
import { scanMusicLibrary, type MusicLibraryRow } from '../scan';
import { transcodeCacheDir } from '../transcode';
import { Err } from '../../../../kernel/errors';
import { TAG, newId } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/**
 * 来源（= 曲库目录）是**全局共享**的：有 `music:write` 权限的人配一次，
 * 所有用户看同一批歌（歌单 / 收藏 / 播放记录 / 合集才是按用户隔离的）。
 */

/** 扫描入参（同步接口与任务队列共用） */
type MusicScanInput = { libraryId?: string; limit?: number; prune?: boolean };

interface MusicScanTotal {
  libraries: number;
  tracks: number;
  added: number;
  updated: number;
  skipped: number;
  probed: number;
  missing: number;
  pruned: number;
}

/**
 * 执行一轮音乐扫描（同步路由与 `music.scan` 任务共用）。
 * 与 photo / video 一样：几万文件的库同步扫描会超过客户端 30s 超时，
 * 界面必须走 `/scan/enqueue` + 任务进度，这里只负责真正的扫描逻辑。
 */
export async function runMusicScan(
  k: KernelApi,
  h: MusicHelpers,
  body: MusicScanInput,
): Promise<MusicScanTotal> {
  let libs: MusicLibraryRow[];
  if (body.libraryId) {
    const one = await h.loadLibrary(body.libraryId);
    if (!one) throw Object.assign(new Error('library not found'), { code: 'E_NOT_FOUND' });
    libs = [one];
  } else {
    libs = (await sql<MusicLibraryRow>`select * from music_libraries`.execute(k.db)).rows;
  }

  const total: MusicScanTotal = {
    libraries: libs.length,
    tracks: 0,
    added: 0,
    updated: 0,
    skipped: 0,
    probed: 0,
    missing: 0,
    pruned: 0,
  };
  for (const lib of libs) {
    const r = await scanMusicLibrary(k.db, lib, body.limit, undefined, { prune: body.prune === true });
    total.tracks += r.tracks;
    total.added += r.added;
    total.updated += r.updated;
    total.skipped += r.skipped;
    total.probed += r.probed;
    total.missing += r.missing;
    total.pruned += r.pruned;
    // 手动扫描也要广播：文件监控触发的扫描会发 `scan.done`，手动这条以前只写日志，
    // 结果就是「点了扫描，曲目页还停在旧列表」，得手动下拉才更新。
    k.events.emit('scan.done', {
      domain: 'music',
      libraryId: lib.id,
      added: r.added,
      updated: r.updated,
      missing: r.missing,
    });
  }
  k.log.info(total, 'music.scan');
  return total;
}

/** 库 */
export async function registerMusicLibrary(app: FastifyInstance, k: KernelApi, h: MusicHelpers): Promise<void> {
    // ---------------------------------------------------------------- 库

    app.post(
      '/api/v1/music/libraries',
      secured('music:write', {
        schema: {
          operationId: 'musicLibraryCreate',
          tags: TAG,
          summary: '新建音乐库（目录须在 files 根内）',
          body: h.ref('MusicLibraryCreateBody'),
          response: {
            200: h.ref('MusicLibraryItem'),
            400: h.ref('MusicErrorResponse'),
            409: h.ref('MusicErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { name?: string; path?: string };
        const name = (body.name || '').trim();
        const raw = (body.path || '').trim();
        if (!name || !raw) {
          return reply.code(400).send({ error: Err.badRequest, message: 'name and path required' });
        }

        // 绝对路径（D:/music、\\host\share\music）直接收：音乐来源和影视 / 相册一样，
        // 用户想加的是「本机哪个目录」，不是「files 根下的哪个子目录」。
        // 相对路径仍按 files 根解析，老数据不受影响。
        let rel: string;
        let abs: string;
        const absolute = isAbsoluteInput(raw);
        try {
          if (absolute) {
            abs = path.resolve(absoluteInput(raw));
            rel = absoluteInput(abs);
          } else {
            abs = resolveInRoot(filesRoot(), raw);
            rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
          }
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path escapes root' });
        }
        if (!rel) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path must be a subdirectory' });
        }
        let st;
        try {
          st = fs.statSync(abs);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'path not found' });
        }
        if (!st.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path is not a directory' });
        }
        // 绝对来源要登记进可读白名单，否则扫描时 resolveAnyPath 会判越界
        if (absolute) registerExtraRoot(abs);

        const existing = await sql<{ id: string }>`
          select id from music_libraries where root_path = ${rel}
        `.execute(k.db);
        if (existing.rows.length > 0) {
          return reply.code(409).send({ error: Err.conflict, message: 'library already exists' });
        }

        const id = newId();
        const now = Math.floor(Date.now() / 1000);
        await sql`
          insert into music_libraries (id, name, root_path, created_at, last_scan_at, items)
          values (${id}, ${name}, ${rel}, ${now}, null, 0)
        `.execute(k.db);

        void h.libWatch.refresh();
        return { id, name, path: rel, items: 0, createdAt: now, lastScanAt: null };
      },
    );

    app.get(
      '/api/v1/music/libraries',
      secured('music:read', {
        schema: {
          operationId: 'musicLibraryList',
          tags: TAG,
          summary: '音乐库列表',
          response: { 200: h.ref('MusicLibraryListResponse') },
        },
      }),
      async (req) => {
        const vis = visibilityOf(k.config, req.user);
        const res = await sql<MusicLibraryRow>`
          select * from music_libraries order by created_at, name limit 500
        `.execute(k.db);
        // 只显示来源目录落在授权范围内的库；超级管理员不受限。
        return {
          items: res.rows
            .filter((r) => pathVisible(vis, r.root_path))
            .map((r) => ({
            id: r.id,
            name: r.name,
            path: r.root_path,
            items: Number(r.items) || 0,
            createdAt: r.created_at,
            lastScanAt: r.last_scan_at,
          })),
        };
      },
    );

    app.post(
      '/api/v1/music/libraries/remove',
      secured('music:write', {
        schema: {
          operationId: 'musicLibraryRemove',
          tags: TAG,
          summary: '删除音乐库（级联清理曲目与歌单引用）',
          body: h.ref('MusicLibraryRemoveBody'),
          response: { 200: h.ref('MusicOkResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const lib = body.id ? await h.loadLibrary(body.id) : null;
        if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

        await k.db.transaction().execute(async (trx: any) => {
          await sql`
            delete from music_playlist_items
             where track_id in (select id from music_tracks where library_id = ${lib.id})
          `.execute(trx);
          await sql`delete from music_tracks where library_id = ${lib.id}`.execute(trx);
          await sql`delete from music_libraries where id = ${lib.id}`.execute(trx);
        });

        void h.libWatch.refresh();
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/music/scan',
      secured('music:write', {
        schema: {
          operationId: 'musicScan',
          tags: TAG,
          summary: '扫描索引（ffmpeg 解析 tags / 时长；未变文件跳过）',
          body: h.ref('MusicScanBody'),
          response: { 200: h.ref('MusicScanResponse'), 404: h.ref('MusicErrorResponse') },
        },
      }),
      async (req, reply) => {
        try {
          return await runMusicScan(k, h, (req.body || {}) as MusicScanInput);
        } catch (err) {
          if ((err as { code?: string })?.code === 'E_NOT_FOUND')
            return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
          throw err;
        }
      },
    );

    // 入队扫描：点「扫描」立刻返回，进度走 /tasks（同步 /scan 保留给脚本与冒烟测试）
    app.post(
      '/api/v1/music/scan/enqueue',
      secured('music:write', {
        schema: {
          operationId: 'musicScanEnqueue',
          tags: TAG,
          summary: '入队扫描（立即返回任务 id；进度与失败记录见 /tasks）',
          body: h.ref('MusicScanBody'),
          response: {
            200: Type.Object({
              tasks: Type.Array(
                Type.Object({
                  libraryId: Type.String(),
                  taskId: Type.String(),
                  reused: Type.Boolean({ description: 'true = 已有同库扫描在排队/运行' }),
                }),
              ),
            }),
            404: h.ref('MusicErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as MusicScanInput;
        let libs: MusicLibraryRow[];
        if (body.libraryId) {
          const one = await h.loadLibrary(body.libraryId);
          if (!one)
            return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
          libs = [one];
        } else {
          libs = (await sql<MusicLibraryRow>`select * from music_libraries`.execute(k.db)).rows;
        }
        const out: Array<{ libraryId: string; taskId: string; reused: boolean }> = [];
        for (const lib of libs) {
          // 同库已有扫描在排队/运行时复用同一个任务，避免连点堆任务
          const r = await k.tasks.enqueueIfIdle(
            'music.scan',
            { ...body, libraryId: lib.id },
            { maxAttempts: 1 },
          );
          out.push({ libraryId: lib.id, taskId: r.id, reused: r.reused });
        }
        return { tasks: out };
      },
    );

    // 扫描任务：内核重启不丢；payload 与同步接口同一套入参
    k.tasks.register('music.scan', async (payload) =>
      runMusicScan(k, h, (payload || {}) as MusicScanInput),
    );

    // ---------------------------------------------------------------- 缓存
    // 转码产出（`dataDir/music-transcode`）占用与清理：客户端设置页用。
    // 这些文件随时可以重建，清理不影响曲库索引。

    app.get(
      '/api/v1/music/cache',
      secured('music:read', {
        schema: {
          operationId: 'musicCacheStats',
          tags: TAG,
          summary: '音乐转码缓存占用',
          response: { 200: h.ref('MusicCacheStatsResponse') },
        },
      }),
      async () => {
        const dir = transcodeCacheDir(k);
        let files = 0;
        let bytes = 0;
        let names: string[];
        try {
          names = await fs.promises.readdir(dir);
        } catch {
          return { files: 0, bytes: 0 };
        }
        for (const name of names) {
          try {
            const st = await fs.promises.stat(path.join(dir, name));
            if (st.isFile()) {
              files += 1;
              bytes += st.size;
            }
          } catch {
            /* 正被删除 / 无权限：跳过 */
          }
        }
        return { files, bytes };
      },
    );

    app.post(
      '/api/v1/music/cache/clear',
      secured('music:write', {
        schema: {
          operationId: 'musicCacheClear',
          tags: TAG,
          summary: '清空音乐转码缓存',
          response: { 200: h.ref('MusicCacheClearResponse') },
        },
      }),
      async () => {
        const dir = transcodeCacheDir(k);
        let removed = 0;
        let bytes = 0;
        let names: string[];
        try {
          names = await fs.promises.readdir(dir);
        } catch {
          return { removed: 0, bytes: 0 };
        }
        for (const name of names) {
          const file = path.join(dir, name);
          try {
            const st = await fs.promises.stat(file);
            if (!st.isFile()) continue;
            await fs.promises.rm(file, { force: true });
            removed += 1;
            bytes += st.size;
          } catch {
            /* 单个文件失败不影响其它 */
          }
        }
        k.log.info({ removed, bytes }, 'music.cache.clear');
        return { removed, bytes };
      },
    );

}
