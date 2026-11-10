import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../../kernel/route';
import { downloadHandler } from '../../files/download';
import {
  filesRoot,
  isAbsoluteInput,
  absoluteInput,
  resolveInRoot,
  resolveAnyPath,
} from '../../files/fs-root';
import { writeCover } from '../ffmpeg';
import { readLyrics, type LyricsResult } from '../lyrics';
import { ensureTranscoded } from '../transcode';
import { runMusicScan } from './library';
import { musicSearchRank, musicSearchWhere } from '../search';
import { foldHan } from '../search-equiv';
import { downloadCover, findCoverUrl, searchLyrics } from '../scrape';
import {
  artistTopTracks,
  artistCrowd,
  albumCrowd,
  clearLastfmCache,
  lastfmCreds,
  lastfmAuthStart,
  lastfmAuthSession,
  lastfmAccountOf,
  saveLastfmAccount,
  unlinkLastfmAccount,
  savePendingToken,
  takePendingToken,
  peekPendingToken,
  lastfmScrobble,
  lastfmNowPlaying,
  normTrackName,
  rankMap,
  writeMusicSetting,
  SETTING_LASTFM_KEY,
  SETTING_LASTFM_SECRET,
  type LastfmTopTrack,
} from '../lastfm';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/**
 * 既有实现 音乐接口的**兼容适配层**。
 *
 * 为什么需要它：前端音乐模块是从 既有实现 整页搬过来的，它调的是 `/api/music/*`，
 * 拿到的是「int 曲目 id + page/pageSize 偏移分页 + snake_case 字段」这套形状；本项目的
 * `/api/v1/music/*` 是「uuid id + cursor 分页 + camelCase」。两边语义对得上但外形差很远。
 *
 * 把这层差异放在服务端而不是 Dart 里，理由：
 * - 30 多个字段的映射只写一遍，不用在客户端维护 cursor→page 的栈；
 * - 真出问题时改一处、跑个冒烟就能回归，不用重编 APK；
 * - 搬运过来的 Dart 源文件一个都不用改（`compat/api_ns.dart` 只做转发）。
 *
 * 约定：
 * - **对外 int id = SQLite 隐式 `rowid`**（曲目 / 歌单 / 合集 / 来源都这样）。内部 uuid 不变，
 *   两者靠 `rowid → id` 的小查询互转；
 * - 时长一律**秒**（既有实现 口径），本项目库里存毫秒；
 * - 分页外壳 `{ items, pagination: { total, page, limit, totalPages, hasNextPage, hasPrevPage } }`；
 * - 全部 `schema.hide = true`：不进 OpenAPI、不生成客户端，纯内部适配口。
 */

const TAGS = ['music'];

/** 都走 hide，避免污染契约与生成的客户端 */
const hidden = (scope: string) =>
  secured(scope, { schema: { hide: true, tags: TAGS } } as never);

interface CompatTrackRow {
  index_id: number;
  id: string;
  library_id: string;
  rel_path: string;
  title: string;
  artist: string | null;
  album: string | null;
  album_artist: string | null;
  genre: string | null;
  track_no: number | null;
  year: number | null;
  duration: number | null;
  bitrate: number | null;
  sample_rate: number | null;
  has_cover: number;
  size: number;
  mtime: number;
  created_at: number;
  root_path: string | null;
  /** 只在「热度」相关查询里带出来（本地播放次数） */
  play_count?: number;
}

/** 热度附加信息：本地播放次数 + Last.fm 排名（未配置 / 未命中都是 0） */
interface HotExtra {
  playCount: number;
  hot: LastfmTopTrack | null;
}

const nowSec = () => Math.floor(Date.now() / 1000);

const normSlashes = (p: string) => String(p || '').replace(/\\/g, '/');

const dirOf = (p: string) => {
  const s = normSlashes(p);
  const i = s.lastIndexOf('/');
  return i < 0 ? '' : s.slice(0, i);
};

const baseOf = (p: string) => {
  const s = normSlashes(p);
  const i = s.lastIndexOf('/');
  return i < 0 ? s : s.slice(i + 1);
};

const extOf = (p: string) => {
  const b = baseOf(p);
  const i = b.lastIndexOf('.');
  return i < 0 ? '' : b.slice(i + 1).toLowerCase();
};

/** 毫秒 → 秒（既有实现 的 `duration` 是秒，客户端按秒格式化） */
const toSec = (ms: number | null | undefined) =>
  Math.max(0, Math.round(Number(ms ?? 0) / 1000));

const toInt = (v: unknown, def = 0) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : def;
};

const asStringArray = (v: unknown): string[] => {
  if (Array.isArray(v)) return v.map((x) => String(x)).filter((x) => x.trim() !== '');
  if (typeof v === 'string' && v.trim()) return [v.trim()];
  return [];
};

/** `x = a or x = b …`；空数组给恒假条件，避免拼出 `where ` 语法错 */
const anyEq = (col: string, values: string[]) =>
  values.reduce(
    (acc: unknown, v: string) => sql`${acc} or ${sql.ref(col)} = ${v}`,
    sql`1 = 0` as unknown,
  );

/** 目录前缀匹配（与合集里那套保持一致） */
const likeOf = (p: string) => `${normSlashes(p).replace(/[\\/]+$/, '')}/%`;

const anyLike = (col: string, likes: string[]) =>
  likes.reduce(
    (acc: unknown, l: string) => sql`${acc} or ${sql.ref(col)} like ${l}`,
    sql`1 = 0` as unknown,
  );

/** 曲目搜索列：标题 / 艺人 / 专辑 / **文件名**（老库很多歌只有文件名带信息） */
const TRACK_SEARCH_COLS = ['t.title', 't.artist', 't.album', 't.rel_path'];

/**
 * 「查无此图」哨兵的内容标记。在线源 / 匹配规则升级时改一下这个值，
 * 旧哨兵自动失效重查 —— 否则老库里几百首「以前查不到」的歌永远补不上封面。
 */
const COVER_NONE_MARK = 'v3';

/** readLyrics 给的是结构化行，既有实现 前端要的是一整段 LRC 文本 */
function lrcTextOf(r: LyricsResult): string {
  if (r.lines.length === 0) return '';
  return r.lines
    .map((line) => {
      const ms = line.timeMs;
      const tag =
        ms == null
          ? ''
          : `[${String(Math.floor(ms / 60000)).padStart(2, '0')}:${String(
              Math.floor((ms % 60000) / 1000),
            ).padStart(2, '0')}.${String(Math.floor((ms % 1000) / 10)).padStart(2, '0')}]`;
      return `${tag}${line.translation ? `${line.text} / ${line.translation}` : line.text}`;
    })
    .join('\n');
}

/**
 * 排序键白名单（带表别名，列表查询里有 join）。
 * `hot` 不在这里：它要融合 Last.fm 排名，走 [registerMusicCompat] 里的内存排序分支。
 */
const SORT_EXPR: Record<string, string> = {
  title: 't.title',
  artist: "coalesce(t.artist, '')",
  album: "coalesce(t.album, '')",
  year: 'coalesce(t.year, 0)',
  duration: 'coalesce(t.duration, 0)',
  track_no: 'coalesce(t.track_no, 0)',
  ctime: 't.created_at',
  mtime: 't.mtime',
  favorite_time: 't.created_at',
};

/** 曲目行 → 既有实现 形状 */
function toCompatTrack(
  row: CompatTrackRow,
  favorite: boolean,
  hot?: HotExtra,
): Record<string, unknown> {
  const rel = normSlashes(row.rel_path);
  const root = row.root_path ? normSlashes(row.root_path) : '';
  // 老库 `rel_path` 本身就是绝对路径（或已经带 root 前缀），再拼一遍会得到
  // `G:/music/G:/music/...`：封面 / 播放 / 删除全靠「后缀兜底」才碰巧没炸。
  const rootPrefix = root.replace(/\/+$/, '').toLowerCase();
  const alreadyRooted =
    isAbsoluteInput(rel) ||
    (rootPrefix !== '' && rel.toLowerCase().startsWith(`${rootPrefix}/`));
  const full = !root || alreadyRooted ? rel : `${root.replace(/\/+$/, '')}/${rel}`;
  const ctime = Number(row.created_at ?? 0);
  const mtime = Number(row.mtime ?? 0);
  return {
    id: Number(row.index_id),
    // 既有实现 用「目录 + 文件名」两段，`fullPath` 再拼起来
    path: dirOf(rel),
    filename: baseOf(rel),
    full_path: full,
    first_file_path: rel,
    file_hash: '',
    title: row.title ?? '',
    artist: row.artist ?? '',
    album: row.album ?? '',
    album_artist: row.album_artist ?? '',
    year: row.year == null ? '' : String(row.year),
    genre: row.genre ?? '',
    track_no: row.track_no == null ? 0 : Number(row.track_no),
    duration: toSec(row.duration),
    size: Number(row.size ?? 0),
    ext: extOf(rel),
    has_inner_cover: Number(row.has_cover ?? 0),
    show_type: 'music',
    music_count: 0,
    is_favorite: favorite ? 1 : 0,
    is_from_file: 1,
    ctime,
    mtime,
    birthtime: ctime,
    bitrate: Number(row.bitrate ?? 0),
    sample_rate: Number(row.sample_rate ?? 0),
    bit_depth: 0,
    // 热度相关：默认全 0，页面据此判断要不要显示热度徽标。
    // `hot_score` 只做展示用的 0~100 归一分，权威排序在服务端内存排序里做。
    play_count: Number(hot?.playCount ?? row.play_count ?? 0) || 0,
    hot_rank: hot?.hot?.rank ?? 0,
    hot_playcount: hot?.hot?.playcount ?? 0,
    hot_listeners: hot?.hot?.listeners ?? 0,
    hot_score: hot?.hot ? Math.max(1, Math.min(100, 101 - hot.hot.rank)) : 0,
  };
}

