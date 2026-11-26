import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { Err } from '../../../kernel/errors';
import { absoluteInput, toPosix } from '../files/fs-root';
import { contentTypeOf, etagOf, matchesEtag, parseRange } from '../files/download';
import { streamWav } from '../media/audio-stream';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../kernel/types';

const TAG = ['blog'];

/** 与媒体令牌同口径：长音频缓冲后 seek 不会撞 401 */
const MEDIA_TOKEN_TTL = 12 * 3600;

/** 只把这些扩展名当成音频；其余文件（含图片本身）不进列表 */
const AUDIO_EXTS = new Set([
  '.mp3',
  '.m4a',
  '.m4b',
  '.aac',
  '.wav',
  '.flac',
  '.ogg',
  '.oga',
  '.opus',
  '.wma',
  '.aiff',
  '.aif',
  '.ape',
  '.mka',
]);

/** 同名封面允许的图片扩展名；顺序即同一主名多张图时的优先级 */
const IMAGE_EXTS = ['.jpg', '.jpeg', '.png', '.webp', '.avif', '.bmp', '.gif'];
const IMAGE_EXT_SET = new Set(IMAGE_EXTS);

interface SourceRow {
  id: string;
  owner_id: string;
  name: string;
  path: string;
  created_at: number;
  updated_at: number;
}

interface CollectionRow {
  id: string;
  owner_id: string;
  name: string;
  description: string;
  created_at: number;
  updated_at: number;
  tracks?: number;
  first_path?: string | null;
}

interface ItemRow {
  id: string;
  collection_id: string;
  owner_id: string;
  path: string;
  title: string;
  position: number;
  created_at: number;
}

interface ProgressRow {
  path: string;
  position_ms: number;
  duration_ms: number;
  listened: number;
  updated_at: number;
}

function newId(): string {
  return crypto.randomBytes(9).toString('base64url');
}

/** 统一成 POSIX 绝对路径（存库 / 回前端 / 比较都用这一种形态） */
function normalizeAbs(input: string): string {
  return toPosix(path.resolve(absoluteInput(input)));
}

function extOf(name: string): string {
  return path.extname(name).toLowerCase();
}

function isAudioName(name: string): boolean {
  return AUDIO_EXTS.has(extOf(name));
}

function baseNameLower(name: string): string {
  return path.basename(name, path.extname(name)).toLowerCase();
}

