import fsp from 'node:fs/promises';
import path from 'node:path';
import { extractEntry, listZipEntries, readZipEntry, readZipFile } from './zip';

/**
 * 书籍元数据（零依赖）：
 *   - epub：读 `META-INF/container.xml` → OPF → title/creator/language/publisher + cover-image
 *   - cbz：图片数作为页数，第一张图作封面；可读 ComicInfo.xml 的 Title/Series
 *   - pdf：`/Title` 与 `/Type /Page` 计数（近似页数），无封面
 *   - txt / mobi / azw3 / cbr / cb7 / djvu：仅文件名与大小
 *
 * 封面只在 `/book/cover` 首次访问时提取并缓存，扫描不写文件。
 */
export const BOOK_EXTENSIONS = new Set([
  'epub',
  'pdf',
  'txt',
  'mobi',
  'azw3',
  'cbz',
  'cbr',
  'cb7',
  'djvu',
]);

const IMAGE_EXT = new Set(['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp']);

export interface BookMeta {
  title: string | null;
  author: string | null;
  language: string | null;
  publisher: string | null;
  pageCount: number | null;
  hasCover: boolean;
}

export interface CoverData {
  data: Buffer;
  ext: string;
}

export function extensionOf(file: string): string {
  const base = file.split(/[\\/]/).pop() || '';
  const idx = base.lastIndexOf('.');
  return idx < 0 ? '' : base.slice(idx + 1).toLowerCase();
}

export function isBookFile(file: string): boolean {
  return BOOK_EXTENSIONS.has(extensionOf(file));
}

export function titleOf(file: string): string {
  const base = file.split(/[\\/]/).pop() || '';
  const idx = base.lastIndexOf('.');
  return (idx < 0 ? base : base.slice(0, idx)).trim() || base;
}

export function mimeOf(ext: string): string {
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'bmp':
      return 'image/bmp';
    default:
      return 'application/octet-stream';
  }
}

function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d: string) => String.fromCharCode(Number(d)))
    .replace(/&amp;/g, '&')
    .trim();
}

function firstTag(xml: string, name: string): string | null {
  const re = new RegExp(`<(?:[\\w-]+:)?${name}\\b[^>]*>([\\s\\S]*?)</(?:[\\w-]+:)?${name}>`, 'i');
  const m = re.exec(xml);
  if (!m) return null;
  const text = decodeEntities(m[1].replace(/<[^>]+>/g, ' '));
  return text || null;
}

interface OpfItem {
  id: string;
  href: string;
  mediaType: string;
  properties: string;
}

function parseOpfItems(opf: string): OpfItem[] {
  const items: OpfItem[] = [];
  for (const m of opf.match(/<item\b[^>]*>/gi) ?? []) {
    const id = /\bid\s*=\s*"([^"]*)"/i.exec(m)?.[1];
    const href = /\bhref\s*=\s*"([^"]*)"/i.exec(m)?.[1];
    const mediaType = /\bmedia-type\s*=\s*"([^"]*)"/i.exec(m)?.[1] ?? '';
    const properties = /\bproperties\s*=\s*"([^"]*)"/i.exec(m)?.[1] ?? '';
    if (id && href) items.push({ id, href, mediaType, properties });
  }
  return items;
}

function resolveZipPath(basePath: string, href: string): string {
  const hrefClean = href.split('#')[0];
  const joined = path.posix.join(path.posix.dirname(basePath), hrefClean);
  return path.posix.normalize(joined).replace(/^\/+/, '');
}

interface EpubParsed {
  meta: BookMeta;
  coverHref: string | null;
  opfPath: string;
}

