import fs from 'node:fs';
import path from 'node:path';
import type { FastifyInstance } from 'fastify';
import { Err } from './errors';

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.wasm': 'application/wasm',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
};

/**
 * 托管 Flutter Web 产物（`apps/colanas_os/build/web`）。
 *
 * 为什么用 `setNotFoundHandler` 而不是注册 `/*` 路由：
 *   - 通配路由会出现在 OpenAPI 里（污染契约），且可能与模块路由的优先级打架；
 *   - 404 处理器只在内核**没有任何路由匹配**时触发，天然只兜 UI 静态资源。
 *
 * 行为：
 *   - `/api/**` 未匹配 → 保持内核原来的 JSON 404（body 与 Fastify 默认一致，`onSend` 仍会补 code/traceId）；
 *   - 非 GET/HEAD → 404 JSON；
 *   - 命中文件 → 按扩展名给 content-type，`cache-control: no-cache`（发布包内文件名带内容哈希时才可长缓存）；
 *   - 未命中 → 返回 `index.html`（SPA 客户端路由兜底）。
 */
export function registerWebUi(app: FastifyInstance, dir: string | null): boolean {
  const indexHtml = dir ? path.join(path.resolve(dir), 'index.html') : '';
  if (!dir || !fs.existsSync(indexHtml)) {
    app.log.info({ dir }, 'web ui not bundled: skip static hosting');
    return false;
  }
  const root = path.resolve(dir);

  app.setNotFoundHandler((req, reply) => {
    const urlPath = (req.url || '/').split('?')[0];

    if (urlPath.startsWith('/api/')) {
      // 与 Fastify 默认 404 保持同一形态，避免破坏既有冒烟断言
      return reply.code(404).send({
        message: `Route ${req.method}:${urlPath} not found`,
        error: 'Not Found',
        statusCode: 404,
      });
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return reply.code(404).send({ error: Err.notFound, message: 'not found' });
    }

    let rel: string;
    try {
      rel = decodeURIComponent(urlPath);
    } catch {
      return reply.code(400).send({ error: Err.badRequest, message: 'bad path' });
    }
    const file = path.join(root, rel.replace(/^[/\\]+/, ''));
    if (!file.startsWith(root)) {
      return reply.code(403).send({ error: Err.forbidden, message: 'path escapes web root' });
    }

    if (fs.existsSync(file) && fs.statSync(file).isFile()) {
      reply.header('content-type', MIME[path.extname(file).toLowerCase()] || 'application/octet-stream');
      reply.header('cache-control', 'no-cache');
      return reply.send(fs.createReadStream(file));
    }

    // SPA 兜底：`/files`、`/settings` 这类前端路由一律给 index.html。
    // 但**带扩展名的资源**（`.woff2`/`.js`/`.wasm`…）缺失时必须 404：
    // 否则浏览器会把 HTML 当字体/脚本解析，出现「Failed to parse font data」
    // 这类看着像损坏、其实是被兜底页顶替的怪问题。
    const ext = path.extname(urlPath).toLowerCase();
    if (ext && ext !== '.html') {
      reply.header('content-type', 'text/plain; charset=utf-8');
      return reply.code(404).send('not found');
    }
    reply.header('content-type', MIME['.html']);
    reply.header('cache-control', 'no-store');
    return reply.send(fs.createReadStream(indexHtml));
  });

  app.log.info({ dir: root }, 'web ui static hosting enabled');
  return true;
}

/**
 * 解析 Web 产物目录：`COLANAS_WEB_DIR` 优先，否则用仓库内的 `apps/colanas_os/build/web`。
 * 内核编译后在 `dist/kernel/`，所以仓库根是 `__dirname/../..`。
 */
export function resolveWebDir(): string | null {
  if (process.env.COLANAS_WEB_DIR) return process.env.COLANAS_WEB_DIR;
  const root = path.resolve(__dirname, '..', '..');
  const dir = path.join(root, 'apps', 'colanas_os', 'build', 'web');
  return fs.existsSync(path.join(dir, 'index.html')) ? dir : null;
}

/**
 * 开发期 CORS：Flutter 的 `flutter run -d chrome --web-port 5173` 页面与内核不同源，
 * 浏览器会拦截；这里按请求的 origin 放行（**只在非 production 调用**）。
 */
export function registerDevCors(app: FastifyInstance): void {
  const allowHeaders =
    'authorization,content-type,range,if-none-match,x-requested-with,x-colanas-client';
  app.addHook('onRequest', async (req, reply) => {
    const origin = req.headers.origin;
    if (!origin) return;
    reply.header('access-control-allow-origin', origin);
    reply.header('vary', 'origin');
    reply.header('access-control-allow-headers', allowHeaders);
    reply.header('access-control-allow-methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
    reply.header('access-control-expose-headers', 'etag,content-range,accept-ranges,content-length');
    reply.header('access-control-max-age', '600');
    if (req.method === 'OPTIONS') reply.code(204).send();
  });
}