import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import {
  absoluteInput,
  filesRoot,
  isAbsoluteInput,
  registerExtraRoot,
  resolveInRoot,
} from '../files/fs-root';
import { walkFiles } from '../files/walk';
import { isMediaFile, isVideoFile } from './exif';
import { MEDIA_VER, readMediaMeta } from './media-meta';
import { findPairedVideo } from './live-photo';
import { encode as geohashEncode } from './geo/geohash';
import { applyAlbumRulesForItems } from './album-rules';
import { recordDeletedFingerprints } from './deleted-fp';

/**
 * 相册扫描：库目录 → photo_items。
 *
 * - 只遍历普通文件，不跟随符号链接（防环）
 * - 扩展名白名单在 exif.ts
 * - 已索引且 size/mtime 未变 → 跳过，实现增量；不删除已消失文件（避免误删用户元数据）
 */
export interface LibraryRow {
  id: string;
  name: string;
  root_path: string;
  created_at: number;
  last_scan_at: number | null;
  items: number;
}

interface ExistingRow {
  rel_path: string;
  size: number;
  mtime: number;
  taken_at: number;
  media_ver: number;
}

export interface ScanResult {
  images: number;
  added: number;
  updated: number;
  skipped: number;
  /** 索引里有、磁盘上已不存在（仅整库扫描时统计；子目录扫描恒为 0） */
  missing: number;
  /** 本次实际清掉的缺失行（仅 prune 时） */
  pruned: number;
}

const UPSERT_BATCH = 100;

/**
 * 一次扫描最多收多少文件。
 *
 * 原来写死 20000：图片 1.9 万的库把视频也收进来后总量越过这个数，
 * 多出来的（DFS 顺序靠后的目录）永远扫不到、也永远成不了条目。
 */
const MAX_SCAN_FILES = 60000;

