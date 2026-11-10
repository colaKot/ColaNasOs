import fs from 'node:fs';
import path from 'node:path';
import { sql } from 'kysely';
import { Type } from '@sinclair/typebox';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { secured } from '../../../kernel/route';
import type { KernelApi } from '../../../kernel/types';
import { Updater } from '../../../kernel/updater';
import {
  readSystemSettings,
  writeSystemSettings,
  type SystemSettings,
} from '../../../kernel/system-settings';
import { configureProxy, activeProxy } from '../../../kernel/proxy-fetch';
import { clearTls, saveTls, tlsInfo, validateTlsPair } from '../../../kernel/tls';
import { Err } from '../../../kernel/errors';
import { httpError } from '../files/fs-root';

const TAG = ['system'];
const ref = (id: string) => ({ $ref: `${id}#` });

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'ErrorResponse' },
);

/** 大模型配置（与 `kernel/system-settings.ts#LlmSettings` 一一对应） */
const SystemLlmSchema = Type.Object(
  {
    enabled: Type.Boolean({ description: '关闭后只用素材拼接，不调模型' }),
    provider: Type.String({ maxLength: 40 }),
    baseUrl: Type.String({ maxLength: 300 }),
    model: Type.String({ maxLength: 120 }),
    apiKey: Type.String({ maxLength: 400, description: '明文（用户要求可查看、可复制）' }),
    webSearch: Type.Boolean({ description: '联网搜索（阿里百炼的搜索插件）' }),
  },
  { $id: 'SystemLlm' },
);
const SystemLlmPatch = Type.Object(
  {
    enabled: Type.Optional(Type.Boolean()),
    provider: Type.Optional(Type.String({ maxLength: 40 })),
    baseUrl: Type.Optional(Type.String({ maxLength: 300 })),
    model: Type.Optional(Type.String({ maxLength: 120 })),
    apiKey: Type.Optional(Type.String({ maxLength: 400 })),
    webSearch: Type.Optional(Type.Boolean()),
  },
  { $id: 'SystemLlmPatch' },
);

const SettingsShape = {
  httpPort: Type.Integer({ minimum: 1, maximum: 65535 }),
  httpsPort: Type.Integer({ minimum: 1, maximum: 65535 }),
  httpsEnabled: Type.Boolean(),
  apiConcurrency: Type.Integer({ minimum: 1, maximum: 8 }),
  hostname: Type.String({ maxLength: 10 }),
  welcome: Type.String({ maxLength: 100 }),
  proxy: Type.String({ maxLength: 200 }),
  javFallback: Type.Boolean(),
  llm: Type.Ref('SystemLlm'),
};
const SystemSettingsSchema = Type.Object(SettingsShape, { $id: 'SystemSettings' });
const SystemSettingsBody = Type.Object(
  {
    httpPort: Type.Optional(Type.Integer({ minimum: 1, maximum: 65535 })),
    httpsPort: Type.Optional(Type.Integer({ minimum: 1, maximum: 65535 })),
    httpsEnabled: Type.Optional(Type.Boolean()),
    apiConcurrency: Type.Optional(Type.Integer({ minimum: 1, maximum: 8 })),
    hostname: Type.Optional(Type.String({ maxLength: 10 })),
    welcome: Type.Optional(Type.String({ maxLength: 100 })),
    proxy: Type.Optional(Type.String({ maxLength: 200 })),
    javFallback: Type.Optional(Type.Boolean()),
    llm: Type.Optional(Type.Ref('SystemLlmPatch')),
  },
  { $id: 'SystemSettingsBody' },
);
const SettingsResponse = Type.Object(
  {
    settings: Type.Ref('SystemSettings'),
    /** 当前生效的代理（保存后立即生效；空 = 直连） */
    activeProxy: Type.String(),
  },
  { $id: 'SystemSettingsResponse' },
);
const CacheClearResponse = Type.Object(
  {
    ok: Type.Boolean(),
    freedBytes: Type.Integer(),
    files: Type.Integer(),
  },
  { $id: 'SystemCacheClearResponse' },
);
const CacheInfoResponse = Type.Object(
  { bytes: Type.Integer(), files: Type.Integer() },
  { $id: 'SystemCacheInfoResponse' },
);
const RestartResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'SystemRestartResponse' });
const DbCompactResponse = Type.Object(
  {
    ok: Type.Boolean(),
    beforeBytes: Type.Integer(),
    afterBytes: Type.Integer(),
    freedBytes: Type.Integer(),
  },
  { $id: 'SystemDbCompactResponse' },
);
const UpdateCheckResponse = Type.Object(
  {
    currentId: Type.Union([Type.String(), Type.Null()]),
    currentVersion: Type.Union([Type.Integer(), Type.Null()]),
    latestId: Type.Union([Type.String(), Type.Null()]),
    latestVersion: Type.Union([Type.Integer(), Type.Null()]),
    hasUpdate: Type.Boolean(),
    versions: Type.Integer(),
  },
  { $id: 'SystemUpdateCheckResponse' },
);