/**
 * 同名歌曲去重：`trackName + 歌手` 相同视为同一首，保留**最新的一条**
 * （先比 mtime，相同再比 created_at）。
 *
 * 为什么在服务端做：歌手页要「只留最新版本」，前端内存去重会让长列表
 * 越滚越慢，而且分页边界上会出现「上一页有、下一页还有」的重复。
 * 只在显式传 `dedupe: 1` 时生效 —— 曲库 / 歌单页必须看到全部文件。
 */
/**
 * 版本标签：同名情况下**允许共存**的那几类（现场 / 不插电 / 混音 / 伴奏）。
 *
 * `normTrackName`（给 Last.fm 匹配用）会把 "晴天 (Live)" 和 "晴天" 归一成同一个键，
 * 但去重不能这么干 —— 用户明确说过「一个 live 一个专辑版可以都留着」。
 */
function versionTagOf(title: string): string {
  const s = String(title ?? '').toLowerCase();
  if (/\blive\b|现场|現場|演唱會|演唱会|unplugged/.test(s)) return 'live';
  if (/\bacoustic\b|不插电|不插電/.test(s)) return 'acoustic';
  if (/\bremix\b|混音|dj版/.test(s)) return 'remix';
  if (/\binstrumental\b|伴奏|纯音乐|純音樂/.test(s)) return 'instrumental';
  return '';
}

/** 标题归一（去重专用）：简繁折叠 + 小写 + 只留字母数字汉字，标点 / 空格 / 括号都抹掉 */
const normTitleForMatch = (raw: unknown) =>
  foldHan(String(raw ?? '').toLowerCase()).replace(/[^a-z0-9\u4e00-\u9fff]+/g, '');

/** 歌手归一：同样做简繁折叠，避免「周杰伦 / 周杰倫」把同一首算成两首 */
const normArtistForMatch = (raw: unknown) =>
  foldHan(String(raw ?? '').toLowerCase()).replace(/[^a-z0-9\u4e00-\u9fff]+/g, '');

/**
 * 去重 key：`归一标题 | 版本标签 | 归一歌手`。
 *
 * 被抹掉的差异都算「同一首」：简繁（我愛你 / 我爱你）、大小写、标点与空格、
 * 「(Remastered)」这类括号尾巴之外的普通括号内容。
 * 保留的差异只有版本标签 —— live / acoustic / remix / instrumental 各留一条。
 */
function dedupeKeyOf(row: CompatTrackRow): string {
  const title = normTitleForMatch(row.title);
  // 归一后为空（标题全是符号 / 空标题）不参与去重，否则会把不相干的歌全合并
  if (!title) return '';
  return `${title}|${versionTagOf(row.title)}|${normArtistForMatch(row.artist)}`;
}

function dedupeByTitle(rows: CompatTrackRow[]): CompatTrackRow[] {
  const best = new Map<string, CompatTrackRow>();
  for (const r of rows) {
    const key = dedupeKeyOf(r);
    if (!key) continue;
    const prev = best.get(key);
    const newer =
      !prev ||
      Number(r.mtime ?? 0) > Number(prev.mtime ?? 0) ||
      (Number(r.mtime ?? 0) === Number(prev.mtime ?? 0) &&
        Number(r.created_at ?? 0) > Number(prev.created_at ?? 0));
    if (newer) best.set(key, r);
  }
  return [...best.values()];
}

/**
 * 内存排序（只用于去重 / 热度这两条分支）。
 *
 * 热度规则：命中 Last.fm 的排在前面且按排名升序；没命中的按**本地播放次数**降序，
 * 再按当前排序键（专辑顺序 / 歌名）兜底 —— 这样「没配 API Key」和「配了但库里
 * 全是冷门翻唱」都不会得到随机顺序。
 */
function compareTracks(
  a: CompatTrackRow,
  b: CompatTrackRow,
  sortKey: string,
  desc: boolean,
  hotOf: (r: CompatTrackRow) => LastfmTopTrack | null,
): number {
  const hotA = hotOf(a);
  const hotB = hotOf(b);
  if (hotA && hotB && hotA.rank !== hotB.rank) return hotA.rank - hotB.rank;
  if (hotA && !hotB) return -1;
  if (!hotA && hotB) return 1;

  const plays = Number(b.play_count ?? 0) - Number(a.play_count ?? 0);
  if (plays !== 0) return plays;

  if (sortKey === 'album_order') {
    const album = String(a.album ?? '').localeCompare(String(b.album ?? ''), 'zh');
    if (album !== 0) return album;
    const no = Number(a.track_no ?? 0) - Number(b.track_no ?? 0);
    if (no !== 0) return no;
    return String(a.title ?? '').localeCompare(String(b.title ?? ''), 'zh');
  }
  const c = String(a.title ?? '').localeCompare(String(b.title ?? ''), 'zh');
  return desc ? -c : c;
}

/** 分页外壳（字段名对齐参考侧 `fromJson`） */
function paginationOf(total: number, page: number, pageSize: number) {
  const size = pageSize > 0 ? pageSize : 30;
  const totalPages = total <= 0 ? 0 : Math.ceil(total / size);
  return {
    total,
    page,
    limit: size,
    pageSize: size,
    totalPages,
    hasNextPage: page < totalPages,
    hasPrevPage: page > 1,
  };
}

/** 库根路径 → 绝对路径（相对路径按 files 根解析；解析不了就原样） */
const absOfRoot = (root: string): string => {
  const raw = String(root || '').trim();
  if (!raw) return '';
  try {
    if (isAbsoluteInput(raw)) return absoluteInput(raw);
    return resolveInRoot(filesRoot(), raw);
  } catch {
    return raw;
  }
};

