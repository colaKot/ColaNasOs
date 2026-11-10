import fs from 'node:fs';
import path from 'node:path';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';

import { Err } from '../../../kernel/errors';
import { resolveSecret, verifyToken } from '../../../kernel/auth';
import type { KernelApi } from '../../../kernel/types';
import type { TransmissionConfig } from './transmission';

/**
 * 内置 transmission 官方 Web UI + RPC 代理。
 *
 * 为什么这么做：列表页只做「看一眼」，批量加种 / 限速 / 改目录这些操作
 * 与其自己再写一遍，不如直接把官方前端（`vendor/transmission-web`，
 * 从 Debian `transmission-common_3.00` 的 `/usr/share/transmission/web` 取出，
 * GPLv3，与本项目同许可）托管出来。
 *
 * 但有两点必须由我们兜住：
 *  1. **同源**：官方前端只往「自己所在域的 `/transmission/rpc`」发请求，
 *     所以内核得代理到用户配置的 RPC 地址（带 Basic 认证与 session-id 握手）；
 *  2. **鉴权**：内核接口都要 JWT，浏览器里的这个静态页拿不到。
 *     解法是「一次性票据换 Cookie」——客户端带 `?t=<jwt>` 打开一次，
 *     内核校验后下发 HttpOnly Cookie 并 302 掉 query，之后静态资源与 RPC 都认这个 Cookie。
 */

const COOKIE = 'nas_tw';
const COOKIE_MAX_AGE = 12 * 3600;

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8',
};

/** 官方 Web UI 的静态目录；没装（未 fetch）时返回空串 */
export function transmissionWebDir(): string {
  const candidates = [
    process.env.COLANAS_TRANSMISSION_WEB_DIR || '',
    // 中文 Web UI（MIT，transmission-web-control）：官方 3.00 前端没有语言机制，
    // 中文用户打开是整页英文；优先用带 zh_CN 语言包的中文前端，缺了再回退官方包。
    path.resolve(process.cwd(), 'vendor', 'transmission-web-control'),
    path.resolve(__dirname, '..', '..', '..', 'vendor', 'transmission-web-control'),
    path.resolve(process.cwd(), 'vendor', 'transmission-web'),
    path.resolve(__dirname, '..', '..', '..', 'vendor', 'transmission-web'),
  ].filter(Boolean);
  for (const dir of candidates) {
    try {
      if (fs.existsSync(path.join(dir, 'index.html'))) return dir;
    } catch {
      /* 下一个候选 */
    }
  }
  return '';
}

function readCookie(header: string | undefined, name: string): string {
  if (!header) return '';
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    if (part.slice(0, idx).trim() === name) return part.slice(idx + 1).trim();
  }
  return '';
}

export interface WebUiDeps {
  /** 当前 transmission 配置（可能是异步的：没配置时内核会去探测本机） */
  cfg: () => TransmissionConfig | null | Promise<TransmissionConfig | null>;
}

