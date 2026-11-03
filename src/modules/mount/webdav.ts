import http, { type IncomingMessage } from 'node:http';
import https from 'node:https';
import type { Readable } from 'node:stream';

/**
 * 零依赖 WebDAV 客户端：PROPFIND 列目录 / GET 下载（透传 Range）/ PUT 上传 / MKCOL / DELETE。
 *
 * 只覆盖挂载场景需要的最小方法集，不实现锁、属性修改、COPY/MOVE。
 */
export interface DavConfig {
  baseUrl: string;
  username: string;
  password: string;
  rootPath: string;
}

export interface RemoteEntry {
  name: string;
  path: string;
  dir: boolean;
  size: number;
  mtime: number | null;
}

const TIMEOUT_MS = 20_000;

const PROPFIND_BODY = `<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>`;

export function mountError(status: number, message: string): Error & { statusCode: number } {
  const err = new Error(message) as Error & { statusCode: number };
  err.statusCode = status;
  return err;
}

function authHeader(cfg: DavConfig): string {
  return 'Basic ' + Buffer.from(`${cfg.username}:${cfg.password}`).toString('base64');
}

/** 拼接 URL：base + rootPath + relPath，逐段编码（保留 `/`） */
export function targetUrl(cfg: DavConfig, relPath: string): URL {
  const base = new URL(cfg.baseUrl);
  const root = cfg.rootPath.replace(/^\/+|\/+$/g, '');
  const rel = relPath.replace(/^\/+|\/+$/g, '');
  const segs = [root, rel].join('/').split('/').filter(Boolean);
  const prefix = base.pathname.endsWith('/') ? base.pathname : `${base.pathname}/`;
  base.pathname = prefix + segs.map((s) => encodeURIComponent(s)).join('/');
  if (segs.length === 0) base.pathname = prefix;
  return base;
}

function request(
  cfg: DavConfig,
  method: string,
  url: URL,
  headers: Record<string, string> = {},
  body?: Buffer,
): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    const lib = url.protocol === 'https:' ? https : http;
    const req = lib.request(
      url,
      {
        method,
        headers: {
          authorization: authHeader(cfg),
          ...(body ? { 'content-length': String(body.length) } : {}),
          ...headers,
        },
      },
      resolve,
    );
    req.setTimeout(TIMEOUT_MS, () => {
      req.destroy(mountError(504, 'webdav timeout'));
    });
    req.on('error', (e) => reject(mountError(502, `webdav request failed: ${e.message}`)));
    if (body) req.write(body);
    req.end();
  });
}

function readAll(res: IncomingMessage, limit = 8 * 1024 * 1024): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    res.on('data', (c: Buffer) => {
      size += c.length;
      if (size > limit) {
        res.destroy();
        reject(mountError(502, 'webdav response too large'));
        return;
      }
      chunks.push(c);
    });
    res.on('end', () => resolve(Buffer.concat(chunks)));
    res.on('error', (e) => reject(mountError(502, `webdav read failed: ${e.message}`)));
  });
}

function toEntryPath(hrefPath: string, rootUrl: URL): string {
  const rootPath = decodeURIComponent(rootUrl.pathname);
  const decoded = decodeURIComponent(hrefPath);
  const rel = decoded.startsWith(rootPath) ? decoded.slice(rootPath.length) : decoded;
  return rel.replace(/^\/+|\/+$/g, '');
}

function parseMultistatus(xml: string, rootUrl: URL, selfPath: string): RemoteEntry[] {
  const out: RemoteEntry[] = [];
  const blocks = xml.split(/<\/(?:d|D):response>/).filter((b) => /<(?:d|D):response[\s>]/i.test(b));

  for (const block of blocks) {
    const href = /<(?:d|D):href[^>]*>([^<]*)</i.exec(block)?.[1];
    if (!href) continue;
    const dir = /<(?:d|D):collection\s*\/?>/i.test(block);
    const size = Number(/<(?:d|D):getcontentlength[^>]*>([^<]*)</i.exec(block)?.[1]) || 0;
    const lastModified = /<(?:d|D):getlastmodified[^>]*>([^<]*)</i.exec(block)?.[1];

    let abs: URL;
    try {
      abs = new URL(href, rootUrl);
    } catch {
      continue;
    }

    const path = toEntryPath(abs.pathname, rootUrl);
    if (path === selfPath && dir) continue; // 跳过当前目录自身
    if (!path) continue;

    const segs = path.split('/');
    out.push({
      name: segs[segs.length - 1],
      path,
      dir,
      size,
      mtime: lastModified ? Math.floor(Date.parse(lastModified) / 1000) || null : null,
    });
  }
  return out;
}

