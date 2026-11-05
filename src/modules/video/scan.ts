import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { resolveAnyPath } from '../files/fs-root';
import { walkFiles } from '../files/walk';
import { mapLimit } from '../media/concurrency';
import { isImageFile, mimeOf, readImageMeta } from '../photo/exif';
import { extensionOf, isVideoFile, probeVideo, titleOf } from './ffmpeg';
import { parseActorNames, syncActorLinks } from './jp-links';
import { imageTitleOf, jpMetaOf, libTypeOf } from './media-type';
import { firstLetterOf, naturalKeyOf } from './image-scope';
import { hasLocalMeta, ingestNfo } from './nfo-ingest';
import { findNfoFile } from './nfo';
import { parseEpisode } from './series';
import {
  uncPathOf,
  ensureSmbSession,
  openSmbPassword,
  parseUnc,
  probeSmb,
  ONLINE_NO,
} from './smb';
import { absRootOf, effectiveSources, relPrefixOf, type VideoSourceRow } from './sources';

/**
 * 影视库扫描：每个来源目录 → video_items / image_items。
 *
 * 一个库可以有多个来源（见 `sources.ts`），扫描按来源循环、各自统计，
 * 最后汇总回库。条目的 `rel_path` 是**带来源根的完整相对路径**，
 * 所以跨来源同名文件不会撞车，播放 / 字幕 / 缩略图也不需要知道库根。
 *
 * 按库类型决定扫什么：
 *   movie / jp_movie / tv → 只扫视频
 *   image                 → 只扫图片（写 image_items）
 *   mixed                 → 视频 + 图片都扫，列表侧合并
 *
 * 增量：size/mtime 未变直接跳过；视频元数据用 ffmpeg `-i`（不解码），
 * 图片元数据只读文件头（不加载整图）。任何一步失败都降级，不阻断入库。
 */
export interface VideoLibraryRow {
  id: string;
  name: string;
  root_path: string;
  created_at: number;
  last_scan_at: number | null;
  items: number;
  lib_type?: string | null;
  jp_movie?: number | null;
  conn_type?: string | null;
  host?: string | null;
  share?: string | null;
  sub_path?: string | null;
  unc_path?: string | null;
  online_state?: number | null;
  /** 上次探测在线性的时间；null = 从未探测。此前只写不读，界面上看不到 */
  online_checked_at?: number | null;
  smb_user?: string | null;
  smb_password_enc?: string | null;
  // 库级设置（082 / 085 迁移）：可选是因为老库行在迁移前后都可能被读到
  show_in_home?: number | null;
  sort_order?: number | null;
  audio_normalize?: number | null;
  scrape_enabled?: number | null;
  auto_scrape?: number | null;
  auto_subtitle?: number | null;
}

interface ExistingRow {
  id: string;
  rel_path: string;
  size: number;
  mtime: number;
  /** 非空 = 这条已经检查过本地 NFO（避免每次全库重读 nfo） */
  nfo_source?: string | null;
  /** 我们上次把 nfo 写进库的时间；用于判断磁盘上的 nfo 是否被用户改过 */
  nfo_updated_at?: number | null;
  /** 落库时用的 HDR 解析口径版本；小于 HDR_META_VERSION 就要重探一次 */
  hdr_meta_v?: number | null;
}

export interface VideoScanResult {
  videos: number;
  images: number;
  added: number;
  updated: number;
  skipped: number;
  probed: number;
  /** 索引里有、磁盘上已不存在（仅整库扫描时统计） */
  missing: number;
  /** 本次实际清掉的缺失行（仅 prune 时） */
  pruned: number;
  /** 文件没变、只补读了本地 NFO 的条数（老库升级后第一次扫描会看到） */
  nfoFilled?: number;
  /** 本次扫不动的原因（目录不存在 / 越界）；空 = 全部来源都正常 */
  errors?: string[];
  /** 因 SMB 离线被**跳过**的来源根（不是错误，前端只用来提示「这部分暂时没扫」） */
  skippedSources?: string[];
}