export function registerTransmissionWebUi(
  app: FastifyInstance,
  k: KernelApi,
  deps: WebUiDeps,
): void {
  // 🔴 官方 Web UI 3.00 的 jQuery 用的是非标准 `Content-Type: json`
  //    （javascript/remote.js 里 `contentType: 'json'`），Fastify 默认只认
  //    application/json / text/plain，会直接 415 —— 页面能打开但**一条下载信息都没有**。
  //    在 onRequest 阶段（早于 content type parser）把请求头规范掉最可靠：
  //    非标准 media type 注册成 parser 在部分 Fastify 版本里仍会被判非法。
  app.addHook('onRequest', async (req) => {
    if (!req.url.startsWith('/transmission/')) return;
    const ct = req.headers['content-type'];
    if (typeof ct === 'string' && /^json(;|$)/i.test(ct.trim())) {
      req.headers['content-type'] = 'application/json';
    }
  });

  const authorized = async (req: FastifyRequest): Promise<boolean> => {
    const cookie = readCookie(req.headers.cookie, COOKIE);
    if (!cookie) return false;
    const secret = await resolveSecret(k.paths.dataDir);
    return verifyToken(cookie, secret) != null;
  };

  const serveStatic = async (req: FastifyRequest, reply: FastifyReply, rel: string) => {
    const dir = transmissionWebDir();
    if (!dir) {
      return reply
        .code(503)
        .type('text/html; charset=utf-8')
        .send(
          '<h3>transmission Web UI 还没装</h3><p>在仓库根目录跑一次 ' +
            '<code>npm run webui</code>（会把官方前端下载到 vendor/transmission-web）。</p>',
        );
    }
    const clean = rel.replace(/\\/g, '/').replace(/(^|\/)\.\.(\/|$)/g, '/');
    const file = path.join(dir, clean === '' || clean === '/' ? 'index.html' : clean);
    if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      return reply.code(404).type('text/plain; charset=utf-8').send('not found');
    }
    const type = MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream';
    return reply.code(200).type(type).send(fs.readFileSync(file));
  };

  /** 静态页入口：先验票据 → 种 Cookie → 302 掉 query → 正常出页面 */
  const entry = async (req: FastifyRequest, reply: FastifyReply, rel: string) => {
    const query = (req.query || {}) as { t?: string };
    const ticket = String(query.t || '').trim();
    if (ticket) {
      const secret = await resolveSecret(k.paths.dataDir);
      if (!verifyToken(ticket, secret)) {
        return reply.code(401).type('text/html; charset=utf-8').send('票据无效，请重新从应用里打开。');
      }
      reply.header(
        'set-cookie',
        `${COOKIE}=${ticket}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${COOKIE_MAX_AGE}`,
      );
      const clean = req.url.replace(/([?&])t=[^&]*/g, '$1').replace(/[?&]$/, '');
      return reply.redirect(clean || '/transmission/web/');
    }
    if (!(await authorized(req))) {
      return reply
        .code(401)
        .type('text/html; charset=utf-8')
        .send(
          '<h3>未授权</h3><p>请回到 ColaNasOs →「下载器」，点右上角「完整界面」进入。</p>',
        );
    }
    return serveStatic(req, reply, rel);
  };

  // 🔴 这几条是「静态页/代理」，不是给客户端调的 API。
  // 不 hide 的话 gen 会把它们写进 openapi.json，gen:client 又会拿通配符 `*`
  // 生成 `getTransmissionWeb({required String *})` 这种非法 Dart，直接编译不过。
  const hidden = { schema: { hide: true } };
  app.get('/transmission', hidden, (req, reply) => reply.redirect('/transmission/web/'));
  app.get('/transmission/web', hidden, (req, reply) => reply.redirect('/transmission/web/'));
  app.get('/transmission/web/', hidden, (req, reply) => entry(req, reply, 'index.html'));
  app.get('/transmission/web/*', hidden, (req, reply) => {
    const wildcard = String((req.params as Record<string, unknown>)['*'] || '');
    return entry(req, reply, wildcard);
  });

  /** RPC 反代：把同源请求打到用户配置的 RPC 地址（Basic 认证 + session-id 原样透传） */
  const proxy = async (req: FastifyRequest, reply: FastifyReply, target: string) => {
    if (!(await authorized(req))) {
      return reply.code(401).send({ error: Err.unauthorized });
    }
    const cfg = await deps.cfg();
    if (!cfg?.url) return reply.code(503).send({ error: 'transmission 未配置' });

    const rawType = String(req.headers['content-type'] || 'application/json').trim();
    const headers: Record<string, string> = {
      // 官方前端的 `json` 不是合法媒体类型，daemon 只认 application/json。
      'content-type': /^json(;|$)/i.test(rawType) ? 'application/json' : rawType,
    };
    const session = req.headers['x-transmission-session-id'];
    if (session) headers['x-transmission-session-id'] = String(session);
    if (cfg.username) {
      headers.authorization =
        'Basic ' + Buffer.from(`${cfg.username}:${cfg.password ?? ''}`).toString('base64');
    }

    let body: string | undefined;
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      body = typeof req.body === 'string' ? req.body : JSON.stringify(req.body ?? {});
    }

    try {
      const res = await fetch(target, { method: req.method, headers, body });
      const text = await res.text();
      const sid = res.headers.get('x-transmission-session-id');
      if (sid) reply.header('x-transmission-session-id', sid);
      const type = res.headers.get('content-type') || 'application/json';
      return reply.code(res.status).type(type).send(text);
    } catch (err) {
      return reply
        .code(502)
        .send({ error: 'proxyFailed', message: String((err as Error)?.message || err) });
    }
  };

  app.all('/transmission/rpc', hidden, async (req, reply) => {
    const cfg = await deps.cfg();
    return proxy(req, reply, cfg?.url || '');
  });

  // Web UI 里「添加种子文件」走这个 multipart 端点；只透传，不解析
  app.all('/transmission/upload', hidden, async (req, reply) => {
    const cfg = await deps.cfg();
    const base = cfg?.url ? cfg.url.replace(/\/rpc\/?$/, '') : '';
    return proxy(req, reply, `${base}/upload`);
  });
}
