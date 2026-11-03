import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { normalizeConfig, type TmdbConfig } from '../discover/tmdb';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { proxyFetch } from '../../../kernel/proxy-fetch';
import { titleOf } from './ffmpeg';
import { libTypeOf, type LibType } from './media-type';
import { scrapeJp } from './jp-scrape';
import { readSystemSettings } from '../../../kernel/system-settings';
import { parseActorNames, syncActorLinks } from './jp-links';
import { nfoPathFor, writeNfo, type NfoMeta } from './nfo';
import {
  detailTmdb,
  downloadTmdbImage,
  guessTitle,
  pickBestCandidate,
  searchTmdb,
  tmdbReady,
  type ScrapedMeta,
} from './tmdb';
import type { VideoItemRow } from './util';

/**
 * 刮削编排（本地 NFO 之外的「联网取元数据」）。
 *
 * 决策顺序（也是实际最省事的顺序）：
 *   日本库且有番号 → 番号源（javdb/javbus/avsox）→ 失败再回退 TMDB
 *   其它库         → TMDB
 *
 * 三条硬约束：
 *   ① **不猜就写**：匹配置信度不够（`pickBest` 得分 < 2）直接返回 notfound，
 *      宁可让用户手动选，也不要把别的片的简介写进来；
 *   ② **没网不崩**：任何网络失败都返回 `unavailable` + 原因，不抛错、不改库；
 *   ③ **不清空**：写库一律 `coalesce(新值, 原值)`，刮削失败不会让已有元数据变空。
 */
export type ScrapeStatus = 'scraped' | 'skipped' | 'notfound' | 'unavailable' | 'failed';

export interface ScrapeOutcome {
  status: ScrapeStatus;
  itemId: string;
  source?: string;
  title?: string;
  /** 写入后的字段数量，便于「到底刮到了什么」的排查 */
  fields?: number;
  nfoWritten?: boolean;
  /**
   * sidecar 的落盘结果：
   *   written  = 写进去了
   *   exists   = 已有文件，auto 模式不覆盖
   *   kept-user= 文件比我们上次写入更新（用户手改过），**主动不覆盖**
   *   error    = 写失败
   */
  sidecar?: 'written' | 'exists' | 'kept-user' | 'error';
  reason?: string;
}

export interface ScrapeOptions {
  /** force = 覆盖已有元数据与已存在的 .nfo；auto = 只补空位 */
  mode?: 'auto' | 'force';
  /** 手动指定条目（来自 /video/tmdb/search 的结果） */
  mediaType?: 'movie' | 'tv';
  tmdbId?: number;
  /** 是否把 nfo 写到片源目录（受设置开关控制，默认 false） */
  writeSidecar?: boolean;
}

export interface VideoTmdbSettings {
  apiKey: string;
  language: string;
  imageBase: string;
  baseUrl: string;
  /** 刮削结果是否写到片源同目录的 .nfo */
  writeSidecar: boolean;
  /** 自动刮削的最低配评分，低于此分不写库 */
  minScore: number;
}

const DEFAULTS: VideoTmdbSettings = {
  apiKey: '',
  language: 'zh-CN',
  imageBase: '',
  baseUrl: '',
  writeSidecar: false,
  minScore: 2,
};

/**
 * 读刮削设置：`video.tmdb` 优先，没配就复用 `discover.tmdb` 的 Key。
 * 共用 Key 是刻意的——用户只需要填一次；但要允许单独覆盖（比如只给刮削换语言）。
 */
export function readScrapeSettings(k: KernelApi): VideoTmdbSettings {
  const own = (k.config.get<Record<string, unknown>>('video.tmdb') || {}) as Record<string, unknown>;
  const shared = (k.config.get<Record<string, unknown>>('discover.tmdb') || {}) as Record<string, unknown>;
  const pick = (key: string) => {
    const v = own[key];
    if (v !== undefined && v !== null && String(v).trim() !== '') return String(v).trim();
    const s = shared[key];
    return s === undefined || s === null ? '' : String(s).trim();
  };
  return {
    apiKey: pick('apiKey'),
    language: pick('language') || DEFAULTS.language,
    imageBase: pick('imageBase'),
    baseUrl: pick('baseUrl'),
    writeSidecar: own.writeSidecar === true || own.writeSidecar === 1,
    minScore:
      Number.isFinite(Number(own.minScore)) && Number(own.minScore) > 0
        ? Number(own.minScore)
        : DEFAULTS.minScore,
  };
}

