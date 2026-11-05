import { sql } from 'kysely';

/**
 * 刮削进度快照（2026-11-04）。
 *
 * 用户口径：
 *   - 「要搜刮的」= 库里还没有 NFO 的条目（`nfo_source` 为空或 none）；
 *   - 「已经刮了的」= 有 nfo / tmdb 来源的条目；
 *   - 「没带 C 又没字幕」= 文件名没有 `-C` 中字标记（`chinese_sub = 0`）
 *     且磁盘上没有外挂字幕（`has_subtitle = 0`）—— 这批是可以补字幕的。
 *
 * 只统计视频条目（`media_type = 'video'`），图片库不进这个口径。
 */
export interface ScrapeStats {
  day: string;
  total: number;
  scraped: number;
  unscraped: number;
  withC: number;
  withSub: number;
  noCNoSub: number;
  /** 按库拆的明细，前端可展开看「哪个库积压最多」 */
  byLibrary: Array<{
    id: string;
    name: string;
    total: number;
    scraped: number;
    unscraped: number;
    noCNoSub: number;
  }>;
  createdAt: number;
}

function dayOf(ts = Date.now()): string {
  // 用本地日期而不是 UTC：用户看到的「今天」是本机时区的今天
  const d = new Date(ts);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export async function computeScrapeStats(db: any): Promise<ScrapeStats> {
  const rows = (
    await sql<{
      library_id: string;
      total: number;
      scraped: number;
      with_c: number;
      with_sub: number;
      no_c_no_sub: number;
    }>`
      select library_id,
             count(*) as total,
             sum(case when coalesce(nfo_source, '') in ('nfo', 'tmdb') then 1 else 0 end) as scraped,
             sum(case when coalesce(chinese_sub, 0) = 1 then 1 else 0 end) as with_c,
             sum(case when coalesce(has_subtitle, 0) = 1 then 1 else 0 end) as with_sub,
             sum(case when coalesce(chinese_sub, 0) = 0
                       and coalesce(has_subtitle, 0) = 0 then 1 else 0 end) as no_c_no_sub
        from video_items
       where media_type = 'video'
       group by library_id
    `.execute(db)
  ).rows;

  const libs = (
    await sql<{ id: string; name: string }>`select id, name from video_libraries`.execute(db)
  ).rows;
  const nameOf = new Map(libs.map((l) => [l.id, l.name]));

  const byLibrary = rows.map((r) => {
    const total = Number(r.total) || 0;
    const scraped = Number(r.scraped) || 0;
    return {
      id: String(r.library_id || ''),
      name: nameOf.get(String(r.library_id || '')) ?? String(r.library_id || ''),
      total,
      scraped,
      unscraped: Math.max(0, total - scraped),
      noCNoSub: Number(r.no_c_no_sub) || 0,
    };
  });

  const sum = (pick: (r: (typeof byLibrary)[number]) => number) =>
    byLibrary.reduce((acc, r) => acc + pick(r), 0);

  const total = sum((r) => r.total);
  const scraped = sum((r) => r.scraped);
  return {
    day: dayOf(),
    total,
    scraped,
    unscraped: sum((r) => r.unscraped),
    withC: rows.reduce((acc, r) => acc + (Number(r.with_c) || 0), 0),
    withSub: rows.reduce((acc, r) => acc + (Number(r.with_sub) || 0), 0),
    noCNoSub: sum((r) => r.noCNoSub),
    byLibrary: byLibrary.sort((a, b) => b.unscraped - a.unscraped),
    createdAt: Date.now(),
  };
}

/** 当天一行，重复执行覆盖（同一天跑两次不该出现两条） */
export async function saveScrapeStats(db: any, s: ScrapeStats): Promise<void> {
  await sql`
    insert into video_scrape_stats
      (day, total, scraped, unscraped, with_c, with_sub, no_c_no_sub, detail, created_at)
    values (${s.day}, ${s.total}, ${s.scraped}, ${s.unscraped}, ${s.withC}, ${s.withSub},
            ${s.noCNoSub}, ${JSON.stringify(s.byLibrary)}, ${s.createdAt})
    on conflict(day) do update set
      total = excluded.total,
      scraped = excluded.scraped,
      unscraped = excluded.unscraped,
      with_c = excluded.with_c,
      with_sub = excluded.with_sub,
      no_c_no_sub = excluded.no_c_no_sub,
      detail = excluded.detail,
      created_at = excluded.created_at
  `.execute(db);
}

export interface ScrapeStatsRow {
  day: string;
  total: number;
  scraped: number;
  unscraped: number;
  withC: number;
  withSub: number;
  noCNoSub: number;
  byLibrary: ScrapeStats['byLibrary'];
  createdAt: number;
}

function rowOf(r: any): ScrapeStatsRow {
  let byLibrary: ScrapeStats['byLibrary'] = [];
  try {
    const parsed = r.detail ? JSON.parse(String(r.detail)) : [];
    if (Array.isArray(parsed)) byLibrary = parsed;
  } catch {
    /* 明细坏了不影响总数 */
  }
  return {
    day: String(r.day || ''),
    total: Number(r.total) || 0,
    scraped: Number(r.scraped) || 0,
    unscraped: Number(r.unscraped) || 0,
    withC: Number(r.with_c) || 0,
    withSub: Number(r.with_sub) || 0,
    noCNoSub: Number(r.no_c_no_sub) || 0,
    byLibrary,
    createdAt: Number(r.created_at) || 0,
  };
}

/** 最近 N 天，新的在前 */
export async function listScrapeStats(db: any, days = 14): Promise<ScrapeStatsRow[]> {
  const limit = Math.max(1, Math.min(Number(days) || 14, 120));
  const rows = (
    await sql`select * from video_scrape_stats order by day desc limit ${limit}`.execute(db)
  ).rows as any[];
  return rows.map(rowOf);
}
