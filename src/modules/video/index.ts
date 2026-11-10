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
  verifySmbShare,
  openSmbPassword,
  sealSmbPassword,
  uncPathOf,
  ONLINE_NO,
  ONLINE_UNKNOWN,
  ONLINE_YES,
} from './smb';
import { registerJpRoutes, fetchSubtitlesForLibrary } from './jp-routes';
import { backfillActorThumbs } from './jp-links';
import { fetchActorProfile } from './jp-actor';

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
import { registerVideoFacets } from './routes/facets';
import { registerVideoPlayback } from './routes/playback';
import { registerVideoSubtitles } from './routes/subtitles';
import { registerVideoCollections } from './routes/collections';
import { registerVideoBrowse } from './routes/browse';
import { registerVideoDuplicates, deleteVideoItems } from './routes/duplicates';
import { registerVideoImageFolders } from './routes/image-folders';
import { registerVideoSmartAlbums } from './routes/smart-albums';
import { registerVideoScrape } from './routes/scrape';
import { computeScrapeStats, saveScrapeStats } from './scrape-stats';
import { registerVideoSettings, hlsRoot, transcodeConf } from './routes/settings';
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
            smb_user: string | null;
            smb_password_enc: string | null;
          }>`
            select id, library_id, host, unc_path, root_path, online_state,
                   smb_user, smb_password_enc
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
          let state = await probeSmb(host, { cacheMs: 0, timeoutMs: 1000 });
          // 端口通 ≠ 共享能读：服务在但共享没挂 / 凭据过期时，内容不该继续露出来
          if (state === ONLINE_YES) {
            const sample = list[0];
            const shareOk = await verifySmbShare(
              String(sample.root_path || ''),
              sample.smb_user ?? null,
              openSmbPassword(sample.smb_password_enc ?? null),
            );
            if (!shareOk) state = ONLINE_NO;
          }
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
            // 状态翻转时广播：客户端据此「连上才让 SMB 内容出现」，不用自己定时轮询探测。
            // 只在翻转时发，正常心跳不产生事件（历史环形队列只有 256 条）。
            if (state !== prev) {
              k.events.emit('video.smb.online', {
                libraryId: r.library_id,
                sourceId: r.id,
                onlineState: state,
              });
            }
          }
        }
      } catch (err) {
        k.log.warn({ err: String(err) }, 'smb probe heartbeat failed');
      }
    };
    // 启动就先探一轮：否则「刚打开客户端」的 20s 内，SMB 库用的是上次关机前的旧状态，
    // 断网时会去碰不存在的网络盘（请求超时、列表空白却不说明原因）。
    // 不 await：探测失败也不能拖慢内核启动。
    void probeTick();
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
    k.tasks.register('video.scan', async (payload, ctx) => {
      const libraryId = String((payload as { libraryId?: string } | null)?.libraryId || '');
      if (!libraryId) return 0;
      const row = (
        await sql<VideoLibraryRow>`
          select * from video_libraries where id = ${libraryId}
        `.execute(k.db)
      ).rows[0];
      if (!row) return 0;
      // 百分比按来源粒度报，条目数按文件粒度报：一个来源要扫几万文件时，
      // 只给百分比的话面板会长时间停在 0%，看起来像没动
      let pct = 0;
      const r = await scanVideoLibrary(k.db, row, undefined, undefined, {
        prune: true,
        onProgress: (p) => {
          pct = p;
          void ctx.progress(p);
        },
        onFiles: (done, total) => void ctx.progress(pct, done, total),
      });
      // 入库即刮：只在这一轮真的新增了条目时排队，且必须由库上的 auto_scrape 显式打开。
      // 复用 scrape_enabled 会让所有存量库在下次扫描后突然开始联网——那是替用户做决定。
      if (r.added > 0 && Number(row.auto_scrape) === 1) {
        void k.tasks
          .enqueueIfIdle('video.scrape.auto', { libraryId }, { maxAttempts: 1 })
          .catch(() => null);
      }
      return r.added + r.updated;
    });
    // 每日刮削进度统计（2026-11-04）：只读本地库，不联网、几十毫秒。
    // 结果写 video_scrape_stats（一天一行），任务面板里也能看到这条跑过。
    k.tasks.register('video.scrape.progress', async (_payload, ctx) => {
      const stats = await computeScrapeStats(k.db);
      await saveScrapeStats(k.db, stats);
      // 进度条用「已刮 / 总数」，面板不用点进去就知道还差多少
      await ctx.progress(
        stats.total > 0 ? Math.round((stats.scraped / stats.total) * 100) : 100,
        stats.scraped,
        stats.total,
      );
      k.log.info(
        {
          scraped: stats.scraped,
          unscraped: stats.unscraped,
          noCNoSub: stats.noCNoSub,
        },
        'video.scrape.progress',
      );
      return 1;
    });
    // 演员头像回填（2026-11-04）：老库的 thumb_path 全空，而 NFO 里其实带着
    // `<actor><thumb>`。增量扫描会跳过未变文件，所以必须单独读一趟 NFO。
    k.tasks.register('video.actor.thumbs', async (payload, ctx) => {
      const p = payload as { libraryId?: string } | null;
      const r = await backfillActorThumbs(k.db, {
        libraryId: p?.libraryId,
        onProgress: (done, total) =>
          void ctx.progress(total > 0 ? Math.round((done / total) * 100) : 100, done, total),
      });
      k.log.info({ scanned: r.scanned, updated: r.updated }, 'video.actor.thumbs');
      return r.updated;
    });
    // 演员档案（身高 / 三围 / 生日 / 出身地）：来自日文维基，需要联网。
    // 头像不走这里（本地 NFO 就有），所以 withJavdb=false —— JavDB 不可达时
    // 每个演员要白等 8s 超时，一千多个演员就是几小时。
    k.tasks.register('video.actor.profile', async (payload, ctx) => {
      const p = payload as { limit?: number } | null;
      const limit = Math.max(1, Math.min(Number(p?.limit) || 600, 20000));
      const rows = (
        await sql<{ id: string; name: string }>`
          select a.id, a.name
            from jp_actors a
            left join jp_actor_items ai on ai.actor_id = a.id
           where coalesce(a.profile, '') = ''
           group by a.id, a.name
           order by count(ai.item_id) desc
           limit ${limit}
        `.execute(k.db)
      ).rows;
      const total = rows.length;
      if (total === 0) return 0;

      const nowSec = Math.floor(Date.now() / 1000);
      let done = 0;
      let filled = 0;
      const queue = [...rows];
      const worker = async () => {
        for (;;) {
          const a = queue.shift();
          if (!a) return;
          try {
            const prof = await fetchActorProfile(a.name, {
              dataDir: k.paths.dataDir,
              withJavdb: false,
              timeoutMs: 6000,
            });
            // 抓不到也落一条「已尝试」的占位（source 为空），避免每次都重新打维基；
            // 档案缓存 7 天过期，之后还会再试
            const body = prof ?? {
              key: a.id,
              name: a.name,
              avatarUrl: null,
              birthday: null,
              heightCm: null,
              bust: null,
              waist: null,
              hips: null,
              birthplace: null,
              source: [],
              fetchedAt: Date.now(),
            };
            await sql`
              update jp_actors set profile = ${JSON.stringify(body)}, updated_at = ${nowSec}
               where id = ${a.id}
            `.execute(k.db);
            if (prof) filled += 1;
          } catch {
            /* 单个失败不阻塞整批 */
          }
          done += 1;
          if (done % 5 === 0) void ctx.progress(Math.round((done / total) * 100), done, total);
        }
      };
      await Promise.all([worker(), worker(), worker()]);
      k.log.info({ total, filled }, 'video.actor.profile');
      return filled;
    });
    // 删除（后台任务）：查重页一次删几十个，SMB 上要几分钟。入队后客户端拿 taskId
    // 轮询进度，不再让 HTTP 请求顶着 30s 超时（2026-11-03 报的 TimeoutException）。
    k.tasks.register('video.items.delete', async (payload, ctx) => {
      const p = payload as { ids?: string[]; permanent?: boolean } | null;
      const ids = (p?.ids || []).filter((v) => typeof v === 'string' && v.trim() !== '');
      if (ids.length === 0) return 0;
      const r = await deleteVideoItems(k, ids, {
        onProgress: (done, total) =>
          void ctx.progress(
            Math.round((done / Math.max(1, total)) * 100),
            done,
            total,
          ),
        // 每条之间检查一次取消：跨卷复制一个 8 GB 的片要两分钟，不能等到全删完才发现
        shouldStop: () => ctx.isCanceled(),
        permanent: p?.permanent === true,
      });
      // 收尾上报真实条数：complete() 会把 done 对齐成 total，
      // 有失败时必须先把真实值写进去，否则界面显示「16/16 完成」但列表里还剩 8 个
      await ctx.progress(100, r.done.length, ids.length);
      if (r.failed.length > 0) {
        k.log.warn(
          { requested: ids.length, done: r.done.length, failed: r.failed.length },
          'video.items.delete: partial failure',
        );
        // 抛错让任务标记 failed：客户端弹窗能看到具体原因，也不会谎报全部成功
        throw new Error(
          `${r.failed.length} 个文件没删掉（成功 ${r.done.length}/${ids.length}）：` +
            r.failed
              .slice(0, 3)
              .map((f) => `${f.path.split('/').pop()} - ${f.error}`)
              .join('；'),
        );
      }
      return r.done.length;
    });
    // 自动字幕：扫描后 / 打开库开关时入队。此前只入队没有注册处理器，
    // 任务队列里是一次「未知任务」——看起来跑了，实际一个字幕都没下。
    // 日本片走 avsubtitles（番号），普通影视走多源（xunlei / assrt / opensubtitles）。
    k.tasks.register('video.subtitle.fetch', async (payload, ctx) => {
      const libraryId = String((payload as { libraryId?: string } | null)?.libraryId || '');
      if (!libraryId) return 0;
      return fetchSubtitlesForLibrary(k, libraryId, (pct, done, total) =>
        void ctx.progress(pct, done, total),
      );
    });
    // 启动即补字幕：开了「自动补字幕」的库在内核重启后立刻排一轮，
    // 不用等下一次扫描或每日调度（此前只有开关 / 扫描 / 每日定时器会入队）。
    try {
      const libs = (
        await sql<{ id: string }>`
          select id from video_libraries where auto_subtitle = 1
        `.execute(k.db)
      ).rows;
      for (const lib of libs) {
        await k.tasks
          .enqueueIfIdle('video.subtitle.fetch', { libraryId: lib.id }, { maxAttempts: 2 })
          .catch(() => null);
      }
      if (libs.length > 0) {
        k.log.info({ libs: libs.length }, 'video.subtitle.fetch enqueued on startup');
      }
    } catch (err) {
      k.log.warn({ err: String(err) }, 'video.subtitle startup enqueue failed');
    }
    // 自动刮削：一次最多补 batch 条，不递归续跑。
    // 理由：notfound 的条目会永远留在候选集里，链式续跑会变成"永远在刮"的死循环；
    // 剩下的量交给用户在设置页再点一次，或者由下一次扫描触发。
    k.tasks.register('video.scrape.auto', async (payload, ctx) => {
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
      for (let i = 0; i < candidates.length; i += 1) {
        const row = candidates[i];
        // 任务面板的进度条要动起来：按已处理条数上报（完成时队列会置 100）
        void ctx.progress(Math.round((i / candidates.length) * 100), i, candidates.length);
        try {
          const out = await scrapeItem(k, row.id, { mode: 'auto' });
          if (out.status === 'scraped') {
            done += 1;
          } else if (out.status === 'notfound') {
            // 已在网上搜过且确实没匹配：落 nfo_updated_at 让它退出候选集。
            // 否则同一批 notfound 每次扫描都被重刮一遍，进度永远不动、更老的条目排不上。
            // unavailable / failed（没网、限流）不落时间，网络恢复后还会重试。
            await sql`
              update video_items set nfo_updated_at = ${Math.floor(Date.now() / 1000)}
               where id = ${row.id}
            `.execute(k.db);
          }
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
      scan: async (lib, subDir) => {
        const result = await scanVideoLibrary(k.db, lib, undefined, subDir, {
          sourceRoot: lib.watchRoot,
          // 整库监控触发的扫描也清理已删文件；子目录扫描不会 prune（数据不完整）
          prune: true,
        });
        // 下载完成后文件监控直接扫、不经过 video.scan 任务，挂在任务里的
        // 自动刮削钩子碰不到。判据与任务版一致：真有新增 + 库显式开了「入库即刮」。
        // enqueueIfIdle 自带去重，多子目录连续触发也只排一次。
        if (result.added > 0 && Number(lib.auto_scrape) === 1) {
          void k.tasks
            .enqueueIfIdle('video.scrape.auto', { libraryId: lib.id }, { maxAttempts: 1 })
            .catch(() => null);
        }
        return result;
      },
      // 文件监控：视频 / 图片会入库；`.nfo` 不入库但**会触发增量扫描**，
      // 否则用户事后补一份 nfo，界面永远不更新（这条是真踩过的）
      accept: (name) => isVideoFile(name) || isImageFile(name) || /\.nfo$/i.test(name),
      remoteRootOf: (lib) => uncPathOf(lib),
    });
    await registerJpRoutes(app, k);
    const h = makeVideoHelpers(k, libWatch);
    await registerVideoLibrary(app, k, h);
    await registerVideoItems(app, k, h);
    await registerVideoFacets(app, k, h);
    await registerVideoPlayback(app, k, h);
    await registerVideoSubtitles(app, k, h);
    await registerVideoCollections(app, k, h);
    await registerVideoBrowse(app, k, h);
    await registerVideoDuplicates(app, k, h);
    registerVideoImageFolders(app, k, h);
    await registerVideoSmartAlbums(app, k, h);
    await registerVideoScrape(app, k, h);
    await registerVideoSettings(app, k);
  },
};
