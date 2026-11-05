import fsp from 'node:fs/promises';
import path from 'node:path';

/**
 * NFO 读 / 写（Kodi / Emby / Jellyfin 通用格式）。
 *
 * 为什么自己写而不引 XML 库：NFO 是**扁平且标签名固定**的方言，真正需要处理的结构
 * 只有「同名标签重复」和 `uniqueid type="..."` 两种。引一个 XML 解析器（以及它带进来的
 * 实体 / DTD 隐患）换不到什么，反而多一个 SBOM 条目。这里一律**宽松提取 + 实体还原**，
 * 解析失败返回 null 而不是抛错——扫库时一条坏 nfo 不能阻断整个库。
 *
 * 只做只读解析 + 极简写出（`writeNfo`）；不做 NFO 的字段级 diff / 合并。
 */
export interface NfoMeta {
  title?: string;
  originalTitle?: string;
  year?: number;
  score?: number;
  overview?: string;
  runtimeMin?: number;
  releaseDate?: string;
  studio?: string;
  genres: string[];
  regions: string[];
  actors: string[];
  /**
   * 演员 → 头像 URL（`<actor><thumb>`，多数日片 NFO 里就带着 JavDB 的
   * `c0.jdbstatic.com/avatars/...`）。
   *
   * 之前解析只取 `<name>`、把 thumb 直接丢了，表现就是「演员全都没有头像」——
   * 而这份数据本地就有，根本不用联网抓（2026-11-04）。
   */
  actorThumbs?: Record<string, string>;
  directors: string[];
  /** nfo 里声明的图片（可能是文件名或 URL，调用方负责解析成实际路径） */
  poster?: string;
  fanart?: string;
  thumb?: string;
  imdbId?: string;
  doubanId?: string;
  tmdbId?: number;
  /** 解析来源标记，写库时落到 nfo_source */
  source: string;
}

const NAMED_ENTITIES: Record<string, string> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
};

export function decodeEntities(text: string): string {
  return String(text ?? '').replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (all, body: string) => {
    if (body.startsWith('#x') || body.startsWith('#X')) {
      const code = Number.parseInt(body.slice(2), 16);
      return Number.isFinite(code) ? String.fromCodePoint(code) : all;
    }
    if (body.startsWith('#')) {
      const code = Number.parseInt(body.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : all;
    }
    const named = NAMED_ENTITIES[body.toLowerCase()];
    return named ?? all;
  });
}

/** 去掉 CDATA 包裹与首尾空白。CDATA 内的内容按字面值处理，不剥标签、不还原实体 */
function cleanText(raw: string): string {
  const text = String(raw ?? '');
  const cdata = /^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/.exec(text);
  if (cdata) return cdata[1].trim();
  return decodeEntities(text.replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

/** 取第一个同名标签的文本（自动跳过带属性的开标签） */
export function tagText(xml: string, tag: string): string | null {
  const re = new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`, 'i');
  const m = re.exec(xml);
  if (!m) return null;
  const text = cleanText(m[1]);
  return text ? text : null;
}

/** 取所有同名标签的文本（去重、保序） */
export function tagAll(xml: string, tag: string): string[] {
  const re = new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`, 'gi');
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const text = cleanText(m[1]);
    if (text) out.push(text);
  }
  return [...new Set(out)];
}

/** 取带某个属性的标签值：`<thumb aspect="poster">x</thumb>` → x */
export function tagTextWithAttr(
  xml: string,
  tag: string,
  attr: string,
  value: string,
): string | null {
  const re = new RegExp(
    `<${tag}[^>]*\\b${attr}\\s*=\\s*["']${value}["'][^>]*>([\\s\\S]*?)</${tag}>`,
    'i',
  );
  const m = re.exec(xml);
  if (!m) return null;
  const text = cleanText(m[1]);
  return text ? text : null;
}

/** `<uniqueid type="imdb">tt123</uniqueid>` → tt123 */
export function uniqueId(xml: string, type: string): string | null {
  const value = tagTextWithAttr(xml, 'uniqueid', 'type', type);
  if (value) return value;
  // 退路：老式 <imdbid> / <tmdbid> / <doubanid> 平铺标签
  return tagText(xml, `${type}id`);
}

function toNumber(raw: string | null): number | undefined {
  if (raw == null) return undefined;
  const n = Number.parseFloat(raw.replace(/[^\d.-]/g, ''));
  return Number.isFinite(n) ? n : undefined;
}