function parseEpub(buf: Buffer): EpubParsed {
  const empty: EpubParsed = {
    meta: { title: null, author: null, language: null, publisher: null, pageCount: null, hasCover: false },
    coverHref: null,
    opfPath: '',
  };

  const container = readZipEntry(buf, 'META-INF/container.xml');
  if (!container) return empty;
  const opfPath = /<rootfile\b[^>]*\bfull-path\s*=\s*"([^"]+)"/i.exec(container.toString('utf8'))?.[1];
  if (!opfPath) return empty;

  const opfBuf = readZipEntry(buf, opfPath);
  if (!opfBuf) return empty;
  const opf = opfBuf.toString('utf8');

  const items = parseOpfItems(opf);
  let coverHref: string | null = null;

  const byProperty = items.find((i) => /\bcover-image\b/i.test(i.properties));
  if (byProperty) {
    coverHref = resolveZipPath(opfPath, byProperty.href);
  } else {
    const coverId = /<meta\b[^>]*\bname\s*=\s*"cover"[^>]*\bcontent\s*=\s*"([^"]*)"/i.exec(opf)?.[1];
    if (coverId) {
      const item = items.find((i) => i.id === coverId);
      if (item) coverHref = resolveZipPath(opfPath, item.href);
    }
  }

  return {
    meta: {
      title: firstTag(opf, 'title'),
      author: firstTag(opf, 'creator'),
      language: firstTag(opf, 'language'),
      publisher: firstTag(opf, 'publisher'),
      pageCount: null,
      hasCover: coverHref !== null,
    },
    coverHref,
    opfPath,
  };
}

/** 提取 epub 封面（扫描只判断 hasCover，路由首次访问时取字节） */
export function readEpubCover(buf: Buffer): CoverData | null {
  const parsed = parseEpub(buf);
  if (!parsed.coverHref) return null;
  const entry = listZipEntries(buf).find((e) => e.name === parsed.coverHref);
  if (!entry) return null;
  const data = extractEntry(buf, entry);
  if (!data) return null;
  const ext = extensionOf(parsed.coverHref);
  return { data, ext: IMAGE_EXT.has(ext) ? ext : 'jpg' };
}

function parseCbz(buf: Buffer): { meta: BookMeta; firstImage: string | null } {
  const entries = listZipEntries(buf).filter((e) => IMAGE_EXT.has(extensionOf(e.name)));
  entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

  let title: string | null = null;
  let author: string | null = null;
  const info = readZipEntry(buf, 'ComicInfo.xml');
  if (info) {
    const xml = info.toString('utf8');
    title = firstTag(xml, 'Title') || firstTag(xml, 'Series');
    author = firstTag(xml, 'Writer') || firstTag(xml, 'Penciller');
  }

  return {
    meta: {
      title,
      author,
      language: null,
      publisher: null,
      pageCount: entries.length > 0 ? entries.length : null,
      hasCover: entries.length > 0,
    },
    firstImage: entries[0]?.name ?? null,
  };
}

export function readCbzCover(buf: Buffer): CoverData | null {
  const { firstImage } = parseCbz(buf);
  if (!firstImage) return null;
  const entry = listZipEntries(buf).find((e) => e.name === firstImage);
  if (!entry) return null;
  const data = extractEntry(buf, entry);
  if (!data) return null;
  const ext = extensionOf(firstImage);
  return { data, ext: IMAGE_EXT.has(ext) ? ext : 'jpg' };
}

function parsePdf(buf: Buffer): BookMeta {
  const text = buf.toString('latin1');
  const titleMatch = /\/Title\s*\(([^)]{1,200})\)/.exec(text);
  const pages = (text.match(/\/Type\s*\/Page[^s]/g) ?? []).length;
  return {
    title: titleMatch ? decodeEntities(titleMatch[1]) : null,
    author: null,
    language: null,
    publisher: null,
    pageCount: pages > 0 ? pages : null,
    hasCover: false,
  };
}

export async function readBookMeta(abs: string): Promise<BookMeta> {
  const ext = extensionOf(abs);
  const base: BookMeta = {
    title: null,
    author: null,
    language: null,
    publisher: null,
    pageCount: null,
    hasCover: false,
  };

  if (ext === 'epub' || ext === 'cbz') {
    const buf = await readZipFile(abs);
    if (!buf) return base;
    if (ext === 'epub') return { ...base, ...parseEpub(buf).meta };
    return { ...base, ...parseCbz(buf).meta };
  }

  if (ext === 'pdf') {
    try {
      const st = await fsp.stat(abs);
      if (st.size > 64 * 1024 * 1024) return base;
      const buf = await fsp.readFile(abs);
      return { ...base, ...parsePdf(buf) };
    } catch {
      return base;
    }
  }

  return base;
}

/** 取封面（epub/cbz）；其余格式返回 null */
export async function readBookCover(abs: string): Promise<CoverData | null> {
  const ext = extensionOf(abs);
  if (ext !== 'epub' && ext !== 'cbz') return null;
  const buf = await readZipFile(abs);
  if (!buf) return null;
  return ext === 'epub' ? readEpubCover(buf) : readCbzCover(buf);
}