const UPSERT_BATCH = 100;
const PROBE_CONCURRENCY = 4;
/**
 * HDR / DV 标记的解析口径版本（写进 `video_items.hdr_meta_v`）。
 *
 * 1 = 修好 `Side data:` 缩进子行解析之后的口径（见 `probeVideo`）。
 * 老行这里是 0，扫描时会被重探一次；口径以后再变就把它 +1，全库自然会再刷一遍。
 */
const HDR_META_VERSION = 1;

interface Candidate {
  rel: string;
  fullRel: string;
  abs: string;
  size: number;
  mtime: number;
  /**
   * 已存在行的主键。
   *
   * 条目 id 的历史格式变过（从「来源内相对路径」改成「带来源根的完整路径」），
   * 所以**不能拿新公式去 update 老行** —— `where id = 新算的 id` 会匹配 0 行，
   * 表现是「扫描说补了 15 条 NFO，库里一条都没变」。有旧行就沿用旧 id。
   */
  existingId?: string;
}

interface ItemRow extends Candidate {
  id: string;
  meta: Awaited<ReturnType<typeof probeVideo>>;
  nfo: Awaited<ReturnType<typeof ingestNfo>>;
}

interface ImageRow extends Candidate {
  id: string;
  meta: Awaited<ReturnType<typeof readImageMeta>>;
}

const emptyResult = (): VideoScanResult => ({
  videos: 0,
  images: 0,
  added: 0,
  updated: 0,
  skipped: 0,
  probed: 0,
  missing: 0,
  pruned: 0,
});

/**
 * 扫描整个库（所有来源）。
 *
 * `opts.sourceRoot` 指定单个来源时只扫那一个（文件监控按来源触发增量时用）；
 * 不指定则遍历全部来源。
 */