/**
 * 评分：Kodi 新格式是 `<ratings><rating name="imdb"><value>7.8</value></rating></ratings>`，
 * 老格式是平铺 `<rating>7.8</rating>`。优先 imdb，其次 tmdb，最后平铺。
 */
function pickScore(xml: string): number | undefined {
  for (const name of ['imdb', 'themoviedb', 'tmdb']) {
    const block = new RegExp(
      `<rating[^>]*name\\s*=\\s*["']${name}["'][^>]*>([\\s\\S]*?)</rating>`,
      'i',
    ).exec(xml);
    if (block) {
      const v = tagText(block[1], 'value') ?? tagText(block[1], 'rating');
      const n = toNumber(v);
      if (n != null) return n;
    }
  }
  return toNumber(tagText(xml, 'rating'));
}

function pickArt(xml: string): { poster?: string; fanart?: string; thumb?: string } {
  const poster =
    tagTextWithAttr(xml, 'thumb', 'aspect', 'poster') ??
    tagTextWithAttr(xml, 'thumb', 'type', 'poster') ??
    null;
  const fanartBlock = /<fanart(?:\s[^>]*)?>([\s\S]*?)<\/fanart>/i.exec(xml);
  const fanart = fanartBlock ? cleanText(fanartBlock[1]) || null : null;
  // 无 aspect 的裸 <thumb> 当 thumb（剧集/海报兜底）；已有 poster 时不重复取
  const plainThumb = poster ? null : tagText(xml, 'thumb');
  return {
    poster: poster ?? undefined,
    fanart: fanart ?? undefined,
    thumb: plainThumb ?? undefined,
  };
}

/**
 * 解析一份 NFO 文本。返回 null 表示「这份文件不像 nfo」。
 *
 * 判据：至少命中 title / 年份 / 唯一 id 之一。空 nfo（只有 `<movie></movie>`）
 * 也返回 null，避免把空结果当成「已刮削」写进库。
 */
export function parseNfo(xml: string): NfoMeta | null {
  const text = String(xml ?? '');
  if (!text.trim()) return null;

  const title = tagText(text, 'title');
  const originalTitle = tagText(text, 'originaltitle') ?? tagText(text, 'original_title');
  const year = toNumber(tagText(text, 'year'));
  const imdbId = uniqueId(text, 'imdb');
  const doubanId = uniqueId(text, 'douban');
  const tmdbRaw = uniqueId(text, 'tmdb');
  const tmdbId = toNumber(tmdbRaw);

  if (!title && !year && !imdbId && !tmdbId && !doubanId) return null;

  const art = pickArt(text);
  const runtime = toNumber(tagText(text, 'runtime'));
  const releaseDate =
    tagText(text, 'premiered') ?? tagText(text, 'releasedate') ?? tagText(text, 'release_date');

  return {
    title: title ?? undefined,
    originalTitle: originalTitle ?? undefined,
    year,
    score: pickScore(text),
    overview: tagText(text, 'plot') ?? tagText(text, 'outline') ?? tagText(text, 'overview') ?? undefined,
    runtimeMin: runtime,
    releaseDate: releaseDate ?? undefined,
    studio: tagText(text, 'studio') ?? undefined,
    genres: tagAll(text, 'genre'),
    regions: [...tagAll(text, 'country'), ...tagAll(text, 'region')],
    actors: parseActorNames(text),
    actorThumbs: parseActorThumbs(text),
    directors: tagAll(text, 'director'),
    poster: art.poster,
    fanart: art.fanart,
    thumb: art.thumb,
    imdbId: imdbId ?? undefined,
    doubanId: doubanId ?? undefined,
    tmdbId,
    source: 'nfo',
  };
}

/**
 * `<actor>` 里带 `<name>` / `<role>` / `<thumb>`，`tagAll('actor')` 会把整段压成一行，
 * 这里单独把演员名抽出来（只要名字，人物墙用）。
 */
export function parseActorNames(xml: string): string[] {
  const re = /<actor(?:\s[^>]*)?>([\s\S]*?)<\/actor>/gi;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const name = tagText(m[1], 'name');
    if (name) out.push(name);
  }
  return [...new Set(out)];
}

/**
 * 演员头像：`<actor><name>X</name><thumb>https://…/avatars/…jpg</thumb></actor>`。
 *
 * 返回 `{ 名字: URL }`。只收 http(s) 的（本地相对路径走 `resolveArtRef` 那套没意义，
 * 演员图基本都在 CDN 上）；同一演员在多条 NFO 里出现时取第一条非空的。
 */