export function tmdbConfigOf(settings: VideoTmdbSettings): TmdbConfig {
  return normalizeConfig({
    apiKey: settings.apiKey,
    language: settings.language,
    imageBase: settings.imageBase || undefined,
    baseUrl: settings.baseUrl || undefined,
  });
}

/** 片源绝对路径；SMB / 越界一律返回 null（刮削本身不依赖文件存在，只有写 nfo 才要） */
function absPathOf(row: { rel_path: string }): string | null {
  try {
    const abs = resolveAnyPath(filesRoot(), row.rel_path);
    return fs.existsSync(abs) ? abs : null;
  } catch {
    return null;
  }
}

function usableMediaType(libType: LibType, row: VideoItemRow): 'movie' | 'tv' {
  if (libType === 'tv') return 'tv';
  if (libType === 'movie' || libType === 'jp_movie') return 'movie';
  // 混合库 / 图片库：按条目自身是否有剧集信息判断
  return row.series ? 'tv' : 'movie';
}

function jsonOf(list: readonly string[] | undefined): string | null {
  const arr = (list ?? []).map((v) => String(v ?? '').trim()).filter(Boolean);
  return arr.length > 0 ? JSON.stringify(arr) : null;
}

function relOrNull(abs: string | null): string | null {
  return abs && abs.trim() ? abs : null;
}

/**
 * 一次刮削。
 *
 * 返回而不是抛错：批量刮削要能一条失败继续下一条，并把原因回传给界面。
 */
