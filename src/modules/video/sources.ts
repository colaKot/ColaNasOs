import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import {
  absoluteInput,
  filesRoot,
  isAbsoluteInput,
  registerExtraRoot,
  resolveAnyPath,
} from '../files/fs-root';
import {
  ONLINE_NO,
  ONLINE_UNKNOWN,
  ONLINE_YES,
  buildUnc,
  normalizeConnType,
  uncPathOf,
  type SmbSourceLike,
} from './smb';

/**
 * 影视库「来源」：一个库可以有多个目录 / 多台 SMB。
 *
 * 为什么独立成表而不是继续用 `video_libraries.root_path` 单值：
 * 用户的真实用法是「一个库 = 一类片子」（例如「演员」），而片子分散在好几个盘上。
 * 旧模型下一个源头就得建一个新库，首页上于是出现三四个同名库。
 *
 * `video_libraries.root_path` 仍然保留，写的是**第一个来源**，
 * 只给那些还没改造过来的读取点（SMB 探测缓存 / 监控兜底）用，
 * 真正的来源集合以本表为准 —— 读取点走 `sourcesOf()` 会自动兜底。
 */
export interface VideoSourceRow extends SmbSourceLike {
  id: string;
  library_id: string;
  root_path: string;
  conn_type: string;
  host?: string | null;
  share?: string | null;
  sub_path?: string | null;
  unc_path?: string | null;
  smb_user?: string | null;
  smb_password_enc?: string | null;
  online_state?: number | null;
  online_checked_at?: number | null;
  sort_order?: number | null;
  items?: number | null;
  last_scan_at?: number | null;
  created_at: number;
}

/** 客户端提交的来源描述（创建 / 修改库时传数组） */
export interface SourceInput {
  connType?: string;
  /** 本地来源：绝对路径或 files 根内相对路径 */
  path?: string;
  host?: string;
  share?: string;
  subPath?: string;
  username?: string;
  password?: string;
}

/** 归一化后的来源（已校验存在性，可直接落库） */
export interface NormalizedSource {
  conn_type: string;
  root_path: string;
  host: string | null;
  share: string | null;
  sub_path: string | null;
  unc_path: string | null;
  smb_user: string | null;
  password_plain: string | null;
}

export interface SourceBuildOpts {
  /** 是否 stat 校验本地目录存在（修改已有来源时可以关掉，避免网络盘离线时改不了名） */
  validate?: boolean;
  /** 校验失败时的错误码文案前缀，用于区分是「哪个来源」出错 */
  labelOf?: (index: number) => string;
}

export class SourceError extends Error {
  statusCode: number;
  constructor(message: string, statusCode = 400) {
    super(message);
    this.statusCode = statusCode;
  }
}

/**
 * 把客户端传来的来源描述归一化成可落库的行。
 *
 * 本地目录允许在 files 根之外（`D:/down/mt/move` 这种），并登记为额外可读根，
 * 否则缩略图 / 播放 / 字幕会 403。绝对路径在库内**保留盘符写法**，
 * 相对路径则原样保留 —— 两种写法都会在 `scan` 侧经 `resolveAnyPath` 还原。
 */
export function normalizeSourceInput(input: SourceInput, index = 0): NormalizedSource {
  const connType = normalizeConnType(input.connType);
  if (connType === 'smb') {
    // 兼容「主机」里直接粘完整 UNC（\\host\share\sub）的写法
    let host = String(input.host ?? '').trim().replace(/^[\\/]+/, '');
    let share = String(input.share ?? '').trim().replace(/^[\\/]+/, '');
    let subPath = String(input.subPath ?? '').trim();
    const parts = host.split(/[\\/]+/).filter(Boolean);
    if (parts.length > 1) {
      host = parts[0];
      if (!share) share = parts[1];
      if (parts.length > 2) {
        subPath = [...parts.slice(2), subPath].filter(Boolean).join('/');
      }
    }
    if (!host || !share) {
      throw new SourceError(`sources[${index}]: host and share required`);
    }
    let unc: string;
    try {
      unc = buildUnc(host, share, subPath);
    } catch {
      throw new SourceError(`sources[${index}]: host and share required`);
    }
    return {
      conn_type: connType,
      root_path: unc,
      host,
      share,
      sub_path: subPath || null,
      unc_path: unc,
      smb_user: String(input.username ?? '').trim() || null,
      password_plain: input.password ? String(input.password) : null,
    };
  }

  const raw = String(input.path ?? '').trim();
  if (!raw) throw new SourceError(`sources[${index}]: path required`);
  const absolute = isAbsoluteInput(raw);
  let abs: string;
  try {
    abs = absolute ? path.resolve(absoluteInput(raw)) : resolveAnyPath(filesRoot(), raw);
  } catch {
    throw new SourceError(`sources[${index}]: path escapes root`);
  }
  return {
    conn_type: connType,
    root_path: absolute
      ? abs.split(path.sep).join('/')
      : path.relative(filesRoot(), abs).split(path.sep).join('/'),
    host: null,
    share: null,
    sub_path: null,
    unc_path: null,
    smb_user: null,
    password_plain: null,
  };
}

