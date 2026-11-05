import { sql } from 'kysely';
import fsp from 'node:fs/promises';
import { actorKey } from './jp-actor';
import { findNfoFile, parseActorThumbs } from './nfo';
import { filesRoot, resolveAnyPath } from '../files/fs-root';

/**
 * 演员 ↔ 作品关联（`jp_actor_items`）。
 *
 * 这张表从建库起就**没有任何写入点** —— 演员列表里的"影片数"恒为 0、"封面样例"恒空，
 * "她的全部作品"也根本查不出来。数据其实一直都在：`video_items.nfo_actors`（JSON 数组）
 * 由 NFO / 刮削写入，只需要在写完之后派生出关联。
 *
 * 约定：
 *   - 关联推导**不联网**，纯本地；演员身份键用 `actorKey()`（与档案/收藏同一套归一化）；
 *   - 单个条目先清后建，保证幂等（改名、换 nfo 都不会留旧关联）；
 *   - `jp_actors` 只补名称与时间，**不覆盖已抓到的头像 / 档案**。
 */

/** nfo_actors 是 JSON 数组字符串；容错成逗号 / 竖线分隔（人工改过的 nfo 见过） */
export function parseActorNames(raw: unknown): string[] {
  if (raw == null) return [];
  if (Array.isArray(raw)) {
    return raw.map((v) => String(v ?? '').trim()).filter(Boolean);
  }
  const text = String(raw).trim();
  if (!text) return [];
  if (text.startsWith('[')) {
    try {
      const arr = JSON.parse(text);
      if (Array.isArray(arr)) return arr.map((v) => String(v ?? '').trim()).filter(Boolean);
    } catch {
      /* 落到下面的分隔符解析 */
    }
  }
  return text
    .split(/[,，|｜/、]/)
    .map((v) => v.trim())
    .filter(Boolean);
}

/** 单个条目最多派生多少个演员，防止脏 nfo 里塞几百个名字 */
const MAX_ACTORS_PER_ITEM = 32;

/**
 * 同步一个条目的演员关联：先删旧关联，再按名字重建。
 * 返回写入的关联条数。
 */
export async function syncActorLinks(
  db: any,
  itemId: string,
  names: readonly string[],
  nowSec = Math.floor(Date.now() / 1000),
  /**
   * 演员 → 头像 URL（来自 NFO 的 `<actor><thumb>`）。
   *
   * 传了就顺手补 `jp_actors.thumb_path`：日片的 NFO 里基本都带 JavDB 的
   * `c0.jdbstatic.com/avatars/...`，之前只解析名字把这部分丢了，
   * 于是「演员全都没有头像」（2026-11-04）。已有值不覆盖（coalesce）。
   */
  thumbs?: Record<string, string> | null,
): Promise<number> {
  const seen = new Set<string>();
  const rows: Array<{ key: string; name: string }> = [];
  for (const raw of names) {
    const name = String(raw ?? '').trim();
    if (!name) continue;
    const key = actorKey(name);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    rows.push({ key, name });
    if (rows.length >= MAX_ACTORS_PER_ITEM) break;
  }

  await sql`delete from jp_actor_items where item_id = ${itemId}`.execute(db);
  if (rows.length === 0) return 0;

  for (const r of rows) {
    const thumb = String(thumbs?.[r.name] ?? '').trim();
    await sql`
      insert into jp_actors (id, name, thumb_path, updated_at)
      values (${r.key}, ${r.name}, ${thumb || null}, ${nowSec})
      on conflict(id) do update set
        name = excluded.name,
        thumb_path = coalesce(nullif(excluded.thumb_path, ''), jp_actors.thumb_path),
        updated_at = excluded.updated_at
    `.execute(db);
    await sql`
      insert or ignore into jp_actor_items (actor_id, item_id) values (${r.key}, ${itemId})
    `.execute(db);
  }
  return rows.length;
}

export interface RebuildResult {
  items: number;
  actors: number;
  links: number;
}

/**
 * 从 `video_items.nfo_actors` 全量重建关联（老库补齐用）。
 *
 * 纯本地、无文件 IO，几万条也就几秒；不联网，所以不会因为站点抽风失败。
 */
