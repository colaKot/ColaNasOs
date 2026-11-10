import crypto from 'node:crypto';
import { Type } from '@sinclair/typebox';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import type { FastifyRequest } from 'fastify';
import { preserveOriginalFingerprint, type FingerprintRow } from './content-md5';
import { findDeletedMatches } from './deleted-fp';

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

// 内容级去重：与「同步」不同，备份判重必须在**该用户全部相册源**范围内做，
// 而不是只看目标目录，更不是全库（跨用户会把别人的照片误判成「已存在」而漏传）。
// md5 可选：只带 size 的请求用于「这个大小在整个图库里一个候选都没有」的快路，
// 客户端据此跳过本地 MD5 直接上传（几万张照片时省掉全量读盘）。
const CheckContentItem = Type.Object(
  {
    size: Type.Integer({ minimum: 0 }),
    md5: Type.Optional(Type.String({ maxLength: 64 })),
  },
  { $id: 'PhotoBackupCheckContentItem' },
);

const CheckContentBody = Type.Object(
  {
    items: Type.Array(Type.Ref(CheckContentItem), { minItems: 1, maxItems: 2000 }),
  },
  { $id: 'PhotoBackupCheckContentBody' },
);

const CheckContentResponse = Type.Object(
  {
    matched: Type.Array(Type.String()),
    absent: Type.Array(Type.Integer()),
    scanned: Type.Integer(),
    hashed: Type.Integer(),
  },
  { $id: 'PhotoBackupCheckContentResponse' },
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
  CheckContentItem,
  CheckContentBody,
  CheckContentResponse,
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

type ContentItem = { size: number; md5?: string };
type ContentRow = FingerprintRow & { root_path: string };

/**
 * 跨全部相册源的内容级去重。
 *
 * 三段式（与既有实现同口径）：
 *  1. size 粗筛：`size` 或 `orig_size` 命中即「可能有候选」。orig_size 是关键——
 *     NAS 上的照片补充 GPS / 旋转 / 重编码后真实 size 会变，手机手里仍是原图 size；
 *     只查 size 会把原图判成 absent，然后重复上传一份。
 *  2. 惰性固化：候选行 `content_md5` 为空时现算并写回（此时文件还是原图）。
 *     content_md5 / orig_size 一旦写入永不覆盖，它们描述「手机上传时那份原始内容」。
 *  3. md5 比对：返回确实存在于服务端的 md5 集合（matched）。
 *
 * 只读索引层 + 极少数候选才读盘；一次请求最多现算 HASH_CAP 个文件，避免
 * 一批 2000 个撞车 size 把磁盘打满。
 */
// 单次请求最多现算多少个候选文件。老库 content_md5 全空时，第一次备份会顺带
// 把撞上 size 的候选补齐；64 太小会让一批 200 个素材里剩下的一百多个被误判成
// 「服务端没有」而重复上传。候选行是按请求里的 size 精确筛出来的，正常一个 size
// 只有一两行，1024 足够覆盖一批且不会把磁盘打满。
const HASH_CAP = 1024;

async function findExistingContent(k: KernelApi, uid: string, raw: ContentItem[]) {
  const items = (Array.isArray(raw) ? raw : []).slice(0, 2000);
  const wantedBySize = new Map<number, Set<string>>();
  const allMd5 = new Set<string>();
  const requestedSizes = new Set<number>();
  for (const it of items) {
    const size = Number(it?.size) || 0;
    if (size <= 0) continue;
    requestedSizes.add(size);
    const md5 = String(it?.md5 || '').trim().toLowerCase();
    if (!/^[0-9a-f]{32}$/.test(md5)) continue;
    const cands = wantedBySize.get(size) ?? new Set<string>();
    cands.add(md5);
    wantedBySize.set(size, cands);
    allMd5.add(md5);
  }
  const result = {
    matched: [] as string[],
    absent: [] as number[],
    scanned: 0,
    hashed: 0,
  };
  if (requestedSizes.size === 0) return result;

  const sizes = [...requestedSizes];
  const sizeList = (slice: number[]) => sql.join(
    slice.map((s) => sql`${s}`),
    sql`, `,
  );
  // 1) size 存在性预检
  const present = new Set<number>();
  for (let i = 0; i < sizes.length; i += 300) {
    const slice = sizes.slice(i, i + 300);
    const rows = (
      await sql<{ size: number; orig_size: number }>`
        select p.size, p.orig_size from photo_items p
         where p.in_trash = 0
           and p.library_id in (select id from photo_libraries where owner_id = ${uid})
           and (p.size in (${sizeList(slice)}) or p.orig_size in (${sizeList(slice)}))
         limit 20000
      `.execute(k.db)
    ).rows;
    for (const r of rows) {
      for (const v of [Number(r.size), Number(r.orig_size)]) {
        if (v > 0 && requestedSizes.has(v)) present.add(v);
      }
    }
  }
  // 在 NAS 上删过的照片同样算「已有」。
  // 回收站里的行还没被物理删，上面那条 SQL 的 `in_trash = 0` 把它们排除了；
  // 清空回收站之后行更是直接没了 —— 不查墓碑的话，用户每备份一次手机，
  // 那些他明确删掉的照片就会被重新传上来一次。
  const dead = await findDeletedMatches(k.db, uid, sizes);
  for (const v of dead.sizes) present.add(v);
  result.absent = sizes.filter((s) => !present.has(s));

  // 2) 内容比对：只有「size 有候选」且「客户端带了 md5」才值得读盘
  const candidateSizes = [...wantedBySize.keys()].filter((s) => present.has(s));
  const matched = new Set<string>();
  for (let i = 0; i < candidateSizes.length; i += 300) {
    if (matched.size >= allMd5.size || result.hashed >= HASH_CAP) break;
    const slice = candidateSizes.slice(i, i + 300);
    const rows = (
      await sql<ContentRow>`
        select p.id, p.rel_path, p.size, p.orig_size, p.content_md5, l.root_path
          from photo_items p join photo_libraries l on l.id = p.library_id
         where p.in_trash = 0 and l.owner_id = ${uid}
           and (p.size in (${sizeList(slice)}) or p.orig_size in (${sizeList(slice)}))
         limit 2000
      `.execute(k.db)
    ).rows;
    for (const row of rows) {
      if (result.hashed >= HASH_CAP) break;
      const dbSize = Number(row.size);
      const origSize = Number(row.orig_size) || 0;
      const cands = wantedBySize.get(dbSize) ?? wantedBySize.get(origSize);
      if (!cands || cands.size === 0) continue;
      result.scanned += 1;
      const fp = await preserveOriginalFingerprint(k.db, row);
      if (fp.md5 && fp.md5 !== String(row.content_md5 || '').trim().toLowerCase()) {
        result.hashed += 1;
      }
      if (fp.md5 && cands.has(fp.md5)) matched.add(fp.md5);
    }
  }
  // 墓碑里带 md5 的直接算命中
  for (const m of dead.md5s) {
    if (allMd5.has(m)) matched.add(m);
  }
  // 墓碑只留了 size（删除时还没补码）：用户已经删了这张照片，这个 size 上报什么
  // md5 都当成「传过了」。宁可少传一次，也不能天天把删掉的照片重新堆上 NAS。
  for (const s of dead.sizeOnly) {
    const cands = wantedBySize.get(s);
    if (!cands) continue;
    for (const m of cands) matched.add(m);
  }
  result.matched = [...matched];
  return result;
}

export async function registerPhotoBackup(app: any, k: KernelApi): Promise<void> {
  for (const schema of PHOTO_BACKUP_SCHEMAS) app.addSchema(schema);

  app.post(
    '/api/v1/photo/backup/check',
    secured('photo:read', {
      schema: {
        operationId: 'photoBackupCheck',
        tags: TAG,
        summary: '（兼容）备份前置比对；新客户端请用 /backup/check_content',
        body: ref('PhotoBackupCheckBody'),
        response: { 200: ref('PhotoBackupCheckResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as {
        files: Array<{ name: string; size: number; md5?: string }>;
      };
      const files = body.files.slice(0, 2000);
      // 旧实现没做用户隔离：会把别人的照片判成「已存在」，比多传一份更糟。
      const uid = String(req.user?.sub || '');

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
               and library_id in (select id from photo_libraries where owner_id = ${uid})
          `.execute(k.db)
        ).rows;
        for (const r of rows) md5Set.add(String(r.content_md5));
      }

      // 同名同大小：按 size 或 orig_size 撞车筛候选（补 GPS 后 size 会变），
      // 再在 JS 里比 basename（SQL 侧没有 basename）。原来还有 limit 20000，
      // 大库会截断导致漏判，这里去掉——候选只按 size 索引，行数可控。
      const sizes = [...new Set(files.map((f) => Number(f.size) || 0))].slice(0, 500);
      const nameKey = new Set<string>();
      if (sizes.length > 0) {
        const sizeArgs = sql.join(
          sizes.map((s) => sql`${s}`),
          sql`, `,
        );
        const rows = (
          await sql<{ rel_path: string; size: number; orig_size: number }>`
            select rel_path, size, orig_size from photo_items
             where in_trash = 0
               and library_id in (select id from photo_libraries where owner_id = ${uid})
               and (size in (${sizeArgs}) or orig_size in (${sizeArgs}))
          `.execute(k.db)
        ).rows;
        for (const r of rows) {
          const name = basenameOf(r.rel_path);
          nameKey.add(`${name}\u0000${Number(r.size) || 0}`);
          if (Number(r.orig_size) > 0) nameKey.add(`${name}\u0000${Number(r.orig_size)}`);
        }
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
    '/api/v1/photo/backup/check_content',
    secured('photo:read', {
      schema: {
        operationId: 'photoBackupCheckContent',
        tags: TAG,
        summary: '备份内容去重：跨全部相册源查已有内容与一定不存在的 size',
        body: ref('PhotoBackupCheckContentBody'),
        response: { 200: ref('PhotoBackupCheckContentResponse') },
      },
    }),
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { items?: ContentItem[] };
      return findExistingContent(
        k,
        String(req.user?.sub || ''),
        Array.isArray(body.items) ? body.items : [],
      );
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