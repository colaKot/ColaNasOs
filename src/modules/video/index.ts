import { sql } from 'kysely';
import type { ServerModule } from '../../../kernel/types';
import { VIDEO_SCHEMAS } from './schemas';
import { scanVideoLibrary, type VideoLibraryRow } from './scan';
import { isVideoFile } from './ffmpeg';
import { isImageFile } from '../photo/exif';
import { bindLibraryWatch } from '../library-watch';
import {
  buildUnc,
  normalizeConnType,
  parseUnc,
  probeSmb,
  sealSmbPassword,
  uncPathOf,
  ONLINE_NO,
  ONLINE_UNKNOWN,
  ONLINE_YES,
} from './smb';
import { registerJpRoutes, fetchSubtitlesForLibrary } from './jp-routes';

import { absoluteInput, isAbsoluteInput, registerExtraRoot } from '../files/fs-root';
import {
  registerSourceRoots,
  sourcesOfMany,
  type VideoSourceRow,
} from './sources';
import { VIDEO_MIGRATIONS } from './migrations';
import { makeVideoHelpers } from './helpers';
import { registerVideoLibrary } from './routes/library';
import { registerVideoItems } from './routes/items';
import { registerVideoPlayback } from './routes/playback';
import { registerVideoSubtitles } from './routes/subtitles';
import { registerVideoCollections } from './routes/collections';
import { registerVideoBrowse } from './routes/browse';
import { registerVideoDuplicates } from './routes/duplicates';
import { registerVideoImageFolders } from './routes/image-folders';
import { registerVideoSmartAlbums } from './routes/smart-albums';
import { registerVideoScrape } from './routes/scrape';
import { scrapeItem } from './scrape';

/**
 * SP3-03 video：库 / 索引 / 列表 / 详情 / 搜索 / 海报 / 播放（一期）。
 *
 *   POST /api/v1/video/libraries        新建库
 *   GET  /api/v1/video/libraries        库列表
 *   POST /api/v1/video/libraries/remove 删除库（级联清理索引）
 *   POST /api/v1/video/scan             扫描索引（ffmpeg 提取时长/宽高/编码/字幕）
 *   GET  /api/v1/video/list             列表（多维排序 + 筛选；`series=none` 只看影片）
 *   GET  /api/v1/video/list/count       条目数（总数 / 已刮削）
 *   GET  /api/v1/video/home             首页四段（来源 / 推荐 / 继续观看 / 每库最近添加）
 *   POST /api/v1/video/watch            标记已观看（电视剧可展开全部集）
 *   POST /api/v1/video/scrape/start     刮削单条（番号优先 → TMDB）
 *   POST /api/v1/video/scrape/batch     批量刮削
 *   POST /api/v1/video/scrape/cleanup   清空刮削结果
 *   POST /api/v1/video/tmdb/search      手动搜 TMDB（纠正刮错）
 *   GET/POST /api/v1/video/tmdb/settings 刮削设置
 *   GET  /api/v1/video/art              刮削海报 / 剧照
 *   GET  /api/v1/video/series           剧集列表（剧名序 + cursor）
 *   GET  /api/v1/video/series/items     某部剧的季 / 集
 *   GET  /api/v1/video/item             详情
 *   GET  /api/v1/video/stats            总片数 / 总时长
 *   GET  /api/v1/video/poster           海报（懒生成 + 文件缓存）
 *   GET  /api/v1/video/subtitles        外挂字幕列表（同目录同主名）
 *   GET  /api/v1/video/subtitle         读一条字幕并转 WebVTT
 *   GET  /api/v1/video/stream           播放 / 下载（复用 files 的 Range / ETag）
 *
 * 合集 / 剧集 / 刮削 / 转码会话（videoPlayer）属二期；
 * 海报与探测目前直接调用 ffmpeg，后续收敛到 media sidecar。
 */
/** 监控订阅的「库 × 来源」复合视图：一个库有多个来源时，每个来源单独订阅一个根 */
export interface VideoWatchTarget extends VideoLibraryRow {
  /** 本次订阅对应的来源根（= 该来源的 root_path） */
  watchRoot?: string;
}