export async function scanVideoLibrary(
  db: any,
  lib: VideoLibraryRow,
  limit = 200000,
  subDir?: string,
  opts: {
    prune?: boolean;
    sourceRoot?: string;
    onProgress?: (pct: number) => void;
    /** 条目口径：已处理文件数 / 已发现文件数（面板显示「12/50」） */
    onFiles?: (done: number, total: number) => void;
  } = {},
): Promise<VideoScanResult> {
  const all = await effectiveSources(db, lib);
  const only = String(opts.sourceRoot || '').trim();
  let targets = only ? all.filter((s) => s.root_path === only) : all;
  // 来源刚被删掉、监控还在按老路径回调：退回扫全库，不要静默什么都不做
  if (targets.length === 0) targets = all;

  const libType = libTypeOf(lib);
  const nowSec = Math.floor(Date.now() / 1000);
  const total = emptyResult();
  const errors: string[] = [];
  const skippedSources: string[] = [];
  const missingVideo: string[] = [];
  const missingImage: string[] = [];
  // 只有「扫全库」才有资格判定缺失：子目录扫描 / 单来源扫描的 seen 集不完整
  const fullLibrary = !subDir && !only;

  let srcDone = 0;
  // 多来源时条目数要跨来源累加，否则第二个来源从 0 开始（用户看到 800/800 → 3/400）
  let fileBase = 0;
  for (const src of targets) {
    // 进度按来源粒度上报（一个来源可能几万文件，内部再细分收益不大）
    opts.onProgress?.((srcDone / Math.max(1, targets.length)) * 90);
    srcDone += 1;
    let rootAbs: string;
    const unc = uncPathOf(src);
    try {
      rootAbs = absRootOf(src);
      if (unc) {
        // 先做 445 探测（1s 超时）：主机常关机，离线时直接跳过这一轮，
        // 不用再等 net use / stat 的网络超时，整次扫描也不会被一台机器拖死。
        // 探测结果同时写回来源表，列表据此隐藏离线来源的内容。
        let host = '';
        try {
          host = parseUnc(unc).host;
        } catch {
          host = '';
        }
        if (host) {
          const state = await probeSmb(host, { cacheMs: 0, timeoutMs: 1000 });
          const checkedAt = Math.floor(Date.now() / 1000);
          await sql`
            update video_library_sources
               set online_state = ${state}, online_checked_at = ${checkedAt}
             where id = ${src.id}
          `.execute(db);
          if (String(src.root_path || '') === String(lib.root_path || '')) {
            await sql`
              update video_libraries
                 set online_state = ${state}, online_checked_at = ${checkedAt}
               where id = ${lib.id}
            `.execute(db);
          }
          if (state === ONLINE_NO) {
            // 来源离线是**预期状态**，不是扫描失败：跳过这一台，其余来源照扫。
            // 以前这里 push 到 errors，前端弹「扫描失败：…smb offline」，
            // 用户会以为自己点的扫描坏了（而且失败来源的内容本来就已经被列表过滤掉）。
            skippedSources.push(String(src.root_path || ''));
            continue;
          }
        }
        // 445 可达 ≠ 有权限：先建立会话，否则 readdir 直接 EACCES，表现为「在线但没内容」
        await ensureSmbSession(
          rootAbs,
          src.smb_user ?? null,
          openSmbPassword(src.smb_password_enc ?? null),
        );
      }
      // 目录不可读时不能继续：否则 seen 为空、missing 变成全部，
      // 一旦打开 prune 会把整库索引误删。
      await fsp.access(rootAbs);
    } catch (err) {
      // 以前这里是 `return 全 0`，连 last_scan_at 都不写 —— 用户看到的是
      // 「扫完了，库还是空的，也没报错」。现在把原因带出去。
      const msg = `${src.root_path}: ${String((err as Error)?.message || err)}`;
      errors.push(msg);
      if (unc) {
        // 读失败 ≥ 实际不可用：记成离线，列表里先隐藏，等下一轮探测再恢复
        const checkedAt = Math.floor(Date.now() / 1000);
        await sql`
          update video_library_sources
             set online_state = ${ONLINE_NO}, online_checked_at = ${checkedAt}
           where id = ${src.id}
        `.execute(db).catch(() => undefined);
      }
      continue;
    }

    try {
      const part = await scanOneSource(
        db,
        lib,
        src,
        rootAbs,
        libType,
        nowSec,
        limit,
        subDir,
        fullLibrary,
        (done, total) => opts.onFiles?.(fileBase + done, fileBase + total),
      );
      total.videos += part.result.videos;
      total.images += part.result.images;
      total.added += part.result.added;
      total.updated += part.result.updated;
      total.skipped += part.result.skipped;
      total.probed += part.result.probed;
      total.nfoFilled = (total.nfoFilled || 0) + (part.result.nfoFilled || 0);
      missingVideo.push(...part.missingVideo);
      missingImage.push(...part.missingImage);
      fileBase += part.result.videos + part.result.images;

      // 单个来源被完整扫过时顺手刷新它自己的统计（列表页按来源显示条数）
      if (!subDir) {
        const srcCount = part.result.videos + part.result.images;
        await sql`
          update video_library_sources set items = ${srcCount}, last_scan_at = ${nowSec}
           where id = ${src.id}
        `.execute(db);
      }
    } catch (err) {
      errors.push(`${src.root_path}: ${String((err as Error)?.message || err)}`);
    }
  }

  total.missing = missingVideo.length + missingImage.length;
  if (fullLibrary && opts.prune && total.missing > 0) {
    total.pruned = await pruneMissingVideo(db, lib.id, missingVideo, missingImage);
  }

  const count =
    Number(
      (
        await sql<{ n: number }>`
          select (select count(*) from video_items where library_id = ${lib.id})
               + (select count(*) from image_items where library_id = ${lib.id}) as n
        `.execute(db)
      ).rows[0]?.n,
    ) || 0;

  // 一条来源都进不去的时候不要写 last_scan_at：否则界面上显示「刚刚扫过」，
  // 让人以为库真的是空的，而不是路径挂了。
  if (errors.length < targets.length) {
    const primary = targets[0];
    if (primary) {
      await sql`
        update video_libraries set
          last_scan_at = ${nowSec},
          items = ${count},
          root_path = ${primary.root_path},
          conn_type = ${primary.conn_type ?? 'local'},
          host = ${primary.host ?? null},
          share = ${primary.share ?? null},
          sub_path = ${primary.sub_path ?? null},
          unc_path = ${primary.unc_path ?? null},
          smb_user = ${primary.smb_user ?? null},
          smb_password_enc = ${primary.smb_password_enc ?? null}
        where id = ${lib.id}
      `.execute(db);
    } else {
      await sql`
        update video_libraries set last_scan_at = ${nowSec}, items = ${count} where id = ${lib.id}
      `.execute(db);
    }
  }
  opts.onProgress?.(95);
  if (errors.length > 0) total.errors = errors;
  if (skippedSources.length > 0) total.skippedSources = skippedSources;
  return total;
}

