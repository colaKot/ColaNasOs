import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { ServerModule } from '../../../kernel/types';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { Err } from '../../../kernel/errors';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * SP3-09 fileBackup / encryptedSpace。
 *
 * 备份：源必须在 files 根内；落 `dataDir/backups/<id>/`，逐文件 sha256 生成 manifest，
 * 恢复时按 manifest 校验后再写回。
 * 加密空间：scrypt 派生 key + AES-256-GCM；密码不落盘，每次请求携带；
 * 表里只存 salt / verifier 与每项的 nonce/tag。
 */
const TAG = ['safety'];
const MAX_FILE = 64 * 1024 * 1024;
const KEY_LEN = 32;

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const BackupRunBody = Type.Object({
  source: Type.String({ minLength: 1 }),
  /** 备份根下的相对子目录名，缺省用时间戳 */
  name: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
});

const BackupRunResponse = Type.Object({
  id: Type.String(),
  dir: Type.String(),
  files: Type.Integer(),
  bytes: Type.Integer(),
  manifest: Type.String(),
});

const BackupItem = Type.Object({
  id: Type.String(),
  source: Type.String(),
  dir: Type.String(),
  files: Type.Integer(),
  bytes: Type.Integer(),
  createdAt: Type.Integer(),
});

const BackupListResponse = Type.Object({ items: Type.Array(BackupItem) });

const RestoreBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  target: Type.String({ minLength: 1 }),
});

const RestoreResponse = Type.Object({ restored: Type.Integer(), skipped: Type.Integer() });

const VaultCreateBody = Type.Object({
  id: Type.String({ pattern: '^[a-z0-9_-]{3,32}$' }),
  password: Type.String({ minLength: 6, maxLength: 128 }),
});

const VaultPutBody = Type.Object({
  id: Type.String(),
  path: Type.String({ minLength: 1, maxLength: 512 }),
  data: Type.String(),
  password: Type.String({ minLength: 6, maxLength: 128 }),
});

const VaultGetBody = Type.Object({
  id: Type.String(),
  path: Type.String({ minLength: 1, maxLength: 512 }),
  password: Type.String({ minLength: 6, maxLength: 128 }),
});

const VaultIdBody = Type.Object({
  id: Type.String(),
  password: Type.String({ minLength: 6, maxLength: 128 }),
});

const OkResponse = Type.Object({ ok: Type.Boolean() });

const VaultItem = Type.Object({
  path: Type.String(),
  size: Type.Integer(),
  updatedAt: Type.Integer(),
});

const VaultListResponse = Type.Object({ id: Type.String(), items: Type.Array(VaultItem) });

interface VaultRow {
  id: string;
  salt: string;
  verifier: string;
}

interface VaultItemRow {
  path: string;
  file: string;
  size: number;
  updated_at: number;
}

interface BackupRow {
  id: string;
  source: string;
  dir: string;
  files: number;
  bytes: number;
  created_at: number;
}

function sha256(data: Buffer | string): string {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function deriveKey(password: string, salt: string): Buffer {
  return crypto.scryptSync(password, salt, KEY_LEN);
}

function walk(dir: string, rel = ''): string[] {
  const out: string[] = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const child = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(dir, child));
    else if (e.isFile()) out.push(child);
  }
  return out.sort();
}

