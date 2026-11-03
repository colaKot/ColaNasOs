import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import type { FastifyRequest } from 'fastify';

/**
 * 手机相册备份。
 *
 * 与「同步」不同：备份只做「手机 → NAS」单向增量，核心价值是**去重**：
 *   - 有 MD5 时按内容判重（同一张照片被相册、微信、截图各存一份也只会进一次）；
 *   - 没 MD5 时退化为「文件名 + 大小」，这是手机相册最常见的重名形态；
 *   - 判定只在索引层做（photo_items），不读盘 —— 几百个文件的 check 也要毫秒级返回。
 */
const TAG = ['photo'];

const CheckFile = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 255 }),
    size: Type.Integer({ minimum: 0 }),
    md5: Type.Optional(Type.String({ maxLength: 64 })),
  },
  { $id: 'PhotoBackupCheckFile' },
);

const CheckBody = Type.Object(
  { files: Type.Array(Type.Ref(CheckFile), { minItems: 1, maxItems: 2000 }) },
  { $id: 'PhotoBackupCheckBody' },
);

const CheckResultFile = Type.Object(
  { name: Type.String(), size: Type.Integer(), md5: Type.String() },
  { $id: 'PhotoBackupCheckResultFile' },
);

const CheckResponse = Type.Object(
  {
    exists: Type.Array(Type.Ref(CheckResultFile)),
    missing: Type.Array(Type.Ref(CheckResultFile)),
    total: Type.Integer(),
    missingBytes: Type.Integer(),
  },
  { $id: 'PhotoBackupCheckResponse' },
);

const CommitBody = Type.Object(
  {
    source: Type.Optional(Type.String({ maxLength: 64 })),
    total: Type.Integer({ minimum: 0 }),
    uploaded: Type.Integer({ minimum: 0 }),
    skipped: Type.Integer({ minimum: 0 }),
    bytes: Type.Integer({ minimum: 0 }),
  },
  { $id: 'PhotoBackupCommitBody' },
);

const Job = Type.Object(
  {
    id: Type.String(),
    source: Type.String(),
    createdAt: Type.Integer(),
    finishedAt: Type.Union([Type.Integer(), Type.Null()]),
    total: Type.Integer(),
    uploaded: Type.Integer(),
    skipped: Type.Integer(),
    bytes: Type.Integer(),
  },
  { $id: 'PhotoBackupJob' },
);

const CommitResponse = Type.Object(
  { job: Type.Ref(Job) },
  { $id: 'PhotoBackupCommitResponse' },
);

const StatusResponse = Type.Object(
  { items: Type.Array(Type.Ref(Job)) },
  { $id: 'PhotoBackupStatusResponse' },
);

export const PHOTO_BACKUP_SCHEMAS = [
  CheckFile,
  CheckBody,
  CheckResultFile,
  CheckResponse,
  CommitBody,
  Job,
  CommitResponse,
  StatusResponse,
];

const ref = (id: string) => ({ $ref: `${id}#` });
const now = () => Math.floor(Date.now() / 1000);

function basenameOf(relPath: string): string {
  const parts = String(relPath || '').split('/');
  return parts[parts.length - 1] || '';
}