export async function scanLibrary(
  db: any,
  lib: LibraryRow,
  limit = MAX_SCAN_FILES,
  subDir?: string,
  opts: { prune?: boolean; force?: boolean } = {},
): Promise<ScanResult> {
  const root = filesRoot();
  let rootAbs: string;
  if (isAbsoluteInput(lib.root_path)) {
    rootAbs = path.resolve(absoluteInput(lib.root_path));
    registerExtraRoot(rootAbs);
  } else {
    try {
      rootAbs = resolveInRoot(root, lib.root_path);
    } catch {
      return { images: 0, added: 0, updated: 0, skipped: 0, missing: 0, pruned: 0 };
    }
  }

  // 增量重扫：`subDir` 为库内相对目录（文件监控按受影响目录触发），缺省扫整库
  const prefix = (subDir ?? '').replace(/^[/\\]+|[/\\]+$/g, '');
  let baseAbs = rootAbs;
  if (prefix) {
    try {
      baseAbs = resolveInRoot(rootAbs, prefix);
    } catch {
      return { images: 0, added: 0, updated: 0, skipped: 0, missing: 0, pruned: 0 };
    }
  }

  const files = await walkFiles(baseAbs, Math.max(1, Math.min(limit, MAX_SCAN_FILES)), isMediaFile);

  // 先收集「被某张图片配对引用的视频」：正式循环里这些视频不单独入库。
  // 与增量 skip 无关——重扫时图片即使被跳过，配对关系仍要完整生效，
  // 因此必须先有完整集合再过滤，不能边扫边判。
  const pairCache = new Map<string, { path: string; size: number } | null>();
  const pairedRel = new Set<string>();
  // 用「相对扫描根目录的路径」做键（大小写不敏感），避免绝对路径构造差异漏过滤
  const relKey = (rel: string) => rel.replace(/\\/g, '/').toLowerCase();
  for (const scanned of files) {
    const rel0 = prefix ? `${prefix}/${scanned}` : scanned;
    const abs0 = path.join(rootAbs, rel0.split('/').join(path.sep));
    if (isVideoFile(abs0)) continue;
    const hit = await findPairedVideo(abs0);
    pairCache.set(abs0, hit);
    if (hit) {
      const relVideo = path.relative(baseAbs, hit.path).split(path.sep).join('/');
      pairedRel.add(relKey(relVideo));
    }
  }

  const existing = new Map<string, ExistingRow>();
  const rows = await sql<ExistingRow>`
    select rel_path, size, mtime, taken_at, media_ver from photo_items where library_id = ${lib.id}
  `.execute(db);
  for (const r of rows.rows) existing.set(r.rel_path, r);

  const result: ScanResult = {
    images: files.length,
    added: 0,
    updated: 0,
    skipped: 0,
    missing: 0,
    pruned: 0,
  };
  const nowSec = Math.floor(Date.now() / 1000);
  const seen = new Set<string>();
  let batch: Array<Record<string, string | number | null>> = [];

  const flush = async () => {
    if (batch.length === 0) return;
    const pending = batch;
    batch = [];
    await db.transaction().execute(async (trx: any) => {
      for (const row of pending) {
        await sql`
          insert into photo_items
            (id, library_id, rel_path, taken_at, size, mtime, width, height, mime, created_at,
             latitude, longitude, geohash, geohash2, geohash3, geohash4, geohash5, geohash6, geohash7,
             camera, media_kind, duration_ms, live_kind, live_size, live_ms,
             live_offset, live_vendor, live_path, media_ver)
          values
            (${row.id}, ${row.libraryId}, ${row.relPath}, ${row.takenAt}, ${row.size},
             ${row.mtime}, ${row.width}, ${row.height}, ${row.mime}, ${row.createdAt},
             ${row.latitude}, ${row.longitude}, ${row.geohash}, ${row.geohash2}, ${row.geohash3},
             ${row.geohash4}, ${row.geohash5}, ${row.geohash6}, ${row.geohash7}, ${row.camera},
             ${row.mediaKind}, ${row.durationMs}, ${row.liveKind}, ${row.liveSize}, ${row.liveMs},
             ${row.liveOffset}, ${row.liveVendor}, ${row.livePath}, ${row.mediaVer})
          on conflict(library_id, rel_path) do update set
            taken_at = excluded.taken_at,
            size = excluded.size,
            -- 文件被补充 GPS / 旋转 / 重编码后 size 会变。把**改写前**的字节数
            -- 固化到 orig_size（只在首次变化时写，永不覆盖），手机再拿原图 size
            -- 来问 check_content 时仍能命中，不会因为服务端改写而重复上传。
            orig_size = case
              when photo_items.orig_size = 0 and photo_items.size <> excluded.size
              then photo_items.size
              else photo_items.orig_size end,
            mtime = excluded.mtime,
            width = excluded.width,
            height = excluded.height,
            mime = excluded.mime,
            latitude = excluded.latitude,
            longitude = excluded.longitude,
            geohash = excluded.geohash,
            geohash2 = excluded.geohash2,
            geohash3 = excluded.geohash3,
            geohash4 = excluded.geohash4,
            geohash5 = excluded.geohash5,
            geohash6 = excluded.geohash6,
            geohash7 = excluded.geohash7,
            camera = excluded.camera,
            media_kind = excluded.media_kind,
            duration_ms = excluded.duration_ms,
            live_kind = excluded.live_kind,
            live_size = excluded.live_size,
            live_ms = excluded.live_ms,
            live_offset = excluded.live_offset,
            live_vendor = excluded.live_vendor,
            live_path = excluded.live_path,
            media_ver = excluded.media_ver
        `.execute(trx);
      }
    });
    // 规则相册：本批新入库 / 更新的照片按规则收进去。
    // 放在事务外面 —— 归集失败不该让整批扫描回滚（照片已经入库了）。
    try {
      await applyAlbumRulesForItems(
        db,
        pending.map((r) => String(r.id)),
      );
    } catch {
      /* 规则相册只是附加便利，不能影响扫描结果 */
    }
  };

  for (const scanned of files) {
    const rel = prefix ? `${prefix}/${scanned}` : scanned;
    const abs = path.join(rootAbs, rel.split('/').join(path.sep));
    let st;
    try {
      st = await fsp.stat(abs);
    } catch {
      continue;
    }

    const mtime = Math.floor(st.mtimeMs);
    const fullRel = `${lib.root_path}/${rel}`.replace(/^\/+/, '');
    seen.add(fullRel);
    // 被配对引用的视频只作为对应图片的「那段视频」，不单独出现在时间轴
    if (isVideoFile(abs) && pairedRel.has(relKey(scanned))) continue;
    const prev = existing.get(fullRel);
    // 坏 EXIF（1899 / 2082 等）会让旧的索引一直停在错误年份：
    // 增量扫描也顺手纠正，不必等用户做一次全量 force 重扫。
    const prevPlausible = !!prev && prev.taken_at > 86400 && prev.taken_at < nowSec + 2 * 86400;
    // media_ver 落后的行必须重读：老数据里 live_kind 空既可能是「真不是动态照片」，
    // 也可能是「当年没认」，只有重读文件头才能补上。
    const prevFresh = !!prev && prev.media_ver >= MEDIA_VER;
    if (
      !opts.force &&
      prev &&
      prevPlausible &&
      prevFresh &&
      prev.size === st.size &&
      prev.mtime === mtime
    ) {
      result.skipped += 1;
      continue;
    }

    const paired = pairCache.get(abs) ?? null;
    const meta = await readMediaMeta(abs, st.size, paired);
    const nowSecForMeta = Math.floor(Date.now() / 1000);
    const rawTaken = meta.takenAt;
    // EXIF 里偶发 1899 / 2082 这类坏日期（时区/字段损坏）：只接受 1970 之后、当前时间附近
    const plausible = rawTaken != null && rawTaken > 86400 && rawTaken < nowSecForMeta + 2 * 86400;
    const takenAt = plausible ? rawTaken : Math.floor(mtime / 1000);
    const latitude = meta.latitude;
    const longitude = meta.longitude;
    const hasGeo = latitude != null && longitude != null;
    const gh = (p: number) => (hasGeo ? geohashEncode(latitude!, longitude!, p) : null);

    batch.push({
      id: `${lib.id}_${Buffer.from(rel).toString('base64url')}`,
      libraryId: lib.id,
      relPath: fullRel,
      takenAt,
      size: st.size,
      mtime,
      width: meta.width,
      height: meta.height,
      mime: meta.mime,
      createdAt: nowSec,
      latitude: hasGeo ? latitude : null,
      longitude: hasGeo ? longitude : null,
      geohash: hasGeo ? geohashEncode(latitude!, longitude!, 8) : null,
      geohash2: gh(2),
      geohash3: gh(3),
      geohash4: gh(4),
      geohash5: gh(5),
      geohash6: gh(6),
      geohash7: gh(7),
      camera: meta.camera,
      mediaKind: meta.mediaKind,
      durationMs: meta.durationMs,
      liveKind: meta.liveKind,
      liveSize: meta.liveSize,
      liveMs: null,
      liveOffset: meta.liveOffset,
      liveVendor: meta.liveVendor,
      livePath: meta.livePath,
      mediaVer: MEDIA_VER,
    });

    if (prev) result.updated += 1;
    else result.added += 1;

    if (batch.length >= UPSERT_BATCH) await flush();
  }

  await flush();

  // 只有整库扫描才能判定「索引里有、磁盘上已经没有」；子目录扫描的数据不完整，不能据此删行
  const missing = prefix ? [] : [...existing.keys()].filter((p) => !seen.has(p));
  result.missing = missing.length;
  if (missing.length > 0 && opts.prune && !prefix) {
    result.pruned = await pruneMissing(db, lib.id, missing);
  }

  await sql`
    update photo_libraries
       set last_scan_at = ${nowSec},
           items = (select count(*) from photo_items where library_id = ${lib.id})
     where id = ${lib.id}
  `.execute(db);

  return result;
}

