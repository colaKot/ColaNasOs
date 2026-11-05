import { createReadStream } from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { absoluteInput, filesRoot, httpError, isAbsoluteInput, resolveInRoot } from './fs-root';

export interface DownloadQuery {
  path?: string;
  /** `1` = 浏览器内联打开，默认附件下载 */
  inline?: string;
}

const MIME: Record<string, string> = {
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.heic': 'image/heic',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.mp3': 'audio/mpeg',
  '.flac': 'audio/flac',
  '.aac': 'audio/aac',
  '.wav': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.7z': 'application/x-7z-compressed',
  '.gz': 'application/gzip',
  '.tar': 'application/x-tar',
};

export function contentTypeOf(file: string): string {
  return MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream';
}

/** 强 ETag：尺寸 + mtime（十六进制），文件一变即变 */
export function etagOf(size: number, mtimeMs: number): string {
  return `"${size.toString(16)}-${Math.floor(mtimeMs).toString(16)}"`;
}

export function matchesEtag(header: string, etag: string): boolean {
  return header
    .split(',')
    .map((s) => s.trim())
    .some((s) => s === etag || s === '*' || s === `W/${etag}`);
}

/**
 * 解析单段 Range：
 * - 返回 `null` → 忽略 Range（多段/非法语法），走 200 全量
 * - 返回 `'unsatisfiable'` → 416
 */
export function parseRange(
  header: string | undefined,
  size: number,
): { start: number; end: number } | 'unsatisfiable' | null {
  if (!header) return null;

  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return null;

  const [, rawStart, rawEnd] = m;
  if (rawStart === '' && rawEnd === '') return null;

  if (rawStart === '') {
    const suffix = Number(rawEnd);
    if (!Number.isFinite(suffix) || suffix <= 0 || size === 0) return 'unsatisfiable';
    return { start: Math.max(0, size - suffix), end: size - 1 };
  }

  const start = Number(rawStart);
  const end = rawEnd === '' ? size - 1 : Math.min(Number(rawEnd), size - 1);
  if (start >= size || start > end) return 'unsatisfiable';
  return { start, end };
}

function disposition(name: string, inline: boolean): string {
  const fallback = name.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  const encoded = encodeURIComponent(name);
  return `${inline ? 'inline' : 'attachment'}; filename="${fallback}"; filename*=UTF-8''${encoded}`;
}

/** GET /api/v1/files/download：Range + ETag + If-None-Match / If-Range，流式输出 */
export async function downloadHandler(req: FastifyRequest, reply: FastifyReply, q: DownloadQuery) {
  const root = filesRoot();
  // 绝对路径（盘符 / UNC）直通：同步的远端目录可能整个在 D 盘，
  // 下载走 /files/download —— 只在 extraRoots 里找会 403。
  const abs = isAbsoluteInput(q.path)
    ? path.resolve(absoluteInput(q.path ?? ''))
    : resolveInRoot(root, q.path);

  let st;
  try {
    st = await fsp.stat(abs);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') throw httpError(404, 'path not found');
    if (code === 'EACCES') throw httpError(403, 'permission denied');
    throw err;
  }
  if (st.isDirectory()) throw httpError(400, 'path is a directory');

  const etag = etagOf(st.size, st.mtimeMs);

  reply.header('ETag', etag);
  reply.header('Last-Modified', st.mtime.toUTCString());
  reply.header('Accept-Ranges', 'bytes');
  reply.header('Cache-Control', 'private, max-age=0');

  const ifNoneMatch = req.headers['if-none-match'];
  if (typeof ifNoneMatch === 'string' && matchesEtag(ifNoneMatch, etag)) {
    return reply.code(304).send();
  }

  reply.header('Content-Type', contentTypeOf(abs));
  reply.header('Content-Disposition', disposition(path.basename(abs), q.inline === '1'));

  // If-Range 不匹配（弱校验/已变更）→ 忽略 Range，返回全量
  let rangeHeader = req.headers.range;
  const ifRange = req.headers['if-range'];
  if (rangeHeader && typeof ifRange === 'string' && ifRange !== etag) rangeHeader = undefined;

  if (!rangeHeader) {
    reply.header('Content-Length', String(st.size));
    return reply.code(200).send(createReadStream(abs));
  }

  const range = parseRange(rangeHeader, st.size);
  if (range === 'unsatisfiable') {
    return reply.code(416).header('Content-Range', `bytes */${st.size}`).send();
  }
  if (range === null) {
    reply.header('Content-Length', String(st.size));
    return reply.code(200).send(createReadStream(abs));
  }

  reply
    .code(206)
    .header('Content-Range', `bytes ${range.start}-${range.end}/${st.size}`)
    .header('Content-Length', String(range.end - range.start + 1));

  return reply.send(createReadStream(abs, { start: range.start, end: range.end }));
}