export function parseActorThumbs(xml: string): Record<string, string> {
  const re = /<actor(?:\s[^>]*)?>([\s\S]*?)<\/actor>/gi;
  const out: Record<string, string> = {};
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const name = tagText(m[1], 'name');
    const thumb = tagText(m[1], 'thumb') ?? tagText(m[1], 'photo');
    if (!name || !thumb) continue;
    if (!/^https?:\/\//i.test(thumb)) continue;
    if (!out[name]) out[name] = thumb;
  }
  return out;
}

// ---------------------------------------------------------------- 定位

const VIDEO_EXTS = new Set([
  '.mkv',
  '.mp4',
  '.avi',
  '.mov',
  '.wmv',
  '.flv',
  '.ts',
  '.m2ts',
  '.webm',
  '.rmvb',
  '.rm',
  '.mpg',
  '.mpeg',
  '.m4v',
  '.iso',
]);

function stemOf(absPath: string): string {
  const base = path.basename(absPath);
  const ext = path.extname(base);
  return ext ? base.slice(0, -ext.length) : base;
}

async function exists(p: string): Promise<boolean> {
  try {
    await fsp.access(p);
    return true;
  } catch {
    return false;
  }
}

/**
 * 找一个视频文件对应的 NFO。顺序即优先级：
 *   ① `<同名>.nfo`      —— 单集 / 单片最标准的写法
 *   ② 同目录 `movie.nfo` —— 一部片一个文件夹的老写法
 *   ③ 同目录 `tvshow.nfo`—— 剧集目录级的元数据（由调用方决定是否采纳）
 */
export async function findNfoFile(absPath: string): Promise<{ file: string; scope: 'item' | 'dir' } | null> {
  const dir = path.dirname(absPath);
  const stem = stemOf(absPath);
  const candidates: Array<{ file: string; scope: 'item' | 'dir' }> = [
    { file: path.join(dir, `${stem}.nfo`), scope: 'item' },
    { file: path.join(dir, 'movie.nfo'), scope: 'dir' },
    { file: path.join(dir, 'tvshow.nfo'), scope: 'dir' },
  ];
  for (const c of candidates) {
    if (await exists(c.file)) return c;
  }
  return null;
}

/**
 * 找本地已有图片。刮削前先认用户自己放好的图，比在线抓一张覆盖率更高。
 *
 * 命名变体来自不同刮削器，全都要认（每种都在用户库里真实出现过）：
 *   `<同名>-poster` / `.poster`（Plex/Jellyfin 标准）
 *   `<同名>-post`     —— tinyMediaManager 简写，漏了就是「明明有封面却 404」
 *   `-cover` / `-folder` / `-thumb`
 *   裸 `poster` / `folder` / `cover`（一部片一个文件夹的老写法）
 *   最后才用与视频同名的图（不含 -fanart / -backdrop / -logo 这类，它们不是海报）
 */
export async function findLocalPoster(absPath: string): Promise<string | null> {
  const dir = path.dirname(absPath);
  const stem = stemOf(absPath);
  const names = [
    `${stem}-poster`,
    `${stem}.poster`,
    `${stem}-post`,
    `${stem}.post`,
    `${stem}-cover`,
    `${stem}-folder`,
    `${stem}-thumb`,
    'poster',
    'folder',
    'cover',
    'thumb',
    stem,
  ];
  for (const name of names) {
    for (const ext of ['.jpg', '.jpeg', '.png', '.webp']) {
      const file = path.join(dir, name + ext);
      if (await exists(file)) return file;
    }
  }
  return null;
}

/**
 * 同上，横版剧照。
 * 同样要把 `<同名>-backdrop` / `<同名>-landscape` 认下来 —— 只认裸 `backdrop`
 * 的话，媒体库自带的 `<同名>-backdrop.jpg` 一张都用不上。
 */
export async function findLocalFanart(absPath: string): Promise<string | null> {
  const dir = path.dirname(absPath);
  const stem = stemOf(absPath);
  const names = [
    `${stem}-fanart`,
    `${stem}.fanart`,
    `${stem}-backdrop`,
    `${stem}-landscape`,
    `${stem}-background`,
    `${stem}-thumb`,
    'fanart',
    'background',
    'backdrop',
    'landscape',
  ];
  for (const name of names) {
    for (const ext of ['.jpg', '.jpeg', '.png', '.webp']) {
      const file = path.join(dir, name + ext);
      if (await exists(file)) return file;
    }
  }
  return null;
}

