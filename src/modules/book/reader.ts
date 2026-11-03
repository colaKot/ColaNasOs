import fsp from 'node:fs/promises';
import path from 'node:path';
import { extractEntry, listZipEntries, readZipEntry, type ZipEntry } from './zip';
import { extensionOf, mimeOf } from './metadata';
import { pdfPageCount, renderPdfPage } from './pdf';

/**
 * 内置阅读器数据源（零依赖）：
 *   - epub：container.xml → OPF → spine 顺序；章节标题优先取 nav 目录，其次 href 文件名
 *   - txt：按「第 N 章 / Chapter N」正则切章，首章前有内容则作「前言」
 *   - cbz：按文件名自然排序的图片页（page2 排在 page10 之前）
 *   - pdf：页数统计后交给客户端用 pdfrx 直接渲染（服务端不渲染页面）
 *   - mobi / azw3 / cbr / cb7：暂不支持（`kind: 'none'`），由路由回 400
 *
 * 只解压单章 / 单页，不整包加载；单页文本与图片都有上限，避免一次返回几十 MB。
 */

const MAX_TEXT_BYTES = 8 * 1024 * 1024;
const MAX_PAGE_TEXT = 200_000;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_EPUB_CHAPTERS = 2000;

export type ReaderKind = 'text' | 'image' | 'pdf' | 'none';

export interface TocPage {
  index: number;
  title: string;
}

export interface TocResult {
  kind: ReaderKind;
  total: number;
  pages: TocPage[];
}

export interface TextPage {
  kind: 'text';
  index: number;
  title: string;
  text: string;
  truncated: boolean;
}

export interface ImagePage {
  kind: 'image';
  index: number;
  title: string;
  mime: string;
  /** base64，前端直接 Image.memory / 文本预览 */
  data: string;
}

export type ReaderPage = TextPage | ImagePage;

function decodeEntities(s: string): string {
  return s
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d: string) => String.fromCharCode(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_, h: string) => String.fromCharCode(parseInt(h, 16)))
    .replace(/&amp;/g, '&');
}

/** HTML → 纯文本：块级标签转换行，去掉脚本 / 样式 / 标签。 */
export function htmlToText(html: string): string {
  const stripped = html
    .replace(/<head\b[\s\S]*?<\/head>/gi, ' ')
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<\/(p|div|h[1-6]|li|tr|blockquote|section)>/gi, '\n')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, ' ');
  return decodeEntities(stripped)
    .split('\n')
    .map((l) => l.replace(/[ \t\u00a0]+/g, ' ').trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function resolveZipPath(basePath: string, href: string): string {
  const hrefClean = href.split('#')[0];
  return path.posix.normalize(path.posix.join(path.posix.dirname(basePath), hrefClean)).replace(/^\/+/, '');
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

interface EpubStructure {
  spineHrefs: string[];
  titles: Map<string, string>;
}

/** nav.xhtml 里 `<a href="x.xhtml#y">标题</a>` → href → 标题 */
function parseNavTitles(nav: string, navPath: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const m of nav.match(/<a\b[^>]*\bhref\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi) ?? []) {
    const href = m.match(/\bhref\s*=\s*"([^"]+)"/i)?.[1];
    const inner = m.replace(/^<a\b[^>]*>/i, '').replace(/<\/a>$/i, '');
    const title = htmlToText(inner).replace(/\s+/g, ' ');
    if (href && title) {
      out.set(resolveZipPath(navPath, href), title.slice(0, 80));
      out.set(href.split('#')[0], title.slice(0, 80));
    }
  }
  return out;
}

function parseEpubStructure(buf: Buffer): EpubStructure | null {
  const container = readZipEntry(buf, 'META-INF/container.xml');
  if (!container) return null;
  const opfPath = /<rootfile\b[^>]*\bfull-path\s*=\s*"([^"]+)"/i.exec(container.toString('utf8'))?.[1];
  if (!opfPath) return null;
  const opfBuf = readZipEntry(buf, opfPath);
  if (!opfBuf) return null;
  const opf = opfBuf.toString('utf8');

  const items = parseOpfItems(opf);
  const byId = new Map(items.map((i) => [i.id, i]));

  const spineHrefs: string[] = [];
  for (const m of opf.match(/<itemref\b[^>]*>/gi) ?? []) {
    const idref = /\bidref\s*=\s*"([^"]*)"/i.exec(m)?.[1];
    if (!idref) continue;
    const item = byId.get(idref);
    if (!item) continue;
    spineHrefs.push(resolveZipPath(opfPath, item.href));
    if (spineHrefs.length >= MAX_EPUB_CHAPTERS) break;
  }

  let titles = new Map<string, string>();
  const nav = items.find((i) => /\bnav\b/i.test(i.properties) && /\.x?html?$/i.test(i.href));
  if (nav) {
    const navPath = resolveZipPath(opfPath, nav.href);
    const navBuf = readZipEntry(buf, navPath);
    if (navBuf) titles = parseNavTitles(navBuf.toString('utf8'), navPath);
  }

  return { spineHrefs, titles };
}