export const video: ServerModule = {
  id: 'video',
  prefix: '/api/v1/video',
  // 图片库 / 混合库复用相册的图片元数据读取（EXIF 宽高与拍摄时间）
  dependsOn: ['photo'],
  permissions: ['video:read', 'video:write'],

  migrations: VIDEO_MIGRATIONS,

  async register(app, k) {
    for (const schema of VIDEO_SCHEMAS) app.addSchema(schema);
    // 影视来源可以是任意本机目录：启动时恢复绝对来源根（缩略图 / 播放 / 字幕都要用）。
    // 来源表是权威清单；`video_libraries.root_path` 只兜住「来源行缺失」的老数据。
    const srcRows = await sql<VideoSourceRow>`
      select * from video_library_sources
    `.execute(k.db);
    registerSourceRoots(srcRows.rows);

    // ---- SMB 在线状态心跳（主机经常关机）
    // 每 20s 对「超过 25s 没检查过」的 SMB 来源做一次 1s 超时的 TCP 探测，写回 online_state。
    // 读接口据此隐藏离线来源的内容；从离线恢复为在线时自动入队补扫，用户不用手动点探测。
    const probeTick = async () => {
      try {
        const cut = Math.floor(Date.now() / 1000) - 25;
        const rows = (
          await sql<{
            id: string;
            library_id: string;
            host: string | null;
            unc_path: string | null;
            root_path: string;
            online_state: number | null;
          }>`
            select id, library_id, host, unc_path, root_path, online_state
              from video_library_sources
             where conn_type = 'smb'
               and (online_checked_at is null or online_checked_at <= ${cut})
             limit 200
          `.execute(k.db)
        ).rows;
        const byHost = new Map<string, typeof rows>();
        for (const r of rows) {
          let host = String(r.host || '').trim();
          if (!host) {
            try {
              host = parseUnc(String(r.unc_path || r.root_path)).host;
            } catch {
              continue;
            }
          }
          if (!host) continue;
          const arr = byHost.get(host) ?? [];
          arr.push(r);
          byHost.set(host, arr);
        }
        const checkedAt = Math.floor(Date.now() / 1000);
        for (const [host, list] of byHost) {
          const state = await probeSmb(host, { cacheMs: 0, timeoutMs: 1000 });
          for (const r of list) {
            const prev = Number(r.online_state ?? ONLINE_UNKNOWN);
            await sql`
              update video_library_sources
                 set online_state = ${state}, online_checked_at = ${checkedAt}
               where id = ${r.id}
            `.execute(k.db);
            // 库上的状态只跟随主来源（root_path = 来源根），供首页卡片隐藏整库离线
            await sql`
              update video_libraries
                 set online_state = ${state}, online_checked_at = ${checkedAt}
               where id = ${r.library_id} and root_path = ${r.root_path}
            `.execute(k.db).catch(() => undefined);
            if (state === ONLINE_YES && prev === ONLINE_NO) {
              void k.tasks
                .enqueueIfIdle('video.scan', { libraryId: r.library_id }, { maxAttempts: 1 })
                .catch(() => null);
            }
          }
        }
      } catch (err) {
        k.log.warn({ err: String(err) }, 'smb probe heartbeat failed');
      }
    };
    const probeTimer = setInterval(() => void probeTick(), 20_000);
    probeTimer.unref?.();
    app.addHook('onClose', async () => {
      clearInterval(probeTimer);
    });

    const absLibs = await sql<{ root_path: string }>`
      select distinct root_path from video_libraries
    `.execute(k.db);
    for (const row of absLibs.rows) {
      if (isAbsoluteInput(row.root_path)) registerExtraRoot(absoluteInput(row.root_path));
    }
    // SMB 来源刚被探测为在线时，入队补扫（任务队列保证去重 / 失败重试 / 重启续跑）
    k.tasks.register('video.scan', async (payload) => {
      const libraryId = String((payload as { libraryId?: string } | null)?.libraryId || '');
      if (!libraryId) return 0;
      const row = (
        await sql<VideoLibraryRow>`
          select * from video_libraries where id = ${libraryId}
        `.execute(k.db)
      ).rows[0];
      if (!row) return 0;
      const r = await scanVideoLibrary(k.db, row, undefined, undefined, { prune: true });
      // 入库即刮：只在这一轮真的新增了条目时排队，且必须由库上的 auto_scrape 显式打开。
      // 复用 scrape_enabled 会让所有存量库在下次扫描后突然开始联网——那是替用户做决定。
      if (r.added > 0 && Number(row.auto_scrape) === 1) {
        void k.tasks
          .enqueueIfIdle('video.scrape.auto', { libraryId }, { maxAttempts: 1 })
          .catch(() => null);
      }
      return r.added + r.updated;
    });
    // 自动字幕：扫描后 / 打开库开关时入队。此前只入队没有注册处理器，
    // 任务队列里是一次「未知任务」——看起来跑了，实际一个字幕都没下。
    // 日本片走 avsubtitles（番号），普通影视走多源（xunlei / assrt / opensubtitles）。
    k.tasks.register('video.subtitle.fetch', async (payload) => {
      const libraryId = String((payload as { libraryId?: string } | null)?.libraryId || '');
      if (!libraryId) return 0;
      return fetchSubtitlesForLibrary(k, libraryId);
    });
    // 自动刮削：一次最多补 batch 条，不递归续跑。
    // 理由：notfound 的条目会永远留在候选集里，链式续跑会变成"永远在刮"的死循环；
    // 剩下的量交给用户在设置页再点一次，或者由下一次扫描触发。
    k.tasks.register('video.scrape.auto', async (payload) => {
      const p = (payload || {}) as { libraryId?: string; batch?: number };
      const libraryId = String(p.libraryId || '');
      if (!libraryId) return 0;
      const lib = (
        await sql<{ auto_scrape: number | null; scrape_enabled: number | null }>`
          select auto_scrape, scrape_enabled from video_libraries where id = ${libraryId}
        `.execute(k.db)
      ).rows[0];
      if (!lib) return 0;
      // 排队后用户可能又把开关关了：执行前再确认一次
      if (Number(lib.auto_scrape) !== 1 || Number(lib.scrape_enabled) === 0) return 0;
      const batch = Math.max(1, Math.min(Number(p.batch) || 30, 200));
      const candidates = (
        await sql<{ id: string }>`
          select id from video_items
           where library_id = ${libraryId}
             -- 判据必须是 nfo_updated_at（刮削写入时一定落这个时间），不能是 nfo_tmdb_id：
             -- 日系走 scrapeJp，writeMeta 只写 nfo_source，nfo_tmdb_id 永远是 null，
             -- 结果就是「每次扫描都把最新那 30 条重刮一遍，更老的永远排不到」。
             -- notfound 也会写 nfo_updated_at（source='none'），所以不会被无限重试。
             and nfo_updated_at is null
             and coalesce(match_nfo, 1) <> 0
           order by created_at desc, id desc
           limit ${batch}
        `.execute(k.db)
      ).rows;
      let done = 0;
      for (const row of candidates) {
        try {
          const out = await scrapeItem(k, row.id, { mode: 'auto' });
          if (out.status === 'scraped') done += 1;
        } catch (e) {
          // 单条失败不打断整批（网络抖动 / TMDB 限流都会发生）
          k.log.warn({ err: e, itemId: row.id }, 'video.scrape.auto: item failed');
        }
      }
      return done;
    });
    const libWatch = bindLibraryWatch<VideoWatchTarget>({
      k,
      domain: 'video',
      // 一个库 N 个来源 → 展开成 N 条订阅记录；复合键区分，事件里仍报真实库 id
      load: async () => {
        const libs = (await sql<VideoLibraryRow>`select * from video_libraries`.execute(k.db)).rows;
        const byLib = await sourcesOfMany(
          k.db,
          libs.map((l) => l.id),
        );
        const out: VideoWatchTarget[] = [];
        for (const lib of libs) {
          const srcs = byLib.get(lib.id) ?? [];
          if (srcs.length === 0) {
            out.push({ ...lib, watchRoot: lib.root_path });
            continue;
          }
          for (const src of srcs) {
            out.push({
              ...lib,
              // 覆盖来源相关字段，让 uncPathOf / 本地根解析都按「这一个来源」来
              root_path: src.root_path,
              conn_type: src.conn_type,
              host: src.host ?? null,
              share: src.share ?? null,
              sub_path: src.sub_path ?? null,
              unc_path: src.unc_path ?? null,
              smb_user: src.smb_user ?? null,
              smb_password_enc: src.smb_password_enc ?? null,
              watchRoot: src.root_path,
            });
          }
        }
        return out;
      },
      keyOf: (lib) => `${lib.id}|${lib.watchRoot ?? ''}`,
      idOf: (lib) => lib.id,
      scan: (lib, subDir) =>
        scanVideoLibrary(k.db, lib, undefined, subDir, {
          sourceRoot: lib.watchRoot,
          // 整库监控触发的扫描也清理已删文件；子目录扫描不会 prune（数据不完整）
          prune: true,
        }),
      // 文件监控：视频 / 图片会入库；`.nfo` 不入库但**会触发增量扫描**，
      // 否则用户事后补一份 nfo，界面永远不更新（这条是真踩过的）
      accept: (name) => isVideoFile(name) || isImageFile(name) || /\.nfo$/i.test(name),
      remoteRootOf: (lib) => uncPathOf(lib),
    });
    await registerJpRoutes(app, k);
    const h = makeVideoHelpers(k, libWatch);
    await registerVideoLibrary(app, k, h);
    await registerVideoItems(app, k, h);
    await registerVideoPlayback(app, k, h);
    await registerVideoSubtitles(app, k, h);
    await registerVideoCollections(app, k, h);
    await registerVideoBrowse(app, k, h);
    await registerVideoDuplicates(app, k, h);
    registerVideoImageFolders(app, k, h);
    await registerVideoSmartAlbums(app, k, h);
    await registerVideoScrape(app, k, h);
  },
};
