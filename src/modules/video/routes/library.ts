import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { scanVideoLibrary, type VideoLibraryRow } from '../scan';
import { libTypeOf, normalizeLibType } from '../media-type';
import {
  parseUnc,
  probeSmb,
  normalizeConnType,
  sealSmbPassword,
  uncPathOf,
  ONLINE_NO,
  ONLINE_UNKNOWN,
  ONLINE_YES,
} from '../smb';
import {
  SourceError,
  assertLocalSourceExists,
  normalizeSourceInput,
  replaceSources,
  sourcesOf,
  sourcesOfMany,
  type NormalizedSource,
  type SourceInput,
  type VideoSourceRow,
} from '../sources';
import { Err } from '../../../../kernel/errors';
import { TAG, newId } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { VideoHelpers } from '../helpers';

/** 来源行 → 契约 */
function sourceItemOf(r: VideoSourceRow) {
  return {
    id: r.id,
    connType: r.conn_type === 'smb' ? 'smb' : 'local',
    path: r.root_path,
    host: r.host ?? null,
    share: r.share ?? null,
    subPath: r.sub_path ?? null,
    username: r.smb_user ?? null,
    onlineState: Number(r.online_state) || ONLINE_UNKNOWN,
    onlineCheckedAt: r.online_checked_at ? Number(r.online_checked_at) : null,
    items: Number(r.items) || 0,
    lastScanAt: r.last_scan_at ?? null,
  };
}

function libraryItemOf(row: VideoLibraryRow, sources: VideoSourceRow[]) {
  const list = sources.map(sourceItemOf);
  return {
    id: row.id,
    name: row.name,
    path: row.root_path,
    items: Number(row.items) || 0,
    createdAt: row.created_at,
    lastScanAt: row.last_scan_at,
    libType: libTypeOf(row),
    connType: (row.conn_type === 'smb' ? 'smb' : 'local') as string,
    onlineState: Number(row.online_state) || ONLINE_UNKNOWN,
    onlineCheckedAt: row.online_checked_at ? Number(row.online_checked_at) : null,
    showInHome: Number(row.show_in_home ?? 1) || 0,
    sortOrder: Number(row.sort_order ?? 0) || 0,
    audioNormalize: Number(row.audio_normalize ?? 0) || 0,
    scrapeEnabled: Number(row.scrape_enabled ?? 1) || 0,
    autoScrape: Number(row.auto_scrape ?? 0) || 0,
    autoSubtitle: Number(row.auto_subtitle ?? 0) || 0,
    sources: list,
  };
}

/** 旧的单来源字段：新客户端不再发，但老客户端 / 脚本还在用 */
function legacySourceOf(body: SourceInput): SourceInput {
  return {
    connType: body.connType,
    path: body.path,
    host: body.host,
    share: body.share,
    subPath: body.subPath,
    username: body.username,
    password: body.password,
  };
}

/** 提交的来源集合：`sources[]` 优先，否则退回旧的单来源字段 */
function requestedSources(sources: SourceInput[] | undefined, body: SourceInput): SourceInput[] {
  if (Array.isArray(sources) && sources.length > 0) return sources;
  return [legacySourceOf(body)];
}

/**
 * 同一目录被两个库（或库里的两个来源）同时收进去会重复索引、重复刮削，
 * 在创建/修改时直接拒掉，比事后去重便宜得多。
 */
async function findRootClash(
  db: any,
  roots: string[],
  selfId: string | null,
): Promise<string | null> {
  if (roots.length === 0) return null;
  const list = sql.join(
    roots.map((r) => sql`${r}`),
    sql`, `,
  );
  const hit = (
    await sql<{ root_path: string }>`
      select root_path from video_library_sources
       where root_path in (${list}) and library_id <> ${selfId ?? ''}
       limit 1
    `.execute(db)
  ).rows[0];
  if (hit) return hit.root_path;
  const hit2 = (
    await sql<{ root_path: string }>`
      select root_path from video_libraries
       where root_path in (${list}) and id <> ${selfId ?? ''}
       limit 1
    `.execute(db)
  ).rows[0];
  return hit2 ? hit2.root_path : null;
}