export const safety: ServerModule = {
  id: 'safety',
  prefix: '/api/v1',
  permissions: ['backup:read', 'backup:write', 'vault:read', 'vault:write'],

  migrations: [
    {
      id: '002_backup_jobs',
      async up(db) {
        await sql`
          create table if not exists backup_jobs (
            id text primary key,
            source text not null,
            dir text not null,
            files integer not null default 0,
            bytes integer not null default 0,
            created_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '003_vaults',
      async up(db) {
        await sql`
          create table if not exists vaults (
            id text primary key,
            salt text not null,
            verifier text not null,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists vault_items (
            vault_id text not null,
            path text not null,
            file text not null,
            size integer not null default 0,
            updated_at integer not null,
            primary key (vault_id, path)
          )
        `.execute(db);
      },
    },
  ],

  async register(app, k) {
    const backupRoot = path.join(k.paths.dataDir, 'backups');
    const vaultRoot = path.join(k.paths.dataDir, 'vaults');

    // ---------------------------------------------------------------- 备份
    app.post(
      '/api/v1/backup/run',
      secured('backup:write', {
        schema: {
          operationId: 'backupRun',
          tags: TAG,
          summary: '备份一个目录（逐文件 sha256 清单）',
          body: BackupRunBody,
          response: { 200: BackupRunResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { source?: string; name?: string };
        if (!body.source) return reply.code(400).send({ error: Err.badRequest, message: 'source required' });

        let src: string;
        try {
          src = resolveInRoot(filesRoot(), body.source);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'source escapes root' });
        }
        if (!fs.existsSync(src) || !fs.statSync(src).isDirectory()) {
          return reply.code(404).send({ error: Err.notFound, message: 'source dir not found' });
        }

        const id = body.name && /^[a-zA-Z0-9._-]{1,64}$/.test(body.name) ? body.name : String(Date.now());
        const dir = path.join(backupRoot, id);
        if (fs.existsSync(path.join(dir, 'manifest.json'))) {
          return reply.code(400).send({ error: Err.conflict, message: `backup exists: ${id}` });
        }

        const files = walk(src);
        const manifest: Record<string, string> = {};
        let bytes = 0;
        fs.mkdirSync(dir, { recursive: true });
        for (const rel of files) {
          const from = path.join(src, rel);
          const to = path.join(dir, 'data', rel);
          fs.mkdirSync(path.dirname(to), { recursive: true });
          fs.copyFileSync(from, to);
          const buf = fs.readFileSync(to);
          manifest[rel] = sha256(buf);
          bytes += buf.length;
        }
        fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');

        await sql`
          insert into backup_jobs (id, source, dir, files, bytes, created_at)
          values (${id}, ${body.source}, ${dir}, ${files.length}, ${bytes}, ${Math.floor(Date.now() / 1000)})
        `.execute(k.db);

        return { id, dir, files: files.length, bytes, manifest: path.join(dir, 'manifest.json') };
      },
    );

    app.get(
      '/api/v1/backup/list',
      secured('backup:read', {
        schema: {
          operationId: 'backupList',
          tags: TAG,
          summary: '列出备份',
          response: { 200: BackupListResponse },
        },
      }),
      async () => {
        const res = await sql<BackupRow>`select * from backup_jobs order by created_at desc limit 200`.execute(k.db);
        return {
          items: res.rows.map((r) => ({
            id: r.id,
            source: r.source,
            dir: r.dir,
            files: r.files,
            bytes: r.bytes,
            createdAt: r.created_at,
          })),
        };
      },
    );

    app.post(
      '/api/v1/backup/restore',
      secured('backup:write', {
        schema: {
          operationId: 'backupRestore',
          tags: TAG,
          summary: '从备份恢复（先校验 sha256）',
          body: RestoreBody,
          response: { 200: RestoreResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; target?: string };
        if (!body.id || !body.target) {
          return reply.code(400).send({ error: Err.badRequest, message: 'id/target required' });
        }

        const res = await sql<BackupRow>`select * from backup_jobs where id = ${body.id}`.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'backup not found' });

        let manifest: Record<string, string>;
        try {
          manifest = JSON.parse(fs.readFileSync(path.join(row.dir, 'manifest.json'), 'utf8'));
        } catch {
          return reply.code(404).send({ error: Err.notFound, message: 'manifest missing' });
        }

        let target: string;
        try {
          target = resolveInRoot(filesRoot(), body.target);
        } catch {
          return reply.code(400).send({ error: Err.badRequest, message: 'target escapes root' });
        }

        let restored = 0;
        let skipped = 0;
        for (const [rel, want] of Object.entries(manifest)) {
          const from = path.join(row.dir, 'data', rel);
          if (!fs.existsSync(from)) {
            skipped += 1;
            continue;
          }
          if (sha256(fs.readFileSync(from)) !== want) {
            return reply.code(400).send({ error: Err.corrupted, message: `checksum mismatch: ${rel}` });
          }
          const to = path.join(target, rel);
          fs.mkdirSync(path.dirname(to), { recursive: true });
          fs.copyFileSync(from, to);
          restored += 1;
        }
        return { restored, skipped };
      },
    );

    // ------------------------------------------------------------ 加密空间
    const vaultDir = (id: string) => path.join(vaultRoot, id);

    const loadVault = async (id: string, password: string): Promise<VaultRow | null> => {
      const res = await sql<VaultRow>`select * from vaults where id = ${id}`.execute(k.db);
      const row = res.rows[0];
      if (!row) return null;
      const key = deriveKey(password, row.salt);
      if (sha256(key) !== row.verifier) return null;
      return row;
    };

    app.post(
      '/api/v1/vault/create',
      secured('vault:write', {
        schema: {
          operationId: 'vaultCreate',
          tags: TAG,
          summary: '创建加密空间',
          body: VaultCreateBody,
          response: { 200: OkResponse, 400: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; password?: string };
        if (!body.id || !body.password) {
          return reply.code(400).send({ error: Err.badRequest, message: 'id/password required' });
        }
        const exists = await sql`select 1 from vaults where id = ${body.id}`.execute(k.db);
        if (exists.rows.length > 0) {
          return reply.code(400).send({ error: Err.conflict, message: 'vault exists' });
        }
        const salt = crypto.randomBytes(16).toString('hex');
        const key = deriveKey(body.password, salt);
        fs.mkdirSync(vaultDir(body.id), { recursive: true });
        await sql`
          insert into vaults (id, salt, verifier, created_at)
          values (${body.id}, ${salt}, ${sha256(key)}, ${Math.floor(Date.now() / 1000)})
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/vault/put',
      secured('vault:write', {
        schema: {
          operationId: 'vaultPut',
          tags: TAG,
          summary: '写入一个文件（AES-256-GCM）',
          body: VaultPutBody,
          response: { 200: OkResponse, 400: ErrorResponse, 403: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; path?: string; data?: string; password?: string };
        if (!body.id || !body.path || body.data === undefined || !body.password) {
          return reply.code(400).send({ error: Err.badRequest, message: 'id/path/data/password required' });
        }
        const vault = await loadVault(body.id, body.password);
        if (!vault) return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });

        const plain = Buffer.from(body.data, 'base64');
        if (plain.length > MAX_FILE) {
          return reply.code(400).send({ error: Err.badRequest, message: 'file too large' });
        }

        const key = deriveKey(body.password, vault.salt);
        const nonce = crypto.randomBytes(12);
        const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
        const enc = Buffer.concat([cipher.update(plain), cipher.final()]);
        const tag = cipher.getAuthTag();

        const file = sha256(body.path);
        fs.mkdirSync(vaultDir(body.id), { recursive: true });
        fs.writeFileSync(path.join(vaultDir(body.id), file), Buffer.concat([nonce, tag, enc]));

        await sql`
          insert into vault_items (vault_id, path, file, size, updated_at)
          values (${body.id}, ${body.path}, ${file}, ${plain.length}, ${Math.floor(Date.now() / 1000)})
          on conflict(vault_id, path) do update set
            file = excluded.file, size = excluded.size, updated_at = excluded.updated_at
        `.execute(k.db);
        return { ok: true };
      },
    );

    app.post(
      '/api/v1/vault/get',
      secured('vault:read', {
        schema: {
          operationId: 'vaultGet',
          tags: TAG,
          summary: '读取并解密一个文件',
          body: VaultGetBody,
          response: { 400: ErrorResponse, 403: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; path?: string; password?: string };
        if (!body.id || !body.path || !body.password) {
          return reply.code(400).send({ error: Err.badRequest, message: 'id/path/password required' });
        }
        const vault = await loadVault(body.id, body.password);
        if (!vault) return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });

        const res = await sql<VaultItemRow>`
          select * from vault_items where vault_id = ${body.id} and path = ${body.path}
        `.execute(k.db);
        const row = res.rows[0];
        if (!row) return reply.code(404).send({ error: Err.notFound, message: 'item not found' });

        const raw = fs.readFileSync(path.join(vaultDir(body.id), row.file));
        const nonce = raw.subarray(0, 12);
        const tag = raw.subarray(12, 28);
        const enc = raw.subarray(28);
        const key = deriveKey(body.password, vault.salt);
        const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
        decipher.setAuthTag(tag);

        let plain: Buffer;
        try {
          plain = Buffer.concat([decipher.update(enc), decipher.final()]);
        } catch {
          return reply.code(400).send({ error: Err.corrupted, message: 'decrypt failed' });
        }
        return { path: body.path, size: plain.length, data: plain.toString('base64') };
      },
    );

    app.post(
      '/api/v1/vault/list',
      secured('vault:read', {
        schema: {
          operationId: 'vaultList',
          tags: TAG,
          summary: '列出加密空间条目',
          body: VaultIdBody,
          response: { 200: VaultListResponse, 403: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; password?: string };
        if (!body.id || !body.password) {
          return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });
        }
        const vault = await loadVault(body.id, body.password);
        if (!vault) return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });

        const res = await sql<VaultItemRow>`
          select * from vault_items where vault_id = ${body.id} order by path
        `.execute(k.db);
        return {
          id: body.id,
          items: res.rows.map((r) => ({ path: r.path, size: r.size, updatedAt: r.updated_at })),
        };
      },
    );

    app.post(
      '/api/v1/vault/export',
      secured('vault:read', {
        schema: {
          operationId: 'vaultExport',
          tags: TAG,
          summary: '解密导出到 files 根内的目录（保留相对路径）',
          body: Type.Object({
            id: Type.String({ minLength: 1 }),
            password: Type.String({ minLength: 1 }),
            target: Type.String({ minLength: 1 }),
          }),
          response: {
            200: Type.Object({ exported: Type.Integer(), target: Type.String() }),
            400: ErrorResponse,
            403: ErrorResponse,
          },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const body = (req.body || {}) as { id?: string; password?: string; target?: string };
        if (!body.id || !body.password || !body.target) {
          return reply.code(400).send({ error: Err.badRequest, message: 'id/password/target required' });
        }
        const vault = await loadVault(body.id, body.password);
        if (!vault) return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });

        const targetAbs = resolveInRoot(filesRoot(), body.target);
        if (fs.existsSync(targetAbs) && !fs.statSync(targetAbs).isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'target must be a directory' });
        }

        const rows = (
          await sql<VaultItemRow>`select * from vault_items where vault_id = ${body.id}`.execute(k.db)
        ).rows;
        const key = deriveKey(body.password, vault.salt);
        let exported = 0;
        for (const row of rows) {
          const rel = String(row.path).replace(/\\/g, '/');
          // 空间内的路径由用户写入，导出一律拒绝 `..` / 空段，避免写到目标目录之外
          if (rel.split('/').some((seg) => seg === '' || seg === '..')) continue;
          const raw = fs.readFileSync(path.join(vaultDir(body.id), row.file));
          const nonce = raw.subarray(0, 12);
          const tag = raw.subarray(12, 28);
          const data = raw.subarray(28);
          const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
          decipher.setAuthTag(tag);
          const plain = Buffer.concat([decipher.update(data), decipher.final()]);
          const out = path.join(targetAbs, rel);
          fs.mkdirSync(path.dirname(out), { recursive: true });
          fs.writeFileSync(out, plain);
          exported += 1;
        }
        return { exported, target: body.target };
      },
    );

    app.post(
      '/api/v1/vault/delete',
      secured('vault:write', {
        schema: {
          operationId: 'vaultDelete',
          tags: TAG,
          summary: '删除加密空间条目',
          body: VaultGetBody,
          response: { 200: OkResponse, 403: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { id?: string; path?: string; password?: string };
        if (!body.id || !body.path || !body.password) {
          return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });
        }
        const vault = await loadVault(body.id, body.password);
        if (!vault) return reply.code(403).send({ error: Err.forbidden, message: 'bad vault or password' });

        const res = await sql<VaultItemRow>`
          select * from vault_items where vault_id = ${body.id} and path = ${body.path}
        `.execute(k.db);
        const row = res.rows[0];
        if (row) fs.rmSync(path.join(vaultDir(body.id), row.file), { force: true });
        await sql`delete from vault_items where vault_id = ${body.id} and path = ${body.path}`.execute(k.db);
        return { ok: true };
      },
    );
  },
};