function titleFromHref(href: string, index: number): string {
  const base = path.posix.basename(href).replace(/\.x?html?$/i, '').replace(/[-_]+/g, ' ').trim();
  return base && base.length <= 60 ? base : `第 ${index + 1} 节`;
}

// 注意两点：① 不能用 \b —— JS 的 \w 只含 ASCII，中文章节名后面没有 word boundary；
// ② 章节名后必须跟空白或行尾，否则「第一章正文。」这种引用正文的整句会被误判为标题。
const CHAPTER_RE =
  /^\s*(?:第\s*[0-9一二三四五六七八九十百千零〇两]+\s*[章节回卷篇幕](?=\s|$)|Chapter\s+\d+(?=\s|$)|CHAPTER\s+\d+(?=\s|$)|(?:序章|楔子|尾声|后记|番外)(?=\s|$)).*$/;

interface TxtChapter {
  title: string;
  start: number;
  end: number;
}

/** 按行扫描标题，返回章节区间（字符偏移）。首章前有内容则插「前言」。 */
export function splitTxt(text: string): TxtChapter[] {
  const chapters: TxtChapter[] = [];
  let offset = 0;
  let current: TxtChapter | null = null;

  for (const raw of text.split('\n')) {
    const line = raw.trim();
    const lineStart = offset;
    offset += raw.length + 1; // + '\n'

    if (line.length > 0 && line.length <= 60 && CHAPTER_RE.test(line)) {
      if (current) {
        current.end = lineStart;
        chapters.push(current);
      }
      current = { title: line, start: lineStart, end: text.length };
    }
  }

  if (current) {
    current.end = text.length;
    chapters.push(current);
  }

  if (chapters.length === 0) {
    return [{ title: '全文', start: 0, end: text.length }];
  }
  const first = chapters[0];
  if (first.start > 0 && text.slice(0, first.start).trim().length > 0) {
    chapters.unshift({ title: '前言', start: 0, end: first.start });
  }
  return chapters;
}

function naturalCompare(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' });
}

function cbzPages(buf: Buffer): ZipEntry[] {
  const entries = listZipEntries(buf).filter(
    (e) =>
      !e.name.startsWith('__MACOSX/') &&
      !e.name.endsWith('/') &&
      /\.(jpe?g|png|webp|gif)$/i.test(e.name),
  );
  return entries.sort((a, b) => naturalCompare(a.name, b.name));
}

/** 目录：返回阅读器需要的数据形态与页（章）列表。 */
export async function readToc(abs: string): Promise<TocResult> {
  const ext = extensionOf(abs);

  if (ext === 'epub') {
    const buf = await fsp.readFile(abs);
    const parsed = parseEpubStructure(buf);
    if (!parsed || parsed.spineHrefs.length === 0) return { kind: 'none', total: 0, pages: [] };
    const pages = parsed.spineHrefs.map((href, i) => ({
      index: i,
      title: parsed.titles.get(href) ?? titleFromHref(href, i),
    }));
    return { kind: 'text', total: pages.length, pages };
  }

  if (ext === 'txt') {
    const buf = await fsp.readFile(abs);
    if (buf.length > MAX_TEXT_BYTES) return { kind: 'none', total: 0, pages: [] };
    const chapters = splitTxt(buf.toString('utf8'));
    const pages = chapters.map((c, i) => ({ index: i, title: c.title.slice(0, 80) }));
    return { kind: 'text', total: pages.length, pages };
  }

  if (ext === 'cbz') {
    const buf = await fsp.readFile(abs);
    const entries = cbzPages(buf);
    const pages = entries.map((e, i) => ({ index: i, title: `第 ${i + 1} 页` }));
    return { kind: 'image', total: pages.length, pages };
  }

  if (ext === 'pdf') {
    // pdfjs 能给出精确页数；解析失败再退回正则统计（大文件只扫头尾）
    const exact = await pdfPageCount(abs);
    const total = exact > 0 ? exact : await countPdfPages(abs);
    const pages = Array.from({ length: total }, (_, i) => ({
      index: i,
      title: `第 ${i + 1} 页`,
    }));
    return { kind: 'pdf', total, pages };
  }

  return { kind: 'none', total: 0, pages: [] };
}