const TlsInfoResponse = Type.Object(
  {
    hasCert: Type.Boolean(),
    subject: Type.String(),
    validFrom: Type.String(),
    validTo: Type.String(),
    enabled: Type.Boolean(),
    port: Type.Integer(),
  },
  { $id: 'SystemTlsInfoResponse' },
);
const TlsUploadBody = Type.Object(
  {
    cert: Type.String({ minLength: 1, maxLength: 200_000 }),
    key: Type.String({ minLength: 1, maxLength: 200_000 }),
  },
  { $id: 'SystemTlsUploadBody' },
);

const LogEntry = Type.Object({
  time: Type.String(),
  level: Type.String(),
  msg: Type.String(),
});
const LogsResponse = Type.Object(
  {
    file: Type.String(),
    size: Type.Integer(),
    /** 文件最后修改时间（ISO；文件不存在时为空串） */
    updatedAt: Type.String(),
    /** 当前页，**时间倒序**（最新 → 最旧）；offset=0 即最新日志 */
    lines: Type.Array(LogEntry),
    /** 是否因扫描字节上限没读到文件头（更早的行没纳入） */
    truncated: Type.Boolean(),
    /** 本次请求的页大小 / 往回跳过的匹配行数 */
    limit: Type.Integer(),
    offset: Type.Integer(),
    /** 是否还有更旧的一页 */
    hasMore: Type.Boolean(),
  },
  { $id: 'SystemLogsResponse' },
);

const SCHEMAS = [
  ErrorResponse,
  SystemLlmSchema,
  SystemLlmPatch,
  SystemSettingsSchema,
  SystemSettingsBody,
  SettingsResponse,
  CacheClearResponse,
  CacheInfoResponse,
  RestartResponse,
  DbCompactResponse,
  UpdateCheckResponse,
  TlsInfoResponse,
  TlsUploadBody,
  LogsResponse,
];

/** 递归统计并删除目录；返回释放字节与文件数 */
function removeDir(dir: string): { bytes: number; files: number } {
  let bytes = 0;
  let files = 0;
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return { bytes, files };
  }
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) {
      const sub = removeDir(abs);
      bytes += sub.bytes;
      files += sub.files;
      try {
        fs.rmdirSync(abs);
      } catch {
        /* 非空 / 占用：下次再清 */
      }
    } else if (e.isFile()) {
      try {
        bytes += fs.statSync(abs).size;
        fs.unlinkSync(abs);
        files += 1;
      } catch {
        /* 占用：跳过 */
      }
    }
  }
  return { bytes, files };
}

/** 只统计不删除 */
function sizeOfDir(dir: string): { bytes: number; files: number } {
  let bytes = 0;
  let files = 0;
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return { bytes, files };
  }
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) {
      const sub = sizeOfDir(abs);
      bytes += sub.bytes;
      files += sub.files;
    } else if (e.isFile()) {
      try {
        bytes += fs.statSync(abs).size;
        files += 1;
      } catch {
        /* 占用：跳过 */
      }
    }
  }
  return { bytes, files };
}

function cacheDirs(k: KernelApi): string[] {
  return ['thumbs', 'covers', 'book-pdf'].map((d) => path.join(k.paths.dataDir, d));
}

/** pino 数字等级 → 可读等级 */
const LOG_LEVELS: Record<number, string> = {
  10: 'trace',
  20: 'debug',
  30: 'info',
  40: 'warn',
  50: 'error',
  60: 'fatal',
};

