import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { filesRoot, resolveAnyPath, resolveInRoot } from '../files/fs-root';
import { walkFilesStream } from '../files/walk';
import { mapLimit } from '../media/concurrency';
import { isAudioFile, probeAudio, titleOf } from './ffmpeg';

/**
 * 音乐库扫描：库目录 → music_tracks。
 *
 * - 增量：size/mtime 未变直接跳过
 * - 元数据由 jellyfin-ffmpeg `-i` 解析（tags / 时长 / 采样率 / 内嵌封面标记）
 * - probe 并发 4，写库 100 条/事务；**流式遍历 + 每 200 条落库**，不封顶也不爆内存
 */
export interface MusicLibraryRow {
  id: string;
  name: string;
  root_path: string;
  created_at: number;
  last_scan_at: number | null;
  items: number;
  /** 启动时自动扫描（1/0，缺省 1） */
  scan_when_start?: number | null;
  /** 目录有变动时自动扫描（1/0，缺省 1） */
  scan_when_change?: number | null;
  /** 每库独立的间隔扫描周期（毫秒，0 = 跟随全局 6 小时校验） */
  scan_interval_ms?: number | null;
}

interface ExistingRow {
  rel_path: string;
  size: number;
  mtime: number;
}

export interface MusicScanResult {
  tracks: number;
  added: number;
  updated: number;
  skipped: number;
  probed: number;
  /** 索引里有、磁盘上已不存在（仅整库扫描时统计） */
  missing: number;
  /** 本次实际清掉的缺失行（仅 prune 时） */
  pruned: number;
}

const UPSERT_BATCH = 100;
const PROBE_CONCURRENCY = 4;
/** 每攒够这么多待探测曲目就先 probe + 落库一次，几万首也不会全压在内存里 */
const SCAN_CHUNK = 200;

interface Candidate {
  rel: string;
  fullRel: string;
  abs: string;
  size: number;
  mtime: number;
}