/** 本地来源存在性校验（单独出来：SMB 不 stat，离线机器会卡住接口） */
export function assertLocalSourceExists(src: NormalizedSource, index = 0): void {
  if (src.conn_type !== 'local') return;
  const absolute = isAbsoluteInput(src.root_path);
  let abs: string;
  try {
    // 相对路径必须按 files 根还原：`path.resolve('media')` 会落到**进程 cwd**，
    // 于是「media 明明存在」也报 path not found —— 这条真把全套 video smoke 打挂过。
    abs = absolute
      ? path.resolve(absoluteInput(src.root_path))
      : resolveAnyPath(filesRoot(), src.root_path);
  } catch {
    throw new SourceError(`sources[${index}]: path escapes root`);
  }
  let st: fs.Stats;
  try {
    st = fs.statSync(abs);
  } catch {
    throw new SourceError(`sources[${index}]: path not found`);
  }
  if (!st.isDirectory()) throw new SourceError(`sources[${index}]: path is not a directory`);
  if (!src.root_path) throw new SourceError(`sources[${index}]: path must be a subdirectory`);
  if (absolute) registerExtraRoot(abs);
}

/** 库没有任何来源行时的兜底：用老字段造一条，保证扫描不会「空转」 */
function fallbackSource(lib: {
  id: string;
  root_path: string;
  conn_type?: string | null;
  host?: string | null;
  share?: string | null;
  sub_path?: string | null;
  unc_path?: string | null;
  smb_user?: string | null;
  smb_password_enc?: string | null;
  online_state?: number | null;
  online_checked_at?: number | null;
  items?: number | null;
  last_scan_at?: number | null;
  created_at?: number | null;
}): VideoSourceRow {
  return {
    id: `src_${lib.id}_0`,
    library_id: lib.id,
    root_path: String(lib.root_path || ''),
    conn_type: normalizeConnType(lib.conn_type),
    host: lib.host ?? null,
    share: lib.share ?? null,
    sub_path: lib.sub_path ?? null,
    unc_path: lib.unc_path ?? null,
    smb_user: lib.smb_user ?? null,
    smb_password_enc: lib.smb_password_enc ?? null,
    online_state: Number(lib.online_state ?? ONLINE_UNKNOWN) || ONLINE_UNKNOWN,
    online_checked_at: lib.online_checked_at ?? null,
    sort_order: 0,
    items: Number(lib.items ?? 0) || 0,
    last_scan_at: lib.last_scan_at ?? null,
    created_at: Number(lib.created_at ?? 0) || 0,
  };
}

export async function sourcesOf(db: any, libraryId: string): Promise<VideoSourceRow[]> {
  const res = await sql<VideoSourceRow>`
    select * from video_library_sources
     where library_id = ${libraryId}
     order by sort_order asc, created_at asc, id asc
  `.execute(db);
  return res.rows;
}

/** 批量取来源（库列表用，避免 N+1） */
export async function sourcesOfMany(
  db: any,
  libraryIds: string[],
): Promise<Map<string, VideoSourceRow[]>> {
  const out = new Map<string, VideoSourceRow[]>();
  if (libraryIds.length === 0) return out;
  const list = sql.join(
    libraryIds.map((id) => sql`${id}`),
    sql`, `,
  );
  const res = await sql<VideoSourceRow>`
    select * from video_library_sources
     where library_id in (${list})
     order by library_id asc, sort_order asc, created_at asc, id asc
  `.execute(db);
  for (const row of res.rows) {
    const arr = out.get(row.library_id);
    if (arr) arr.push(row);
    else out.set(row.library_id, [row]);
  }
  return out;
}