/** 库 */
export async function registerVideoLibrary(
  app: FastifyInstance,
  k: KernelApi,
  h: VideoHelpers,
): Promise<void> {
  // ---------------------------------------------------------------- 库

  app.post(
    '/api/v1/video/libraries',
    secured('video:write', {
      schema: {
        operationId: 'videoLibraryCreate',
        tags: TAG,
        summary: '新建影视库（可一次给多个来源目录）',
        body: h.ref('VideoLibraryCreateBody'),
        response: {
          200: h.ref('VideoLibraryItem'),
          400: h.ref('VideoErrorResponse'),
          409: h.ref('VideoErrorResponse'),
        },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as SourceInput & {
        name?: string;
        libType?: string;
        sources?: SourceInput[];
      };
      const name = (body.name || '').trim();
      const libType = normalizeLibType(body.libType);
      if (!name) {
        return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      }

      const wanted = requestedSources(body.sources, body);
      let normalized: NormalizedSource[];
      try {
        normalized = wanted.map((s, i) => {
          const n = normalizeSourceInput(s, i);
          // 本地目录当场校验：路径打错的话，建完库扫出 0 条，用户会以为功能坏了
          assertLocalSourceExists(n, i);
          return n;
        });
      } catch (err) {
        const msg = err instanceof SourceError ? err.message : 'invalid source';
        return reply.code(400).send({ error: Err.badRequest, message: msg });
      }

      const roots = normalized.map((n) => n.root_path);
      if (new Set(roots).size !== roots.length) {
        return reply.code(409).send({ error: Err.conflict, message: 'duplicated source' });
      }
      const clash = await findRootClash(k.db, roots, null);
      if (clash) {
        return reply
          .code(409)
          .send({ error: Err.conflict, message: `source already in use: ${clash}` });
      }

      const id = newId();
      const now = Math.floor(Date.now() / 1000);
      const primary = normalized[0];
      await sql`
        insert into video_libraries
          (id, name, root_path, created_at, last_scan_at, items, lib_type, jp_movie,
           conn_type, host, share, sub_path, unc_path, smb_user, smb_password_enc,
           online_state, online_checked_at)
        values (${id}, ${name}, ${primary.root_path}, ${now}, null, 0, ${libType},
                ${libType === 'jp_movie' ? 1 : 0},
                ${primary.conn_type}, ${primary.host}, ${primary.share}, ${primary.sub_path},
                ${primary.unc_path}, ${primary.smb_user},
                ${primary.password_plain ? sealSmbPassword(primary.password_plain) : null},
                ${ONLINE_UNKNOWN}, null)
      `.execute(k.db);
      const sources = await replaceSources(k.db, id, normalized, sealSmbPassword);

      void h.libWatch.refresh();
      // 建完库立刻扫一遍：不扫的话列表永远是空的，看起来就像「加了个库但没东西」。
      // 走任务队列（而不是同步 await）是为了让接口立刻返回，界面能马上看到库卡片。
      void k.tasks
        .enqueueIfIdle('video.scan', { libraryId: id }, { maxAttempts: 2 })
        .catch((err) => k.log.warn({ err: String(err) }, 'enqueue scan after create failed'));

      const row = (
        await sql<VideoLibraryRow>`select * from video_libraries where id = ${id}`.execute(k.db)
      ).rows[0];
      return libraryItemOf(
        row ?? ({
          id,
          name,
          root_path: primary.root_path,
          created_at: now,
          last_scan_at: null,
          items: 0,
          lib_type: libType,
          conn_type: primary.conn_type,
          online_state: ONLINE_UNKNOWN,
          online_checked_at: null,
        } as VideoLibraryRow),
        sources,
      );
    },
  );

  app.post(
    '/api/v1/video/libraries/update',
    secured('video:write', {
      schema: {
        operationId: 'videoLibraryUpdate',
        tags: TAG,
        summary: '修改影视库（名称 / 类型 / 来源集合）',
        body: h.ref('VideoLibraryUpdateBody'),
        response: {
          200: h.ref('VideoLibraryItem'),
          400: h.ref('VideoErrorResponse'),
          404: h.ref('VideoErrorResponse'),
          409: h.ref('VideoErrorResponse'),
        },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as SourceInput & {
        id?: string;
        name?: string;
        libType?: string;
        sources?: SourceInput[];
      };
      const lib = body.id ? await h.loadLibrary(body.id) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

      const name = body.name === undefined ? lib.name : (body.name || '').trim();
      if (!name) {
        return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      }
      if (body.libType !== undefined && normalizeLibType(body.libType) !== libTypeOf(lib)) {
        return reply
          .code(400)
          .send({ error: Err.badRequest, message: 'library type is immutable' });
      }
      const libType = libTypeOf(lib);

      const hasSources =
        Array.isArray(body.sources) && body.sources.length > 0;
      const sourceTouched =
        hasSources ||
        body.connType !== undefined ||
        body.path !== undefined ||
        body.host !== undefined ||
        body.share !== undefined ||
        body.subPath !== undefined ||
        body.username !== undefined ||
        body.password !== undefined;

      const current = await sourcesOf(k.db, lib.id);
      let next: VideoSourceRow[] = current;

      if (sourceTouched) {
        // 没给 sources 时：旧的多来源整体保留，只把第一项按提交的字段改掉
        const base0 = current[0];
        const headConn = normalizeConnType(
          body.connType ?? base0?.conn_type ?? lib.conn_type ?? 'local',
        );
        const head: SourceInput = {
          connType: headConn,
          path:
            body.path ?? (headConn === 'smb' ? undefined : (base0?.root_path ?? lib.root_path)),
          host: body.host ?? base0?.host ?? lib.host ?? undefined,
          share: body.share ?? base0?.share ?? lib.share ?? undefined,
          subPath: body.subPath ?? base0?.sub_path ?? lib.sub_path ?? undefined,
          username: body.username ?? base0?.smb_user ?? lib.smb_user ?? undefined,
          password: body.password,
        };
        const wanted = hasSources
          ? (body.sources as SourceInput[])
          : [
              head,
              ...current.slice(1).map((r) => ({
                connType: r.conn_type,
                path: r.root_path,
                host: r.host ?? undefined,
                share: r.share ?? undefined,
                subPath: r.sub_path ?? undefined,
                username: r.smb_user ?? undefined,
                password: undefined,
              })),
            ];
        let normalized: NormalizedSource[];
        try {
          normalized = wanted.map((s, i) => {
            const n = normalizeSourceInput(s, i);
            assertLocalSourceExists(n, i);
            return n;
          });
        } catch (err) {
          const msg = err instanceof SourceError ? err.message : 'invalid source';
          return reply.code(400).send({ error: Err.badRequest, message: msg });
        }
        const roots = normalized.map((n) => n.root_path);
        if (new Set(roots).size !== roots.length) {
          return reply.code(409).send({ error: Err.conflict, message: 'duplicated source' });
        }
        const clash = await findRootClash(k.db, roots, lib.id);
        if (clash) {
          return reply
            .code(409)
            .send({ error: Err.conflict, message: `source already in use: ${clash}` });
        }
        next = await replaceSources(k.db, lib.id, normalized, sealSmbPassword);
      }

      const primary = next[0] ?? null;
      await sql`
        update video_libraries set
          name = ${name},
          lib_type = ${libType},
          jp_movie = ${libType === 'jp_movie' ? 1 : 0},
          root_path = ${primary ? primary.root_path : lib.root_path},
          conn_type = ${primary ? (primary.conn_type ?? 'local') : (lib.conn_type ?? 'local')},
          host = ${primary ? (primary.host ?? null) : (lib.host ?? null)},
          share = ${primary ? (primary.share ?? null) : (lib.share ?? null)},
          sub_path = ${primary ? (primary.sub_path ?? null) : (lib.sub_path ?? null)},
          unc_path = ${primary ? (primary.unc_path ?? null) : (lib.unc_path ?? null)},
          smb_user = ${primary ? (primary.smb_user ?? null) : (lib.smb_user ?? null)},
          smb_password_enc = ${primary ? (primary.smb_password_enc ?? null) : (lib.smb_password_enc ?? null)},
          online_state = ${ONLINE_UNKNOWN}
        where id = ${lib.id}
      `.execute(k.db);

      void h.libWatch.refresh();
      // 来源变了必须重扫，否则新目录里的片子永远不会入库
      if (sourceTouched) {
        void k.tasks
          .enqueueIfIdle('video.scan', { libraryId: lib.id }, { maxAttempts: 2 })
          .catch(() => null);
      }

      const row =
        (await sql<VideoLibraryRow>`select * from video_libraries where id = ${lib.id}`.execute(k.db))
          .rows[0] ?? lib;
      return libraryItemOf(row, next);
    },
  );

  app.get(
    '/api/v1/video/libraries',
    secured('video:read', {
      schema: {
        operationId: 'videoLibraryList',
        tags: TAG,
        summary: '影视库列表（含全部来源）',
        response: { 200: h.ref('VideoLibraryListResponse') },
      },
    }),
    async () => {
      const res = await sql<VideoLibraryRow>`
        select * from video_libraries
         order by coalesce(sort_order, 0) asc, created_at asc, name asc
         limit 500
      `.execute(k.db);
      const byLib = await sourcesOfMany(
        k.db,
        res.rows.map((r) => r.id),
      );
      return {
        items: res.rows.map((r) => libraryItemOf(r, byLib.get(r.id) ?? [])),
      };
    },
  );

  // 库级开关：只改行为设置，不碰来源路径 —— 所以和 /libraries/update 分开，
  // 那条路由要探测 SMB、改路径、重绑监控，改个开关不该付那套代价。
  app.post(
    '/api/v1/video/libraries/flags',
    secured('video:write', {
      schema: {
        operationId: 'videoLibraryFlags',
        tags: TAG,
        summary: '修改库级开关（首页可见 / 排序 / 响度归一 / 刮削 / 入库即刮 / 自动字幕）',
        body: h.ref('VideoLibraryFlagsBody'),
        response: { 200: h.ref('VideoLibraryItem'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as {
        id?: string;
        showInHome?: boolean;
        sortOrder?: number;
        audioNormalize?: boolean;
        scrapeEnabled?: boolean;
        autoScrape?: boolean;
        autoSubtitle?: boolean;
      };
      const lib = body.id ? await h.loadLibrary(body.id) : null;
      if (!lib) {
        return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
      }
      const id = lib.id;
      const flag = (v: boolean) => (v ? 1 : 0);
      if (body.showInHome !== undefined) {
        await sql`update video_libraries set show_in_home = ${flag(body.showInHome)} where id = ${id}`.execute(
          k.db,
        );
      }
      if (body.audioNormalize !== undefined) {
        await sql`update video_libraries set audio_normalize = ${flag(body.audioNormalize)} where id = ${id}`.execute(
          k.db,
        );
      }
      if (body.scrapeEnabled !== undefined) {
        await sql`update video_libraries set scrape_enabled = ${flag(body.scrapeEnabled)} where id = ${id}`.execute(
          k.db,
        );
      }
      if (body.autoScrape !== undefined) {
        await sql`update video_libraries set auto_scrape = ${flag(body.autoScrape)} where id = ${id}`.execute(
          k.db,
        );
      }
      if (body.autoSubtitle !== undefined) {
        await sql`update video_libraries set auto_subtitle = ${flag(body.autoSubtitle)} where id = ${id}`.execute(
          k.db,
        );
        // 打开开关时立刻补一轮，不必等下次扫描（任务内部会再确认一次开关）
        if (body.autoSubtitle) {
          void k.tasks
            .enqueueIfIdle('video.subtitle.fetch', { libraryId: id }, { maxAttempts: 2 })
            .catch((err) => k.log.warn({ err: String(err) }, 'enqueue subtitle task failed'));
        }
      }
      if (body.sortOrder !== undefined) {
        const order = Math.max(0, Math.min(Number(body.sortOrder) || 0, 99999));
        await sql`update video_libraries set sort_order = ${order} where id = ${id}`.execute(k.db);
      }

      const row =
        (
          await sql<VideoLibraryRow>`select * from video_libraries where id = ${id}`.execute(k.db)
        ).rows[0] ?? lib;
      return libraryItemOf(row, await sourcesOf(k.db, id));
    },
  );

  // SMB 片源探测：列表只读缓存，这里才是真实探测（800ms 超时 + 15s 缓存）
  app.post(
    '/api/v1/video/sources/probe',
    secured('video:write', {
      schema: {
        operationId: 'videoSourceProbe',
        tags: TAG,
        summary: '探测 SMB 来源可达性并刷新在线状态',
        body: h.ref('VideoSourceProbeBody'),
        response: { 200: h.ref('VideoSourceProbeResponse'), 400: h.ref('VideoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string; sourceId?: string; host?: string };
      let host = String(body.host || '').trim();
      let lib: VideoLibraryRow | null = null;
      let src: VideoSourceRow | null = null;

      if (body.sourceId) {
        src =
          (
            await sql<VideoSourceRow>`
              select * from video_library_sources where id = ${body.sourceId}
            `.execute(k.db)
          ).rows[0] ?? null;
        if (!src) {
          return reply.code(400).send({ error: Err.badRequest, message: 'source not found' });
        }
        lib = await h.loadLibrary(src.library_id);
        const unc = uncPathOf(src);
        if (!unc) {
          return reply.code(400).send({ error: Err.badRequest, message: 'not an smb source' });
        }
        host = parseUnc(unc).host;
      } else if (body.id) {
        lib = await h.loadLibrary(body.id);
        if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
        // 不给 sourceId 时探第一个 SMB 来源（一个库可能有多个，前端会逐个探）
        const all = await sourcesOf(k.db, lib.id);
        src = all.find((s) => uncPathOf(s)) ?? null;
        const unc = src ? uncPathOf(src) : uncPathOf(lib);
        if (!unc) {
          return reply.code(400).send({ error: Err.badRequest, message: 'not an smb source' });
        }
        host = parseUnc(unc).host;
      }
      if (!host) {
        return reply.code(400).send({ error: Err.badRequest, message: 'id or host required' });
      }

      const state = await probeSmb(host);
      const checkedAt = Math.floor(Date.now() / 1000);
      if (src) {
        await sql`
          update video_library_sources
             set online_state = ${state}, online_checked_at = ${checkedAt}
           where id = ${src.id}
        `.execute(k.db);
      }
      if (lib) {
        await sql`
          update video_libraries
             set online_state = ${state}, online_checked_at = ${checkedAt}
           where id = ${lib.id}
        `.execute(k.db);
        // 上线即补扫：刚变在线时入队一次扫描，免得「上线了但片库还是空」
        if (state === ONLINE_YES) {
          await k.tasks
            .enqueueIfIdle('video.scan', { libraryId: lib.id }, { maxAttempts: 1 })
            .catch(() => null);
        }
      }
      return {
        id: lib ? lib.id : null,
        sourceId: src ? src.id : null,
        host,
        onlineState: state === ONLINE_YES ? ONLINE_YES : state === ONLINE_NO ? ONLINE_NO : ONLINE_UNKNOWN,
        checkedAt,
      };
    },
  );

  app.post(
    '/api/v1/video/libraries/remove',
    secured('video:write', {
      schema: {
        operationId: 'videoLibraryRemove',
        tags: TAG,
        summary: '删除影视库（级联清理索引与来源）',
        body: h.ref('VideoLibraryRemoveBody'),
        response: { 200: h.ref('VideoOkResponse'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string };
      const lib = body.id ? await h.loadLibrary(body.id) : null;
      if (!lib) return reply.code(404).send({ error: Err.notFound, message: 'library not found' });

      await k.db.transaction().execute(async (trx: any) => {
        await sql`delete from video_items where library_id = ${lib.id}`.execute(trx);
        await sql`delete from image_items where library_id = ${lib.id}`.execute(trx);
        await sql`delete from video_library_sources where library_id = ${lib.id}`.execute(trx);
        await sql`delete from video_libraries where id = ${lib.id}`.execute(trx);
      });

      void h.libWatch.refresh();
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/video/scan',
    secured('video:write', {
      schema: {
        operationId: 'videoScan',
        tags: TAG,
        summary: '扫描索引（ffmpeg 提取元数据；未变文件跳过）',
        body: h.ref('VideoScanBody'),
        response: { 200: h.ref('VideoScanResponse'), 404: h.ref('VideoErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { libraryId?: string; limit?: number; prune?: boolean };
      let libs: VideoLibraryRow[];
      if (body.libraryId) {
        const one = await h.loadLibrary(body.libraryId);
        if (!one)
          return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
        libs = [one];
      } else {
        const res = await sql<VideoLibraryRow>`select * from video_libraries`.execute(k.db);
        libs = res.rows;
      }

      const total = {
        libraries: libs.length,
        videos: 0,
        images: 0,
        added: 0,
        updated: 0,
        skipped: 0,
        probed: 0,
        missing: 0,
        pruned: 0,
        nfoFilled: 0,
        errors: [] as string[],
      };
      for (const lib of libs) {
        const r = await scanVideoLibrary(k.db, lib, body.limit, undefined, {
          // 默认清理：访问检查失败时 scan 会直接报错，不会把整库误判成缺失
          prune: body.prune !== false,
        });
        total.videos += r.videos;
        total.images += r.images;
        total.added += r.added;
        total.updated += r.updated;
        total.skipped += r.skipped;
        total.probed += r.probed;
        total.missing += r.missing;
        total.pruned += r.pruned;
        total.nfoFilled += r.nfoFilled || 0;
        if (r.errors?.length) {
          for (const e of r.errors) total.errors.push(`${lib.name}: ${e}`);
          k.log.warn({ library: lib.name, errors: r.errors }, 'video.scan: source unreachable');
        }
      }
      k.log.info(total, 'video.scan');
      // 扫描完成后补字幕：入队执行（重启不丢、失败按退避重试；开关未开时 handler 直接返回 0）
      for (const lib of libs) {
        void k.tasks
          .enqueueIfIdle('video.subtitle.fetch', { libraryId: lib.id }, { maxAttempts: 2 })
          .catch((err) => k.log.warn({ err: String(err) }, 'enqueue subtitle task failed'));
      }
      return total;
    },
  );
}
