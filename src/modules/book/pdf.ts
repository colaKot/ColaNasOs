import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import type { Buffer } from 'node:buffer';
import { createCanvas, DOMMatrix, ImageData, Path2D } from '@napi-rs/canvas';

/**
 * PDF 内置阅读（book 二期）：**服务端渲染成 PNG**，客户端复用现有图片阅读器。
 *
 * 为什么不放客户端：pdfrx 的 Web 端依赖 PDFium WASM，实测 Flutter Web 产物里
 * 并没有打包该资源（内网 NAS 也无法从 CDN 拉），而 Electron 桌面加载的正是 Web 产物。
 * 服务端渲染对所有端一致，也不给客户端新增原生依赖。
 *
 * 约束：
 *   - 单文档缓存（同一时刻只保留一个 PDF），按 `abs + mtime + size` 失效；
 *   - 渲染串行（一张一张来），避免多页并发把内存打满；
 *   - PNG 落盘缓存（`<dataDir>/book-pdf/<sha1>-<page>-<width>.png`），重复翻页不再渲染；
 *   - 文件上限 128 MB（pdfjs 会把整个文件读进内存）。
 */

const MAX_PDF_BYTES = 128 * 1024 * 1024;
const DEFAULT_WIDTH = 1200;
const MAX_WIDTH = 2400;
const RENDER_TIMEOUT_MS = 20_000;

// pdfjs 的 legacy CJS 构建在 Node 下需要这些全局对象；必须在 require 之前挂上
(globalThis as Record<string, unknown>).DOMMatrix = DOMMatrix;
(globalThis as Record<string, unknown>).ImageData = ImageData;
(globalThis as Record<string, unknown>).Path2D = Path2D;

type PdfDocumentLike = {
  numPages: number;
  getPage(index: number): Promise<{
    getViewport(params: { scale: number }): { width: number; height: number };
    render(params: { canvasContext: unknown; viewport: unknown }): { promise: Promise<void> };
    cleanup(): void;
  }>;
  destroy(): Promise<void>;
};

type CanvasLike = ReturnType<typeof createCanvas>;

interface CachedDoc {
  key: string;
  doc: PdfDocumentLike;
}

let cached: CachedDoc | null = null;
let chain: Promise<unknown> = Promise.resolve();

function pdfjs(): {
  getDocument(params: Record<string, unknown>): { promise: Promise<PdfDocumentLike> };
} {
  // pdfjs 的 legacy 构建是 CJS；用 require 而不是静态 import，
  // 保证上面的 DOMMatrix/ImageData/Path2D 全局挂载先执行。
  return require('pdfjs-dist/legacy/build/pdf.js');
}

function enqueue<T>(task: () => Promise<T>): Promise<T> {
  const next = chain.then(task, task);
  chain = next.catch(() => undefined);
  return next;
}

function canvasFactory() {
  return {
    create(width: number, height: number) {
      const canvas = createCanvas(Math.max(1, Math.ceil(width)), Math.max(1, Math.ceil(height)));
      return { canvas, context: canvas.getContext('2d') };
    },
    reset(target: { canvas: CanvasLike }, width: number, height: number) {
      target.canvas.width = Math.max(1, Math.ceil(width));
      target.canvas.height = Math.max(1, Math.ceil(height));
    },
    destroy(target: { canvas: CanvasLike }) {
      target.canvas.width = 0;
      target.canvas.height = 0;
    },
  };
}

async function docKey(abs: string): Promise<string> {
  const stat = await fsp.stat(abs);
  return `${abs}|${stat.size}|${Math.floor(stat.mtimeMs)}`;
}

async function loadDoc(abs: string): Promise<PdfDocumentLike> {
  const key = await docKey(abs);
  if (cached && cached.key === key) return cached.doc;
  if (cached) {
    const old = cached.doc;
    cached = null;
    await old.destroy().catch(() => undefined);
  }

  const stat = await fsp.stat(abs);
  if (stat.size > MAX_PDF_BYTES) throw Object.assign(new Error('pdf too large'), { code: 'tooLarge' });

  const data = await fsp.readFile(abs);
  const doc = await pdfjs().getDocument({
    data: new Uint8Array(data),
    canvasFactory: canvasFactory(),
    // 内置字体不走系统字体，避免缺字体警告与平台差异
    disableFontFace: true,
    useSystemFonts: false,
    isEvalSupported: false,
  }).promise;
  cached = { key, doc };
  return doc;
}

/** 精确页数；解析失败返回 0（客户端仍可尝试打开，页数以渲染器为准）。 */
export async function pdfPageCount(abs: string): Promise<number> {
  try {
    return await enqueue(async () => (await loadDoc(abs)).numPages);
  } catch {
    return 0;
  }
}

export interface PdfRenderedPage {
  png: Buffer;
  total: number;
}

/**
 * 渲染某一页为 PNG（0 基）。越界返回 null；超时 / 损坏返回 null。
 * [maxWidth] 为输出宽度（像素），默认 1200，上限 2400。
 */
export async function renderPdfPage(
  abs: string,
  index: number,
  cacheDir: string,
  maxWidth = DEFAULT_WIDTH,
): Promise<PdfRenderedPage | null> {
  if (!Number.isInteger(index) || index < 0) return null;
  const width = Math.min(MAX_WIDTH, Math.max(320, Math.trunc(maxWidth) || DEFAULT_WIDTH));

  let key: string;
  try {
    key = await docKey(abs);
  } catch {
    return null;
  }
  const hash = crypto.createHash('sha1').update(`${key}|${width}`).digest('hex');
  const target = path.join(cacheDir, 'book-pdf', `${hash}-${index}.png`);

  try {
    const stat = await fsp.stat(target);
    if (stat.size > 0) {
      const doc = await enqueue(async () => loadDoc(abs));
      return { png: await fsp.readFile(target), total: doc.numPages };
    }
  } catch {
    /* 未命中缓存 */
  }

  return enqueue(async () => {
    try {
      const doc = await loadDoc(abs);
      if (index >= doc.numPages) return null;

      const page = await doc.getPage(index + 1);
      const base = page.getViewport({ scale: 1 });
      const scale = width / base.width;
      const viewport = page.getViewport({ scale });
      const canvas = createCanvas(
        Math.max(1, Math.ceil(viewport.width)),
        Math.max(1, Math.ceil(viewport.height)),
      );
      const context = canvas.getContext('2d');

      await Promise.race([
        page.render({ canvasContext: context, viewport }).promise,
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error('pdf render timeout')), RENDER_TIMEOUT_MS),
        ),
      ]);
      const png = canvas.toBuffer('image/png');
      page.cleanup();

      await fsp.mkdir(path.dirname(target), { recursive: true });
      await fsp.writeFile(target, png);
      return { png, total: doc.numPages };
    } catch {
      return null;
    }
  });
}

/** 测试 / 运维：清空当前缓存文档（不删磁盘 PNG）。 */
export async function resetPdfCache(): Promise<void> {
  const doc = cached?.doc;
  cached = null;
  if (doc) await doc.destroy().catch(() => undefined);
}

/** 仅用于单测：缓存目录存在即可。 */
export function pdfCacheDir(dataDir: string): string {
  const dir = path.join(dataDir, 'book-pdf');
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch {
    /* 目录已存在 / 无权限由后续写入报错 */
  }
  return dir;
}