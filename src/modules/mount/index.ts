import crypto from 'node:crypto';
import fs from 'node:fs';
import type { Readable } from 'node:stream';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { ServerModule } from '../../../kernel/types';
import {
  joinRemote,
  rcloneAvailable,
  rcloneDeleteFile,
  rcloneDownload,
  rcloneList,
  rcloneMkdir,
  rcloneUpload,
} from './rclone';
import { openSecret, sealSecret } from './secrets';
import { MOUNT_SCHEMAS } from './schemas';
import { davDelete, davList, davMkdir, davOpen, davTest, davUpload, mountError } from './webdav';
import { Err } from '../../../kernel/errors';
import type { FastifyReply } from 'fastify';

/**
 * SP3-07 fileMount：远程挂载（WebDAV / rclone 后端）。
 *
 *   POST /api/v1/mount/mounts         新建挂载（凭据 AES-256-GCM 加密落库）
 *   GET  /api/v1/mount/mounts         挂载列表（不含密码）
 *   POST /api/v1/mount/mounts/remove  删除挂载
 *   POST /api/v1/mount/mounts/test    连接测试（同时更新 status / lastError）
 *   GET  /api/v1/mount/list           浏览远程目录（相对挂载根）
 *   GET  /api/v1/mount/download       下载（WebDAV 透传 Range；rclone 落临时文件）
 *   POST /api/v1/mount/upload         上传（application/x-colanas-upload 原始流）
 *   POST /api/v1/mount/mkdir          新建目录
 *   POST /api/v1/mount/delete         删除文件（不删目录，避免误删整棵）
 *
 * 设计取舍：**不做 FUSE 真挂载**（Windows 需 WinFsp、Linux 需 fuse，跨端一致性差），
 * 改为服务端代理读写 —— 客户端拿到的是统一的「远程目录」体验。
 * SMB / NFS / 网盘统一走 rclone（本机未安装时明确 501）。
 */
const TAG = ['mount'];

interface MountRow {
  id: string;
  name: string;
  kind: string;
  base_url: string;
  username: string;
  secret: string;
  root_path: string;
  read_only: number;
  status: string;
  last_error: string | null;
  last_check_at: number | null;
  created_at: number;
}

function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}

function toMount(r: MountRow) {
  return {
    id: r.id,
    name: r.name,
    kind: r.kind,
    baseUrl: r.base_url,
    username: r.username,
    rootPath: r.root_path,
    readOnly: r.read_only === 1,
    status: r.status,
    lastError: r.last_error,
    lastCheckAt: r.last_check_at,
    createdAt: r.created_at,
  };
}

function normalizeRel(input: string | undefined): string {
  return (input || '').replace(/\\/g, '/').replace(/^\/+|\/+$/g, '');
}

