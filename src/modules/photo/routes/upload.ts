import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import { TAG } from '../util';
import { scanLibrary, type LibraryRow } from '../scan';
import { isImageFile } from '../exif';
import { absoluteInput, filesRoot, isAbsoluteInput, resolveInRoot } from '../../files/fs-root';

/**
 * 相册网页上传（SP3-02 二期）：浏览器选图 → 原始流写入来源目录 → 只扫该目录入库。
 *
 * 与 mount 上传同一条约定：`application/x-colanas-upload` 原始流（不带 multipart），
 * 因为生成的 Dart client 只会发 JSON。单张上限 64 MB；同名自动加 `-1/-2` 后缀。
 */
const MAX_UPLOAD_BYTES = 64 * 1024 * 1024;
const MAX_NAME_LEN = 200;

const UploadQuery = Type.Object({
  libraryId: Type.String({ minLength: 1 }),
  /** 相对来源目录的目录（缺省 `手机上传/YYYY-MM`） */
  dir: Type.Optional(Type.String({ maxLength: 400 })),
  fileName: Type.String({ minLength: 1, maxLength: MAX_NAME_LEN }),
});

const UploadResponse = Type.Object({
  ok: Type.Boolean(),
  path: Type.String({ description: '相对来源目录的最终路径' }),
  indexed: Type.Integer(),
  size: Type.Integer(),
});

function defaultDir(): string {
  const now = new Date();
  return `手机上传/${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

function safeName(raw: string): string {
  // 文件名要保留中文/空格，只去掉控制字符（NUL..US）
  // eslint-disable-next-line no-control-regex
  const base = path.basename(String(raw || '')).replace(/[\u0000-\u001f]/g, '').trim();
  return base.slice(0, MAX_NAME_LEN);
}

/** 同名文件不覆盖：`a.jpg` → `a-1.jpg` …（最多 100 次） */
async function uniqueTarget(dirAbs: string, name: string): Promise<string> {
  const ext = path.extname(name);
  const stem = ext ? name.slice(0, -ext.length) : name;
  let candidate = path.join(dirAbs, name);
  for (let i = 1; i <= 100; i += 1) {
    try {
      await fsp.access(candidate);
    } catch {
      return candidate;
    }
    candidate = path.join(dirAbs, `${stem}-${i}${ext}`);
  }
  return candidate;
}

export async function registerPhotoUpload(app: FastifyInstance, k: KernelApi): Promise<void> {
  if (!app.hasContentTypeParser('application/x-colanas-upload')) {
    app.addContentTypeParser('application/x-colanas-upload', (_req, payload, done) => {
      done(null, payload);
    });
  }

  app.post(
    '/api/v1/photo/upload',
    secured('photo:write', {
      validatorCompiler: (() => () => true) as never,
      schema: {
        operationId: 'photoUpload',
        tags: TAG,
        summary: '上传照片到相册来源（application/x-colanas-upload 原始流）',
        querystring: UploadQuery,
        body: Type.Unsafe({ type: 'string', format: 'binary' }),
        response: {
          200: UploadResponse,
          400: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
          404: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
          413: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
        },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { libraryId?: string; dir?: string; fileName?: string };
      const row = (
        await sql<LibraryRow>`select * from photo_libraries where id = ${q.libraryId || ''}`.execute(
          k.db,
        )
      ).rows[0];
      if (!row) {
        return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
      }

      const name = safeName(q.fileName || '');
      if (!name || !isImageFile(name)) {
        return reply
          .code(400)
          .send({ error: Err.unsupported, message: 'unsupported image type' });
      }

      const relDir = (q.dir || defaultDir())
        .replace(/\\/g, '/')
        .replace(/^\/+|\/+$/g, '');
      if (!relDir || relDir.split('/').some((seg) => seg === '..' || seg === '')) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid dir' });
      }

      // 来源根：绝对目录（任意盘符）或 files 根内相对目录
      let rootAbs: string;
      try {
        rootAbs = isAbsoluteInput(row.root_path)
          ? path.resolve(absoluteInput(row.root_path))
          : resolveInRoot(filesRoot(), row.root_path);
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'source missing' });
      }

      const dirAbs = path.resolve(rootAbs, relDir);
      if (dirAbs !== rootAbs && !dirAbs.startsWith(rootAbs + path.sep)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'dir escapes library' });
      }
      await fsp.mkdir(dirAbs, { recursive: true });
      const target = await uniqueTarget(dirAbs, name);

      let bytes = 0;
      const limit = new Transform({
        transform(chunk: Buffer, _enc, callback) {
          bytes += chunk.length;
          if (bytes > MAX_UPLOAD_BYTES) {
            callback(new Error('upload too large'));
            return;
          }
          callback(null, chunk);
        },
      });

      try {
        await pipeline(req.raw, limit, fs.createWriteStream(target));
      } catch (err) {
        await fsp.rm(target, { force: true }).catch(() => undefined);
        const tooLarge = err instanceof Error && err.message === 'upload too large';
        return reply
          .code(tooLarge ? 413 : 400)
          .send({
            error: tooLarge ? Err.tooLarge : Err.badRequest,
            message: tooLarge ? 'image exceeds 64 MB' : String(err),
          });
      }

      let size = bytes;
      try {
        size = (await fsp.stat(target)).size;
      } catch {
        /* 用已写字节数兜底 */
      }

      // 只扫刚上传的目录：增量入库，不触发整库 walk
      let indexed = 0;
      try {
        const result = await scanLibrary(k.db, row, 20000, relDir);
        indexed = Number(result.added ?? 0);
      } catch (err) {
        k.log.warn({ err, library: row.name }, 'photo upload: scan after upload failed');
      }

      return {
        ok: true,
        path: `${relDir}/${path.basename(target)}`,
        indexed,
        size,
      };
    },
  );
}