export async function scrapeItem(
  k: KernelApi,
  itemId: string,
  opts: ScrapeOptions = {},
): Promise<ScrapeOutcome> {
  const db = k.db;
  const row = (
    await sql<VideoItemRow & { lib_type?: string | null; jp_movie?: number | null; scrape_enabled?: number | null }>`
      select i.*, l.lib_type, l.jp_movie, l.scrape_enabled
        from video_items i left join video_libraries l on l.id = i.library_id
       where i.id = ${itemId}
    `.execute(db)
  ).rows[0];
  if (!row) return { status: 'notfound', itemId, reason: 'item not found' };
  if (Number(row.match_nfo) === 0) return { status: 'skipped', itemId, reason: 'excluded' };
  if (Number(row.scrape_enabled) === 0) return { status: 'skipped', itemId, reason: 'library disabled' };

  const libType = libTypeOf(row as never);
  const settings = readScrapeSettings(k);
  const cfg = tmdbConfigOf(settings);
  const nowSec = Math.floor(Date.now() / 1000);
  const artDir = path.join(k.paths.dataDir, 'video-art');
  /** 全局开关：TMDB 认不出时按番号兜底（默认关；jp 库本来就番号优先） */
  const javFallback = readSystemSettings(k.config).javFallback;

  let meta: ScrapedMeta | null = null;
  let source = '';
  let lowConfidence = false;
  /** 番号源抓到的热度（JavDB 评价人数 / 评分）；0 = 没抓到 */
  let jpVotes = 0;
  let jpScore = 0;

  const code = String(row.code ?? '').trim();

  /** 把番号源结果映射成 ScrapedMeta（封面直接落盘） */
  const applyJp = async (jp: NonNullable<Awaited<ReturnType<typeof scrapeJp>>>): Promise<void> => {
    const cover = jp.coverUrl
      ? await downloadRemoteImage(jp.coverUrl, artDir, itemId, 'poster')
      : null;
    meta = {
      title: jp.title || undefined,
      year: jp.releasedAt ? Number(String(jp.releasedAt).slice(0, 4)) || undefined : undefined,
      releaseDate: jp.releasedAt ?? undefined,
      overview: undefined,
      genres: jp.tags,
      regions: ['日本'],
      actors: jp.actors,
      directors: [],
      posterPath: null,
      poster: relOrNull(cover) ?? undefined,
      source: jp.source,
    };
    source = jp.source;
    jpVotes = jp.votes;
    jpScore = jp.score;
  };

  /**
   * 普通影视库的番号兜底：只在 TMDB 明确认不出、且开关打开时尝试。
   * 手动指定 `tmdbId` 时不兜底（用户已经做了选择）。
   */
  const tryJpFallback = async (): Promise<boolean> => {
    if (!javFallback || !code || libType === 'jp_movie' || opts.tmdbId) return false;
    const jp = await scrapeJp(code);
    if (!jp) return false;
    await applyJp(jp);
    return true;
  };

  // ---------------------------------------------------------------- ① 番号源优先（jp 库）
  if (libType === 'jp_movie' && code && !opts.tmdbId) {
    const jp = await scrapeJp(code);
    if (jp) await applyJp(jp);
  }

  // ---------------------------------------------------------------- ② TMDB
  if (!meta) {
    if (!tmdbReady(cfg)) {
      return {
        status: 'unavailable',
        itemId,
        reason: settings.apiKey ? 'TMDB 未就绪' : '未配置 TMDB API Key',
      };
    }
    const mediaType = opts.mediaType ?? usableMediaType(libType, row);
    try {
      if (opts.tmdbId && opts.tmdbId > 0) {
        meta = await detailTmdb(cfg, opts.tmdbId, mediaType);
        source = 'tmdb';
        if (!meta) return { status: 'notfound', itemId, reason: 'tmdb detail empty' };
      } else {
        const seed = String(row.nfo_name ?? '').trim();
        const guessed = guessTitle(seed || titleOf(row.rel_path));
        const query = seed || guessed.title;
        const year = Number(row.nfo_year) > 0 ? Number(row.nfo_year) : guessed.year;
        if (!query) {
          if (!(await tryJpFallback())) {
            return { status: 'notfound', itemId, reason: 'no usable title' };
          }
        } else {
          const candidates = await searchTmdb(cfg, query, mediaType, year ?? undefined);
          const { best, score } = pickBestCandidate(candidates, { title: query, year });
          if (!best || score < settings.minScore) {
            // 低置信度 / 无候选：开关打开时先按番号兜底，仍失败才上报
            if (!(await tryJpFallback())) {
              lowConfidence = true;
              return {
                status: 'notfound',
                itemId,
                reason: `低置信度（${score.toFixed(1)} < ${settings.minScore}），建议手动匹配`,
                title: query,
              };
            }
          } else {
            const detail = await detailTmdb(cfg, best.tmdbId, mediaType);
            if (!detail) {
              if (!(await tryJpFallback())) {
                return { status: 'notfound', itemId, reason: 'tmdb detail empty' };
              }
            } else {
              meta = detail;
              source = 'tmdb';
            }
          }
        }
      }
    } catch (e) {
      return {
        status: 'unavailable',
        itemId,
        reason: String((e as Error)?.message || e).slice(0, 160),
      };
    }
  }

  if (!meta) return { status: 'notfound', itemId, reason: 'no metadata' };

  // ---------------------------------------------------------------- ③ 图片落地
  let poster = relOrNull(meta.poster ?? null);
  let fanart = relOrNull(meta.fanart ?? null);
  if (meta.posterPath) {
    const got = await downloadTmdbImage(cfg, meta.posterPath, 'w500', artDir);
    if (got) poster = got;
  }
  if (meta.backdropPath) {
    const got = await downloadTmdbImage(cfg, meta.backdropPath, 'w780', artDir);
    if (got) fanart = got;
  }

  // ---------------------------------------------------------------- ④ 写库
  const fields = await writeMeta(db, itemId, meta, {
    poster,
    fanart,
    thumb: poster,
    source,
    nowSec,
    overwrite: opts.mode === 'force',
  });

  // 热度单独写：`ScrapedMeta` 是 TMDB 的口径，塞进去会污染 NFO 导出；
  // 这两列只服务日系的排序，抓不到就留 0（排序自然降级，不编数据）。
  if (jpVotes > 0 || jpScore > 0) {
    await sql`
      update video_items set jp_hot_votes = ${jpVotes}, jp_hot_score = ${jpScore}
       where id = ${itemId}
    `.execute(db);
  }

  // ---------------------------------------------------------------- ⑤ 可选：写 nfo 到片源目录
  let nfoWritten = false;
  let sidecar: ScrapeOutcome['sidecar'];
  const wantSidecar = opts.writeSidecar ?? settings.writeSidecar;
  if (wantSidecar) {
    const abs = absPathOf(row);
    if (abs) {
      // 写 .nfo 时图片必须**就在片子旁边**，否则 Kodi 读到 nfo 却找不到图。
      // 所以先把它从 data/video-art 复制成「<同名>-poster.jpg」再引用。
      const localPoster = await copyArtBeside(abs, poster, 'poster');
      const localFanart = await copyArtBeside(abs, fanart, 'fanart');
      const nfoMeta: NfoMeta = {
        title: meta.title,
        originalTitle: meta.originalTitle,
        year: meta.year,
        score: meta.score,
        overview: meta.overview,
        runtimeMin: meta.runtimeMin,
        releaseDate: meta.releaseDate,
        studio: meta.studio,
        genres: meta.genres,
        regions: meta.regions,
        actors: meta.actors,
        directors: meta.directors,
        poster: localPoster,
        fanart: localFanart,
        imdbId: meta.imdbId,
        tmdbId: meta.tmdbId,
        doubanId: meta.doubanId,
        source,
      };
      // 冲突合并：磁盘 nfo 比我们上次写库更新 ⇒ 用户手改过。
      // 这种情况**连 force 也不覆盖**——自动刮削把人家改好的打回去是最容易被骂的行为。
      const target = nfoPathFor(abs);
      const editedAt = fs.existsSync(target) ? fs.statSync(target).mtimeMs / 1000 : 0;
      if (editedAt > 0 && editedAt > (Number(row.nfo_updated_at) || 0)) {
        sidecar = 'kept-user';
      } else {
        const r = await writeNfo(abs, nfoMeta, { overwrite: opts.mode === 'force' });
        nfoWritten = r.written;
        sidecar = r.written ? 'written' : r.reason === 'exists' ? 'exists' : 'error';
      }
    }
  }

  return {
    status: 'scraped',
    itemId,
    source,
    title: meta.title,
    fields,
    nfoWritten,
    sidecar,
    reason: lowConfidence ? 'low confidence' : undefined,
  };
}