async function expectOk(res: IncomingMessage, okStatuses: number[], action: string): Promise<void> {
  if (okStatuses.includes(res.statusCode ?? 0)) return;
  const body = await readAll(res, 4096).catch(() => Buffer.alloc(0));
  const text = body.toString('utf8').slice(0, 200);
  throw mountError(
    res.statusCode === 401 || res.statusCode === 403 ? 401 : 502,
    `${action} failed: HTTP ${res.statusCode}${text ? ' ' + text : ''}`,
  );
}

/** 列目录（Depth: 1），返回相对 rootPath 的路径 */
export async function davList(cfg: DavConfig, relPath: string): Promise<RemoteEntry[]> {
  const url = targetUrl(cfg, relPath);
  const res = await request(cfg, 'PROPFIND', url, {
    depth: '1',
    'content-type': 'application/xml; charset=utf-8',
  }, Buffer.from(PROPFIND_BODY));
  await expectOk(res, [207, 200], 'list');
  const xml = (await readAll(res)).toString('utf8');
  const entries = parseMultistatus(xml, targetUrl(cfg, ''), relPath.replace(/^\/+|\/+$/g, ''));
  entries.sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1));
  return entries;
}

/** 连接测试：对根做 Depth 0 PROPFIND（207/200 即可） */
export async function davTest(cfg: DavConfig): Promise<void> {
  const url = targetUrl(cfg, '');
  const res = await request(cfg, 'PROPFIND', url, {
    depth: '0',
    'content-type': 'application/xml; charset=utf-8',
  }, Buffer.from(PROPFIND_BODY));
  await expectOk(res, [207, 200], 'test');
  await readAll(res, 64 * 1024);
}

/** 打开下载流（透传 Range / If-None-Match 等头） */
export async function davOpen(
  cfg: DavConfig,
  relPath: string,
  headers: Record<string, string>,
): Promise<IncomingMessage> {
  const res = await request(cfg, 'GET', targetUrl(cfg, relPath), headers);
  if ((res.statusCode ?? 0) >= 400) {
    await expectOk(res, [], 'download');
  }
  return res;
}

/** 上传（PUT）；未知长度时不带 Content-Length（分块传输） */
export async function davUpload(
  cfg: DavConfig,
  relPath: string,
  body: Readable,
  size?: number,
): Promise<void> {
  const url = targetUrl(cfg, relPath);
  await new Promise<void>((resolve, reject) => {
    const lib = url.protocol === 'https:' ? https : http;
    const req = lib.request(
      url,
      {
        method: 'PUT',
        headers: {
          authorization: authHeader(cfg),
          ...(size !== undefined && size >= 0 ? { 'content-length': String(size) } : {}),
        },
      },
      (res) => {
        readAll(res, 4096)
          .catch(() => Buffer.alloc(0))
          .then(() => {
            if ((res.statusCode ?? 0) >= 400) {
              reject(mountError(502, `upload failed: HTTP ${res.statusCode}`));
            } else {
              resolve();
            }
          });
      },
    );
    req.setTimeout(TIMEOUT_MS * 6, () => req.destroy(mountError(504, 'upload timeout')));
    req.on('error', (e) => reject(mountError(502, `upload failed: ${e.message}`)));
    body.pipe(req);
  });
}

export async function davMkdir(cfg: DavConfig, relPath: string): Promise<void> {
  const res = await request(cfg, 'MKCOL', targetUrl(cfg, relPath));
  await expectOk(res, [201, 200, 405], 'mkdir');
}

export async function davDelete(cfg: DavConfig, relPath: string): Promise<void> {
  const res = await request(cfg, 'DELETE', targetUrl(cfg, relPath));
  await expectOk(res, [204, 200, 202], 'delete');
}