interface SourceScanOutcome {
  result: VideoScanResult;
  missingVideo: string[];
  missingImage: string[];
}

/** 扫一个来源目录 */
async function scanOneSource(
  db: any,
  lib: VideoLibraryRow,
  src: VideoSourceRow,
  rootAbs: string,
  libType: string,
  nowSec: number,
  limit: number,
  subDir: string | undefined,
  wantMissing: boolean,
  onFiles?: (done: number, total: number) => void,
): Promise<SourceScanOutcome> {
  const libTypeWantsVideo = libType !== 'image';
  const libTypeWantsImage = libType === 'image' || libType === 'mixed';

  // 增量重扫：`subDir` 为来源内相对目录（文件监控按受影响目录触发），缺省扫整来源
  const prefix = (subDir ?? '').replace(/^[/\\]+|[/\\]+$/g, '');
  let baseAbs = rootAbs;
  if (prefix) {
    try {
      baseAbs = resolveAnyPath(rootAbs, prefix);
    } catch {
      return {
        result: emptyResult(),
        missingVideo: [],
        missingImage: [],
      };
    }
  }

  // 条目 rel_path = `${来源根}/${来源内相对路径}`，按前缀把本来源的行圈出来
  const relPrefix = relPrefixOf(src);
  const rootKey = String(src.root_path || '').replace(/\/+$/, '');

  const videoExisting = new Map<string, ExistingRow>();
  if (libTypeWantsVideo) {
    const rows = await sql<ExistingRow>`
      select id, rel_path, size, mtime, nfo_source, nfo_updated_at, hdr_meta_v from video_items
       where library_id = ${lib.id}
         and substr(rel_path, 1, ${relPrefix.length}) = ${relPrefix}
    `.execute(db);
    for (const r of rows.rows) videoExisting.set(r.rel_path, r);
  }
  const imageExisting = new Map<string, ExistingRow>();
  if (libTypeWantsImage) {
    const rows = await sql<ExistingRow>`
      select id, rel_path, size, mtime from image_items
       where library_id = ${lib.id}
         and substr(rel_path, 1, ${relPrefix.length}) = ${relPrefix}
    `.execute(db);
    for (const r of rows.rows) imageExisting.set(r.rel_path, r);
  }

  const seenVideo = new Set<string>();
  const seenImage = new Set<string>();
  const result = emptyResult();

  // 「已完成/总数」的累计基数（跨视频趟 / 图片趟单调递增）
  let fileDone = 0;
  let fileTotal = 0;

  const collect = async (
    predicate: (name: string) => boolean,
    existing: Map<string, ExistingRow>,
    seen: Set<string>,
    backfill?: Candidate[],
    /**
     * 文件没变、但行里的元数据是旧口径算出来的，返回 true 就重探一次。
     * 只有视频趟会传（图片没有 HDR 标记），传 null 时走原来的「文件没变就跳过」。
     */
    staleMeta?: ((prev: ExistingRow) => boolean) | null,
  ): Promise<Candidate[]> => {
    const files = await walkFiles(baseAbs, Math.max(1, Math.min(limit, 200000)), predicate);
    const needs: Candidate[] = [];
    // 条目口径：视频趟跑完接着跑图片趟，所以用累计基数，
    // 否则第二趟的数字会从头开始（用户看到 500/500 → 0/80 会以为任务重跑了）
    const base = fileDone;
    const total = Math.max(fileTotal, base + files.length);
    for (let fi = 0; fi < files.length; fi += 1) {
      // 每 25 个报一次：一个来源能有几万文件，每次都写库反而拖慢扫描
      if (onFiles && fi % 25 === 0) onFiles(base + fi, total);
      const scanned = files[fi];
      const rel = prefix ? `${prefix}/${scanned}` : scanned;
      const abs = path.join(rootAbs, rel.split('/').join(path.sep));
      let st;
      try {
        st = await fsp.stat(abs);
      } catch {
        continue;
      }
      const mtime = Math.floor(st.mtimeMs);
      const fullRel = `${rootKey}/${rel}`.replace(/^\/+/, '');
      seen.add(fullRel);
      const prev = existing.get(fullRel);
      const sameFile = prev != null && prev.size === st.size && prev.mtime === mtime;
      // 文件没变、但 HDR 标记是旧解析口径算出来的 → 值得重新 ffprobe 一次
      // （早期版本把 `Side data:` 的缩进子行整块丢了，DV/HDR 全落成 0）。
      const staleMetaRow = sameFile && prev != null && staleMeta ? staleMeta(prev) === true : false;
      if (sameFile && prev && !staleMetaRow) {
        // 文件没变，但元数据可能变了，两种要补：
        //   ① 老库（nfo_source 为 null）——本功能上线前入库的，补一次
        //   ② 之前没读到 nfo，现在同目录多了 .nfo / 海报 —— 用户事后补的，最常见
        // 只补 NFO，不重新 ffprobe（探测比读 nfo 贵两个数量级）
        if (backfill) {
          const neverChecked = prev.nfo_source == null;
          const hadNoNfo = String(prev.nfo_source || '') === 'none';
          //   ③ 用户手改了已有的 .nfo（文件比我们上次写库更新）——不重读的话，
          //      改完重扫一遍还是旧值，是"改了不起作用"的真实来源
          const edited = await nfoFileNewerThan(abs, Number(prev.nfo_updated_at) || 0);
          if (neverChecked || (hadNoNfo && (await hasLocalMeta(abs))) || edited) {
            backfill.push({ rel, fullRel, abs, size: st.size, mtime, existingId: prev.id });
          }
        }
        result.skipped += 1;
        continue;
      }
      if (!prev) result.added += 1;
      // 只为「文件变了」记更新；口径升级导致的重探不算用户视角的"更新"，
      // 数量体现在 result.probed 里
      else if (!sameFile) result.updated += 1;
      needs.push({ rel, fullRel, abs, size: st.size, mtime, existingId: prev?.id });
    }
    fileDone = base + files.length;
    fileTotal = Math.max(fileTotal, fileDone);
    return needs;
  };

  // ---------------------------------------------------------------- 视频

  if (libTypeWantsVideo) {
    const backfill: Candidate[] = [];
    const needs = await collect(isVideoFile, videoExisting, seenVideo, backfill, (p) =>
      Number(p.hdr_meta_v || 0) < HDR_META_VERSION,
    );
    result.videos = needs.length + videoExisting.size;
    const isJp = libType === 'jp_movie';

    const probed = await mapLimit(needs, PROBE_CONCURRENCY, async (c): Promise<ItemRow> => {
      // ffprobe 与 nfo 读并行：两者互不依赖，串起来会让全库扫描慢一倍
      const [meta, nfo] = await Promise.all([probeVideo(c.abs), ingestNfo(c.abs)]);
      return {
        ...c,
        // id 用带来源根的全路径：多来源下「不同目录里的同名文件」不会撞成一条
        id: `${lib.id}_${Buffer.from(c.fullRel).toString('base64url')}`,
        meta,
        nfo,
      };
    });
    for (const p of probed) if (p.meta.durationMs !== null) result.probed += 1;

    for (let i = 0; i < probed.length; i += UPSERT_BATCH) {
      const chunk = probed.slice(i, i + UPSERT_BATCH);
      await db.transaction().execute(async (trx: any) => {
        for (const p of chunk) {
          const m = p.meta;
          const ep = parseEpisode(p.rel);
          const jp = jpMetaOf(p.rel);
          await sql`
            insert into video_items
              (id, library_id, rel_path, title, duration, width, height, video_codec,
               audio_codec, container, has_subtitle, size, mtime, created_at,
               series, season, episode, media_type, code, uncensored, chinese_sub,
               is_4k, hdr10, hdr10plus, hlg, dolby_vision, dolby_atmos, hdr_meta_v)
            values
              (${p.id}, ${lib.id}, ${p.fullRel}, ${titleOf(p.rel)}, ${m.durationMs},
               ${m.width}, ${m.height}, ${m.videoCodec}, ${m.audioCodec},
               ${extensionOf(p.rel)}, ${m.hasSubtitle ? 1 : 0}, ${p.size}, ${p.mtime}, ${nowSec},
               ${ep.series}, ${ep.season}, ${ep.episode}, ${'video'},
               ${isJp ? jp.code : null}, ${isJp ? jp.uncensored : 0}, ${isJp ? jp.chineseSub : 0},
               ${m.is4k ? 1 : 0}, ${m.hdr10 ? 1 : 0}, ${m.hdr10plus ? 1 : 0},
               ${m.hlg ? 1 : 0}, ${m.dolbyVision ? 1 : 0}, ${m.dolbyAtmos ? 1 : 0},
               ${HDR_META_VERSION})
            on conflict(library_id, rel_path) do update set
              title = excluded.title,
              duration = excluded.duration,
              width = excluded.width,
              height = excluded.height,
              video_codec = excluded.video_codec,
              audio_codec = excluded.audio_codec,
              container = excluded.container,
              has_subtitle = excluded.has_subtitle,
              size = excluded.size,
              mtime = excluded.mtime,
              series = excluded.series,
              season = excluded.season,
              episode = excluded.episode,
              media_type = excluded.media_type,
              code = excluded.code,
              uncensored = excluded.uncensored,
              chinese_sub = excluded.chinese_sub,
              is_4k = excluded.is_4k,
              hdr10 = excluded.hdr10,
              hdr10plus = excluded.hdr10plus,
              hlg = excluded.hlg,
              dolby_vision = excluded.dolby_vision,
              dolby_atmos = excluded.dolby_atmos,
              hdr_meta_v = excluded.hdr_meta_v
          `.execute(trx);
          await applyNfo(trx, p.existingId ?? p.id, p.nfo, nowSec, Math.floor((p.nfo.mtimeMs || 0) / 1000));
        }
      });
    }

    // —— 只补 NFO 的通道：文件没变但从未检查过本地 nfo 的条目
    let filled = 0;
    for (let i = 0; i < backfill.length; i += UPSERT_BATCH) {
      const chunk = backfill.slice(i, i + UPSERT_BATCH);
      const ingested = await mapLimit(chunk, PROBE_CONCURRENCY * 2, async (c) => ({
        // 有旧行就按旧主键更新，别拿新公式去猜（见 Candidate.existingId 的注释）
        id: c.existingId ?? `${lib.id}_${Buffer.from(c.fullRel).toString('base64url')}`,
        nfo: await ingestNfo(c.abs),
      }));
      await db.transaction().execute(async (trx: any) => {
        for (const row of ingested) {
          // 计「真的写进去的行数」，不是「尝试次数」——
          // 之前这里 `filled += 1` 恒等于候选数，主键对不上时日志照样说「补了 15 条」。
          filled += await applyNfo(trx, row.id, row.nfo, nowSec, Math.floor((row.nfo.mtimeMs || 0) / 1000));
        }
      });
    }
    if (filled > 0) result.nfoFilled = filled;
  }

  // ---------------------------------------------------------------- 图片

  if (libTypeWantsImage) {
    const needs = await collect(isImageFile, imageExisting, seenImage);
    result.images = needs.length + imageExisting.size;

    const metas = await mapLimit(needs, PROBE_CONCURRENCY * 2, async (c): Promise<ImageRow> => {
      const meta = await readImageMeta(c.abs);
      return {
        ...c,
        id: `${lib.id}_img_${Buffer.from(c.fullRel).toString('base64url')}`,
        meta,
      };
    });

    for (let i = 0; i < metas.length; i += UPSERT_BATCH) {
      const chunk = metas.slice(i, i + UPSERT_BATCH);
      await db.transaction().execute(async (trx: any) => {
        for (const p of chunk) {
          const title = imageTitleOf(p.rel);
          await sql`
            insert into image_items
              (id, library_id, rel_path, title, natural_name, filename_fl,
               taken_at, size, mtime, width, height, mime, created_at)
            values
              (${p.id}, ${lib.id}, ${p.fullRel}, ${title},
               ${naturalKeyOf(title)}, ${firstLetterOf(title)},
               ${p.meta.takenAt == null ? null : Number(p.meta.takenAt)}, ${p.size}, ${p.mtime},
               ${p.meta.width}, ${p.meta.height}, ${mimeOf(p.rel)}, ${nowSec})
            on conflict(library_id, rel_path) do update set
              title = excluded.title,
              natural_name = excluded.natural_name,
              filename_fl = excluded.filename_fl,
              taken_at = excluded.taken_at,
              size = excluded.size,
              mtime = excluded.mtime,
              width = excluded.width,
              height = excluded.height,
              mime = excluded.mime
          `.execute(trx);
        }
      });
    }
  }

  // 只有整库扫描才能判定「索引里有、磁盘上已经没有」；子目录扫描的数据不完整，不能据此删行
  const missingVideo = wantMissing
    ? [...videoExisting.keys()].filter((p) => !seenVideo.has(p))
    : [];
  const missingImage = wantMissing
    ? [...imageExisting.keys()].filter((p) => !seenImage.has(p))
    : [];

  return { result, missingVideo, missingImage };
}