/**
 * 写元数据。`overwrite=false` 时只补空位（`auto` 模式，避免手动改过的值被自动覆盖）。
 *
 * 实现上 auto 也用 coalesce：新值优先、null 保留旧值——这样「刮削成功」一定能改进数据，
 * 而「刮削返回半份数据」不会把原有字段清掉。
 */
async function writeMeta(
  db: any,
  itemId: string,
  meta: ScrapedMeta,
  extra: {
    poster: string | null;
    fanart: string | null;
    thumb: string | null;
    source: string;
    nowSec: number;
    overwrite: boolean;
  },
): Promise<number> {
  const values: Record<string, string | number | null> = {
    nfo_name: meta.title ?? null,
    nfo_original_name: meta.originalTitle ?? null,
    nfo_year: meta.year ?? null,
    nfo_score: meta.score ?? null,
    nfo_overview: meta.overview ?? null,
    nfo_runtime: meta.runtimeMin ?? null,
    nfo_release_date: meta.releaseDate ?? null,
    nfo_studio: meta.studio ?? null,
    nfo_genres: jsonOf(meta.genres),
    nfo_regions: jsonOf(meta.regions),
    nfo_actors: jsonOf(meta.actors),
    nfo_directors: jsonOf(meta.directors),
    nfo_poster: extra.poster,
    nfo_fanart: extra.fanart,
    nfo_thumb: extra.thumb,
    nfo_imdb_id: meta.imdbId ?? null,
    nfo_douban_id: meta.doubanId ?? null,
    nfo_tmdb_id: meta.tmdbId ?? null,
  };
  const filled = Object.values(values).filter((v) => v !== null && v !== '').length;

  await sql`
    update video_items set
      nfo_name = coalesce(${values.nfo_name}, nfo_name),
      nfo_original_name = coalesce(${values.nfo_original_name}, nfo_original_name),
      nfo_year = coalesce(${values.nfo_year}, nfo_year),
      nfo_score = coalesce(${values.nfo_score}, nfo_score),
      nfo_overview = coalesce(${values.nfo_overview}, nfo_overview),
      nfo_runtime = coalesce(${values.nfo_runtime}, nfo_runtime),
      nfo_release_date = coalesce(${values.nfo_release_date}, nfo_release_date),
      nfo_studio = coalesce(${values.nfo_studio}, nfo_studio),
      nfo_genres = coalesce(${values.nfo_genres}, nfo_genres),
      nfo_regions = coalesce(${values.nfo_regions}, nfo_regions),
      nfo_actors = coalesce(${values.nfo_actors}, nfo_actors),
      nfo_directors = coalesce(${values.nfo_directors}, nfo_directors),
      nfo_poster = coalesce(${values.nfo_poster}, nfo_poster),
      nfo_fanart = coalesce(${values.nfo_fanart}, nfo_fanart),
      nfo_thumb = coalesce(${values.nfo_thumb}, nfo_thumb),
      nfo_imdb_id = coalesce(${values.nfo_imdb_id}, nfo_imdb_id),
      nfo_douban_id = coalesce(${values.nfo_douban_id}, nfo_douban_id),
      nfo_tmdb_id = coalesce(${values.nfo_tmdb_id}, nfo_tmdb_id),
      nfo_source = ${extra.source || 'manual'},
      nfo_updated_at = ${extra.nowSec},
      match_nfo = 1
     where id = ${itemId}
  `.execute(db);

  // 刮到的演员也要派生关联，否则"演员作品"永远只在 nfo_actors 里躺着
  if (values.nfo_actors) {
    await syncActorLinks(db, itemId, parseActorNames(values.nfo_actors), extra.nowSec).catch(
      () => 0,
    );
  }
  return filled;
}