const MAX_PDF_SCAN_BYTES = 16 * 1024 * 1024;

/** 统计 PDF 页对象（`/Type /Page`，排除 `/Pages`）；先读头部，头部没有再看尾部。 */
async function countPdfPages(abs: string): Promise<number> {
  try {
    const { size } = await fsp.stat(abs);
    if (size === 0) return 0;

    const readRange = async (start: number, length: number): Promise<string> => {
      const fh = await fsp.open(abs, 'r');
      try {
        const buf = Buffer.alloc(length);
        const { bytesRead } = await fh.read(buf, 0, length, start);
        return buf.subarray(0, bytesRead).toString('latin1');
      } finally {
        await fh.close();
      }
    };

    const head = await readRange(0, Math.min(size, MAX_PDF_SCAN_BYTES));
    const headPages = countPageObjects(head);
    if (headPages > 0 || size <= MAX_PDF_SCAN_BYTES) return headPages;

    const tail = await readRange(Math.max(0, size - MAX_PDF_SCAN_BYTES), MAX_PDF_SCAN_BYTES);
    return countPageObjects(tail);
  } catch {
    return 0;
  }
}

function countPageObjects(text: string): number {
  let count = 0;
  const re = /\/Type\s*\/Page(?![s\w])/g;
  while (re.exec(text)) count += 1;
  return count;
}

/** 单页：文本页返回纯文本（超长截断），图片页返回 base64。 */
export async function readPage(
  abs: string,
  index: number,
  cacheDir?: string,
): Promise<ReaderPage | null> {
  const ext = extensionOf(abs);
  if (!Number.isInteger(index) || index < 0) return null;

  if (ext === 'epub') {
    const buf = await fsp.readFile(abs);
    const parsed = parseEpubStructure(buf);
    if (!parsed) return null;
    const href = parsed.spineHrefs[index];
    if (!href) return null;
    const entry = listZipEntries(buf).find((e) => e.name === href);
    if (!entry) return null;
    const data = extractEntry(buf, entry);
    if (!data) return null;
    const title = parsed.titles.get(href) ?? titleFromHref(href, index);
    return textPage(index, title, htmlToText(data.toString('utf8')));
  }

  if (ext === 'txt') {
    const buf = await fsp.readFile(abs);
    if (buf.length > MAX_TEXT_BYTES) return null;
    const text = buf.toString('utf8');
    const chapter = splitTxt(text)[index];
    if (!chapter) return null;
    return textPage(index, chapter.title.slice(0, 80), text.slice(chapter.start, chapter.end));
  }

  if (ext === 'cbz') {
    const buf = await fsp.readFile(abs);
    const entries = cbzPages(buf);
    const entry = entries[index];
    if (!entry) return null;
    if (entry.size > MAX_IMAGE_BYTES) return null;
    const data = extractEntry(buf, entry);
    if (!data) return null;
    return {
      kind: 'image',
      index,
      title: `第 ${index + 1} 页`,
      mime: mimeOf(extensionOf(entry.name)),
      data: data.toString('base64'),
    };
  }

  if (ext === 'pdf') {
    if (!cacheDir) return null;
    const rendered = await renderPdfPage(abs, index, cacheDir);
    if (!rendered) return null;
    return {
      kind: 'image',
      index,
      title: `第 ${index + 1} 页`,
      mime: 'image/png',
      data: rendered.png.toString('base64'),
    };
  }

  return null;
}

function textPage(index: number, title: string, raw: string): TextPage {
  const text = raw.trim();
  const truncated = text.length > MAX_PAGE_TEXT;
  return {
    kind: 'text',
    index,
    title,
    text: truncated ? text.slice(0, MAX_PAGE_TEXT) : text,
    truncated,
  };
}