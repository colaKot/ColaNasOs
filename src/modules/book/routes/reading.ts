import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { secured } from '../../../../kernel/route';
import { downloadHandler } from '../../files/download';
import { filesRoot, resolveAnyPath } from '../../files/fs-root';
import { mimeOf, readBookCover, isBookFile } from '../metadata';
import { readPage, readToc } from '../reader';
import { Err } from '../../../../kernel/errors';
import { TAG, COVER_EXTENSIONS } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { BookHelpers } from '../helpers';

/** 封面 / 阅读 */
export async function registerBookReading(app: FastifyInstance, k: KernelApi, h: BookHelpers): Promise<void> {
    // ---------------------------------------------------------------- 封面 / 阅读

    app.get(
      '/api/v1/book/cover',
      secured('book:read', {
        schema: {
          operationId: 'bookCover',
          tags: TAG,
          summary: '封面（epub / cbz 内嵌图，首次访问提取并缓存）',
          querystring: h.ref('BookIdQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadBook(q.id, '') : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });
        if (row.has_cover !== 1) {
          return reply.code(404).send({ error: Err.notFound, message: 'no embedded cover' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        if (!fs.existsSync(abs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        const hash = crypto
          .createHash('sha1')
          .update(`${row.rel_path}:${row.mtime}`)
          .digest('hex')
          .slice(0, 32);
        const dir = path.join(k.paths.dataDir, 'book-covers');

        let hitExt: string | null = null;
        for (const ext of COVER_EXTENSIONS) {
          if (fs.existsSync(path.join(dir, `${hash}.${ext}`))) {
            hitExt = ext;
            break;
          }
        }
        k.cache.record('book.cover', hitExt !== null);
        if (hitExt) {
          reply.type(mimeOf(hitExt)).header('cache-control', 'public, max-age=86400');
          return reply.send(fs.createReadStream(path.join(dir, `${hash}.${hitExt}`)));
        }

        const cover = await readBookCover(abs);
        if (!cover) {
          return reply.code(404).send({ error: Err.notFound, message: 'cover unavailable' });
        }

        fs.mkdirSync(dir, { recursive: true });
        const out = path.join(dir, `${hash}.${cover.ext}`);
        fs.writeFileSync(out, cover.data);
        reply.type(mimeOf(cover.ext)).header('cache-control', 'public, max-age=86400');
        return reply.send(fs.createReadStream(out));
      },
    );

    app.get(
      '/api/v1/book/toc',
      secured('book:read', {
        schema: {
          operationId: 'bookToc',
          tags: TAG,
          summary: '内置阅读器目录（epub spine / txt 分章 / cbz 图片页）',
          querystring: h.ref('BookIdQuery'),
          response: {
            200: h.ref('BookTocResponse'),
            400: h.ref('BookErrorResponse'),
            404: h.ref('BookErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadBook(q.id, '') : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        if (!fs.existsSync(abs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        const toc = await readToc(abs);
        if (toc.kind === 'none') {
          return reply
            .code(400)
            .send({ error: Err.unsupported, message: '该格式暂不支持内置阅读器（支持 epub / txt / cbz / pdf）' });
        }
        // pdf 由客户端渲染：页数统计失败（total=0）也允许打开，页数以渲染器为准
        if (toc.total === 0 && toc.kind !== 'pdf') {
          return reply.code(400).send({ error: Err.empty, message: '未解析出可读内容' });
        }
        return toc;
      },
    );

    app.get(
      '/api/v1/book/page',
      secured('book:read', {
        schema: {
          operationId: 'bookPage',
          tags: TAG,
          summary: '内置阅读器单页（文本页返回纯文本，图片页返回 base64）',
          querystring: h.ref('BookPageQuery'),
          response: {
            200: h.ref('BookPageResponse'),
            400: h.ref('BookErrorResponse'),
            404: h.ref('BookErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; index?: number };
        const row = q.id ? await h.loadBook(q.id, '') : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });
        const index = Number(q.index);
        if (!Number.isInteger(index) || index < 0) {
          return reply.code(400).send({ error: Err.badRequest, message: 'index must be >= 0' });
        }

        let abs: string;
        try {
          abs = resolveAnyPath(filesRoot(), row.rel_path);
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }
        if (!fs.existsSync(abs)) {
          return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
        }

        // pdf 由服务端渲染成 PNG，PNG 缓存在 dataDir/book-pdf
        const page = await readPage(abs, index, k.paths.dataDir);
        if (!page) {
          return reply.code(404).send({ error: Err.notFound, message: 'page unavailable' });
        }
        return page;
      },
    );

    app.get(
      '/api/v1/book/file-url',
      secured('book:read', {
        schema: {
          operationId: 'bookFileUrl',
          tags: TAG,
          summary: '生成带短期令牌的阅读地址（可直接交给外部阅读器）',
          querystring: h.ref('BookIdQuery'),
          response: { 200: h.ref('BookFileUrlResponse'), 404: h.ref('BookErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadBook(q.id, '') : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });

        const expiresInSec = 300;
        const token = k.auth.sign({ sub: 'book-reader', scopes: ['book:read'] }, expiresInSec);
        return {
          url: `/api/v1/book/file?id=${encodeURIComponent(row.id)}&token=${encodeURIComponent(token)}`,
          expiresInSec,
        };
      },
    );

    app.get(
      '/api/v1/book/file',
      secured('book:read', {
        schema: {
          operationId: 'bookFile',
          tags: TAG,
          summary: '阅读 / 下载（支持 Range / ETag）',
          querystring: h.ref('BookIdQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string };
        const row = q.id ? await h.loadBook(q.id, '') : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'book not found' });
        return downloadHandler(req, reply, { path: row.rel_path });
      },
    );

    app.get(
      '/api/v1/book/cache',
      secured('book:read', {
        schema: {
          operationId: 'bookCacheStats',
          tags: TAG,
          summary: '封面 / PDF 页图缓存占用',
          response: { 200: h.ref('BookCacheStatsResponse') },
        },
      }),
      async () => {
        const dirs = [path.join(k.paths.dataDir, 'book-covers'), path.join(k.paths.dataDir, 'book-pdf')];
        let files = 0;
        let bytes = 0;
        for (const dir of dirs) {
          let names: string[];
          try {
            names = fs.readdirSync(dir);
          } catch {
            continue;
          }
          for (const name of names) {
            try {
              const st = fs.statSync(path.join(dir, name));
              if (st.isFile()) {
                files += 1;
                bytes += st.size;
              }
            } catch {
              /* 正在写 / 已删：跳过 */
            }
          }
        }
        return { files, bytes };
      },
    );

    app.post(
      '/api/v1/book/cache/clear',
      secured('book:write', {
        schema: {
          operationId: 'bookCacheClear',
          tags: TAG,
          summary: '清空封面 / PDF 页图缓存',
          response: { 200: h.ref('BookCacheClearResponse') },
        },
      }),
      async () => {
        const dirs = [path.join(k.paths.dataDir, 'book-covers'), path.join(k.paths.dataDir, 'book-pdf')];
        let files = 0;
        let bytes = 0;
        for (const dir of dirs) {
          let names: string[];
          try {
            names = fs.readdirSync(dir);
          } catch {
            continue;
          }
          for (const name of names) {
            const target = path.join(dir, name);
            try {
              const st = fs.statSync(target);
              if (!st.isFile()) continue;
              files += 1;
              bytes += st.size;
              fs.rmSync(target, { force: true });
            } catch {
              /* 单个文件失败不影响其它 */
            }
          }
        }
        return { files, bytes };
      },
    );
}