/**
 * 把 nfo 里声明的图片值解析成实际路径：
 *   - `http(s)://…` 原样返回（调用方决定是否下载）
 *   - 相对路径 → 相对 nfo 所在目录
 */
export function resolveArtRef(value: string | undefined, baseDir: string): string | null {
  const text = String(value ?? '').trim();
  if (!text) return null;
  if (/^https?:\/\//i.test(text)) return text;
  return path.join(baseDir, text);
}

/** 该文件是否像视频（writeNfo 判断「要不要给这条写 nfo」用） */
export function looksLikeVideo(name: string): boolean {
  return VIDEO_EXTS.has(path.extname(name).toLowerCase());
}

// ---------------------------------------------------------------- 写出

function esc(text: string): string {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function xmlList(tag: string, values: readonly string[] | undefined): string {
  if (!values || values.length === 0) return '';
  return values.map((v) => `  <${tag}>${esc(v)}</${tag}>`).join('\n') + '\n';
}

/**
 * 生成一份 Kodi 风格 NFO 文本。只写有值的字段，不写空标签
 * （空标签会让 Kodi 把已有信息覆盖成空）。
 */
export function buildNfo(meta: NfoMeta, kind: 'movie' | 'episode' = 'movie'): string {
  const root = kind === 'episode' ? 'episodedetails' : 'movie';
  const lines: string[] = [`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`, `<${root}>`];
  if (meta.title) lines.push(`  <title>${esc(meta.title)}</title>`);
  if (meta.originalTitle) lines.push(`  <originaltitle>${esc(meta.originalTitle)}</originaltitle>`);
  if (meta.year) lines.push(`  <year>${meta.year}</year>`);
  if (meta.score != null) lines.push(`  <rating>${meta.score.toFixed(1)}</rating>`);
  if (meta.overview) lines.push(`  <plot>${esc(meta.overview)}</plot>`);
  if (meta.runtimeMin) lines.push(`  <runtime>${Math.round(meta.runtimeMin)}</runtime>`);
  if (meta.releaseDate) lines.push(`  <premiered>${esc(meta.releaseDate)}</premiered>`);
  if (meta.studio) lines.push(`  <studio>${esc(meta.studio)}</studio>`);
  if (meta.imdbId) lines.push(`  <uniqueid type="imdb">${esc(meta.imdbId)}</uniqueid>`);
  if (meta.tmdbId) lines.push(`  <uniqueid type="tmdb">${meta.tmdbId}</uniqueid>`);
  if (meta.doubanId) lines.push(`  <uniqueid type="douban">${esc(meta.doubanId)}</uniqueid>`);
  if (meta.poster) lines.push(`  <thumb aspect="poster">${esc(meta.poster)}</thumb>`);
  if (meta.fanart) lines.push(`  <fanart><thumb>${esc(meta.fanart)}</thumb></fanart>`);
  lines.push(xmlList('genre', meta.genres).trimEnd());
  lines.push(xmlList('country', meta.regions).trimEnd());
  lines.push(xmlList('director', meta.directors).trimEnd());
  if (meta.actors.length > 0) {
    lines.push(
      meta.actors
        .map((name) => `  <actor><name>${esc(name)}</name></actor>`)
        .join('\n'),
    );
  }
  const body = lines.filter((l) => l.trim() !== '').join('\n');
  return `${body}\n</${root}>\n`;
}

/**
 * 把 NFO 写到视频同目录（`<同名>.nfo`）。
 *
 * ⚠️ 这是**唯一会写用户目录**的操作，由 `video.nfo.sidecar` 开关控制（默认关）。
 * 已有文件不覆盖：用户手写的 nfo 优先级高于我们的自动刮削结果。
 */
export function nfoPathFor(absPath: string): string {
  return path.join(path.dirname(absPath), `${stemOf(absPath)}.nfo`);
}

export async function writeNfo(
  absPath: string,
  meta: NfoMeta,
  opts: { overwrite?: boolean; kind?: 'movie' | 'episode' } = {},
): Promise<{ written: boolean; file: string; reason?: string }> {
  const file = nfoPathFor(absPath);
  if (!opts.overwrite && (await exists(file))) {
    return { written: false, file, reason: 'exists' };
  }
  try {
    await fsp.writeFile(file, buildNfo(meta, opts.kind ?? 'movie'), 'utf-8');
    return { written: true, file };
  } catch (e) {
    return { written: false, file, reason: String((e as Error)?.message || e) };
  }
}