/** 清空一条的刮削结果（保留文件名派生的 title，删掉 nfo_* 与本地海报） */
export async function cleanupScrape(k: KernelApi, itemId: string): Promise<{ cleared: boolean }> {
  const res = await sql`
    update video_items set
      nfo_name = null, nfo_original_name = null, nfo_year = null, nfo_score = null,
      nfo_overview = null, nfo_runtime = null, nfo_release_date = null, nfo_studio = null,
      nfo_genres = null, nfo_regions = null, nfo_actors = null, nfo_directors = null,
      nfo_poster = null, nfo_fanart = null, nfo_thumb = null,
      nfo_imdb_id = null, nfo_douban_id = null, nfo_tmdb_id = null,
      nfo_source = 'none', nfo_updated_at = ${Math.floor(Date.now() / 1000)}
     where id = ${itemId}
  `.execute(k.db);
  return { cleared: Number(res.numAffectedRows ?? 0) > 0 };
}

/** 把一条标成「不再自动刮削」 */
export async function setMatchNfo(k: KernelApi, itemId: string, match: boolean): Promise<boolean> {
  const res = await sql`
    update video_items set match_nfo = ${match ? 1 : 0} where id = ${itemId}
  `.execute(k.db);
  return Number(res.numAffectedRows ?? 0) > 0;
}


/**
 * 把刮削图复制到片子旁边，返回「相对片子的文件名」（供 nfo 引用）。
 *
 * 三种情况都返回 undefined：
 *   - 没图
 *   - 图本来就在片子同目录（直接复用文件名）
 *   - 复制失败（nfo 里干脆不声明图，好过声明一个不存在的文件）
 */
async function copyArtBeside(
  absVideo: string,
  src: string | null,
  kind: 'poster' | 'fanart',
): Promise<string | undefined> {
  const from = String(src ?? '').trim();
  if (!from || /^https?:\/\//i.test(from)) return undefined;
  const dir = path.dirname(absVideo);
  const stem = path.basename(absVideo).replace(/\.[^.]+$/, '');
  const ext = path.extname(from) || '.jpg';
  const target = path.join(dir, `${stem}-${kind}${ext}`);
  try {
    if (path.resolve(from) === path.resolve(target)) return path.basename(target);
    // 已在同目录且同名（用户自己放的图）就不动它
    if (path.dirname(path.resolve(from)) === path.resolve(dir)) {
      return path.basename(from);
    }
    await fsp.copyFile(from, target);
    return path.basename(target);
  } catch {
    return undefined;
  }
}

/** 下载任意远端图片到本地（番号源封面用；失败返回 null，不写坏路径） */async function downloadRemoteImage(
  url: string,
  dir: string,
  itemId: string,
  kind: string,
): Promise<string | null> {
  const text = String(url ?? '').trim();
  if (!/^https?:\/\//i.test(text)) return null;
  try {
    fs.mkdirSync(dir, { recursive: true });
    const target = path.join(dir, `${itemId.replace(/[^\w-]/g, '_')}-${kind}.jpg`);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12_000);
    try {
      const res = await proxyFetch(text, {
        signal: controller.signal,
        headers: { 'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)' },
      });
      if (!res.ok) return null;
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length < 512) return null;
      fs.writeFileSync(target, buf);
      return target;
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
}
