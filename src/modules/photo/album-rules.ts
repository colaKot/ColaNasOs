import { sql } from 'kysely';
import type { Kysely } from 'kysely';

/**
 * 规则相册：相册除了「手工往里加照片」，还能配一组命中条件，符合的自动进来。
 *
 * 三种规则（彼此是 **OR**，命中任意一条就归入 —— 用户口径是「是这个头像的，
 * 或者这个场景的，或者这个日期段的，都归到这个相册」）：
 *
 *   · face  —— 命某人脸聚类（`photo_faces.cluster_id`）
 *   · scene —— 命中某场景标签（`photo_scenes.label`，如 海滩 / 夜景）
 *   · date  —— 拍摄时间落在这个区间（`photo_items.taken_at`，秒）
 *
 * 存成 `photo_albums.rules_json`，结构见 [AlbumRule]。为什么用 JSON 而不是
 * 单独一张 `photo_album_rules` 表：规则永远跟着相册整体读写（改一次就是整组替换），
 * 没有「单独查某条规则」的需求，拆表只会多一次 join 和一堆级联删除。
 */
export type AlbumRule =
  | { kind: 'face'; value: string }
  | { kind: 'scene'; value: string }
  | { kind: 'date'; from?: number; to?: number };

/** 单条规则的宽松上限，防止有人往 rules_json 里塞几万个值把 SQL 撑爆 */
const MAX_RULES = 20;

/** 把库里的 JSON 文本解析成规则数组；脏数据一律当空，不让相册打不开 */
export function parseAlbumRules(raw: unknown): AlbumRule[] {
  if (typeof raw !== 'string' || raw.trim() === '') return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const out: AlbumRule[] = [];
  for (const item of parsed.slice(0, MAX_RULES)) {
    if (!item || typeof item !== 'object') continue;
    const r = item as Record<string, unknown>;
    const kind = String(r.kind || '');
    if (kind === 'face' || kind === 'scene') {
      const value = String(r.value ?? '').trim();
      if (value) out.push({ kind, value });
      continue;
    }
    if (kind === 'date') {
      const from = Number.isFinite(Number(r.from)) ? Number(r.from) : undefined;
      const to = Number.isFinite(Number(r.to)) ? Number(r.to) : undefined;
      // 两端都空的 date 规则等于「全部照片」，那不该是相册规则，丢掉
      if (from !== undefined || to !== undefined) out.push({ kind: 'date', from, to });
    }
  }
  return out;
}

/** 序列化（顺手做一次规范化，保证入库的就是能解析回来的形态） */
export function serializeAlbumRules(rules: AlbumRule[]): string {
  return JSON.stringify(parseAlbumRules(JSON.stringify(rules)));
}

/**
 * 规则 → SQL 过滤片段（对 `photo_items i` 生效）。
 *
 * 没有任何规则时返回 null，调用方据此跳过整个回填流程（普通手工相册走这条）。
 */
export function albumRulesWhere(rules: AlbumRule[]) {
  if (rules.length === 0) return null;
  const parts = rules.map((r) => {
    switch (r.kind) {
      case 'face':
        return sql`exists (select 1 from photo_faces f where f.photo_id = i.id and f.cluster_id = ${r.value})`;
      case 'scene':
        return sql`exists (select 1 from photo_scenes s where s.photo_id = i.id and s.label = ${r.value})`;
      case 'date': {
        // 单边开区间也要能表达：只给 from = 某天之后，只给 to = 某天之前
        const seg: ReturnType<typeof sql>[] = [];
        if (r.from !== undefined) seg.push(sql`i.taken_at >= ${r.from}`);
        if (r.to !== undefined) seg.push(sql`i.taken_at <= ${r.to}`);
        return sql`(${sql.join(seg, sql` and `)})`;
      }
    }
  });
  return sql`(${sql.join(parts, sql` or `)})`;
}

/**
 * 把符合规则的现有照片补进相册（幂等：`insert or ignore`）。
 *
 * 用在三个地方：新建规则相册、改了规则、以及「规则没变但想手动重算一次」。
 * 返回新加入的行数。
 */
export async function backfillAlbumByRules(
  db: Kysely<any>,
  albumId: string,
  rules: AlbumRule[],
): Promise<number> {
  const where = albumRulesWhere(rules);
  if (!where) return 0;
  const now = Math.floor(Date.now() / 1000);
  // 一条 insert ... select 就够：让 SQLite 自己算命中集合，比拉 id 回来再逐条插快得多，
  // 也不用担心两万张照片把内存撑爆。
  const res: any = await sql`
    insert or ignore into photo_album_items (album_id, item_id, added_at)
    select ${albumId}, i.id, ${now}
      from photo_items i
     where i.in_trash = 0
       and ${where}
  `.execute(db);
  return Number(res?.numAffectedRows ?? 0) || 0;
}

/**
 * 新照片 / 新打标之后调用：把命中的规则相册收进去。
 *
 * 为什么按 itemId 而不是全库重算：扫描和 AI 分析是分批来的，每批几十上百张，
 * 全库重算一遍两万张照片是 O(n) × 相册数，白烧 CPU。这里只对刚变化的这几张
 * 反查规则，代价是 O(批大小)。
 *
 * 「这本相册该不该看到这张照片」由 `photo_libraries.owner_id = photo_albums.owner_id`
 * 决定 —— 照片属于库，库属于人，相册也属于人。调用方不用传 owner，
 * 免得每个 hook 点都要自己去 join 一次库表。
 *
 * 调用点：扫描入库后、场景/人脸打标落库后。重复调用安全（幂等）。
 */
export async function applyAlbumRulesForItems(
  db: Kysely<any>,
  itemIds: string[],
): Promise<number> {
  const ids = [...new Set(itemIds.filter(Boolean))].slice(0, 500);
  if (ids.length === 0) return 0;
  const inList = sql.join(
    ids.map((id) => sql`${id}`),
    sql`, `,
  );

  const albums = (
    await sql<{ id: string; rules_json: string }>`
      select distinct a.id, a.rules_json
        from photo_albums a
        join photo_libraries l on l.owner_id = a.owner_id
        join photo_items i on i.library_id = l.id
       where a.rules_json <> '[]'
         and i.id in (${inList})
    `.execute(db)
  ).rows;
  if (albums.length === 0) return 0;

  const now = Math.floor(Date.now() / 1000);
  let added = 0;
  for (const album of albums) {
    const where = albumRulesWhere(parseAlbumRules(album.rules_json));
    if (!where) continue;
    const res: any = await sql`
      insert or ignore into photo_album_items (album_id, item_id, added_at)
      select ${album.id}, i.id, ${now}
        from photo_items i
       where i.in_trash = 0 and i.id in (${inList}) and ${where}
    `.execute(db);
    added += Number(res?.numAffectedRows ?? 0) || 0;
  }
  return added;
}
