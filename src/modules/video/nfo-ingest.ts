import path from 'node:path';
import {
  findLocalFanart,
  findLocalPoster,
  findNfoFile,
  parseNfo,
  resolveArtRef,
  type NfoMeta,
} from './nfo';
import fsp from 'node:fs/promises';

/**
 * 扫描期「吃进」一个视频文件的本地元数据：NFO + 同目录图片。
 *
 * 与 `scrape.ts` 的区别：这里**只读本地、不联网**，所以永远可以在扫描里跑；
 * 联网刮削是显式动作（用户点或任务队列），不进扫描主路径。
 * 这样「用户已经用 Kodi/Emby 刮好的库」扫描一遍就有完整信息，零网络请求。
 */
export interface NfoIngest {
  name: string | null;
  originalName: string | null;
  year: number | null;
  score: number | null;
  overview: string | null;
  runtime: number | null;
  releaseDate: string | null;
  studio: string | null;
  /** JSON 数组文本，写库直接用 */
  genres: string | null;
  regions: string | null;
  actors: string | null;
  directors: string | null;
  poster: string | null;
  fanart: string | null;
  thumb: string | null;
  imdbId: string | null;
  doubanId: string | null;
  tmdbId: number | null;
  /** `nfo` = 读到了；`none` = 检查过但没有（用于增量扫描的「已检查」标记） */
  source: 'nfo' | 'none';
  /**
   * nfo 文件的 mtime（毫秒）；0 = 没找到文件。
   * 用来判断「用户是否在我们上次写入之后手改过这个文件」——冲突合并的唯一判据。
   */
  mtimeMs: number;
}

const EMPTY: NfoIngest = {  mtimeMs: 0,
  name: null,
  originalName: null,
  year: null,
  score: null,
  overview: null,
  runtime: null,
  releaseDate: null,
  studio: null,
  genres: null,
  regions: null,
  actors: null,
  directors: null,
  poster: null,
  fanart: null,
  thumb: null,
  imdbId: null,
  doubanId: null,
  tmdbId: null,
  source: 'none',
};

function jsonOf(values: readonly string[] | undefined): string | null {
  const list = (values ?? []).map((v) => String(v ?? '').trim()).filter(Boolean);
  return list.length > 0 ? JSON.stringify(list) : null;
}

function numOrNull(v: number | undefined): number | null {
  return v != null && Number.isFinite(v) ? Number(v) : null;
}

function textOrNull(v: string | undefined): string | null {
  const text = String(v ?? '').trim();
  return text ? text : null;
}

/**
 * nfo 声明的本地图片要**真的存在**才收下。
 * 只写路径不校验的后果：客户端拿到一条 404 的图，海报位显示裂图，
 * 而且下次扫描还被 `nfo_source` 挡着不会重试。
 */
async function usableArt(value: string | null): Promise<string | null> {
  const text = String(value ?? '').trim();
  if (!text) return null;
  if (/^https?:\/\//i.test(text)) return text;
  try {
    await fsp.access(text);
    return text;
  } catch {
    return null;
  }
}

/**
 * 同目录现在是否有可吃的本地元数据（nfo 或海报）。
 *
 * 增量扫描用它判断「文件没变，但用户事后补了 nfo / 图」，
 * 只有真的发现了才把这条拉去补读，避免全库每次重扫白跑一遍。
 */
export async function hasLocalMeta(absPath: string): Promise<boolean> {
  try {
    if (await findNfoFile(absPath)) return true;
    if (await findLocalPoster(absPath)) return true;
  } catch {
    /* 读不了就当没有 */
  }
  return false;
}

/**
 * 读一个视频文件的本地元数据。
 *
 * 图片解析优先级：NFO 声明的 → 同目录约定文件名。两者都没有就留空，
 * 由 `hasArt=false` 让客户端回退首帧。
 */
export async function ingestNfo(absPath: string): Promise<NfoIngest> {
  let meta: NfoMeta | null = null;
  let nfoDir: string | null = null;
  let mtimeMs = 0;
  try {
    const found = await findNfoFile(absPath);
    if (found) {
      nfoDir = path.dirname(found.file);
      const xml = await fsp.readFile(found.file, 'utf-8');
      meta = parseNfo(xml);
      // stat 失败不该挡住建库：mtime 拿不到就按 0 处理（等于"不是用户改的"）
      mtimeMs = await fsp.stat(found.file).then((st) => st.mtimeMs).catch(() => 0);
    }
  } catch {
    // 读不了 nfo 就按「没有」处理；不能因为一个坏文件挡住整库扫描
    meta = null;
  }

  let poster = await usableArt(nfoDir ? resolveArtRef(meta?.poster, nfoDir) : null);
  let fanart = await usableArt(nfoDir ? resolveArtRef(meta?.fanart, nfoDir) : null);
  let thumb = await usableArt(nfoDir ? resolveArtRef(meta?.thumb, nfoDir) : null);

  // 远端图不在这里下载（扫描不联网），只登记 URL；
  // 本地缺图时按约定文件名找一张现成的。
  if (!poster) poster = await findLocalPoster(absPath);
  if (!fanart) fanart = await findLocalFanart(absPath);
  if (!thumb) thumb = poster;

  if (!meta) {
    // 没有 nfo，但可能有图 —— 只回图，其余留空
    if (!poster && !fanart && !thumb) return EMPTY;
    return {
      ...EMPTY,
      poster,
      fanart,
      thumb,
      // 只有图不算「有 NFO 元数据」，但仍标记已检查
      source: 'none',
      mtimeMs,
    };
  }

  return {
    name: textOrNull(meta.title),
    originalName: textOrNull(meta.originalTitle),
    year: numOrNull(meta.year),
    score: numOrNull(meta.score),
    overview: textOrNull(meta.overview),
    runtime: numOrNull(meta.runtimeMin),
    releaseDate: textOrNull(meta.releaseDate),
    studio: textOrNull(meta.studio),
    genres: jsonOf(meta.genres),
    regions: jsonOf(meta.regions),
    actors: jsonOf(meta.actors),
    directors: jsonOf(meta.directors),
    poster,
    fanart,
    thumb,
    imdbId: textOrNull(meta.imdbId),
    doubanId: textOrNull(meta.doubanId),
    tmdbId: numOrNull(meta.tmdbId),
    source: 'nfo',
    mtimeMs,
  };
}