/**
 * 磁盘上的 .nfo 是否比 `baselineSec` 更新（= 用户在我们写库之后手改过）。
 *
 * 只做存在性/时间检查，不读内容 —— 这条判断会跑在每个"文件没变"的条目上，
 * 必须便宜。真正的解析留给后面 ingestNfo。
 */
async function nfoFileNewerThan(absPath: string, baselineSec: number): Promise<boolean> {
  try {
    const found = await findNfoFile(absPath);
    if (!found) return false;
    const st = await fsp.stat(found.file);
    return Math.floor(st.mtimeMs / 1000) > baselineSec;
  } catch {
    return false;
  }
}

/**
 * 把本地 NFO / 本地图片的结果写进条目。
 *
 * 覆盖规则（重要）：每列都用 `coalesce(新值, 原值)`——
 *   - 读到了 nfo → 覆盖；
 *   - 没读到 → 只补空位，**不清空**已有值。
 * 否则「文件被重新探测」会把在线刮削（TMDB / 番号源）的结果整列抹成 NULL。
 *
 * `nfo_source` 单独处理：只在「读到 nfo」或「当前为空」时改写，
 * 避免把已经刮削过的库降级成 `none` 让下次又白跑一遍。
 */
async function applyNfo(
  trx: any,
  id: string,
  ing: Awaited<ReturnType<typeof ingestNfo>>,
  nowSec: number,
  nfoMtimeSec = 0,
): Promise<number> {
  const strong = ing.source === 'nfo' ? 1 : 0;
  // 冲突判定（唯一判据）：磁盘 nfo 的 mtime 晚于我们上次写库的时间 ⇒ 用户手改过，
  // 以文件为准**覆盖**；否则只补空位（coalesce）。
  // 之前一律 coalesce，导致"手改了 nfo 却永远不生效"——用户改完重扫一遍，看到的还是旧值。
  const edited = sql`(${nfoMtimeSec} > coalesce(nfo_updated_at, 0))`;
  const pick = (col: string, v: unknown) =>
    sql`(case when ${edited} then ${v} else coalesce(${v}, ${sql.raw(col)}) end)`;

  const res = await sql`
    update video_items set
      nfo_name = ${pick('nfo_name', ing.name)},
      nfo_original_name = ${pick('nfo_original_name', ing.originalName)},
      nfo_year = ${pick('nfo_year', ing.year)},
      nfo_score = ${pick('nfo_score', ing.score)},
      nfo_overview = ${pick('nfo_overview', ing.overview)},
      nfo_runtime = ${pick('nfo_runtime', ing.runtime)},
      nfo_release_date = ${pick('nfo_release_date', ing.releaseDate)},
      nfo_studio = ${pick('nfo_studio', ing.studio)},
      nfo_genres = ${pick('nfo_genres', ing.genres)},
      nfo_regions = ${pick('nfo_regions', ing.regions)},
      nfo_actors = ${pick('nfo_actors', ing.actors)},
      nfo_directors = ${pick('nfo_directors', ing.directors)},
      nfo_poster = ${pick('nfo_poster', ing.poster)},
      nfo_fanart = ${pick('nfo_fanart', ing.fanart)},
      nfo_thumb = ${pick('nfo_thumb', ing.thumb)},
      nfo_imdb_id = ${pick('nfo_imdb_id', ing.imdbId)},
      nfo_douban_id = ${pick('nfo_douban_id', ing.doubanId)},
      nfo_tmdb_id = ${pick('nfo_tmdb_id', ing.tmdbId)},
      nfo_source = (case when ${edited} or ${strong} = 1 then ${ing.source}
                         else coalesce(nfo_source, ${'none'}) end),
      nfo_updated_at = (case when ${edited} or ${strong} = 1 then ${nowSec}
                             else nfo_updated_at end)
     where id = ${id}
  `.execute(trx);

  // 演员关联从 nfo_actors 派生（`jp_actor_items` 以前没有任何写入点，
  // 所以演员列表的"影片数"恒为 0）。只有本次 NFO 带演员时才重建，避免把已有联动清空。
  // 顺带把 NFO 里的 `<actor><thumb>` 写进 `jp_actors.thumb_path` —— 演员头像的来源。
  if (ing.actors) {
    let thumbs: Record<string, string> | null = null;
    if (ing.actorThumbs) {
      try {
        const parsed = JSON.parse(ing.actorThumbs);
        if (parsed && typeof parsed === 'object') thumbs = parsed as Record<string, string>;
      } catch {
        /* 坏 JSON 就当没有，不影响关联 */
      }
    }
    await syncActorLinks(trx, id, parseActorNames(ing.actors), nowSec, thumbs).catch(() => 0);
  }
  return Number(res.numAffectedRows ?? 0);
}