/**
 * 清理「磁盘上已不存在」的照片行（显式 prune 才走这里）。
 * 先清相册成员再删主行，避免留下指向不存在照片的成员记录。
 */
async function pruneMissing(db: any, libraryId: string, relPaths: string[]): Promise<number> {
  const BATCH = 400;
  let removed = 0;
  for (let i = 0; i < relPaths.length; i += BATCH) {
    const chunk = relPaths.slice(i, i + BATCH);
    const list = sql.join(
      chunk.map((p) => sql`${p}`),
      sql`, `,
    );
    const ids = (
      await sql<{ id: string }>`
        select id from photo_items where library_id = ${libraryId} and rel_path in (${list})
      `.execute(db)
    ).rows.map((r) => r.id);
    // prune 是物理删行（索引有、磁盘无）：先留指纹，否则手机备份会把这些
    // 「用户刚在 NAS 上删掉」的照片当成从没备份过、又传一遍。
    // owner 传空串 → 按每行自身的库 owner 写，扫描是跨用户后台任务。
    await recordDeletedFingerprints(db, '', ids);
    await sql`
      delete from photo_album_items
       where item_id in (select id from photo_items where library_id = ${libraryId} and rel_path in (${list}))
    `.execute(db);
    const res = await sql`
      delete from photo_items where library_id = ${libraryId} and rel_path in (${list})
    `.execute(db);
    removed += Number(res.numAffectedRows ?? 0);
  }
  return removed;
}