export async function rebuildActorLinks(
  db: any,
  opts: { libraryId?: string; limit?: number } = {},
): Promise<RebuildResult> {
  const limit = Math.max(1, Math.min(Number(opts.limit) || 20000, 200000));
  const rows = (
    await sql<{ id: string; nfo_actors: string | null }>`
      select id, nfo_actors from video_items
       where media_type = 'video'
         and nfo_actors is not null
         ${opts.libraryId ? sql`and library_id = ${opts.libraryId}` : sql``}
       order by created_at desc
       limit ${limit}
    `.execute(db)
  ).rows;

  const nowSec = Math.floor(Date.now() / 1000);
  let links = 0;
  for (const row of rows) {
    links += await syncActorLinks(db, row.id, parseActorNames(row.nfo_actors), nowSec);
  }
  const actors = Number(
    (await sql<{ n: number }>`select count(*) as n from jp_actors`.execute(db)).rows[0]?.n,
  );
  return { items: rows.length, actors: actors || 0, links };
}

/**
 * 从 NFO 的 `<actor><thumb>` 回填演员头像（2026-11-04）。
 *
 * 为什么需要单独一趟：增量扫描会跳过「文件没变」的条目，所以老库即使升级了
 * 解析逻辑也不会重新读 NFO，`jp_actors.thumb_path` 会一直是空的。
 * 这里只读**还没头像**的演员关联到的条目，读到就补，已有值不覆盖。
 *
 * 纯本地读盘（SMB 上每份 NFO 几 KB），不联网；2000 条量级约 1~2 分钟，
 * 所以走后台任务而不是 HTTP 同步。
 */
export interface ThumbBackfillResult {
  scanned: number;
  updated: number;
}

export async function backfillActorThumbs(
  db: any,
  opts: {
    libraryId?: string;
    limit?: number;
    onProgress?: (done: number, total: number) => void;
  } = {},
): Promise<ThumbBackfillResult> {
  const limit = Math.max(1, Math.min(Number(opts.limit) || 5000, 200000));
  const rows = (
    await sql<{ item_id: string; rel_path: string }>`
      select distinct i.id as item_id, i.rel_path
        from video_items i
        join jp_actor_items ai on ai.item_id = i.id
        join jp_actors a on a.id = ai.actor_id
       where coalesce(a.thumb_path, '') = ''
         and coalesce(i.nfo_source, '') = 'nfo'
         ${opts.libraryId ? sql`and i.library_id = ${opts.libraryId}` : sql``}
       limit ${limit}
    `.execute(db)
  ).rows;
  if (rows.length === 0) return { scanned: 0, updated: 0 };

  const root = filesRoot();
  let updated = 0;
  let done = 0;
  for (const row of rows) {
    done += 1;
    try {
      const abs = resolveAnyPath(root, row.rel_path);
      const found = await findNfoFile(abs);
      if (!found) continue;
      const xml = await fsp.readFile(found.file, 'utf-8');
      const thumbs = parseActorThumbs(xml);
      for (const [name, url] of Object.entries(thumbs)) {
        const key = actorKey(name);
        if (!key) continue;
        const res = await sql`
          update jp_actors set thumb_path = ${url}
           where id = ${key} and coalesce(thumb_path, '') = ''
        `.execute(db);
        updated += Number(res.numAffectedRows || 0);
      }
    } catch {
      // 单个文件读不到（离线 / 权限）不该中断整趟
    }
    if (opts.onProgress && done % 20 === 0) opts.onProgress(done, rows.length);
  }
  opts.onProgress?.(done, rows.length);
  return { scanned: rows.length, updated };
}

/** 清掉既没有作品也没有档案的演员行（重建后可能留下空壳） */
export async function pruneOrphanActors(db: any): Promise<number> {
  const res = await sql`
    delete from jp_actors
     where (profile is null or profile = '')
       and id not in (select actor_id from jp_actor_items)
  `.execute(db);
  return Number(res.numAffectedRows || 0);
}