/** 清理「磁盘上已不存在」的视频/图片行（显式 prune 才走这里）；先清观看进度再删主行 */
async function pruneMissingVideo(
  db: any,
  libraryId: string,
  videoRels: string[],
  imageRels: string[],
): Promise<number> {
  const BATCH = 400;
  let removed = 0;
  for (let i = 0; i < videoRels.length; i += BATCH) {
    const chunk = videoRels.slice(i, i + BATCH);
    const list = sql.join(
      chunk.map((p) => sql`${p}`),
      sql`, `,
    );
    await sql`
      delete from video_progress
       where item_id in (select id from video_items where library_id = ${libraryId} and rel_path in (${list}))
    `.execute(db);
    const res = await sql`
      delete from video_items where library_id = ${libraryId} and rel_path in (${list})
    `.execute(db);
    removed += Number(res.numAffectedRows ?? 0);
  }
  for (let i = 0; i < imageRels.length; i += BATCH) {
    const chunk = imageRels.slice(i, i + BATCH);
    const list = sql.join(
      chunk.map((p) => sql`${p}`),
      sql`, `,
    );
    const res = await sql`
      delete from image_items where library_id = ${libraryId} and rel_path in (${list})
    `.execute(db);
    removed += Number(res.numAffectedRows ?? 0);
  }
  return removed;
}
