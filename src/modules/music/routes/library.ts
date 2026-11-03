import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { filesRoot, resolveInRoot } from '../../files/fs-root';
import { scanMusicLibrary, type MusicLibraryRow } from '../scan';
import { Err } from '../../../../kernel/errors';
import { TAG, newId } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

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

        let rel: string;
        let abs: string;
        try {
          abs = resolveInRoot(filesRoot(), raw);
          rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
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
      async () => {
        const res = await sql<MusicLibraryRow>`
          select * from music_libraries order by created_at, name limit 500
        `.execute(k.db);
        return {
          items: res.rows.map((r) => ({
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
        const body = (req.body || {}) as { libraryId?: string; limit?: number; prune?: boolean };
        let libs: MusicLibraryRow[];
        if (body.libraryId) {
          const one = await h.loadLibrary(body.libraryId);
          if (!one) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
          libs = [one];
        } else {
          const res = await sql<MusicLibraryRow>`select * from music_libraries`.execute(k.db);
          libs = res.rows;
        }

        const total = {
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
        }
        k.log.info(total, 'music.scan');
        return total;
      },
    );

}