/** pino level → 日志页筛选口径：warn 含 error/fatal，info 是其下所有 */
function levelMatch(level: string, want: 'warn' | 'error' | 'info'): boolean {
  const lv = String(level || '').toLowerCase();
  const isError = lv === 'error' || lv === 'fatal';
  const isWarn = lv === 'warn';
  if (want === 'error') return isError;
  if (want === 'warn') return isError || isWarn;
  return !isError && !isWarn;
}

/** 一行 pino JSON → { time, level, msg }；非 JSON 行按 info 原样展示 */
function parseLogLine(raw: string): { time: string; level: string; msg: string } {
  try {
    const rec = JSON.parse(raw) as { time?: number; level?: number | string; msg?: string };
    const level =
      typeof rec.level === 'number'
        ? (LOG_LEVELS[rec.level] ?? 'info')
        : typeof rec.level === 'string'
          ? rec.level
          : 'info';
    return {
      time: typeof rec.time === 'number' ? new Date(rec.time).toISOString() : '',
      level,
      msg: String(rec.msg ?? ''),
    };
  } catch {
    return { time: '', level: 'info', msg: raw };
  }
}

const LOG_CHUNK = 64 * 1024;
/** 单文件轮转上限 10MB，留点余量；防止异常大文件把设置页拖死 */
const LOG_SCAN_MAX_BYTES = 16 * 1024 * 1024;

interface LogPage {
  lines: { time: string; level: string; msg: string }[];
  hasMore: boolean;
  truncated: boolean;
}

/**
 * 日志分页：从文件末尾**按块倒读**，凑够 `offset + limit + 1` 条匹配行就停。
 *
 * 旧实现把尾部 2MB 全 split 一遍再 slice：翻页时既拿不到更早的行，也白扫一大片。
 * 现在第 1 页通常只读几十 KB。级别过滤在倒读时逐行做，所以筛选后也不会被
 * info 日志挤出窗口（2026-11-03 那个「日志页里啥也看不到」的坑天然消失）。
 * 返回顺序是「最新 → 最旧」，第 1 页即最新日志。
 */
function readLogPage(
  file: string,
  opts: { offset: number; limit: number; level: 'warn' | 'error' | 'info' | '' },
): LogPage {
  let size: number;
  try {
    size = fs.statSync(file).size;
  } catch {
    return { lines: [], hasMore: false, truncated: false };
  }
  if (size === 0) return { lines: [], hasMore: false, truncated: false };

  const collected: LogPage['lines'] = [];
  const { level: want, offset, limit } = opts;
  let skipped = 0;
  let pos = size;
  let scanned = 0;
  /** 更靠后的块切下来的首段（可能只有半行），要拼到下一块的末尾 */
  let pending = '';
  let done = false;
  let fd: number | null = null;

  const take = (raw: string): void => {
    if (done || !raw.trim()) return;
    const entry = parseLogLine(raw);
    if (want && !levelMatch(entry.level, want)) return;
    if (skipped < offset) {
      skipped += 1;
      return;
    }
    collected.push(entry);
    // 多收一条只为判断「还有下一页」，不返回给客户端
    if (collected.length > limit) done = true;
  };

  try {
    fd = fs.openSync(file, 'r');
    while (pos > 0 && !done && scanned < LOG_SCAN_MAX_BYTES) {
      const len = Math.min(LOG_CHUNK, pos);
      pos -= len;
      scanned += len;
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, pos);
      const parts = (buf.toString('utf8') + pending).split(/\r?\n/);
      // 首段可能不完整（前面还有字节），留到下一轮拼接
      pending = parts.shift() ?? '';
      // 其余是完整行、按文件顺序旧→新；倒序遍历 = 最新在前
      for (let i = parts.length - 1; i >= 0 && !done; i -= 1) take(parts[i]);
    }
    // 读到文件头时，最后剩下的首段就是第一行
    if (!done && pos === 0 && pending.trim()) take(pending);
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }

  return {
    lines: collected.slice(0, limit),
    hasMore: collected.length > limit,
    truncated: pos > 0 && scanned >= LOG_SCAN_MAX_BYTES,
  };
}