/**
 * 库的有效来源集合；库里一行来源都没有时退回老字段（兼容手工改库 / 老数据）。
 * 返回顺序即展示顺序，第一个来源同时会写回 `video_libraries.root_path`。
 */
export async function effectiveSources(db: any, lib: any): Promise<VideoSourceRow[]> {
  const rows = await sourcesOf(db, lib.id);
  if (rows.length > 0) return rows;
  return [fallbackSource(lib)];
}

/**
 * 用一组新来源整体替换库的来源集合。
 *
 * 按 `root_path` 对齐复用旧行：改个密码 / 调顺序不该把在线状态和条目数清掉。
 * 返回落库后的来源行（顺序即提交顺序）。
 */
export async function replaceSources(
  db: any,
  libraryId: string,
  sources: NormalizedSource[],
  sealPassword: (plain: string) => string,
): Promise<VideoSourceRow[]> {
  const existing = await sourcesOf(db, libraryId);
  const byRoot = new Map(existing.map((r) => [r.root_path, r]));
  const now = Math.floor(Date.now() / 1000);
  const keep = new Set<string>();
  const out: VideoSourceRow[] = [];

  for (let i = 0; i < sources.length; i += 1) {
    const src = sources[i];
    // 先按 root_path 复用（改密码 / 调顺序不该清掉在线状态和条目数）；
    // 路径本身变了（本地目录改成 SMB、改了子路径）时 root 对不上，
    // 再按位置复用旧行 —— 否则会拿旧 id 去 insert，主键冲突直接 500。
    const prev =
      byRoot.get(src.root_path) ??
      (existing[i] && !keep.has(existing[i].id) ? existing[i] : undefined);
    const id = prev?.id ?? `src_${libraryId}_${i}`;
    keep.add(id);
    // 密码留空 = 不改（与 update 的语义一致），只有填了才覆盖
    const enc = src.password_plain
      ? sealPassword(src.password_plain)
      : (prev?.smb_password_enc ?? null);
    const connChanged = prev ? normalizeConnType(prev.conn_type) !== src.conn_type : true;
    if (prev) {
      await sql`
        update video_library_sources set
          root_path = ${src.root_path},
          conn_type = ${src.conn_type},
          host = ${src.host},
          share = ${src.share},
          sub_path = ${src.sub_path},
          unc_path = ${src.unc_path},
          smb_user = ${src.smb_user},
          smb_password_enc = ${enc},
          online_state = ${connChanged ? ONLINE_UNKNOWN : (prev.online_state ?? ONLINE_UNKNOWN)},
          online_checked_at = ${connChanged ? null : (prev.online_checked_at ?? null)},
          sort_order = ${i}
        where id = ${id}
      `.execute(db);
    } else {
      await sql`
        insert into video_library_sources
          (id, library_id, root_path, conn_type, host, share, sub_path, unc_path,
           smb_user, smb_password_enc, online_state, online_checked_at,
           sort_order, items, last_scan_at, created_at)
        values (${id}, ${libraryId}, ${src.root_path}, ${src.conn_type}, ${src.host}, ${src.share},
                ${src.sub_path}, ${src.unc_path}, ${src.smb_user}, ${enc}, ${ONLINE_UNKNOWN}, null,
                ${i}, 0, null, ${now})
      `.execute(db);
    }
    out.push({
      id,
      library_id: libraryId,
      root_path: src.root_path,
      conn_type: src.conn_type,
      host: src.host,
      share: src.share,
      sub_path: src.sub_path,
      unc_path: src.unc_path,
      smb_user: src.smb_user,
      smb_password_enc: enc,
      online_state: prev && !connChanged ? (prev.online_state ?? ONLINE_UNKNOWN) : ONLINE_UNKNOWN,
      online_checked_at: prev && !connChanged ? (prev.online_checked_at ?? null) : null,
      sort_order: i,
      items: prev?.items ?? 0,
      last_scan_at: prev?.last_scan_at ?? null,
      created_at: prev?.created_at ?? now,
    });
  }

  for (const row of existing) {
    if (keep.has(row.id)) continue;
    await sql`delete from video_library_sources where id = ${row.id}`.execute(db);
  }
  return out;
}

/** 来源根在本机的绝对路径；UNC 直接返回 UNC，本地越界抛错 */
export function absRootOf(src: VideoSourceRow): string {
  const unc = uncPathOf(src);
  if (unc) return unc;
  return resolveAnyPath(filesRoot(), src.root_path);
}