export async function scanMusicLibrary(
  db: any,
  lib: MusicLibraryRow,
  limit = 0,
  subDir?: string,
  opts: { prune?: boolean } = {},
): Promise<MusicScanResult> {
  const root = filesRoot();
  let rootAbs: string;
  try {
    // root_path 可能是绝对路径（音乐来源允许任意本机目录 / SMB 共享），
    // 相对路径仍按 files 根解析
    rootAbs = resolveAnyPath(root, lib.root_path);
  } catch {
    return { tracks: 0, added: 0, updated: 0, skipped: 0, probed: 0, missing: 0, pruned: 0 };
  }

  // 增量重扫：`subDir` 为库内相对目录（文件监控按受影响目录触发），缺省扫整库
  const prefix = (subDir ?? '').replace(/^[/\\]+|[/\\]+$/g, '');
  let baseAbs = rootAbs;
  if (prefix) {
    try {
      baseAbs = resolveInRoot(rootAbs, prefix);
    } catch {
      return { tracks: 0, added: 0, updated: 0, skipped: 0, probed: 0, missing: 0, pruned: 0 };
    }
  }

  const existing = new Map<string, ExistingRow>();
  const rows = await sql<ExistingRow>`
    select rel_path, size, mtime from music_tracks where library_id = ${lib.id}
  `.execute(db);
  for (const r of rows.rows) existing.set(r.rel_path, r);

  const result: MusicScanResult = {
    tracks: 0,
    added: 0,
    updated: 0,
    skipped: 0,
    probed: 0,
    missing: 0,
    pruned: 0,
  };
  const nowSec = Math.floor(Date.now() / 1000);
  const seen = new Set<string>();
  /** `limit > 0` 才封顶（冒烟用小值），缺省扫到底 */
  const capped = limit > 0;
  let buffer: Candidate[] = [];

  /** 把攒下的待探测曲目 probe + 落库，然后清空（内存在这里回落） */
  const flush = async (): Promise<void> => {
    if (buffer.length === 0) return;
    const batch = buffer;
    buffer = [];
    const probed = await mapLimit(batch, PROBE_CONCURRENCY, async (c) => {
      const meta = await probeAudio(c.abs);
      return { ...c, meta };
    });
    for (const p of probed) if (p.meta.durationMs !== null) result.probed += 1;

    for (let i = 0; i < probed.length; i += UPSERT_BATCH) {
      const chunk = probed.slice(i, i + UPSERT_BATCH);
      await db.transaction().execute(async (trx: any) => {
        for (const p of chunk) {
          const m = p.meta;
          await sql`
            insert into music_tracks
              (id, library_id, rel_path, title, artist, album, album_artist, genre, track_no,
               year, duration, bitrate, sample_rate, channels, codec, has_cover, size, mtime, created_at)
            values
              (${`${lib.id}_${Buffer.from(p.rel).toString('base64url')}`}, ${lib.id}, ${p.fullRel},
               ${m.title || titleOf(p.rel)}, ${m.artist}, ${m.album}, ${m.albumArtist}, ${m.genre},
               ${m.trackNo}, ${m.year}, ${m.durationMs}, ${m.bitrate}, ${m.sampleRate}, ${m.channels},
               ${m.codec}, ${m.hasCover ? 1 : 0}, ${p.size}, ${p.mtime}, ${nowSec})
            on conflict(library_id, rel_path) do update set
              title = excluded.title,
              artist = excluded.artist,
              album = excluded.album,
              album_artist = excluded.album_artist,
              genre = excluded.genre,
              track_no = excluded.track_no,
              year = excluded.year,
              duration = excluded.duration,
              bitrate = excluded.bitrate,
              sample_rate = excluded.sample_rate,
              channels = excluded.channels,
              codec = excluded.codec,
              has_cover = excluded.has_cover,
              size = excluded.size,
              mtime = excluded.mtime
          `.execute(trx);
        }
      });
    }
  };

  // 流式遍历：以前是 `walkFiles(limit)` 一次性取出（默认封顶 20000），
  // 库超过 2 万首就永远只索引前 2 万，怎么点扫描都补不进来。
  await walkFilesStream(baseAbs, isAudioFile, async (scanned) => {
    if (capped && seen.size >= limit) return false;
    const rel = prefix ? `${prefix}/${scanned}` : scanned;
    const abs = path.join(rootAbs, rel.split('/').join(path.sep));
    let st;
    try {
      st = await fsp.stat(abs);
    } catch {
      return;
    }
    const mtime = Math.floor(st.mtimeMs);
    const fullRel = `${lib.root_path}/${rel}`.replace(/^\/+/, '');
    seen.add(fullRel);
    result.tracks += 1;
    const prev = existing.get(fullRel);
    if (prev && prev.size === st.size && prev.mtime === mtime) {
      result.skipped += 1;
      return;
    }
    if (prev) result.updated += 1;
    else result.added += 1;
    buffer.push({ rel, fullRel, abs, size: st.size, mtime });
    if (buffer.length >= SCAN_CHUNK) await flush();
  });
  await flush();

  // 只有整库扫描才能判定「索引里有、磁盘上已经没有」；子目录扫描的数据不完整，不能据此删行
  const missing = prefix ? [] : [...existing.keys()].filter((p) => !seen.has(p));
  result.missing = missing.length;
  if (missing.length > 0 && opts.prune && !prefix) {
    result.pruned = await pruneMissingMusic(db, lib.id, missing);
  }

  await sql`
    update music_libraries
       set last_scan_at = ${nowSec},
           items = (select count(*) from music_tracks where library_id = ${lib.id})
     where id = ${lib.id}
  `.execute(db);

  return result;
}

/** 清理「磁盘上已不存在」的曲目（显式 prune 才走这里）；先清歌单成员再删主行 */
async function pruneMissingMusic(db: any, libraryId: string, relPaths: string[]): Promise<number> {
  const BATCH = 400;
  let removed = 0;
  for (let i = 0; i < relPaths.length; i += BATCH) {
    const chunk = relPaths.slice(i, i + BATCH);
    const list = sql.join(
      chunk.map((p) => sql`${p}`),
      sql`, `,
    );
    await sql`
      delete from music_playlist_items
       where track_id in (select id from music_tracks where library_id = ${libraryId} and rel_path in (${list}))
    `.execute(db);
    const res = await sql`
      delete from music_tracks where library_id = ${libraryId} and rel_path in (${list})
    `.execute(db);
    removed += Number(res.numAffectedRows ?? 0);
  }
  return removed;
}