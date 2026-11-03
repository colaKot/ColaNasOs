import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { walkFiles } from '../files/walk';
import { mapLimit } from '../media/concurrency';
import { isAudioFile, probeAudio, titleOf } from './ffmpeg';

/**
 * 音乐库扫描：库目录 → music_tracks。
 *
 * - 增量：size/mtime 未变直接跳过
 * - 元数据由 jellyfin-ffmpeg `-i` 解析（tags / 时长 / 采样率 / 内嵌封面标记）
 * - probe 并发 4，写库 100 条/事务
 */
export interface MusicLibraryRow {
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
  limit = 20000,
  subDir?: string,
  opts: { prune?: boolean } = {},
): Promise<MusicScanResult> {
  const root = filesRoot();
  let rootAbs: string;
  try {
    rootAbs = resolveInRoot(root, lib.root_path);
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

  const files = await walkFiles(baseAbs, Math.max(1, Math.min(limit, 20000)), isAudioFile);

  const existing = new Map<string, ExistingRow>();
  const rows = await sql<ExistingRow>`
    select rel_path, size, mtime from music_tracks where library_id = ${lib.id}
  `.execute(db);
  for (const r of rows.rows) existing.set(r.rel_path, r);

  const result: MusicScanResult = {
    tracks: files.length,
    added: 0,
    updated: 0,
    skipped: 0,
    probed: 0,
    missing: 0,
    pruned: 0,
  };
  const nowSec = Math.floor(Date.now() / 1000);
  const seen = new Set<string>();

  const needs: Candidate[] = [];
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
    const prev = existing.get(fullRel);
    if (prev && prev.size === st.size && prev.mtime === mtime) {
      result.skipped += 1;
      continue;
    }
    if (prev) result.updated += 1;
    else result.added += 1;
    needs.push({ rel, fullRel, abs, size: st.size, mtime });
  }

  const probed = await mapLimit(needs, PROBE_CONCURRENCY, async (c) => {
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