/** 条目 rel_path 以来源根开头的判定条件（不用 like：文件名里的 `_` 会被当通配符） */
export function relPrefixOf(src: VideoSourceRow): string {
  return `${String(src.root_path || '').replace(/\/+$/, '')}/`;
}

/** 库的「主来源」写回 video_libraries 的老字段（只给未改造的读取点兜底） */
export function primaryOf(sources: VideoSourceRow[]): VideoSourceRow | null {
  return sources[0] ?? null;
}

/**
 * 已知离线的 SMB 来源根前缀（与 `rel_path` 的前缀口径一致，带尾斜杠）。
 *
 * 一台常关机的 SMB 主机下线后，库里的索引还在，但任何一条内容都取不到图 / 放不了。
 * 读接口用这组前缀把「离线来源」的行排除掉：列表、搜索、首页、统计都只显示能用的内容；
 * 这样离线期间既不会出现一排裂图，也不会因为去 stat 网络盘而卡住接口。
 *
 * 同时看来源表与库表：老数据可能只有库上的单来源字段，没有 `video_library_sources` 行。
 */
/**
 * 已知离线的 SMB 来源根（列表 / 搜索 / 海报都按它过滤）。
 *
 * 判据是「**不是** ONLINE_YES」而不是「= ONLINE_NO」：
 * 只有探测确认在线（YES）才认为能读；UNKNOWN（刚重启、还没探到）也按离线处理。
 * 理由：UNKNOWN 时去碰网络盘 = 每个请求等一次 SMB 超时，列表和搜索都会被拖死；
 * 而内核启动与之后每 20s 都会探测，探到 YES 后内容自然出现（客户端收到
 * `video.smb.online` 事件后刷新）。用户要的是「连上才出现」，不是「乐观显示再报错」。
 */
export async function offlineSmbPrefixes(db: any): Promise<string[]> {
  const rows = (
    await sql<{ root_path: string }>`
      select root_path from video_library_sources
       where conn_type = 'smb' and coalesce(online_state, 0) <> ${ONLINE_YES}
      union
      select root_path from video_libraries
       where conn_type = 'smb' and coalesce(online_state, 0) <> ${ONLINE_YES}
    `.execute(db)
  ).rows;
  const out = new Set<string>();
  for (const r of rows) {
    // rel_path 里来源根可能保留反斜杠（UNC），统一按正斜杠比较
    const p = String(r.root_path || '').replace(/\\/g, '/').replace(/\/+$/, '');
    if (p) out.add(`${p}/`);
  }
  return [...out];
}

/** SQL 条件：排除落在离线 SMB 来源里的行；`column` 可带表别名（`v.rel_path`） */
export function offlineCond(prefixes: string[], column = 'rel_path'): ReturnType<typeof sql> {
  if (prefixes.length === 0) return sql`1 = 1`;
  const exprs = prefixes.map((raw) => {
    const p = raw.replace(/\\/g, '/');
    return sql`substr(replace(${sql.raw(column)}, '\\', '/'), 1, ${p.length}) = ${p}`;
  });
  return sql`not (${sql.join(exprs, sql` or `)})`;
}

/** 内存版：`rel_path` 是否落在某个已知离线的来源内 */
export function isOfflinePath(relPath: string, prefixes: string[]): boolean {
  const p = String(relPath || '').replace(/\\/g, '/');
  return p.length > 0 && prefixes.some((prefix) => p.startsWith(prefix.replace(/\\/g, '/')));
}

/**
 * 登记库的所有本地来源根，让缩略图 / 播放 / 字幕能读到 files 根之外的文件。
 * 启动时和每次改库后都要调 —— 这个白名单是进程内内存，重启即失效。
 */
export function registerSourceRoots(sources: VideoSourceRow[]): void {
  for (const src of sources) {
    // SMB 的 UNC 根也登记：缩略图 / 原图 / 下载都走 resolveAnyPath，
    // 不登记的话多来源 SMB 库只有第一个根能出图。
    const root = String(src.root_path || '');
    if (!isAbsoluteInput(root)) continue;
    try {
      registerExtraRoot(path.resolve(absoluteInput(root)));
    } catch {
      /* 路径非法就跳过，扫描时会报出具体原因 */
    }
  }
}