function isUnder(rootAbs: string, targetAbs: string): boolean {
  const rel = path.relative(path.resolve(rootAbs), path.resolve(targetAbs));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

/** 目录里的图片索引：主文件名（小写）→ 封面绝对路径，按扩展名优先级取第一张 */
function imageIndexOfDir(dir: string): Map<string, string> {
  const out = new Map<string, string>();
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  const files = entries
    .filter((e) => e.isFile() && IMAGE_EXT_SET.has(extOf(e.name)))
    .sort((a, b) => IMAGE_EXTS.indexOf(extOf(a.name)) - IMAGE_EXTS.indexOf(extOf(b.name)));
  for (const f of files) {
    const key = baseNameLower(f.name);
    if (!out.has(key)) out.set(key, path.join(dir, f.name));
  }
  return out;
}

/**
 * 批量求封面：同一目录只 readdir 一次。
 * 返回与 `audios` 等长的数组（null = 没有同名图片）。
 */
function coversOf(audios: string[]): (string | null)[] {
  const cache = new Map<string, Map<string, string>>();
  return audios.map((abs) => {
    const dir = path.dirname(abs);
    let index = cache.get(dir);
    if (!index) {
      index = imageIndexOfDir(dir);
      cache.set(dir, index);
    }
    return index.get(baseNameLower(abs)) ?? null;
  });
}

/** 同 [imageIndexOfDir]，但走异步 readdir，便于按目录并发扫描 */
async function imageIndexOfDirAsync(dir: string): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  let entries: fs.Dirent[];
  try {
    entries = await fs.promises.readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  const files = entries
    .filter((e) => e.isFile() && IMAGE_EXT_SET.has(extOf(e.name)))
    .sort((a, b) => IMAGE_EXTS.indexOf(extOf(a.name)) - IMAGE_EXTS.indexOf(extOf(b.name)));
  for (const f of files) {
    const key = baseNameLower(f.name);
    if (!out.has(key)) out.set(key, path.join(dir, f.name));
  }
  return out;
}

/** 有并发上限的 map：SMB / 机械盘上逐条 stat 会很慢，并发能把延迟摊薄 */
async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (;;) {
      const i = next;
      next += 1;
      if (i >= items.length) return;
      out[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

/** Web 端浏览器打不开的音频扩展名（与音乐模块同一口径） */
const WEB_UNSAFE_AUDIO_EXTS = new Set(['.ape', '.wma', '.aiff', '.aif', '.alac']);

function needsWebAudioTranscode(abs: string): boolean {
  return WEB_UNSAFE_AUDIO_EXTS.has(path.extname(abs).toLowerCase());
}

/**
 * 递归收集目录下的音频文件（POSIX 绝对路径）。
 * 限制层级与数量，避免把整块磁盘拖进合集时卡住接口。
 */
function audioFilesUnder(dirAbs: string, max = 5000, maxDepth = 32): string[] {
  const out: string[] = [];
  const walk = (dir: string, depth: number): void => {
    if (out.length >= max || depth > maxDepth) return;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    for (const e of entries) {
      if (out.length >= max) return;
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) {
        walk(abs, depth + 1);
      } else if (e.isFile() && isAudioName(e.name)) {
        out.push(toPosix(abs));
      }
    }
  };
  walk(dirAbs, 0);
  return out;
}

/** 把绝对路径流给客户端（Range / ETag 与 files 下载同口径，但不受 filesRoot 限制） */
function streamAbsoluteFile(req: FastifyRequest, reply: FastifyReply, abs: string, cacheSeconds = 0) {
  let st: fs.Stats;
  try {
    st = fs.statSync(abs);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'EACCES') return reply.code(403).send({ error: Err.forbidden, message: 'permission denied' });
    return reply.code(404).send({ error: Err.notFound, message: 'file not found' });
  }
  if (!st.isFile()) {
    return reply.code(400).send({ error: Err.badRequest, message: 'path is not a file' });
  }

  const etag = etagOf(st.size, st.mtimeMs);
  reply.header('ETag', etag);
  reply.header('Last-Modified', st.mtime.toUTCString());
  reply.header('Accept-Ranges', 'bytes');
  reply.header('Cache-Control', cacheSeconds > 0 ? `private, max-age=${cacheSeconds}` : 'private, max-age=0');
  reply.header('Content-Type', contentTypeOf(abs));

  const ifNoneMatch = req.headers['if-none-match'];
  if (typeof ifNoneMatch === 'string' && matchesEtag(ifNoneMatch, etag)) {
    return reply.code(304).send();
  }

  let rangeHeader = req.headers.range;
  const ifRange = req.headers['if-range'];
  if (rangeHeader && typeof ifRange === 'string' && ifRange !== etag) rangeHeader = undefined;

  if (!rangeHeader) {
    reply.header('Content-Length', String(st.size));
    return reply.code(200).send(fs.createReadStream(abs));
  }

  const range = parseRange(rangeHeader, st.size);
  if (range === 'unsatisfiable') {
    return reply.code(416).header('Content-Range', `bytes */${st.size}`).send();
  }
  if (range === null) {
    reply.header('Content-Length', String(st.size));
    return reply.code(200).send(fs.createReadStream(abs));
  }
  reply
    .code(206)
    .header('Content-Range', `bytes ${range.start}-${range.end}/${st.size}`)
    .header('Content-Length', String(range.end - range.start + 1));
  return reply.send(fs.createReadStream(abs, { start: range.start, end: range.end }));
}

/**
 * 本地博客 / 博客合集。
 *
 * 目录源是这个模块的根：用户挑一个本地文件夹，后端按需扫描（不建索引），
 * 只暴露音频文件；封面取「同目录同名图片」。合集存的是音频绝对路径，
 * 因此不复制文件，也不会在移除目录源时误删任何东西。
 */
export async function registerLocalBlog(app: FastifyInstance, k: KernelApi): Promise<void> {
  /** 读侧白名单：任何已登记的目录源都允许流式读取（合集可能跨用户引用） */
  const allRoots = async (): Promise<string[]> => {
    const rows = await sql<{ path: string }>`select path from blog_local_sources`.execute(k.db);
    return rows.rows.map((r) => normalizeAbs(r.path)).filter(Boolean);
  };

  const ownerRoots = async (owner: string): Promise<string[]> => {
    const rows = await sql<{ path: string }>`
      select path from blog_local_sources where owner_id = ${owner}
    `.execute(k.db);
    return rows.rows.map((r) => normalizeAbs(r.path)).filter(Boolean);
  };

  const underAny = (roots: string[], abs: string): boolean => roots.some((r) => isUnder(r, abs));

  /** 一次读出这批路径的播放进度（分块规避 SQLite 变量上限） */
  const progressFor = async (owner: string, paths: string[]): Promise<Map<string, ProgressRow>> => {
    const map = new Map<string, ProgressRow>();
    for (let i = 0; i < paths.length; i += 400) {
      const chunk = paths.slice(i, i + 400);
      if (chunk.length === 0) continue;
      const rows = await sql<ProgressRow>`
        select path, position_ms, duration_ms, listened, updated_at
          from blog_local_progress
         where owner_id = ${owner}
           and path in (${sql.join(chunk.map((p) => sql`${p}`), sql`, `)})
      `.execute(k.db);
      for (const r of rows.rows) map.set(r.path, r);
    }
    return map;
  };

  const mediaToken = () => k.auth.sign({ sub: 'blog-local', scopes: ['blog:read'] }, MEDIA_TOKEN_TTL);

  /** 封面地址始终用**音频路径**拼（cover 接口自己找同名图），令牌只签一次 */
  const coverUrlOf = (audioAbs: string, token: string): string =>
    `/api/v1/blog/local/cover?path=${encodeURIComponent(toPosix(audioAbs))}&token=${encodeURIComponent(token)}`;

  const toSource = (r: SourceRow) => ({
    id: r.id,
    name: r.name,
    path: r.path,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  });

  const loadSource = async (id: string, owner: string): Promise<SourceRow | null> => {
    const rows = await sql<SourceRow>`
      select * from blog_local_sources where id = ${id} and owner_id = ${owner}
    `.execute(k.db);
    return rows.rows[0] ?? null;
  };

  const loadCollection = async (id: string, owner: string): Promise<CollectionRow | null> => {
    const rows = await sql<CollectionRow>`
      select * from blog_collections where id = ${id} and owner_id = ${owner}
    `.execute(k.db);
    return rows.rows[0] ?? null;
  };

  // ---------------------------------------------------------------- 目录源

  app.get(
    '/api/v1/blog/local/sources',
    secured('blog:read', {
      schema: {
        operationId: 'blogLocalSources',
        tags: TAG,
        summary: '本地博客目录源列表',
        response: { 200: { $ref: 'BlogLocalSourceListResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const rows = await sql<SourceRow>`
        select * from blog_local_sources
         where owner_id = ${owner}
         order by created_at desc, id
      `.execute(k.db);
      return { items: rows.rows.map(toSource) };
    },
  );

  app.post(
    '/api/v1/blog/local/sources',
    secured('blog:write', {
      schema: {
        operationId: 'blogLocalSourceAdd',
        tags: TAG,
        summary: '添加本地目录源（只存配置，不搬文件）',
        body: { $ref: 'BlogLocalSourceBody#' },
        response: {
          200: { $ref: 'BlogLocalSource#' },
          400: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { path?: string; name?: string };
      const raw = String(body.path || '').trim();
      if (!raw) return reply.code(400).send({ error: Err.badRequest, message: 'path required' });
      const abs = normalizeAbs(raw);
      let st: fs.Stats;
      try {
        st = fs.statSync(path.resolve(absoluteInput(raw)));
      } catch {
        return reply.code(400).send({ error: Err.badRequest, message: 'path not found' });
      }
      if (!st.isDirectory()) {
        return reply.code(400).send({ error: Err.badRequest, message: 'path is not a directory' });
      }

      // 同一目录重复添加：直接返回已有配置，避免列表里出现两条一样的源
      const existing = (
        await sql<SourceRow>`
          select * from blog_local_sources where owner_id = ${owner}
        `.execute(k.db)
      ).rows.find((r) => normalizeAbs(r.path) === abs);
      if (existing) return toSource(existing);

      const now = Math.floor(Date.now() / 1000);
      const id = newId();
      const name = String(body.name || '').trim() || path.basename(abs) || abs;
      await sql`
        insert into blog_local_sources (id, owner_id, name, path, created_at, updated_at)
        values (${id}, ${owner}, ${name}, ${abs}, ${now}, ${now})
      `.execute(k.db);
      return { id, name, path: abs, createdAt: now, updatedAt: now };
    },
  );

  app.post(
    '/api/v1/blog/local/sources/remove',
    secured('blog:write', {
      schema: {
        operationId: 'blogLocalSourceRemove',
        tags: TAG,
        summary: '移除目录源（仅移除配置，不删本地文件）',
        body: { $ref: 'BlogLocalSourceRemoveBody#' },
        response: { 200: { $ref: 'BlogOkResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const id = String((req.body as { id?: string } | null)?.id || '');
      if (id) {
        await sql`
          delete from blog_local_sources where id = ${id} and owner_id = ${owner}
        `.execute(k.db);
      }
      return { ok: true };
    },
  );

  // ---------------------------------------------------------------- 浏览 / 播放

  app.get(
    '/api/v1/blog/local/browse',
    secured('blog:read', {
      schema: {
        operationId: 'blogLocalBrowse',
        tags: TAG,
        summary: '浏览目录源（多层子目录 + 只列音频 + 同名图片封面）',
        querystring: { $ref: 'BlogLocalBrowseQuery#' },
        response: {
          200: { $ref: 'BlogLocalBrowseResponse#' },
          400: { $ref: 'BlogErrorResponse#' },
          404: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { sourceId?: string; path?: string };
      const owner = req.user?.sub || '';
      const source = q.sourceId ? await loadSource(q.sourceId, owner) : null;
      if (!source) {
        return reply.code(404).send({ error: Err.notFound, message: 'source not found' });
      }
      const sourceAbs = normalizeAbs(source.path);
      const abs = q.path && q.path.trim() ? normalizeAbs(q.path) : sourceAbs;
      if (!isUnder(sourceAbs, abs)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'path outside source' });
      }

      let entries: fs.Dirent[];
      try {
        const st = fs.statSync(path.resolve(absoluteInput(abs)));
        if (!st.isDirectory()) {
          return reply.code(400).send({ error: Err.badRequest, message: 'path is not a directory' });
        }
        entries = fs.readdirSync(path.resolve(absoluteInput(abs)), { withFileTypes: true });
      } catch {
        return reply.code(404).send({ error: Err.notFound, message: 'path not found' });
      }

      const dirAbs = path.resolve(absoluteInput(abs));
      const token = mediaToken();
      const coverIndex = imageIndexOfDir(dirAbs);
      const dirs = entries
        .filter((e) => e.isDirectory())
        .map((e) => ({ name: e.name, path: toPosix(path.join(dirAbs, e.name)) }))
        .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

      const audios = entries
        .filter((e) => e.isFile() && isAudioName(e.name))
        .map((e) => {
          const fileAbs = path.join(dirAbs, e.name);
          let size = 0;
          try {
            size = fs.statSync(fileAbs).size;
          } catch {
            /* 读不到大小不影响列出 */
          }
          return {
            name: e.name,
            title: path.basename(e.name, path.extname(e.name)),
            path: toPosix(fileAbs),
            size,
            coverUrl: coverIndex.has(baseNameLower(e.name))
              ? coverUrlOf(fileAbs, token)
              : null,
          };
        })
        .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

      const progress = await progressFor(owner, audios.map((a) => a.path));
      const audiosWithProgress = audios.map((a) => {
        const p = progress.get(a.path);
        return {
          ...a,
          listened: Boolean(p?.listened),
          positionMs: p?.position_ms ?? 0,
        };
      });

      return {
        path: toPosix(dirAbs),
        parent: toPosix(dirAbs) === sourceAbs ? null : toPosix(path.dirname(dirAbs)),
        dirs,
        audios: audiosWithProgress,
      };
    },
  );

  app.post(
    '/api/v1/blog/local/progress',
    secured('blog:read', {
      schema: {
        operationId: 'blogLocalProgress',
        tags: TAG,
        summary: '上报本地音频播放进度（≥90% 记为已听，之后不再回落）',
        body: { $ref: 'BlogLocalProgressBody#' },
        response: {
          200: { $ref: 'BlogOkResponse#' },
          400: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { path?: string; positionMs?: number; durationMs?: number };
      const abs = normalizeAbs(String(body.path || ''));
      if (!abs || !isAudioName(abs) || !underAny(await ownerRoots(owner), abs)) {
        return reply.code(400).send({ error: Err.badRequest, message: 'invalid path' });
      }
      const duration = Math.max(0, Math.floor(Number(body.durationMs) || 0));
      let position = Math.max(0, Math.floor(Number(body.positionMs) || 0));
      if (duration > 0 && position > duration) position = duration;
      const prev = (
        await sql<Pick<ProgressRow, 'listened'>>`
          select listened from blog_local_progress
           where owner_id = ${owner} and path = ${abs}
        `.execute(k.db)
      ).rows[0];
      // 已听是单向标记：重听从 0 开始也不会把标签摘掉
      const listened = Boolean(prev?.listened) || (duration > 0 && position / duration >= 0.9);
      const now = Math.floor(Date.now() / 1000);
      await sql`
        insert into blog_local_progress
          (owner_id, path, position_ms, duration_ms, listened, updated_at)
        values (${owner}, ${abs}, ${position}, ${duration}, ${listened ? 1 : 0}, ${now})
        on conflict (owner_id, path) do update set
          position_ms = excluded.position_ms,
          duration_ms = excluded.duration_ms,
          listened = excluded.listened,
          updated_at = excluded.updated_at
      `.execute(k.db);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/blog/local/audio-url',
    secured('blog:read', {
      schema: {
        operationId: 'blogLocalAudioUrl',
        tags: TAG,
        summary: '本地音频的带令牌播放地址',
        querystring: { $ref: 'BlogLocalPathQuery#' },
        response: {
          200: { $ref: 'BlogLocalAudioUrlResponse#' },
          404: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { path?: string; format?: string };
      const raw = String(q.path || '');
      if (!raw) return reply.code(404).send({ error: Err.notFound, message: 'audio missing' });
      const abs = normalizeAbs(raw);
      if (!isAudioName(abs) || !underAny(await allRoots(), abs) || !fs.existsSync(path.resolve(absoluteInput(abs)))) {
        return reply.code(404).send({ error: Err.notFound, message: 'audio missing' });
      }
      const token = mediaToken();
      const format = q.format === 'auto' ? '&format=auto' : '';
      return {
        url: `/api/v1/blog/local/audio?path=${encodeURIComponent(toPosix(abs))}&token=${encodeURIComponent(token)}${format}`,
        expiresInSec: MEDIA_TOKEN_TTL,
      };
    },
  );

  app.get(
    '/api/v1/blog/local/audio',
    secured('blog:read', {
      schema: {
        operationId: 'blogLocalAudio',
        tags: TAG,
        summary: '本地音频流（支持 Range / ETag；format=auto 时 Web 不支持格式实时转 PCM 推流）',
        querystring: { $ref: 'BlogLocalPathQuery#' },
        response: { 404: { $ref: 'BlogErrorResponse#' } },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { path?: string; format?: string };
      const raw = String(q.path || '');
      if (!raw) return reply.code(404).send({ error: Err.notFound, message: 'audio missing' });
      const abs = normalizeAbs(raw);
      if (!isAudioName(abs) || !underAny(await allRoots(), abs)) {
        return reply.code(404).send({ error: Err.notFound, message: 'audio missing' });
      }
      const src = path.resolve(absoluteInput(abs));
      // 浏览器解不了的格式：边解码边推 PCM（WAV），首字节几百毫秒就能出声；
      // 探测失败 / 没有 ffmpeg 时退回原始文件，不阻断桌面端播放
      if (q.format === 'auto' && needsWebAudioTranscode(abs)) {
        if (await streamWav(req, reply, src)) return;
      }
      return streamAbsoluteFile(req, reply, src);
    },
  );

  app.get(
    '/api/v1/blog/local/cover',
    secured('blog:read', {
      schema: {
        operationId: 'blogLocalCover',
        tags: TAG,
        summary: '本地音频的同名封面（没有同名图片时 404）',
        querystring: { $ref: 'BlogLocalPathQuery#' },
        response: { 404: { $ref: 'BlogErrorResponse#' } },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { path?: string };
      const raw = String(q.path || '');
      if (!raw) return reply.code(404).send({ error: Err.notFound, message: 'cover missing' });
      const abs = normalizeAbs(raw);
      if (!isAudioName(abs) || !underAny(await allRoots(), abs)) {
        return reply.code(404).send({ error: Err.notFound, message: 'cover missing' });
      }
      const dir = path.dirname(path.resolve(absoluteInput(abs)));
      const cover = imageIndexOfDir(dir).get(baseNameLower(abs));
      if (!cover) return reply.code(404).send({ error: Err.notFound, message: 'cover missing' });
      return streamAbsoluteFile(req, reply, cover, 3600);
    },
  );

  app.post(
    '/api/v1/blog/local/delete',
    secured('blog:write', {
      schema: {
        operationId: 'blogLocalDelete',
        tags: TAG,
        summary: '删除本地音频文件或整个目录（目录递归删除）',
        body: { $ref: 'BlogLocalDeleteBody#' },
        response: { 200: { $ref: 'BlogLocalDeleteResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const roots = await ownerRoots(owner);
      const paths = ((req.body || {}) as { paths?: string[] }).paths || [];
      let deleted = 0;
      for (const raw of paths) {
        const abs = normalizeAbs(String(raw || ''));
        if (!abs || !underAny(roots, abs)) continue;
        // 目录源根本身不许删：那是用户的入口，误删会把整库一起带走
        if (roots.some((r) => r === abs)) continue;
        const target = path.resolve(absoluteInput(abs));
        let st: fs.Stats;
        try {
          st = fs.statSync(target);
        } catch {
          continue;
        }
        const isDir = st.isDirectory();
        const isAudio = !isDir && isAudioName(abs);
        if (!isDir && !isAudio) continue;
        try {
          // 目录连同子目录 / 封面等一起删；文件只删自身
          fs.rmSync(target, { recursive: isDir, force: true });
          deleted += 1;
        } catch {
          // 文件被占用 / 已消失：跳过，不让批量删除整体失败
          continue;
        }
        // 文件没了，合集里的同路径条目也一并清掉，避免留下点开就 404 的死条目
        if (isDir) {
          await sql`
            delete from blog_collection_items
             where owner_id = ${owner}
               and (path = ${abs} or substr(path, 1, ${abs.length + 1}) = ${`${abs}/`})
          `.execute(k.db);
          await sql`
            delete from blog_local_progress
             where owner_id = ${owner}
               and (path = ${abs} or substr(path, 1, ${abs.length + 1}) = ${`${abs}/`})
          `.execute(k.db);
        } else {
          await sql`
            delete from blog_collection_items
             where owner_id = ${owner} and path = ${abs}
          `.execute(k.db);
          await sql`
            delete from blog_local_progress
             where owner_id = ${owner} and path = ${abs}
          `.execute(k.db);
        }
      }
      return { ok: true, deleted };
    },
  );

  // ---------------------------------------------------------------- 博客合集

  app.get(
    '/api/v1/blog/collections',
    secured('blog:read', {
      schema: {
        operationId: 'blogCollections',
        tags: TAG,
        summary: '博客合集列表（含音频数与封面）',
        response: { 200: { $ref: 'BlogCollectionListResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const rows = (
        await sql<CollectionRow>`
          select c.*,
                 (select count(*) from blog_collection_items i
                   where i.collection_id = c.id) as tracks,
                 (select i.path from blog_collection_items i
                   where i.collection_id = c.id
                   order by i.position, i.created_at limit 1) as first_path
            from blog_collections c
           where c.owner_id = ${owner}
           order by c.created_at desc, c.id
           limit 200
        `.execute(k.db)
      ).rows;
      const token = mediaToken();
      const covers = coversOf(rows.map((r) => String(r.first_path || '')).filter(Boolean));
      let coverAt = 0;
      return {
        items: rows.map((r) => {
          let cover: string | null = null;
          if (r.first_path) {
            cover = covers[coverAt] ? coverUrlOf(r.first_path, token) : null;
            coverAt += 1;
          }
          return {
            id: r.id,
            name: r.name,
            description: r.description || '',
            tracks: Number(r.tracks) || 0,
            coverUrl: cover,
            createdAt: r.created_at,
            updatedAt: r.updated_at,
          };
        }),
      };
    },
  );

  app.post(
    '/api/v1/blog/collections',
    secured('blog:write', {
      schema: {
        operationId: 'blogCollectionCreate',
        tags: TAG,
        summary: '新建空博客合集',
        body: { $ref: 'BlogCollectionBody#' },
        response: {
          200: { $ref: 'BlogCollection#' },
          400: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { name?: string; description?: string };
      const name = String(body.name || '').trim();
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: 'name required' });
      const now = Math.floor(Date.now() / 1000);
      const id = newId();
      const description = String(body.description || '').trim().slice(0, 500);
      await sql`
        insert into blog_collections (id, owner_id, name, description, created_at, updated_at)
        values (${id}, ${owner}, ${name}, ${description}, ${now}, ${now})
      `.execute(k.db);
      return {
        id,
        name,
        description,
        tracks: 0,
        coverUrl: null,
        createdAt: now,
        updatedAt: now,
      };
    },
  );

  app.post(
    '/api/v1/blog/collections/update',
    secured('blog:write', {
      schema: {
        operationId: 'blogCollectionUpdate',
        tags: TAG,
        summary: '重命名 / 修改合集简介',
        body: { $ref: 'BlogCollectionUpdateBody#' },
        response: {
          200: { $ref: 'BlogCollection#' },
          404: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { id?: string; name?: string; description?: string };
      const row = body.id ? await loadCollection(body.id, owner) : null;
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });

      const name = body.name !== undefined ? String(body.name).trim() || row.name : row.name;
      const description =
        body.description !== undefined
          ? String(body.description).trim().slice(0, 500)
          : row.description;
      const now = Math.floor(Date.now() / 1000);
      await sql`
        update blog_collections
           set name = ${name}, description = ${description}, updated_at = ${now}
         where id = ${row.id}
      `.execute(k.db);

      const stat = await sql<{ n: number; first_path: string | null }>`
        select count(*) as n,
               (select path from blog_collection_items
                 where collection_id = ${row.id}
                 order by position, created_at limit 1) as first_path
          from blog_collection_items
         where collection_id = ${row.id}
      `.execute(k.db);
      const first = stat.rows[0]?.first_path || null;
      const token = mediaToken();
      return {
        id: row.id,
        name,
        description,
        tracks: Number(stat.rows[0]?.n) || 0,
        coverUrl: first && coversOf([first])[0] ? coverUrlOf(first, token) : null,
        createdAt: row.created_at,
        updatedAt: now,
      };
    },
  );

  app.post(
    '/api/v1/blog/collections/remove',
    secured('blog:write', {
      schema: {
        operationId: 'blogCollectionRemove',
        tags: TAG,
        summary: '删除合集（不动本地音频）',
        body: { $ref: 'BlogCollectionIdBody#' },
        response: { 200: { $ref: 'BlogOkResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const id = String((req.body as { id?: string } | null)?.id || '');
      if (id) {
        await sql`
          delete from blog_collection_items where collection_id = ${id} and owner_id = ${owner}
        `.execute(k.db);
        await sql`
          delete from blog_collections where id = ${id} and owner_id = ${owner}
        `.execute(k.db);
      }
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/blog/collections/items',
    secured('blog:read', {
      schema: {
        operationId: 'blogCollectionItems',
        tags: TAG,
        summary: '合集内的音频（按排序）',
        querystring: { $ref: 'BlogCollectionItemsQuery#' },
        response: {
          200: { $ref: 'BlogCollectionItemsResponse#' },
          404: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const owner = req.user?.sub || '';
      const id = String((req.query as { id?: string } | null)?.id || '');
      const row = id ? await loadCollection(id, owner) : null;
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });

      const items = (
        await sql<ItemRow>`
          select * from blog_collection_items
           where collection_id = ${row.id} and owner_id = ${owner}
           order by position, created_at
           limit 1000
        `.execute(k.db)
      ).rows;
      // 封面 / 体积在 SMB、机械盘上逐个读很慢：目录去重后并发扫，
      // 文件也并发 stat，把「打开合集」的首屏延迟摊薄（上限 16 并发）。
      const dirs = Array.from(new Set(items.map((i) => path.dirname(i.path))));
      const dirIndexes = await mapLimit(dirs, 8, (d) => imageIndexOfDirAsync(d));
      const coverIndex = new Map(dirs.map((d, i) => [d, dirIndexes[i]] as const));
      const sizes = await mapLimit(items, 16, async (i) => {
        try {
          return (await fs.promises.stat(path.resolve(absoluteInput(i.path)))).size;
        } catch {
          return 0; // 文件被移走：仍然列出，播放时再报 404
        }
      });
      const progress = await progressFor(owner, items.map((i) => i.path));
      const token = mediaToken();
      return {
        id: row.id,
        name: row.name,
        description: row.description || '',
        items: items.map((i, idx) => {
          const cover = coverIndex.get(path.dirname(i.path))?.get(baseNameLower(i.path));
          const p = progress.get(i.path);
          return {
            id: i.id,
            path: i.path,
            title: i.title,
            size: sizes[idx],
            coverUrl: cover ? coverUrlOf(i.path, token) : null,
            listened: Boolean(p?.listened),
            positionMs: p?.position_ms ?? 0,
            playedAt: p?.updated_at ?? 0,
          };
        }),
      };
    },
  );

  app.post(
    '/api/v1/blog/collections/add',
    secured('blog:write', {
      schema: {
        operationId: 'blogCollectionAdd',
        tags: TAG,
        summary: '把本地音频（或目录下所有层级的音频）加入合集',
        body: { $ref: 'BlogCollectionAddBody#' },
        response: {
          200: { $ref: 'BlogCollectionAddResponse#' },
          404: { $ref: 'BlogErrorResponse#' },
        },
      },
    }),
    async (req, reply) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { id?: string; paths?: string[] };
      const row = body.id ? await loadCollection(body.id, owner) : null;
      if (!row) return reply.code(404).send({ error: Err.notFound, message: 'collection not found' });

      const roots = await ownerRoots(owner);
      const existing = new Set(
        (
          await sql<{ path: string }>`
            select path from blog_collection_items where collection_id = ${row.id}
          `.execute(k.db)
        ).rows.map((r) => normalizeAbs(r.path)),
      );
      const maxRow = (
        await sql<{ n: number | null }>`
          select max(position) as n from blog_collection_items where collection_id = ${row.id}
        `.execute(k.db)
      ).rows[0];
      let pos = Number(maxRow?.n) + 1;
      if (!Number.isFinite(pos)) pos = 0;

      const now = Math.floor(Date.now() / 1000);
      let added = 0;
      let skipped = 0;
      for (const raw of body.paths || []) {
        const abs = normalizeAbs(String(raw || ''));
        if (!abs) {
          skipped += 1;
          continue;
        }
        // 越界路径（不在任何目录源内）不接收，避免合集变成任意文件索引
        if (!underAny(roots, abs)) {
          skipped += 1;
          continue;
        }
        const target = path.resolve(absoluteInput(abs));
        let st: fs.Stats;
        try {
          st = fs.statSync(target);
        } catch {
          // 扫描后文件可能已被删：不把死条目写进合集
          skipped += 1;
          continue;
        }
        // 目录：把其下所有层级的音频都收进合集；文件：只收自身
        let targets: string[];
        if (st.isDirectory()) {
          targets = audioFilesUnder(target);
        } else if (isAudioName(abs)) {
          targets = [abs];
        } else {
          skipped += 1;
          continue;
        }
        if (targets.length === 0) {
          skipped += 1;
          continue;
        }
        for (const fileAbs of targets) {
          // 扫描后文件可能已被删：不把死条目写进合集
          if (!fs.existsSync(path.resolve(absoluteInput(fileAbs)))) {
            skipped += 1;
            continue;
          }
          if (existing.has(fileAbs)) {
            skipped += 1;
            continue;
          }
          existing.add(fileAbs);
          await sql`
            insert into blog_collection_items
              (id, collection_id, owner_id, path, title, position, created_at)
            values (
              ${newId()}, ${row.id}, ${owner}, ${fileAbs},
              ${path.basename(fileAbs, path.extname(fileAbs))}, ${pos}, ${now}
            )
          `.execute(k.db);
          pos += 1;
          added += 1;
        }
      }
      if (added > 0) {
        await sql`
          update blog_collections set updated_at = ${now} where id = ${row.id}
        `.execute(k.db);
      }
      return { ok: true, added, skipped };
    },
  );

  app.post(
    '/api/v1/blog/collections/remove-item',
    secured('blog:write', {
      schema: {
        operationId: 'blogCollectionRemoveItem',
        tags: TAG,
        summary: '从合集移除一条音频（不动本地文件）',
        body: { $ref: 'BlogCollectionRemoveItemBody#' },
        response: { 200: { $ref: 'BlogOkResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { id?: string; itemId?: string };
      if (body.id && body.itemId) {
        await sql`
          delete from blog_collection_items
           where id = ${body.itemId} and collection_id = ${body.id} and owner_id = ${owner}
        `.execute(k.db);
      }
      return { ok: true };
    },
  );

  app.post(
    '/api/v1/blog/collections/reorder',
    secured('blog:write', {
      schema: {
        operationId: 'blogCollectionReorder',
        tags: TAG,
        summary: '按给定的条目顺序重排合集',
        body: { $ref: 'BlogCollectionReorderBody#' },
        response: { 200: { $ref: 'BlogOkResponse#' } },
      },
    }),
    async (req) => {
      const owner = req.user?.sub || '';
      const body = (req.body || {}) as { id?: string; itemIds?: string[] };
      if (!body.id) return { ok: true };
      const ids = body.itemIds || [];
      for (let i = 0; i < ids.length; i += 1) {
        await sql`
          update blog_collection_items
             set position = ${i}
           where id = ${ids[i]} and collection_id = ${body.id} and owner_id = ${owner}
        `.execute(k.db);
      }
      await sql`
        update blog_collections
           set updated_at = ${Math.floor(Date.now() / 1000)}
         where id = ${body.id} and owner_id = ${owner}
      `.execute(k.db);
      return { ok: true };
    },
  );
}