export async function registerPhotoBackup(app: any, k: KernelApi): Promise<void> {
  for (const schema of PHOTO_BACKUP_SCHEMAS) app.addSchema(schema);

  app.post(
    '/api/v1/photo/backup/check',
    secured('photo:read', {
      schema: {
        operationId: 'photoBackupCheck',
        tags: TAG,
        summary: '备份前置比对：哪些文件库里已经有了（MD5 优先，其次同名同大小）',
        body: ref('PhotoBackupCheckBody'),
        response: { 200: ref('PhotoBackupCheckResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        files: Array<{ name: string; size: number; md5?: string }>;
      };
      const files = body.files.slice(0, 2000);

      const md5Set = new Set<string>();
      const md5s = files.map((f) => String(f.md5 || '').trim()).filter(Boolean);
      for (let i = 0; i < md5s.length; i += 400) {
        const chunk = md5s.slice(i, i + 400);
        const rows = (
          await sql<{ content_md5: string }>`
            select distinct content_md5 from photo_items
             where content_md5 in (${sql.join(
               chunk.map((m) => sql`${m}`),
               sql`, `,
             )})
          `.execute(k.db)
        ).rows;
        for (const r of rows) md5Set.add(String(r.content_md5));
      }

      // 同名同大小：按 size 撞车筛候选，再在 JS 里比 basename（SQL 侧没有 basename）
      const sizes = [...new Set(files.map((f) => Number(f.size) || 0))].slice(0, 500);
      const nameKey = new Set<string>();
      if (sizes.length > 0) {
        const rows = (
          await sql<{ rel_path: string; size: number }>`
            select rel_path, size from photo_items
             where in_trash = 0 and size in (${sql.join(
               sizes.map((s) => sql`${s}`),
               sql`, `,
             )})
             limit 20000
          `.execute(k.db)
        ).rows;
        for (const r of rows) nameKey.add(`${basenameOf(r.rel_path)}\u0000${Number(r.size) || 0}`);
      }

      const exists: Array<{ name: string; size: number; md5: string }> = [];
      const missing: Array<{ name: string; size: number; md5: string }> = [];
      let missingBytes = 0;
      for (const f of files) {
        const size = Number(f.size) || 0;
        const md5 = String(f.md5 || '');
        const hit = (md5 && md5Set.has(md5)) || nameKey.has(`${f.name}\u0000${size}`);
        const item = { name: f.name, size, md5 };
        if (hit) exists.push(item);
        else {
          missing.push(item);
          missingBytes += size;
        }
      }

      return { exists, missing, total: files.length, missingBytes };
    },
  );

  app.post(
    '/api/v1/photo/backup/commit',
    secured('photo:write', {
      schema: {
        operationId: 'photoBackupCommit',
        tags: TAG,
        summary: '登记一次备份结果',
        body: ref('PhotoBackupCommitBody'),
        response: { 200: ref('PhotoBackupCommitResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        source?: string;
        total?: number;
        uploaded?: number;
        skipped?: number;
        bytes?: number;
      };
      const id = crypto.randomUUID();
      const ts = now();
      await sql`
        insert into photo_backup_jobs
          (id, owner_id, source, created_at, finished_at, total, uploaded, skipped, bytes)
        values (${id}, ${req.user?.sub || ''}, ${String(body.source || 'mobile').slice(0, 64)}, ${ts}, ${ts},
                ${Number(body.total) || 0}, ${Number(body.uploaded) || 0}, ${Number(body.skipped) || 0},
                ${Number(body.bytes) || 0})
      `.execute(k.db);
      return {
        job: {
          id,
          source: String(body.source || 'mobile').slice(0, 64),
          createdAt: ts,
          finishedAt: ts,
          total: Number(body.total) || 0,
          uploaded: Number(body.uploaded) || 0,
          skipped: Number(body.skipped) || 0,
          bytes: Number(body.bytes) || 0,
        },
      };
    },
  );

  app.get(
    '/api/v1/photo/backup/status',
    secured('photo:read', {
      schema: {
        operationId: 'photoBackupStatus',
        tags: TAG,
        summary: '最近的备份记录',
        response: { 200: ref('PhotoBackupStatusResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const rows = (
        await sql<{
          id: string;
          source: string;
          created_at: number;
          finished_at: number | null;
          total: number;
          uploaded: number;
          skipped: number;
          bytes: number;
        }>`
          select id, source, created_at, finished_at, total, uploaded, skipped, bytes
            from photo_backup_jobs
           where owner_id = ${req.user?.sub || ''}
           order by created_at desc limit 20
        `.execute(k.db)
      ).rows;
      return {
        items: rows.map((r) => ({
          id: r.id,
          source: r.source,
          createdAt: Number(r.created_at),
          finishedAt: r.finished_at == null ? null : Number(r.finished_at),
          total: Number(r.total),
          uploaded: Number(r.uploaded),
          skipped: Number(r.skipped),
          bytes: Number(r.bytes),
        })),
      };
    },
  );
}