export function registerSystemSettings(app: FastifyInstance, k: KernelApi): void {
  for (const schema of SCHEMAS) app.addSchema(schema);

  app.get(
    '/api/v1/system/settings',
    secured('system:read', {
      schema: {
        operationId: 'systemSettingsGet',
        tags: TAG,
        summary: '全局设置（端口 / 并发 / 主机名 / 欢迎语 / 代理 / 日系兜底 / 大模型）',
        response: { 200: ref('SystemSettingsResponse') },
      },
    }),
    async () => ({
      settings: readSystemSettings(k.config) as unknown as SystemSettings,
      activeProxy: activeProxy(),
    }),
  );

  app.post(
    '/api/v1/system/settings',
    secured('system:write', {
      schema: {
        operationId: 'systemSettingsSet',
        tags: TAG,
        summary: '保存全局设置（端口/并发重启后生效；代理立即生效）',
        body: ref('SystemSettingsBody'),
        response: {
          200: ref('SystemSettingsResponse'),
          400: ref('ErrorResponse'),
        },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const body = (req.body || {}) as Record<string, unknown>;
      let saved: SystemSettings;
      try {
        saved = await writeSystemSettings(k.config, body);
      } catch (err) {
        return reply
          .code(400)
          .send({ error: Err.badRequest, message: String((err as Error)?.message || err) });
      }
      configureProxy(saved.proxy);
      app.log.info(
        { httpPort: saved.httpPort, apiConcurrency: saved.apiConcurrency, proxy: activeProxy() },
        'system settings saved',
      );
      return { settings: saved, activeProxy: activeProxy() };
    },
  );

  app.get(
    '/api/v1/system/tls',
    secured('system:read', {
      schema: {
        operationId: 'systemTlsInfo',
        tags: TAG,
        summary: 'HTTPS 证书状态（用户上传证书方案）',
        response: { 200: ref('SystemTlsInfoResponse') },
      },
    }),
    async () => {
      const s = readSystemSettings(k.config);
      return { ...tlsInfo(k.paths.dataDir), enabled: s.httpsEnabled, port: s.httpsPort };
    },
  );

  app.post(
    '/api/v1/system/tls',
    secured('system:write', {
      schema: {
        operationId: 'systemTlsUpload',
        tags: TAG,
        summary: '上传 HTTPS 证书与私钥（PEM；重启后启用）',
        body: ref('SystemTlsUploadBody'),
        response: { 200: ref('SystemTlsInfoResponse'), 400: ref('ErrorResponse') },
      },
    }),
    async (req: FastifyRequest, reply) => {
      const b = (req.body || {}) as { cert?: string; key?: string };
      const err = validateTlsPair(b.cert || '', b.key || '');
      if (err) {
        return reply.code(400).send({ error: Err.badRequest, message: err });
      }
      saveTls(k.paths.dataDir, b.cert || '', b.key || '');
      const s = readSystemSettings(k.config);
      return { ...tlsInfo(k.paths.dataDir), enabled: s.httpsEnabled, port: s.httpsPort };
    },
  );

  app.post(
    '/api/v1/system/tls/clear',
    secured('system:write', {
      schema: {
        operationId: 'systemTlsClear',
        tags: TAG,
        summary: '删除已上传的 HTTPS 证书',
        response: { 200: Type.Ref('SystemRestartResponse') },
      },
    }),
    async () => {
      clearTls(k.paths.dataDir);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/system/cache/info',
    secured('system:read', {
      schema: {
        operationId: 'systemCacheInfo',
        tags: TAG,
        summary: '缓存占用（缩略图 / 封面 / PDF 渲染）',
        response: { 200: ref('SystemCacheInfoResponse') },
      },
    }),
    async () => {
      let bytes = 0;
      let files = 0;
      for (const dir of cacheDirs(k)) {
        const r = sizeOfDir(dir);
        bytes += r.bytes;
        files += r.files;
      }
      return { bytes, files };
    },
  );

  app.post(
    '/api/v1/system/cache/clear',
    secured('system:write', {
      schema: {
        operationId: 'systemCacheClear',
        tags: TAG,
        summary: '清理缩略图 / 封面 / PDF 渲染缓存并清零命中计数（不动媒体库文件）',
        response: { 200: ref('SystemCacheClearResponse') },
      },
    }),
    async () => {
      const dirs = cacheDirs(k);
      let freedBytes = 0;
      let files = 0;
      for (const dir of dirs) {
        const r = removeDir(dir);
        freedBytes += r.bytes;
        files += r.files;
      }
      k.cache.reset();
      app.log.info({ freedBytes, files }, 'system cache cleared');
      return { ok: true, freedBytes, files };
    },
  );

  app.post(
    '/api/v1/system/db/compact',
    secured('system:write', {
      schema: {
        operationId: 'systemDbCompact',
        tags: TAG,
        summary: '数据库碎片整理（VACUUM，重写数据文件回收空洞空间）',
        response: {
          200: ref('SystemDbCompactResponse'),
          409: ref('ErrorResponse'),
        },
      },
    }),
    async (_req, reply) => {
      const file = path.join(k.paths.dataDir, 'colanas.sqlite');
      // 只量主库会得到假的「整理后更大」：WAL 里的数据在 checkpoint 前还没落回主库。
      // 这里按「主库 + -wal」算实际占用。
      const sizeOf = (): number => {
        let total = 0;
        for (const f of [file, `${file}-wal`]) {
          try {
            total += fs.statSync(f).size;
          } catch {
            /* 文件不存在按 0 算 */
          }
        }
        return total;
      };
      const before = sizeOf();
      try {
        // WAL 模式下先把日志落回主库，VACUUM 之后再 checkpoint 清空 -wal，
        // 否则「腾出来的空间」只是从一个文件挪到另一个文件。
        await sql`pragma wal_checkpoint(truncate)`.execute(k.db);
        await sql`vacuum`.execute(k.db);
        await sql`pragma wal_checkpoint(truncate)`.execute(k.db);
      } catch (err) {
        // 有并发写事务时 SQLite 会拒绝 VACUUM（database is locked）：明确告诉界面稍后重试
        app.log.warn({ err: String((err as Error)?.message || err) }, 'db compact failed');
        return reply.code(409).send({
          error: Err.conflict,
          message: `database busy: ${String((err as Error)?.message || err)}`,
        });
      }
      const after = sizeOf();
      const freedBytes = Math.max(0, before - after);
      app.log.info({ before, after, freedBytes }, 'database compacted');
      return { ok: true, beforeBytes: before, afterBytes: after, freedBytes };
    },
  );

  app.post(
    '/api/v1/system/restart',
    secured('system:write', {
      schema: {
        operationId: 'systemRestart',
        tags: TAG,
        summary: '重启内核（桌面端由外壳自动拉起；浏览器需手动刷新）',
        response: { 200: ref('SystemRestartResponse') },
      },
    }),
    async (_req, reply) => {
      // 先回包，再关闭（onClose 会停 sidecar / 释放 DB），最后由宿主重启
      setTimeout(async () => {
        try {
          await app.close();
        } catch {
          /* 关闭失败也要退出，交给宿主重启 */
        }
        process.exit(0);
      }, 400);
      return reply.send({ ok: true });
    },
  );

  app.get(
    '/api/v1/system/update/check',
    secured('system:read', {
      schema: {
        operationId: 'systemUpdateCheck',
        tags: TAG,
        summary: '检查本地版本目录（当前版本 / 最新版本）',
        response: { 200: ref('SystemUpdateCheckResponse') },
      },
    }),
    async () => {
      const updater = new Updater(k.paths.dataDir);
      const list = updater.list();
      const cur = updater.current();
      const latest = list.length > 0 ? list[list.length - 1] : null;
      return {
        currentId: cur?.id ?? null,
        currentVersion: cur?.version ?? null,
        latestId: latest?.id ?? null,
        latestVersion: latest?.version ?? null,
        hasUpdate: latest !== null && (!cur || latest.version > cur.version),
        versions: list.length,
      };
    },
  );

  app.get(
    '/api/v1/system/logs',
    secured('system:read', {
      schema: {
        operationId: 'systemLogs',
        tags: TAG,
        summary: '服务端日志分页（logs/kernel.log，时间倒序；第 1 页为最新）',
        querystring: Type.Object({
          // 别写 default：ajv 会把缺省值填进 q.limit，导致下面的 lines 兼容别名永远失效
          limit: Type.Optional(
            Type.Integer({ minimum: 1, maximum: 200, description: '每页行数（缺省 50）' }),
          ),
          offset: Type.Optional(
            Type.Integer({ minimum: 0, description: '从最新一条往回跳过的匹配行数（缺省 0）' }),
          ),
          /** 兼容旧调用方：等价于 limit */
          lines: Type.Optional(Type.Integer({ minimum: 1, maximum: 1000 })),
          file: Type.Optional(Type.String({ maxLength: 64 })),
          level: Type.Optional(
            Type.Union(
              [
                Type.Literal('all'),
                Type.Literal('warn'),
                Type.Literal('error'),
                Type.Literal('info'),
              ],
              {
                description:
                  'warn = warn+error（含 fatal）；error = 仅 error；info = 其余。筛选在截断**之前**做',
              },
            ),
          ),
        }),
        response: { 200: ref('SystemLogsResponse') },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as {
        lines?: number; limit?: number; offset?: number; file?: string; level?: string;
      };
      // 只允许读 logs 目录下的 kernel.log 及轮转文件，避免任意路径读取
      const name = q.file && /^kernel\.log(\.\d+)?$/.test(q.file) ? q.file : 'kernel.log';
      const file = path.join(k.paths.dataDir, 'logs', name);
      // lines 是旧参数（「取最后 N 行」），现在作为 limit 的兼容别名
      const limit = Math.min(Math.max(Math.trunc(Number(q.limit ?? q.lines ?? 50) || 50), 1), 200);
      const offset = Math.min(Math.max(Math.trunc(Number(q.offset ?? 0) || 0), 0), 1_000_000);
      const want = q.level === 'warn' || q.level === 'error' || q.level === 'info' ? q.level : '';
      // 倒读时逐行做级别过滤，天然保证「筛完还能凑够一页」
      const page = readLogPage(file, { offset, limit, level: want });

      let size = 0;
      let updatedAt = '';
      try {
        const st = fs.statSync(file);
        size = st.size;
        updatedAt = st.mtime.toISOString();
      } catch {
        /* 尚未写日志：返回空列表 */
      }

      return {
        file: name,
        size,
        updatedAt,
        lines: page.lines,
        truncated: page.truncated,
        limit,
        offset,
        hasMore: page.hasMore,
      };
    },
  );

  // 客户端日志上报：前端异常（请求超时 / 渲染炸 / 未捕获异常）落一条到同一份日志里。
  // 不加这个，「设置 → 日志」永远只有服务端视角，用户报的错（比如删除超时）一条也找不到。
  app.post(
    '/api/v1/system/client-log',
    secured('system:write', {
      schema: {
        operationId: 'systemClientLog',
        tags: TAG,
        summary: '上报一条客户端日志（前端错误 / 警告）',
        body: Type.Object({
          level: Type.Union([
            Type.Literal('error'),
            Type.Literal('warn'),
            Type.Literal('info'),
          ]),
          message: Type.String({ maxLength: 2000 }),
          route: Type.Optional(Type.String({ maxLength: 300, description: '接口 / 页面 / 操作' })),
          detail: Type.Optional(Type.String({ maxLength: 4000, description: '堆栈或上下文' })),
        }),
        response: { 200: Type.Object({ ok: Type.Boolean() }) },
      },
    }),
    async (req) => {
      const b = (req.body || {}) as {
        level?: string;
        message?: string;
        route?: string;
        detail?: string;
      };
      const message = String(b.message || '').trim().slice(0, 2000);
      if (!message) throw httpError(400, 'message required');
      const route = String(b.route || '').trim().slice(0, 300);
      // 日志页只渲染 msg，所以把路由拼进去；堆栈放 meta 里，避免一行占半屏
      const line = route ? `[client] ${message} (${route})` : `[client] ${message}`;
      const meta = { client: true, route, detail: String(b.detail || '').slice(0, 4000) };
      if (b.level === 'error') k.log.error(meta, line);
      else if (b.level === 'info') k.log.info(meta, line);
      else k.log.warn(meta, line);
      return { ok: true };
    },
  );
}