export async function registerMusicCompat(
  app: FastifyInstance,
  k: KernelApi,
  h: MusicHelpers,
): Promise<void> {
  const owner = (req: FastifyRequest) => req.user?.sub ?? '';

  /** 曲目 rowid → uuid（收藏 / 歌单 / 历史都要用 uuid 落库） */
  const idsOfIndex = async (indexIds: number[]): Promise<Map<number, string>> => {
    const out = new Map<number, string>();
    const clean = Array.from(new Set(indexIds.map((n) => toInt(n)).filter((n) => n > 0)));
    if (clean.length === 0) return out;
    const rows = await sql<{ index_id: number; id: string }>`
      select rowid as index_id, id from music_tracks
       where rowid in (${sql.raw(clean.join(','))})
    `.execute(k.db);
    for (const r of rows.rows) out.set(Number(r.index_id), r.id);
    return out;
  };

  /** 当前用户的收藏集合（uuid） */
  const favoriteIds = async (req: FastifyRequest): Promise<Set<string>> => {
    const rows = await sql<{ item_id: string }>`
      select item_id from music_favorites where owner_id = ${owner(req)}
    `.execute(k.db);
    return new Set(rows.rows.map((r) => r.item_id));
  };

  /** 用来源路径（音乐来源的绝对 / 相对根）换 library_id 列表 */
  const libraryIdsOfSources = async (sources: string[]): Promise<string[]> => {
    if (sources.length === 0) return [];
    const all = await sql<{ id: string; root_path: string }>`
      select id, root_path from music_libraries
    `.execute(k.db);
    const want = new Set(sources.map((s) => normSlashes(s).replace(/\/+$/, '')));
    return all.rows
      .filter((r) => want.has(normSlashes(r.root_path).replace(/\/+$/, '')))
      .map((r) => r.id);
  };

  /** 合集路径 → `rel_path like` 条件；无效合集给恒假 */
  const collectionWhere = async (req: FastifyRequest, collectionId: number) => {
    const col = await sql<{ paths: string }>`
      select paths from music_collections
       where rowid = ${collectionId} and owner_id = ${owner(req)}
    `.execute(k.db);
    const raw = col.rows[0]?.paths;
    let paths: string[] = [];
    if (raw) {
      try {
        const v = JSON.parse(raw);
        if (Array.isArray(v)) paths = v.map((x) => String(x));
      } catch {
        paths = [];
      }
    }
    return paths.length
      ? sql`(${anyLike('rel_path', paths.map(likeOf))})`
      : sql`1 = 0`;
  };

  /**
   * 按路径找曲目。客户端传过来的可能是：
   * - `music/sub/a.mp3`（相对 files 根，= 本项目的 `rel_path`）；
   * - `G:/nas/music/sub/a.mp3`（库根是绝对路径时，`rel_path` 本身就是绝对值）；
   * - 库内相对路径 `sub/a.mp3`（既有实现 里最常见的形状）。
   * 三种都吃下：等值 → 传参是 rel_path 的后缀 → rel_path 是传参的后缀。
   */
  const findTrackRow = async (raw: string): Promise<CompatTrackRow | null> => {
    const p = normSlashes(String(raw || '')).trim();
    if (!p) return null;
    // 老库 rel_path 里混着反斜杠（`G:\music/xxx.flac`），而客户端回传的是
    // normSlashes 后的正斜杠。两侧先统一斜杠再比，否则封面 / 播放 / 删除全部 404。
    const res = await sql<CompatTrackRow>`
      select t.rowid as index_id, t.*, l.root_path
        from music_tracks t join music_libraries l on l.id = t.library_id
       where replace(t.rel_path, '\\', '/') = ${p}
          or ${p} like '%/' || replace(t.rel_path, '\\', '/')
          or replace(t.rel_path, '\\', '/') like '%/' || ${p}
       order by length(t.rel_path) desc
       limit 1
    `.execute(k.db);
    return res.rows[0] ?? null;
  };

  /** 歌单 / 合集的预览曲目（前 4 首有封面的优先） */
  const previewsOfTracks = async (trackIds: string[]) => {
    if (trackIds.length === 0) return [];
    const rows = await sql<{
      index_id: number;
      rel_path: string;
      has_cover: number;
    }>`
      select rowid as index_id, rel_path, has_cover from music_tracks
       where id in (${sql.raw(trackIds.map((t) => `'${t.replace(/'/g, "''")}'`).join(','))})
       order by has_cover desc
       limit 4
    `.execute(k.db);
    return rows.rows.map((r) => ({
      id: Number(r.index_id),
      path: dirOf(r.rel_path),
      filename: baseOf(r.rel_path),
      show_type: 'music',
      first_file_path: normSlashes(r.rel_path),
      has_inner_cover: Number(r.has_cover ?? 0),
    }));
  };

  // ============================================================ 曲库列表

  app.post('/api/v1/music/compat/list', hidden('music:read'), async (req: FastifyRequest) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const page = Math.max(1, toInt(body.page, 1));
    const pageSize = Math.min(500, Math.max(1, toInt(body.page_size ?? body.pageSize, 30)));
    const offset = (page - 1) * pageSize;
    const search = String(body.search ?? '').trim();
    const artists = asStringArray(body.artists);
    const albums = asStringArray(body.albums);
    const genres = asStringArray(body.genres);
    const isFavorite = toInt(body.is_favorite ?? body.isFavorite, 0) === 1;
    const isHistory = toInt(body.isHistory ?? body.is_history, 0) === 1;
    const listId = toInt(body.list_id ?? body.listId, 0);
    const collectionId = toInt(body.collection_id ?? body.collectionId, 0);
    const sources = asStringArray(body.sourceList ?? body.source_list);
    const sortKey = String(body.sort_by ?? body.sortBy ?? 'title').toLowerCase();
    const desc = String(body.sort_order ?? body.sortOrder ?? 'asc').toLowerCase() === 'desc';

    let where = sql`1 = 1`;
    const searchClause = musicSearchWhere(TRACK_SEARCH_COLS, search);
    if (searchClause) where = sql`${where} and ${searchClause}`;
    if (artists.length > 0) where = sql`${where} and (${anyEq('t.artist', artists)})`;
    if (albums.length > 0) where = sql`${where} and (${anyEq('t.album', albums)})`;
    if (genres.length > 0) where = sql`${where} and (${anyEq('t.genre', genres)})`;

    if (sources.length > 0) {
      const libIds = await libraryIdsOfSources(sources);
      where = libIds.length
        ? sql`${where} and (${anyEq('t.library_id', libIds)})`
        : sql`${where} and 1 = 0`;
    }

    if (isFavorite) {
      where = sql`${where} and exists (
        select 1 from music_favorites f
         where f.item_id = t.id and f.owner_id = ${owner(req)})`;
    }

    if (collectionId > 0) {
      where = sql`${where} and (${await collectionWhere(req, collectionId)})`;
    }

    if (listId > 0) {
      // 歌单详情：子列表传的是 `list_id`（= music_playlists.rowid）
      where = sql`${where} and exists (
        select 1 from music_playlist_items i join music_playlists p on p.id = i.playlist_id
         where i.track_id = t.id and p.rowid = ${listId} and p.owner_id = ${owner(req)})`;
    }

    const expr = SORT_EXPR[sortKey] ?? SORT_EXPR.title;
    const dir = sql.raw(desc ? 'desc' : 'asc');
    // 精确 / 连续命中排前面，纯跳字模糊命中沉底（只用于这里的偏移分页）
    const rank = musicSearchRank(TRACK_SEARCH_COLS, search);
    const rankPrefix = rank ? sql`${rank}, ` : sql``;

    // ---------------------------------------------------------- 排序 / 分页
    // 三条分支，别合并：
    // 1. 播放历史：按最后一次播放时间倒序（每首只出现一次）；
    // 2. 去重 / 热度：SQLite 做不了「同名取最新」和「Last.fm 排名融合」，
    //    先取全量在内存里处理再切片（歌手页曲目量级可控，专辑页不会走这条）；
    // 3. 通用：SQL 排序 + 偏移分页（性能路径，绝大多数页面走这里）。
    const dedupe = toInt(body.dedupe, 0) === 1;
    const hotMode = sortKey === 'hot';
    const artistName = artists.length === 1 ? artists[0] : '';

    if (!isHistory && (dedupe || (hotMode && artistName !== ''))) {
      const all = await sql<CompatTrackRow>`
        select t.rowid as index_id, t.*, l.root_path,
               (select count(*) from music_plays p where p.item_id = t.id) as play_count
          from music_tracks t join music_libraries l on l.id = t.library_id
         where ${where}
      `.execute(k.db);
      const list = dedupe ? dedupeByTitle(all.rows) : all.rows;
      const top = hotMode ? rankMap((await artistTopTracks(k, artistName, 100)).items) : null;
      const hotOf = (r: CompatTrackRow): LastfmTopTrack | null =>
        top ? (top.get(normTrackName(r.title)) ?? null) : null;
      list.sort((a, b) => compareTracks(a, b, sortKey, desc, hotOf));
      const total = list.length;
      const pageRows = list.slice(offset, offset + pageSize);
      const favs = await favoriteIds(req);
      return {
        items: pageRows.map((r) =>
          toCompatTrack(r, favs.has(r.id), {
            playCount: Number(r.play_count ?? 0),
            hot: hotOf(r),
          }),
        ),
        pagination: paginationOf(total, page, pageSize),
        filters: null,
        validPaths: [] as string[],
        // 前端只用它显示「热度来自 Last.fm / 本地播放量」，不做逻辑判断
        hot_source: top && top.size > 0 ? 'lastfm' : 'local',
      };
    }

    const totalRes = await sql<{ n: number }>`
      select count(*) as n
        from music_tracks t join music_libraries l on l.id = t.library_id
       where ${where}
    `.execute(k.db);
    const total = Number(totalRes.rows[0]?.n) || 0;

    let rows;
    if (isHistory) {
      // 播放历史：按「最后一次播放时间」倒序，且每首只出现一次
      rows = await sql<CompatTrackRow>`
        select t.rowid as index_id, t.*, l.root_path, max(p.played_at) as last_played
          from music_tracks t
          join music_libraries l on l.id = t.library_id
          join music_plays p on p.item_id = t.id and p.owner_id = ${owner(req)}
         where ${where}
         group by t.id
         order by ${rankPrefix}last_played ${dir}
         limit ${pageSize} offset ${offset}
      `.execute(k.db);
    } else {
      // 专辑原生顺序（专辑名 → 音轨号 → 曲名）不是单一列能表达的，单独拼一段。
      // 它恒为升序：所谓「按专辑顺序」就是唱片上的顺序，倒过来没有意义。
      const orderSql =
        sortKey === 'album_order'
          ? sql.raw(
              "coalesce(t.album, '') asc, coalesce(t.track_no, 0) asc, t.title asc",
            )
          : sql`${sql.raw(expr)} ${dir}`;
      rows = await sql<CompatTrackRow>`
        select t.rowid as index_id, t.*, l.root_path
          from music_tracks t join music_libraries l on l.id = t.library_id
         where ${where}
         order by ${rankPrefix}${orderSql}, t.id asc
         limit ${pageSize} offset ${offset}
      `.execute(k.db);
    }

    const favs = await favoriteIds(req);
    return {
      items: rows.rows.map((r) => toCompatTrack(r, favs.has(r.id))),
      pagination: paginationOf(total, page, pageSize),
      filters: null,
      validPaths: [] as string[],
    };
  });

  app.post(
    '/api/v1/music/compat/list/count',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const sources = asStringArray(body.sourceList ?? body.source_list);
      let where = sql`1 = 1`;
      if (sources.length > 0) {
        const libIds = await libraryIdsOfSources(sources);
        where = libIds.length
          ? sql`${where} and (${anyEq('library_id', libIds)})`
          : sql`${where} and 1 = 0`;
      }
      const res = await sql<{ n: number }>`
        select count(*) as n from music_tracks t where ${where}
      `.execute(k.db);
      return { songs: Number(res.rows[0]?.n) || 0 };
    },
  );

  app.post('/api/v1/music/compat/detail', hidden('music:read'), async (req: FastifyRequest) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const filePath = normSlashes(String(body.file_path ?? body.filePath ?? '').trim());
    const indexId = toInt(body.index_id ?? body.indexId, 0);
    let row: CompatTrackRow | null = null;
    if (indexId > 0) {
      const res = await sql<CompatTrackRow>`
        select t.rowid as index_id, t.*, l.root_path
          from music_tracks t join music_libraries l on l.id = t.library_id
         where t.rowid = ${indexId}
      `.execute(k.db);
      row = res.rows[0] ?? null;
    } else if (filePath) {
      row = await findTrackRow(filePath);
    }
    if (!row) return {};
    const favs = await favoriteIds(req);
    const item = toCompatTrack(row, favs.has(row.id));
    // 既有实现 的 detail/get 回 `{ item, lyrics }`，搬过来的播放控制器正是从
    // data['lyrics'] 取词。以前这里只回平铺字段，旁挂 .lrc / 内嵌 LYRICS 一首都不显示。
    let lyrics = '';
    try {
      const abs = resolveAnyPath(filesRoot(), row.rel_path);
      if (fs.existsSync(abs)) lyrics = lrcTextOf(await readLyrics(abs));
    } catch {
      /* 路径失效 / 读不出来就当没歌词，不影响详情本身 */
    }
    return { ...item, item, lyrics };
  });

  app.post('/api/v1/music/compat/delete', hidden('music:write'), async (req: FastifyRequest) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const paths = asStringArray(body.paths).map((p) => normSlashes(p));
    if (paths.length === 0) return { ok: true, affected: 0 };
    let affected = 0;
    for (const rel of paths) {
      const row = await findTrackRow(rel);
      if (!row) continue;
      await sql`delete from music_playlist_items where track_id = ${row.id}`.execute(k.db);
      await sql`delete from music_favorites where item_id = ${row.id}`.execute(k.db);
      await sql`delete from music_plays where item_id = ${row.id}`.execute(k.db);
      await sql`delete from music_tracks where id = ${row.id}`.execute(k.db);
      affected += 1;
    }
    return { ok: true, affected, recycled: toInt(body.recycle, 0) === 1 };
  });

  // ============================================================ 专辑 / 艺人聚合

  const aggregate = async (col: 'album' | 'artist', body: Record<string, unknown>) => {
    const page = Math.max(1, toInt(body.page, 1));
    const pageSize = Math.min(1000, Math.max(1, toInt(body.page_size ?? body.pageSize, 30)));
    const offset = (page - 1) * pageSize;
    const search = String(body.search ?? '').trim();
    const sources = asStringArray(body.sourceList ?? body.source_list);
    const sortKey = String(body.sort_by ?? body.sortBy ?? '').toLowerCase();
    const desc = String(body.sort_order ?? body.sortOrder ?? '').toLowerCase() === 'desc';

    let where = sql`${sql.ref(col)} is not null and ${sql.ref(col)} != ''`;
    if (search) {
      const sw = musicSearchWhere([col], search);
      if (sw) where = sql`${where} and ${sw}`;
    }
    if (sources.length > 0) {
      const libIds = await libraryIdsOfSources(sources);
      where = libIds.length
        ? sql`${where} and (${anyEq('library_id', libIds)})`
        : sql`${where} and 1 = 0`;
    }

    const totalRes = await sql<{ n: number }>`
      select count(*) as n from (
        select ${sql.ref(col)} as k from music_tracks where ${where} group by ${sql.ref(col)}
      )
    `.execute(k.db);
    const total = Number(totalRes.rows[0]?.n) || 0;

    const order =
      sortKey === 'count' || sortKey === 'tracks'
        ? sql.raw(`count(*) ${desc ? 'desc' : 'asc'}, ${col} asc`)
        : sql.raw(`${col} ${desc ? 'desc' : 'asc'}`);

    const rows = await sql<{ name: string; tracks: number; first_file_path: string | null }>`
      select ${sql.ref(col)} as name,
             count(*) as tracks,
             min(rel_path) as first_file_path
        from music_tracks
       where ${where}
       group by ${sql.ref(col)}
       order by ${order}
       limit ${pageSize} offset ${offset}
    `.execute(k.db);

    return {
      items: rows.rows
        .map((r) => ({
          key_type: col,
          name: r.name ?? '',
          first_file_path: r.first_file_path ?? '',
          index_count: Number(r.tracks) || 0,
        }))
        .filter((r) => r.name !== ''),
      pagination: paginationOf(total, page, pageSize),
      validPaths: [] as string[],
    };
  };

  app.post('/api/v1/music/compat/album/list', hidden('music:read'), async (req: FastifyRequest) =>
    aggregate('album', (req.body || {}) as Record<string, unknown>),
  );

  app.post('/api/v1/music/compat/artist/list', hidden('music:read'), async (req: FastifyRequest) =>
    aggregate('artist', (req.body || {}) as Record<string, unknown>),
  );

  // ============================================================ 专辑 / 歌手详情
  //
  // 三级页面（专辑详情 / 歌手详情）的**头部数据**。曲目列表本身仍走 `/compat/list`
  // （复用已有的分页、多选、右键菜单、播放续页），这里只回元信息 + Last.fm 热度。
  // 一个接口塞两套分页语义只会让两边都别扭。

  app.post(
    '/api/v1/music/compat/album/detail',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const name = String(body.name ?? '').trim();
      const artistFilter = String(body.artist ?? '').trim();
      if (!name) return { key_type: 'album', name: '', found: false };
      const where = artistFilter
        ? sql`t.album = ${name} and (t.artist = ${artistFilter} or t.album_artist = ${artistFilter})`
        : sql`t.album = ${name}`;

      const agg = await sql<{
        tracks: number;
        total_duration: number | null;
        year: number | null;
        genre: string | null;
        artist: string | null;
        album_artist: string | null;
        cover_path: string | null;
        first_index_id: number | null;
      }>`
        select count(*) as tracks,
               sum(coalesce(t.duration, 0)) as total_duration,
               min(nullif(coalesce(t.year, 0), 0)) as year,
               min(nullif(t.genre, '')) as genre,
               min(nullif(t.artist, '')) as artist,
               min(nullif(t.album_artist, '')) as album_artist,
               min(case when t.has_cover = 1 then t.rel_path end) as cover_path,
               min(t.rowid) as first_index_id
          from music_tracks t
         where ${where}
      `.execute(k.db);
      const row = agg.rows[0];
      const tracks = Number(row?.tracks ?? 0);
      if (tracks === 0) return { key_type: 'album', name, found: false };

      // 封面优先取「有内嵌封面」的那首；没有就退回第一首（客户端会走默认封面）
      const anyPath = await sql<{ rel_path: string }>`
        select t.rel_path from music_tracks t where ${where}
         order by t.has_cover desc, t.track_no asc, t.title asc limit 1
      `.execute(k.db);

      const albumArtist = String(row?.album_artist || row?.artist || artistFilter || '');
      const crowd = await albumCrowd(k, albumArtist, name);
      return {
        key_type: 'album',
        name,
        found: true,
        artist: albumArtist,
        cover_path: String(row?.cover_path || anyPath.rows[0]?.rel_path || ''),
        track_count: tracks,
        total_duration: Math.round(Number(row?.total_duration ?? 0) / 1000),
        year: row?.year == null ? '' : String(row.year),
        genre: String(row?.genre ?? ''),
        first_index_id: Number(row?.first_index_id ?? 0) || 0,
        crowd,
      };
    },
  );

  app.post(
    '/api/v1/music/compat/artist/detail',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const name = String(body.name ?? '').trim();
      if (!name) return { key_type: 'artist', name: '', found: false };

      const agg = await sql<{
        tracks: number;
        total_duration: number | null;
        genre: string | null;
        cover_path: string | null;
      }>`
        select count(*) as tracks,
               sum(coalesce(t.duration, 0)) as total_duration,
               min(nullif(t.genre, '')) as genre,
               min(case when t.has_cover = 1 then t.rel_path end) as cover_path
          from music_tracks t
         where t.artist = ${name} or t.album_artist = ${name}
      `.execute(k.db);
      const row = agg.rows[0];
      const tracks = Number(row?.tracks ?? 0);
      if (tracks === 0) return { key_type: 'artist', name, found: false };

      const anyPath = await sql<{ rel_path: string }>`
        select t.rel_path from music_tracks t
         where t.artist = ${name} or t.album_artist = ${name}
         order by t.has_cover desc, t.year desc, t.title asc limit 1
      `.execute(k.db);

      // 收录专辑：按专辑聚合，年份倒序（新专辑在前），最多 200 张
      const albums = await sql<{
        name: string;
        tracks: number;
        year: number | null;
        cover_path: string | null;
        first_path: string | null;
      }>`
        select t.album as name,
               count(*) as tracks,
               min(nullif(coalesce(t.year, 0), 0)) as year,
               min(case when t.has_cover = 1 then t.rel_path end) as cover_path,
               min(t.rel_path) as first_path
          from music_tracks t
         where (t.artist = ${name} or t.album_artist = ${name})
           and t.album is not null and t.album != ''
         group by t.album
         order by year desc, name asc
         limit 200
      `.execute(k.db);

      const crowd = await artistCrowd(k, name);
      return {
        key_type: 'artist',
        name,
        found: true,
        cover_path: String(row?.cover_path || anyPath.rows[0]?.rel_path || ''),
        track_count: tracks,
        album_count: albums.rows.length,
        total_duration: Math.round(Number(row?.total_duration ?? 0) / 1000),
        genre: String(row?.genre ?? ''),
        albums: albums.rows.map((r) => ({
          name: String(r.name ?? ''),
          cover_path: String(r.cover_path || r.first_path || ''),
          year: r.year == null ? '' : String(r.year),
          index_count: Number(r.tracks ?? 0) || 0,
        })),
        crowd,
      };
    },
  );

  // ============================================================ Last.fm 配置
  //
  // 只读公开数据不需要用户登录，但**开发者**要一个 API Key。Key 存在服务端
  // （不落到客户端、不进 APK），客户端只看到「已配置 / 未配置」和打码后的串。

  const maskKey = (key: string) =>
    key.length <= 8 ? '*'.repeat(key.length) : `${key.slice(0, 4)}****${key.slice(-4)}`;

  app.get('/api/v1/music/compat/lastfm/config', hidden('music:read'), async (req) => {
    const { apiKey, secret } = await lastfmCreds(k);
    const account = await lastfmAccountOf(k, owner(req));
    return {
      configured: apiKey !== '',
      api_key_masked: apiKey ? maskKey(apiKey) : '',
      // Secret 永远不回原文，只告诉客户端「填没填」—— 签名只在服务端做。
      secret_configured: secret !== '',
      linked: account != null,
      username: account?.userName ?? '',
      // 客户端设置页据此提示「热度排序会退化为本地播放量」
      cache_ttl_artist: 7 * 24 * 3600,
      cache_ttl_album: 24 * 3600,
    };
  });

  app.post('/api/v1/music/compat/lastfm/config', hidden('music:write'), async (req) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const key = String(body.api_key ?? body.apiKey ?? '').trim();
    const secret = String(body.api_secret ?? body.apiSecret ?? '').trim();
    if ('api_key' in body || 'apiKey' in body) {
      await writeMusicSetting(k, SETTING_LASTFM_KEY, key);
    }
    if ('api_secret' in body || 'apiSecret' in body) {
      await writeMusicSetting(k, SETTING_LASTFM_SECRET, secret);
    }
    const creds = await lastfmCreds(k);
    const account = await lastfmAccountOf(k, owner(req));
    return {
      configured: creds.apiKey !== '',
      api_key_masked: creds.apiKey ? maskKey(creds.apiKey) : '',
      secret_configured: creds.secret !== '',
      linked: account != null,
      username: account?.userName ?? '',
    };
  });

  app.post('/api/v1/music/compat/lastfm/test', hidden('music:read'), async () => {
    const creds = await lastfmCreds(k);
    if (!creds.apiKey) return { ok: false, reason: 'no_key', message: '还没有填写 API Key' };
    // 用一个固定的、几乎不可能查不到的歌手做探针，比新加一个 lastfm.ping 稳
    const probe = await artistTopTracks(k, 'Coldplay', 3);
    if (probe.error) return { ok: false, reason: 'upstream', message: probe.error };
    return { ok: probe.items.length > 0, samples: probe.items.map((t) => t.name) };
  });

  app.post('/api/v1/music/compat/lastfm/cache/clear', hidden('music:write'), async () => {
    const removed = await clearLastfmCache(k);
    return { ok: true, removed };
  });

  // ------------------------------------------------------------ 账号绑定
  //
  // Last.fm 的授权不是 OAuth 2.0：先 auth.getToken 拿临时 token，浏览器去
  // `last.fm/api/auth` 点同意，它再带着 token 重定向回**我们自己注册的回调地址**。
  // 回调是浏览器直接打开的，**没有 JWT**，所以它不能走 secured —— 用临时 token
  // 反查是哪个用户发起的（token 是我们生成的随机串，且只在绑定期间有效）。

  app.post('/api/v1/music/compat/lastfm/link/start', hidden('music:read'), async (req) => {
    const start = await lastfmAuthStart(k);
    if (!start.ok || !start.token || !start.url) {
      return { ok: false, error: start.error ?? 'auth_failed' };
    }
    await savePendingToken(k, start.token, owner(req));
    // 回调地址与 Last.fm 后台注册的保持一致（用户填的就是这条）
    return { ok: true, url: start.url, token: start.token };
  });

  // 公开路由（浏览器重定向进来，没有 JWT），但同样不进契约：
  // 它不是给客户端调的 API，是 Last.fm 的回调入口。
  app.get(
    '/api/v1/music/compat/lastfm/link/callback',
    { schema: { hide: true, tags: TAGS } },
    async (req, reply) => {
    const query = (req.query || {}) as { token?: string; format?: string };
    const token = String(query.token ?? '').trim();
    const wantsJson = String(query.format ?? '').toLowerCase() === 'json';

    const done = async (ok: boolean, message: string, userName = '') => {
      if (wantsJson) return { ok, message, username: userName };
      reply.type('text/html; charset=utf-8');
      return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>Last.fm 绑定${ok ? '成功' : '失败'}</title>
<style>body{font-family:-apple-system,"Segoe UI",sans-serif;display:flex;min-height:100vh;
align-items:center;justify-content:center;margin:0;background:#f6f7f9;color:#1b1b1f}
.card{background:#fff;padding:36px 44px;border-radius:16px;box-shadow:0 8px 30px rgba(0,0,0,.08);
text-align:center;max-width:520px}h2{margin:0 0 12px;font-size:20px}
p{margin:0;color:#5b5b66;line-height:1.7}</style></head><body><div class="card">
<h2>${ok ? '✅ Last.fm 已绑定' : '⚠️ 绑定失败'}</h2>
<p>${message}</p><p style="margin-top:14px">可以关闭这个页面，回到 ColaNasOs。</p>
</div></body></html>`;
    };

    if (!token) return done(false, '回调缺少 token 参数。');
    const ownerId = await takePendingToken(k, token);
    if (!ownerId) return done(false, '这个授权链接已失效，请回到设置页重新点「绑定」。');

    const session = await lastfmAuthSession(k, token);
    if (!session.ok || !session.sessionKey) {
      return done(false, `换取 session 失败：${session.error ?? 'unknown'}`);
    }
    await saveLastfmAccount(k, ownerId, session.sessionKey, session.userName ?? '');
    k.log.info({ ownerId, username: session.userName }, 'music.lastfm.linked');
    return done(
      true,
      `绑定账号：${session.userName ?? '(未知)'}。以后听歌会自动同步播放记录。`,
      session.userName ?? '',
    );
  });

  /**
   * 兜底完成绑定：不依赖浏览器回调。
   *
   * 为什么要它：Last.fm 的授权页在**没有配 Callback URL**（或填的地址浏览器访问不到，
   * 比如填了 127.0.0.1 但你是从别的机器开的页面）时，只会显示
   * 「You can now close your browser」而**不跳回**我们的回调路由。此时 token 仍然有效，
   * 让 App 直接拿它换 session 即可 —— 否则用户看到的就是「授权成功了但点刷新没反应」。
   */
  app.post('/api/v1/music/compat/lastfm/link/complete', hidden('music:write'), async (req) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const token = String(body.token ?? '').trim();
    if (!token) return { ok: false, reason: 'no_token' };
    const me = owner(req);
    // pending 里记的必须是当前用户，防止别人把 token 拿来绑到自己名下
    const pendingOwner = await peekPendingToken(k, token);
    if (!pendingOwner) return { ok: false, reason: 'token_expired' };
    if (pendingOwner !== me) return { ok: false, reason: 'token_mismatch' };

    const session = await lastfmAuthSession(k, token);
    if (!session.ok || !session.sessionKey) {
      return { ok: false, reason: session.error ?? 'auth_failed' };
    }
    await saveLastfmAccount(k, me, session.sessionKey, session.userName ?? '');
    await takePendingToken(k, token);
    k.log.info({ ownerId: me, username: session.userName }, 'music.lastfm.linked.via-complete');
    return { ok: true, username: session.userName ?? '' };
  });

  /**
   * 恢复绑定：服务端还留着「已授权但没换成 session」的 pending token 时直接补完成。
   *
   * 为什么需要：`link/start` 拿到的 token 只存在**客户端内存**里，页面一刷新
   * （换网络、换域名、App 重启）就没了，于是「我明明在 Last.fm 点过授权，回来还是未绑定」。
   * 服务端 pending 表还在，按最新优先逐个试 `auth.getSession`，能换到就落库。
   */
  app.post('/api/v1/music/compat/lastfm/link/resume', hidden('music:write'), async (req) => {
    const me = owner(req);
    const existing = await lastfmAccountOf(k, me);
    if (existing) return { ok: true, linked: true, username: existing.userName ?? '' };

    const rows = (
      await sql<{ key: string }>`
        select key from music_settings
         where key like 'lastfm.pending.%' and value = ${me}
         order by updated_at desc limit 5
      `.execute(k.db)
    ).rows;
    let lastError = '';
    for (const row of rows) {
      const token = row.key.slice('lastfm.pending.'.length);
      const session = await lastfmAuthSession(k, token);
      if (!session.ok || !session.sessionKey) {
        lastError = session.error ?? '';
        // 「has not been issued」= 这个 token 在 Last.fm 侧已经作废
        // （同一 App 重新 getToken 会把上一个顶掉，用户连点两次绑定就会这样）。
        // 留着它只会让每次刷新都白试一遍，直接清掉。
        if (/has not been issued|invalid token/i.test(lastError)) {
          await takePendingToken(k, token);
        }
        continue;
      }
      await saveLastfmAccount(k, me, session.sessionKey, session.userName ?? '');
      await takePendingToken(k, token);
      k.log.info({ ownerId: me, username: session.userName }, 'music.lastfm.linked.via-resume');
      return { ok: true, linked: true, username: session.userName ?? '' };
    }
    // detail 给排查用：Last.fm 的原话（"Unauthorized Token - ..." 之类）
    return {
      ok: false,
      linked: false,
      reason: rows.length === 0 ? 'no_pending' : 'not_authorized',
      detail: lastError || undefined,
    };
  });

  app.post('/api/v1/music/compat/lastfm/link/unlink', hidden('music:write'), async (req) => {
    await unlinkLastfmAccount(k, owner(req));
    return { ok: true, linked: false };
  });

  app.get('/api/v1/music/compat/lastfm/link/status', hidden('music:read'), async (req) => {
    const account = await lastfmAccountOf(k, owner(req));
    return { linked: account != null, username: account?.userName ?? '' };
  });

  /** 客户端在「播放满 30s 且过半」时调用；阈值判断在客户端，这里只签名转发 */
  app.post('/api/v1/music/compat/lastfm/scrobble', hidden('music:write'), async (req) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const account = await lastfmAccountOf(k, owner(req));
    if (!account) return { ok: false, reason: 'not_linked' };
    const artist = String(body.artist ?? '').trim();
    const track = String(body.track ?? '').trim();
    if (!artist || !track) return { ok: false, reason: 'bad_params' };
    const ts = Number(body.timestamp ?? 0) || Math.floor(Date.now() / 1000);
    const result = await lastfmScrobble(k, account.sessionKey, {
      artist,
      track,
      album: String(body.album ?? '').trim() || undefined,
      timestamp: ts,
      durationSec: Number(body.duration ?? 0) || undefined,
    });
    if (!result.ok) k.log.warn({ error: result.error }, 'music.lastfm.scrobble failed');
    return result;
  });

  app.post('/api/v1/music/compat/lastfm/now-playing', hidden('music:write'), async (req) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const account = await lastfmAccountOf(k, owner(req));
    if (!account) return { ok: false, reason: 'not_linked' };
    const artist = String(body.artist ?? '').trim();
    const track = String(body.track ?? '').trim();
    if (!artist || !track) return { ok: false, reason: 'bad_params' };
    const ok = await lastfmNowPlaying(k, account.sessionKey, {
      artist,
      track,
      album: String(body.album ?? '').trim() || undefined,
      durationSec: Number(body.duration ?? 0) || undefined,
    });
    return { ok };
  });

  // ============================================================ 歌单

  app.post(
    '/api/v1/music/compat/playlist/list',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const page = Math.max(1, toInt(body.page, 1));
      const pageSize = Math.min(200, Math.max(1, toInt(body.page_size ?? body.pageSize, 30)));
      const offset = (page - 1) * pageSize;
      const search = String(body.search ?? '').trim();

      let where = sql`owner_id = ${owner(req)}`;
      if (search) {
        const sw = musicSearchWhere(['name'], search);
        if (sw) where = sql`${where} and ${sw}`;
      }

      const totalRes = await sql<{ n: number }>`
        select count(*) as n from music_playlists where ${where}
      `.execute(k.db);
      const total = Number(totalRes.rows[0]?.n) || 0;

      const rows = await sql<{
        index_id: number;
        id: string;
        name: string;
        created_at: number;
      }>`
        select rowid as index_id, id, name, created_at
          from music_playlists
         where ${where}
         order by created_at desc, name asc
         limit ${pageSize} offset ${offset}
      `.execute(k.db);

      const items = [];
      for (const r of rows.rows) {
        const trackIds = await sql<{ track_id: string }>`
          select track_id from music_playlist_items
           where playlist_id = ${r.id} order by position limit 8
        `.execute(k.db);
        items.push({
          id: Number(r.index_id),
          uid: 0,
          name: r.name,
          create_time: Number(r.created_at ?? 0),
          previews: await previewsOfTracks(trackIds.rows.map((x) => x.track_id)),
        });
      }
      return { items, pagination: paginationOf(total, page, pageSize) };
    },
  );

  app.post(
    '/api/v1/music/compat/playlist/create',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const name = String(body.name ?? '').trim();
      if (!name) return { id: 0, uid: 0, name: '', create_time: 0, previews: [] };
      const id = `pl_${nowSec()}_${Math.random().toString(36).slice(2, 8)}`;
      const now = nowSec();
      await sql`
        insert into music_playlists (id, name, owner_id, created_at, updated_at)
        values (${id}, ${name}, ${owner(req)}, ${now}, ${now})
      `.execute(k.db);
      const row = await sql<{ index_id: number }>`
        select rowid as index_id from music_playlists where id = ${id}
      `.execute(k.db);
      return {
        id: Number(row.rows[0]?.index_id ?? 0),
        uid: 0,
        name,
        create_time: now,
        previews: [],
      };
    },
  );

  app.post(
    '/api/v1/music/compat/playlist/update',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const name = String(body.name ?? '').trim();
      const hit = await sql<{ id: string; name: string; created_at: number }>`
        select id, name, created_at from music_playlists
         where rowid = ${indexId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { id: 0, uid: 0, name: '', create_time: 0, previews: [] };
      if (name) {
        await sql`
          update music_playlists set name = ${name}, updated_at = ${nowSec()}
           where id = ${row.id}
        `.execute(k.db);
      }
      return {
        id: indexId,
        uid: 0,
        name: name || row.name,
        create_time: Number(row.created_at ?? 0),
        previews: [],
      };
    },
  );

  app.post(
    '/api/v1/music/compat/playlist/delete',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const hit = await sql<{ id: string }>`
        select id from music_playlists where rowid = ${indexId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { ok: true };
      await sql`delete from music_playlist_items where playlist_id = ${row.id}`.execute(k.db);
      await sql`delete from music_playlists where id = ${row.id}`.execute(k.db);
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/music/compat/playlist/index/add',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const listId = toInt(body.list_id ?? body.listId, 0);
      const indexIds = asStringArray(body.index_ids).map((x) => toInt(x, 0));
      const hit = await sql<{ id: string }>`
        select id from music_playlists where rowid = ${listId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const playlist = hit.rows[0];
      if (!playlist) return { ok: false, added: 0 };
      const map = await idsOfIndex(indexIds);
      const uuids = [...new Set(map.values())];
      const maxRow = await sql<{ m: number | null }>`
        select max(position) as m from music_playlist_items where playlist_id = ${playlist.id}
      `.execute(k.db);
      const startPos = Number(maxRow.rows[0]?.m ?? -1) + 1;
      let added = 0;
      if (uuids.length > 0) {
        // 先一次查已存在，再只插真正新增的 —— 顺带把 `added` 从「尝试次数」修正成「实际新增」。
        // 原实现逐首 insert（500 次往返），且 `added` 恒等于尝试数。
        const have = await sql<{ track_id: string }>`
          select track_id from music_playlist_items
           where playlist_id = ${playlist.id}
             and track_id in (${sql.join(
               uuids.map((u) => sql`${u}`),
               sql`, `,
             )})
        `.execute(k.db);
        const haveSet = new Set(have.rows.map((r) => String(r.track_id)));
        const fresh = uuids.filter((u) => !haveSet.has(u));
        for (let i = 0; i < fresh.length; i += 200) {
          const values = fresh
            .slice(i, i + 200)
            .map((u, j) => sql`(${playlist.id}, ${u}, ${startPos + i + j}, ${nowSec()})`);
          await sql`
            insert into music_playlist_items (playlist_id, track_id, position, added_at)
            values ${sql.join(values, sql`, `)}
            on conflict(playlist_id, track_id) do nothing
          `.execute(k.db);
        }
        added = fresh.length;
      }
      await sql`update music_playlists set updated_at = ${nowSec()} where id = ${playlist.id}`.execute(
        k.db,
      );
      return { ok: true, added };
    },
  );

  app.post(
    '/api/v1/music/compat/playlist/index/remove',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const listId = toInt(body.list_id ?? body.listId, 0);
      const indexIds = asStringArray(body.index_ids).map((x) => toInt(x, 0));
      const hit = await sql<{ id: string }>`
        select id from music_playlists where rowid = ${listId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const playlist = hit.rows[0];
      if (!playlist) return { ok: false, removed: 0 };
      const map = await idsOfIndex(indexIds);
      const uuids = [...new Set(map.values())];
      let removed = 0;
      // 一条 `in (...)` 删完（原来是逐首 delete，500 首 = 500 次独立隐式提交）
      for (let i = 0; i < uuids.length; i += 200) {
        const slice = uuids.slice(i, i + 200);
        const res: any = await sql`
          delete from music_playlist_items
           where playlist_id = ${playlist.id}
             and track_id in (${sql.join(
               slice.map((u) => sql`${u}`),
               sql`, `,
             )})
        `.execute(k.db);
        removed += Number(res.numAffectedRows || 0);
      }
      return { ok: true, removed };
    },
  );

  // ============================================================ 合集

  const collectionItems = async (req: FastifyRequest, limit: number, offset: number, search: string) => {
    let where = sql`owner_id = ${owner(req)}`;
    if (search) {
      const sw = musicSearchWhere(['name'], search);
      if (sw) where = sql`${where} and ${sw}`;
    }

    const totalRes = await sql<{ n: number }>`
      select count(*) as n from music_collections where ${where}
    `.execute(k.db);
    const total = Number(totalRes.rows[0]?.n) || 0;

    const rows = await sql<{
      index_id: number;
      id: string;
      name: string;
      paths: string;
      created_at: number;
    }>`
      select rowid as index_id, id, name, paths, created_at
        from music_collections
       where ${where}
       order by created_at desc
       limit ${limit} offset ${offset}
    `.execute(k.db);

    const items = [];
    for (const r of rows.rows) {
      let paths: string[] = [];
      try {
        const v = JSON.parse(r.paths || '[]');
        if (Array.isArray(v)) paths = v.map((x) => String(x));
      } catch {
        paths = [];
      }
      let previews: unknown[] = [];
      if (paths.length > 0) {
        const cond = anyLike('rel_path', paths.map(likeOf));
        const tracks = await sql<{ id: string }>`
          select id from music_tracks where (${cond}) order by has_cover desc limit 8
        `.execute(k.db);
        previews = await previewsOfTracks(tracks.rows.map((x) => x.id));
      }
      items.push({
        id: Number(r.index_id),
        uid: 0,
        name: r.name,
        path_list: paths,
        create_time: Number(r.created_at ?? 0),
        previews,
      });
    }
    return { items, total };
  };

  app.post(
    '/api/v1/music/compat/collection/list',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const page = Math.max(1, toInt(body.page, 1));
      const pageSize = Math.min(200, Math.max(1, toInt(body.pageSize ?? body.page_size, 20)));
      const search = String(body.keyword ?? body.search ?? '').trim();
      const data = await collectionItems(req, pageSize, (page - 1) * pageSize, search);
      return {
        items: data.items,
        pagination: paginationOf(data.total, page, pageSize),
        total: data.total,
        page,
        pageSize,
      };
    },
  );

  app.post(
    '/api/v1/music/compat/collection/get',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const rows = await sql<{ index_id: number; name: string; paths: string; created_at: number }>`
        select rowid as index_id, name, paths, created_at from music_collections
         where rowid = ${indexId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const r = rows.rows[0];
      if (!r) return { id: 0, uid: 0, name: '', path_list: [], create_time: 0, previews: [] };
      let paths: string[] = [];
      try {
        const v = JSON.parse(r.paths || '[]');
        if (Array.isArray(v)) paths = v.map((x) => String(x));
      } catch {
        paths = [];
      }
      let previews: unknown[] = [];
      if (paths.length > 0) {
        const cond = anyLike('rel_path', paths.map(likeOf));
        const tracks = await sql<{ id: string }>`
          select id from music_tracks where (${cond}) order by has_cover desc limit 8
        `.execute(k.db);
        previews = await previewsOfTracks(tracks.rows.map((x) => x.id));
      }
      return {
        id: Number(r.index_id),
        uid: 0,
        name: r.name,
        path_list: paths,
        create_time: Number(r.created_at ?? 0),
        previews,
      };
    },
  );

  app.post(
    '/api/v1/music/compat/collection/create',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const name = String(body.name ?? '').trim();
      const paths = asStringArray(body.path_list ?? body.pathList);
      if (!name) return { id: 0 };
      const id = `col_${nowSec()}_${Math.random().toString(36).slice(2, 8)}`;
      const now = nowSec();
      await sql`
        insert into music_collections (id, owner_id, name, paths, created_at, updated_at)
        values (${id}, ${owner(req)}, ${name}, ${JSON.stringify(paths)}, ${now}, ${now})
      `.execute(k.db);
      const row = await sql<{ index_id: number }>`
        select rowid as index_id from music_collections where id = ${id}
      `.execute(k.db);
      return { id: Number(row.rows[0]?.index_id ?? 0) };
    },
  );

  app.post(
    '/api/v1/music/compat/collection/update',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const name = String(body.name ?? '').trim();
      const paths = asStringArray(body.path_list ?? body.pathList);
      const hit = await sql<{ id: string }>`
        select id from music_collections where rowid = ${indexId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { ok: false };
      if (name) {
        await sql`
          update music_collections
             set name = ${name}, paths = ${JSON.stringify(paths)}, updated_at = ${nowSec()}
           where id = ${row.id}
        `.execute(k.db);
      }
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/music/compat/collection/delete',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const hit = await sql<{ id: string }>`
        select id from music_collections where rowid = ${indexId} and owner_id = ${owner(req)}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { affected: 0 };
      await sql`delete from music_collections where id = ${row.id}`.execute(k.db);
      return { affected: 1 };
    },
  );

  // ============================================================ 收藏 / 历史

  app.post(
    '/api/v1/music/compat/favorite/batch',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexIds = asStringArray(body.index_ids).map((x) => toInt(x, 0));
      const favorite = body.is_favorite === true || toInt(body.is_favorite, 0) === 1;
      const map = await idsOfIndex(indexIds);
      const me = owner(req);
      for (const uuid of map.values()) {
        if (favorite) {
          await sql`
            insert into music_favorites (item_id, owner_id, created_at)
            values (${uuid}, ${me}, ${nowSec()})
            on conflict(owner_id, item_id) do nothing
          `.execute(k.db);
        } else {
          await sql`
            delete from music_favorites where item_id = ${uuid} and owner_id = ${me}
          `.execute(k.db);
        }
      }
      return { ok: true, affected: map.size };
    },
  );

  app.post(
    '/api/v1/music/compat/history/refresh',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.index_id ?? body.indexId, 0);
      const filePath = normSlashes(String(body.file_path ?? body.filePath ?? '').trim());
      let uuid: string | null = null;
      if (indexId > 0) {
        const map = await idsOfIndex([indexId]);
        uuid = map.get(indexId) ?? null;
      } else if (filePath) {
        const row = await findTrackRow(filePath);
        uuid = row?.id ?? null;
      }
      if (!uuid) return { ok: false };
      await sql`
        insert into music_plays (id, item_id, owner_id, played_at)
        values (${`ph_${nowSec()}_${Math.random().toString(36).slice(2, 8)}`}, ${uuid}, ${owner(req)}, ${nowSec()})
      `.execute(k.db);
      return { ok: true };
    },
  );

  // ============================================================ 歌词

  app.post(
    '/api/v1/music/compat/lyric/search',
    hidden('music:read'),
    async (req: FastifyRequest) => {
      // 搬运壳本来就带整套「自动搜词 → 严格匹配 → 写旁挂 .lrc」链路，
      // 以前这里写死返回 []，整条链从来没通过电。接上公开免 key 的 LRCLIB，
      // 只在本地没歌词时由客户端触发；源不可用就退化成空列表，不报错。
      const body = (req.body || {}) as Record<string, unknown>;
      const keyword = String(body.keyword ?? body.q ?? '').trim();
      if (!keyword) return [] as unknown[];
      return searchLyrics(keyword) as unknown as unknown[];
    },
  );

  app.post(
    '/api/v1/music/compat/lyric/set',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const musicPath = normSlashes(String(body.music_path ?? body.musicPath ?? '').trim());
      const lrc = String(body.lrc ?? '');
      if (!musicPath || !lrc.trim()) return { ok: false };
      const row = await findTrackRow(musicPath);
      // rel_path 是**相对 files 根**（扫描时拼成 `${root_path}/${rel}`）；
      // root_path 本身是绝对路径时 rel_path 也就是绝对路径 —— 两种都要能吃下。
      const relPath = normSlashes(row?.rel_path ?? musicPath);
      const dirRel = path.dirname(relPath);
      let targetDir: string;
      try {
        if (isAbsoluteInput(dirRel)) targetDir = absoluteInput(dirRel);
        else targetDir = resolveInRoot(filesRoot(), dirRel === '.' ? '' : dirRel);
      } catch {
        return { ok: false };
      }
      const stem = path.basename(relPath, path.extname(relPath));
      const lrcPath = path.join(targetDir, `${stem}.lrc`);
      try {
        if (!fs.existsSync(targetDir)) return { ok: false };
        fs.writeFileSync(lrcPath, lrc, 'utf8');
        return { ok: true, path: lrcPath };
      } catch {
        return { ok: false };
      }
    },
  );

  // ============================================================ 来源（= 曲库目录）

  const sourceOf = (row: {
    index_id: number;
    root_path: string;
    created_at: number;
    last_scan_at: number | null;
    scan_when_start?: number | null;
    scan_when_change?: number | null;
    scan_interval_ms?: number | null;
  }) => {
    const abs = absOfRoot(row.root_path);
    let exists: boolean;
    try {
      exists = !!abs && fs.existsSync(abs);
    } catch {
      exists = false;
    }
    // 三个开关以前是硬编码常量（1 / 1 / 0），点了也不会落库 —— 现在读真列
    const intervalMs = Math.max(0, Math.trunc(Number(row.scan_interval_ms ?? 0) || 0));
    return {
      id: Number(row.index_id),
      path: row.root_path,
      exists,
      scan_when_start: Number(row.scan_when_start ?? 1) ? 1 : 0,
      scan_when_change: Number(row.scan_when_change ?? 1) ? 1 : 0,
      is_show: 1,
      show_type: 'music',
      ctime: Number(row.created_at ?? 0),
      scan_interval: intervalMs > 0 ? 1 : 0,
      scan_interval_ms: intervalMs,
      scan_interval_config: '{}',
      last_scan_time: Number(row.last_scan_at ?? 0),
    };
  };

  app.post('/api/v1/music/compat/source/list', hidden('music:read'), async () => {
    const rows = await sql<{
      index_id: number;
      root_path: string;
      created_at: number;
      last_scan_at: number | null;
      scan_when_start: number | null;
      scan_when_change: number | null;
      scan_interval_ms: number | null;
    }>`
      select rowid as index_id, root_path, created_at, last_scan_at,
             scan_when_start, scan_when_change, scan_interval_ms
        from music_libraries order by created_at, name limit 500
    `.execute(k.db);
    return rows.rows.map(sourceOf);
  });

  app.post('/api/v1/music/compat/source/add', hidden('music:write'), async (req: FastifyRequest) => {
    const body = (req.body || {}) as Record<string, unknown>;
    const raw = String(body.path ?? '').trim();
    if (!raw) return { ok: false, message: 'path required' };
    let rel: string;
    let abs: string;
    try {
      if (isAbsoluteInput(raw)) {
        abs = absoluteInput(raw);
        rel = abs;
      } else {
        abs = resolveInRoot(filesRoot(), raw);
        rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
      }
    } catch {
      return { ok: false, message: 'path escapes root' };
    }
    try {
      if (!fs.statSync(abs).isDirectory()) return { ok: false, message: 'not a directory' };
    } catch {
      return { ok: false, message: 'path not found' };
    }
    const existed = await sql<{ index_id: number }>`
      select rowid as index_id from music_libraries where root_path = ${rel}
    `.execute(k.db);
    if (existed.rows[0]) {
      return { ok: true, id: Number(existed.rows[0].index_id) };
    }
    const id = `ml_${nowSec()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = baseOf(rel) || rel;
    await sql`
      insert into music_libraries (id, name, root_path, created_at, last_scan_at, items)
      values (${id}, ${name}, ${rel}, ${nowSec()}, null, 0)
    `.execute(k.db);
    const row = await sql<{ index_id: number }>`
      select rowid as index_id from music_libraries where id = ${id}
    `.execute(k.db);
    return { ok: true, id: Number(row.rows[0]?.index_id ?? 0) };
  });

  app.post(
    '/api/v1/music/compat/source/update',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const hit = await sql<{ id: string }>`
        select id from music_libraries where rowid = ${indexId}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { ok: false, message: 'not found' };

      // 以前这里硬性要求 path 非空，而前端开关只发 scan_when_* —— 结果每次都
      // 返回 `path required`，开关弹回去还弹「操作失败」。现在 path 可选，
      // 开关逐字段落库。
      let touched = false;
      let watchTouched = false;
      const raw = String(body.path ?? '').trim();
      if (raw) {
        let rel = raw;
        try {
          if (!isAbsoluteInput(raw)) {
            const abs = resolveInRoot(filesRoot(), raw);
            rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
          }
        } catch {
          return { ok: false, message: 'path escapes root' };
        }
        await sql`update music_libraries set root_path = ${rel} where id = ${row.id}`.execute(k.db);
        touched = true;
        watchTouched = true;
      }

      const flag = (v: unknown): number | null => {
        if (v === undefined || v === null || v === '') return null;
        const n = Number(v);
        if (!Number.isFinite(n)) return null;
        return n ? 1 : 0;
      };
      const has = (key: string) => Object.prototype.hasOwnProperty.call(body, key);
      const startFlag = flag(body.scan_when_start ?? body.scanWhenStart);
      if (startFlag !== null) {
        await sql`update music_libraries set scan_when_start = ${startFlag} where id = ${row.id}`.execute(k.db);
        touched = true;
      }
      const changeFlag = flag(body.scan_when_change ?? body.scanWhenChange);
      if (changeFlag !== null) {
        await sql`update music_libraries set scan_when_change = ${changeFlag} where id = ${row.id}`.execute(k.db);
        touched = true;
        watchTouched = true;
      }
      // 间隔扫描：前端发的是小时数（scan_interval + scan_interval_ms），两者取其一
      const rawMs = Number(body.scan_interval_ms ?? body.scanIntervalMs ?? 0);
      const rawHours = Number(body.scan_interval_hours ?? body.scanIntervalHours ?? 0);
      const enabled = Number(body.scan_interval ?? body.scanInterval ?? 0) !== 0;
      if (Number.isFinite(rawMs) && rawMs > 0) {
        await sql`update music_libraries set scan_interval_ms = ${Math.trunc(rawMs)} where id = ${row.id}`.execute(k.db);
        touched = true;
        watchTouched = true;
      } else if (Number.isFinite(rawHours) && rawHours > 0) {
        const ms = Math.trunc(rawHours * 3600 * 1000);
        await sql`update music_libraries set scan_interval_ms = ${ms} where id = ${row.id}`.execute(k.db);
        touched = true;
        watchTouched = true;
      } else if (has('scan_interval') && !enabled) {
        await sql`update music_libraries set scan_interval_ms = 0 where id = ${row.id}`.execute(k.db);
        touched = true;
        watchTouched = true;
      }

      // show_type 只是客户端展示偏好，服务端没有对应列，视为已接受
      if (!touched && !has('show_type') && !has('showType')) {
        return { ok: false, message: 'nothing to update' };
      }
      // 策略变了要让文件监控重建订阅 / 重排间隔定时器，否则开关「改了不生效」
      if (watchTouched) void h.libWatch.refresh();
      // 回整行：前端拿到结果后会直接 `MusicSource.fromJson(data)` 覆盖本地那一条，
      // 只回 `{ok:true}` 会把列表项清空成 id=0 / path=''。
      const after = await sql<{
        index_id: number;
        root_path: string;
        created_at: number;
        last_scan_at: number | null;
        scan_when_start: number | null;
        scan_when_change: number | null;
        scan_interval_ms: number | null;
      }>`
        select rowid as index_id, root_path, created_at, last_scan_at,
               scan_when_start, scan_when_change, scan_interval_ms
          from music_libraries where id = ${row.id}
      `.execute(k.db);
      return { ok: true, ...(after.rows[0] ? sourceOf(after.rows[0]) : {}) };
    },
  );

  app.post(
    '/api/v1/music/compat/source/delete',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const hit = await sql<{ id: string }>`
        select id from music_libraries where rowid = ${indexId}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { ok: false, message: 'not found' };
      await sql`
        delete from music_playlist_items
         where track_id in (select id from music_tracks where library_id = ${row.id})
      `.execute(k.db);
      await sql`delete from music_tracks where library_id = ${row.id}`.execute(k.db);
      await sql`delete from music_libraries where id = ${row.id}`.execute(k.db);
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/music/compat/source/scan',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const raw = String(body.path ?? '').trim();
      let libs: Array<{ id: string }> = [];
      if (raw && raw !== 'all') {
        const hit = await sql<{ id: string }>`
          select id from music_libraries where root_path = ${raw} or root_path like ${'%' + raw}
           limit 1
        `.execute(k.db);
        if (hit.rows[0]) libs = [hit.rows[0]];
      } else {
        libs = (await sql<{ id: string }>`select id from music_libraries`.execute(k.db)).rows;
      }
      if (libs.length === 0) return { ok: false, message: 'source not found' };

      // 默认**入队**并立刻返回（进度与失败见 /tasks）。整库几万首要逐个 probe，
      // 同步跑必然撞客户端 30s 超时 —— 用户看到的就是「点了扫描、报失败、像没反应」，
      // 其实后台还在跑。脚本 / 冒烟需要同步结果时传 `sync: true`。
      if (body.sync === true) {
        const total = {
          libraries: libs.length,
          tracks: 0,
          added: 0,
          updated: 0,
          skipped: 0,
          probed: 0,
          missing: 0,
          pruned: 0,
        };
        try {
          for (const lib of libs) {
            const r = await runMusicScan(k, h, { libraryId: lib.id });
            total.tracks += r.tracks;
            total.added += r.added;
            total.updated += r.updated;
            total.skipped += r.skipped;
            total.probed += r.probed;
            total.missing += r.missing;
            total.pruned += r.pruned;
          }
          return { ok: true, ...total };
        } catch (e) {
          return { ok: false, message: String((e as Error)?.message ?? e) };
        }
      }

      const tasks: Array<{ libraryId: string; taskId: string; reused: boolean }> = [];
      for (const lib of libs) {
        const r = await k.tasks.enqueueIfIdle('music.scan', { libraryId: lib.id }, { maxAttempts: 1 });
        tasks.push({ libraryId: lib.id, taskId: r.id, reused: r.reused });
      }
      return { ok: true, queued: true, reused: tasks.every((t) => t.reused), tasks };
    },
  );

  app.post(
    '/api/v1/music/compat/source/relocate',
    hidden('music:write'),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as Record<string, unknown>;
      const indexId = toInt(body.id, 0);
      const newPath = String(body.new_path ?? body.newPath ?? '').trim();
      if (!newPath) return { ok: false, message: 'new_path required' };
      const hit = await sql<{ id: string }>`
        select id from music_libraries where rowid = ${indexId}
      `.execute(k.db);
      const row = hit.rows[0];
      if (!row) return { ok: false, message: 'not found' };
      let rel = newPath;
      try {
        if (!isAbsoluteInput(newPath)) {
          const abs = resolveInRoot(filesRoot(), newPath);
          rel = path.relative(filesRoot(), abs).split(path.sep).join('/');
        }
      } catch {
        return { ok: false, message: 'path escapes root' };
      }
      await sql`update music_libraries set root_path = ${rel} where id = ${row.id}`.execute(k.db);
      return { ok: true };
    },
  );

  // ---------------------------------------------------------------- 封面 / 播放（按路径）

  // 搬过来的音乐端**全程按文件路径**取封面和音频（`MusicListItem` 里虽然也有 int id，
  // 但音频地址和 `artUri` 都是用 `full_path` 拼的）。主模块那边是 `?id=<uuid>`，
  // 这里补两个按路径寻址的隐藏口，内部复用同一套缓存 / Range / 转码逻辑。

  /** 路径 → 曲目行 + 绝对路径 */
  const resolveTrackAbs = async (raw: string) => {
    const row = await findTrackRow(raw);
    if (!row) return null;
    try {
      return { row, abs: resolveAnyPath(filesRoot(), row.rel_path) };
    } catch {
      return null;
    }
  };

  app.get('/api/v1/music/compat/cover', hidden('music:read'), async (req: FastifyRequest, reply) => {
    const q = (req.query || {}) as { path?: string; size?: string };
    const hit = await resolveTrackAbs(String(q.path ?? ''));
    // 老库 has_cover 常常没回填，别用这个标记把「文件里其实有内嵌封面」挡掉：
    // 有文件就试着抽一次，抽不到再 404（结果按 path:mtime:size 缓存）。
    if (!hit || !fs.existsSync(hit.abs)) {
      return reply.code(404).send({ error: 'not_found', message: 'no cover' });
    }
    const size = Math.min(1000, Math.max(48, toInt(q.size, 320)));
    const hash = crypto
      .createHash('sha1')
      .update(`${hit.row.rel_path}:${hit.row.mtime}:${size}`)
      .digest('hex')
      .slice(0, 32);
    const out = path.join(k.paths.dataDir, 'covers', `${hash}.jpg`);
    // 哨兵带版本：接在线源之前写的空文件要作废旧，否则老库里那些
    // 「抽不到内嵌封面」的曲目永远没有机会走在线兜底。
    const noneFile = `${out}.none`;
    if (fs.existsSync(noneFile)) {
      let mark = '';
      try { mark = fs.readFileSync(noneFile, 'utf8'); } catch { /* 读不了就当旧的 */ }
      if (mark === COVER_NONE_MARK) {
        return reply.code(404).send({ error: 'not_found', message: 'cover unavailable' });
      }
      try { fs.rmSync(noneFile, { force: true }); } catch { /* 下次最多再试一次 */ }
    }
    if (!fs.existsSync(out)) {
      fs.mkdirSync(path.dirname(out), { recursive: true });
      let got = await writeCover(hit.abs, out, size);
      if (!got) {
        // 本地没有内嵌封面流 → 在线兜底。图片只落服务端缓存，不往音乐目录写。
        const looked = await findCoverUrl({
          title: hit.row.title,
          artist: hit.row.artist,
          album: hit.row.album,
          durationMs: hit.row.duration,
        });
        // iTunes 的 artwork 一律 jpg，正好对上 ${out}.jpg 与 image/jpeg
        const buf = looked.kind === 'ok' ? await downloadCover(looked.url) : null;
        if (buf) {
          fs.writeFileSync(out, buf);
          got = true;
        } else if (looked.kind === 'empty') {
          // 只有「明确查无此图」才写哨兵；网络抖动 / 源不可达 / 图片下载失败
          // 都不写，下次刷新还能自动重试，不会把曲目永久拉黑。
          try { fs.writeFileSync(noneFile, COVER_NONE_MARK); } catch { /* 忽略 */ }
        }
      }
      if (!got) {
        return reply.code(404).send({ error: 'not_found', message: 'cover unavailable' });
      }
    }
    reply.type('image/jpeg').header('cache-control', 'public, max-age=86400');
    return reply.send(fs.createReadStream(out));
  });

  app.get(
    '/api/v1/music/compat/stream',
    hidden('music:read'),
    async (req: FastifyRequest, reply) => {
      const q = (req.query || {}) as { path?: string; format?: string };
      const hit = await resolveTrackAbs(String(q.path ?? ''));
      if (!hit || !fs.existsSync(hit.abs)) {
        return reply.code(404).send({ error: 'not_found', message: 'track not found' });
      }
      if (q.format === 'transcoded') {
        const out = await ensureTranscoded(k, hit.abs, hit.row);
        if (!out) return reply.code(404).send({ error: 'not_found', message: 'transcode unavailable' });
        return downloadHandler(req, reply, { path: out });
      }
      return downloadHandler(req, reply, { path: hit.row.rel_path });
    },
  );
}