export const mount: ServerModule = {
  id: 'mount',
  prefix: '/api/v1/mount',
  permissions: ['mount:read', 'mount:write'],

  migrations: [
    {
      id: '034_remote_mounts',
      async up(db) {
        await sql`
          create table if not exists remote_mounts (
            id text primary key,
            name text not null,
            kind text not null,
            base_url text not null,
            username text not null default '',
            secret text not null default '',
            root_path text not null default '',
            read_only integer not null default 0,
            status text not null default 'unknown',
            last_error text,
            last_check_at integer,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_remote_mounts_kind on remote_mounts(kind, created_at desc)
        `.execute(db);
      },
    },
  ],

  async register(app, k) {
    for (const schema of MOUNT_SCHEMAS) app.addSchema(schema);
    const ref = (id: string) => ({ $ref: `${id}#` });

    // 上传用原始流，避开 files 模块已注册的 octet-stream（同类型重复注册会冲突）
    app.addContentTypeParser('application/x-colanas-upload', (_req, payload, done) => {
      done(null, payload);
    });

    const loadMount = async (id: string): Promise<MountRow | null> => {
      const res = await sql<MountRow>`select * from remote_mounts where id = ${id}`.execute(k.db);
      return res.rows[0] ?? null;
    };

    const markStatus = async (id: string, status: string, lastError: string | null) => {
      await sql`
        update remote_mounts
           set status = ${status}, last_error = ${lastError}, last_check_at = ${Math.floor(Date.now() / 1000)}
         where id = ${id}
      `.execute(k.db);
    };

    // 挂载状态后台刷新（蓝图 §56）：远程后端没有事件，只能周期性探测；
    // `COLANAS_MOUNT_POLL_MS=0` 关闭（只保留页面里的手动「连接测试」）
    const mountPollEnv = Number(process.env.COLANAS_MOUNT_POLL_MS);
    const mountPollMs = Number.isFinite(mountPollEnv) && mountPollEnv >= 0 ? mountPollEnv : 10 * 60 * 1000;
    if (mountPollMs > 0) {
      const timer = setInterval(() => {
        void (async () => {
          const rows = (await sql<MountRow>`select * from remote_mounts`.execute(k.db)).rows;
          for (const row of rows) {
            try {
              if (row.kind === 'webdav') await davList(await davConfig(row), '');
              else await rcloneList(remoteSpec(row, ''));
              await markStatus(row.id, 'ok', null);
            } catch (err) {
              const e = err as Error & { statusCode?: number };
              await markStatus(
                row.id,
                e.statusCode === 401 ? 'unauthorized' : 'error',
                String(e.message || e).slice(0, 300),
              );
            }
          }
        })().catch((err) => k.log.warn({ error: String(err) }, 'mount poll failed'));
      }, mountPollMs);
      timer.unref?.();
    }

    /** 统一错误映射：mountError 的 401 / 501 原样透出，其余 502 */
    const fail = (reply: FastifyReply, err: unknown) => {
      const e = err as Error & { statusCode?: number };
      const code = e.statusCode && [400, 401, 404, 501].includes(e.statusCode) ? e.statusCode : 502;
      return reply.code(code).send({ error: code === 401 ? 'unauthorized' : 'upstream', message: e.message });
    };

    const passwordOf = async (row: MountRow): Promise<string> => {
      if (!row.secret) return '';
      const plain = openSecret(row.secret);
      if (plain === null) throw mountError(401, '挂载凭据已失效（密钥变更），请重新填写密码');
      return plain;
    };

    const davConfig = async (row: MountRow) => ({
      baseUrl: row.base_url,
      username: row.username,
      password: await passwordOf(row),
      rootPath: row.root_path,
    });

    const remoteSpec = (row: MountRow, relPath: string) =>
      joinRemote(row.base_url, [row.root_path, normalizeRel(relPath)].filter(Boolean).join('/'));

    // ---------------------------------------------------------------- 挂载 CRUD

    app.post(
      '/api/v1/mount/mounts',
      secured('mount:write', {
        schema: {
          operationId: 'mountCreate',
          tags: TAG,
          summary: '新建远程挂载（WebDAV / rclone）',
          body: ref('MountCreateBody'),
          response: {
            200: ref('MountItem'),
            400: ref('MountErrorResponse'),
            409: ref('MountErrorResponse'),
          },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as {
          name?: string;
          kind?: string;
          baseUrl?: string;
          username?: string;
          password?: string;
          rootPath?: string;
          readOnly?: boolean;
        };
        const name = (body.name || '').trim();
        const kind = (body.kind || '').trim();
        const baseUrl = (body.baseUrl || '').trim();
        if (!name || !baseUrl) {
          return reply.code(400).send({ error: Err.badRequest, message: 'name and baseUrl required' });
        }
        if (kind !== 'webdav' && kind !== 'rclone') {
          return reply.code(400).send({ error: Err.badRequest, message: 'kind must be webdav or rclone' });
        }
        if (kind === 'webdav') {
          let u: URL;
          try {
            u = new URL(baseUrl);
          } catch {
            return reply.code(400).send({ error: Err.badRequest, message: 'baseUrl 不是合法 URL' });
          }
          if (u.protocol !== 'http:' && u.protocol !== 'https:') {
            return reply.code(400).send({ error: Err.badRequest, message: 'baseUrl 只支持 http/https' });
          }
        }

        const dup = await sql<{ id: string }>`
          select id from remote_mounts where name = ${name} and kind = ${kind}
        `.execute(k.db);
        if (dup.rows.length > 0) {
          return reply.code(409).send({ error: Err.conflict, message: '同名挂载已存在' });
        }

        const id = newId();
        const now = Math.floor(Date.now() / 1000);
        const password = body.password || '';
        await sql`
          insert into remote_mounts
            (id, name, kind, base_url, username, secret, root_path, read_only, status, last_error, last_check_at, created_at)
          values
            (${id}, ${name}, ${kind}, ${baseUrl}, ${body.username || ''},
             ${password ? sealSecret(password) : ''}, ${normalizeRel(body.rootPath)}, ${body.readOnly ? 1 : 0},
             'unknown', null, null, ${now})
        `.execute(k.db);

        const row = await loadMount(id);
        return row ? toMount(row) : { id, name, kind, baseUrl, username: body.username || '', rootPath: '', readOnly: false, status: 'unknown', lastError: null, lastCheckAt: null, createdAt: now };
      },
    );

    app.get(
      '/api/v1/mount/mounts',
      secured('mount:read', {
        schema: {
          operationId: 'mountList',
          tags: TAG,
          summary: '挂载列表（不含密码）',
          response: { 200: ref('MountListResponse') },
        },
      }),
      async () => {
        const res = await sql<MountRow>`
          select * from remote_mounts order by created_at desc, id limit 200
        `.execute(k.db);
        return { items: res.rows.map(toMount) };
      },
    );

    app.post(
      '/api/v1/mount/mounts/remove',
      secured('mount:write', {
        schema: {
          operationId: 'mountRemove',
          tags: TAG,
          summary: '删除挂载（只删配置，不动远程数据）',
          body: ref('MountRemoveBody'),
          response: { 200: ref('MountOkResponse'), 404: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const row = body.id ? await loadMount(body.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        await sql`delete from remote_mounts where id = ${row.id}`.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/mount/mounts/test',
      secured('mount:write', {
        schema: {
          operationId: 'mountTest',
          tags: TAG,
          summary: '连接测试（同时更新 status / lastError）',
          body: ref('MountTestBody'),
          response: { 200: ref('MountItem'), 404: ref('MountErrorResponse'), 502: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string };
        const row = body.id ? await loadMount(body.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });

        try {
          if (row.kind === 'webdav') {
            await davTest(await davConfig(row));
          } else {
            if (!(await rcloneAvailable())) {
              throw mountError(501, 'rclone 不可用（安装后设置 COLANAS_RCLONE 或加入 PATH）');
            }
            await rcloneList(remoteSpec(row, ''));
          }
          await markStatus(row.id, 'ok', null);
          const fresh = await loadMount(row.id);
          return fresh ? toMount(fresh) : toMount(row);
        } catch (err) {
          const e = err as Error & { statusCode?: number };
          await markStatus(row.id, 'error', e.message);
          return fail(reply, err);
        }
      },
    );

    // ---------------------------------------------------------------- 浏览 / 传输

    app.get(
      '/api/v1/mount/list',
      secured('mount:read', {
        schema: {
          operationId: 'mountBrowse',
          tags: TAG,
          summary: '浏览远程目录（相对挂载根）',
          querystring: ref('MountBrowseQuery'),
          response: { 200: ref('MountBrowseResponse'), 404: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; path?: string };
        const row = q.id ? await loadMount(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        const rel = normalizeRel(q.path);

        try {
          const items =
            row.kind === 'webdav'
              ? await davList(await davConfig(row), rel)
              : await rcloneList(remoteSpec(row, rel));
          await markStatus(row.id, 'ok', null);
          return { path: rel, items };
        } catch (err) {
          return fail(reply, err);
        }
      },
    );

    app.get(
      '/api/v1/mount/download-url',
      secured('mount:read', {
        schema: {
          operationId: 'mountDownloadUrl',
          tags: TAG,
          summary: '生成带短期令牌的下载地址（可直接交给外部下载器）',
          querystring: ref('MountPathQuery'),
          response: { 200: ref('MountDownloadUrlResponse'), 404: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; path?: string };
        const row = q.id ? await loadMount(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        const rel = normalizeRel(q.path);
        if (!rel) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });

        const expiresInSec = 300;
        const token = k.auth.sign({ sub: 'mount-download', scopes: ['mount:read'] }, expiresInSec);
        return {
          url:
            `/api/v1/mount/download?id=${encodeURIComponent(row.id)}` +
            `&path=${encodeURIComponent(rel)}&token=${encodeURIComponent(token)}`,
          expiresInSec,
        };
      },
    );

    app.get(
      '/api/v1/mount/download',
      secured('mount:read', {
        schema: {
          operationId: 'mountDownload',
          tags: TAG,
          summary: '下载远程文件（WebDAV 透传 Range）',
          querystring: ref('MountPathQuery'),
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; path?: string };
        const row = q.id ? await loadMount(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        const rel = normalizeRel(q.path);
        if (!rel) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });

        try {
          if (row.kind === 'webdav') {
            const headers: Record<string, string> = {};
            if (req.headers.range) headers.range = String(req.headers.range);
            if (req.headers['if-none-match']) headers['if-none-match'] = String(req.headers['if-none-match']);
            const upstream = await davOpen(await davConfig(row), rel, headers);
            const passthrough = [
              'content-type',
              'content-length',
              'content-range',
              'accept-ranges',
              'etag',
              'last-modified',
            ];
            for (const h of passthrough) {
              const v = upstream.headers[h];
              if (typeof v === 'string') reply.header(h, v);
            }
            reply.code(upstream.statusCode ?? 200);
            return reply.send(upstream);
          }

          const { file, size } = await rcloneDownload(remoteSpec(row, rel));
          reply.header('content-length', String(size)).type('application/octet-stream');
          const stream = fs.createReadStream(file);
          stream.on('close', () => fs.rmSync(file, { force: true }));
          return reply.send(stream);
        } catch (err) {
          return fail(reply, err);
        }
      },
    );

    app.post(
      '/api/v1/mount/upload',
      secured('mount:write', {
        validatorCompiler: (() => () => true) as any,
        schema: {
          operationId: 'mountUpload',
          tags: TAG,
          summary: '上传（application/x-colanas-upload 原始流）',
          querystring: ref('MountUploadQuery'),
          body: Type.Unsafe({ type: 'string', format: 'binary' }),
          response: { 200: ref('MountOkResponse'), 404: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const q = (req.query || {}) as { id?: string; path?: string; size?: number };
        const row = q.id ? await loadMount(q.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        if (row.read_only === 1) return reply.code(400).send({ error: Err.badRequest, message: 'readOnly mount' });
        const rel = normalizeRel(q.path);
        if (!rel) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });

        try {
          const body = req.body as Readable;
          const size = Number(q.size);
          if (row.kind === 'webdav') {
            await davUpload(await davConfig(row), rel, body, Number.isFinite(size) ? size : undefined);
          } else {
            await rcloneUpload(body, remoteSpec(row, rel));
          }
          return { ok: true };
        } catch (err) {
          return fail(reply, err);
        }
      },
    );

    app.post(
      '/api/v1/mount/mkdir',
      secured('mount:write', {
        schema: {
          operationId: 'mountMkdir',
          tags: TAG,
          summary: '新建远程目录',
          body: ref('MountPathBody'),
          response: { 200: ref('MountOkResponse'), 404: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; path?: string };
        const row = body.id ? await loadMount(body.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        if (row.read_only === 1) return reply.code(400).send({ error: Err.badRequest, message: 'readOnly mount' });
        const rel = normalizeRel(body.path);
        if (!rel) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });

        try {
          if (row.kind === 'webdav') await davMkdir(await davConfig(row), rel);
          else await rcloneMkdir(remoteSpec(row, rel));
          return { ok: true };
        } catch (err) {
          return fail(reply, err);
        }
      },
    );

    app.post(
      '/api/v1/mount/delete',
      secured('mount:write', {
        schema: {
          operationId: 'mountDelete',
          tags: TAG,
          summary: '删除远程文件（不删目录）',
          body: ref('MountPathBody'),
          response: { 200: ref('MountOkResponse'), 404: ref('MountErrorResponse') },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; path?: string };
        const row = body.id ? await loadMount(body.id) : null;
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'mount not found' });
        if (row.read_only === 1) return reply.code(400).send({ error: Err.badRequest, message: 'readOnly mount' });
        const rel = normalizeRel(body.path);
        if (!rel) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });

        try {
          if (row.kind === 'webdav') await davDelete(await davConfig(row), rel);
          else await rcloneDeleteFile(remoteSpec(row, rel));
          return { ok: true };
        } catch (err) {
          return fail(reply, err);
        }
      },
    );
  },
};