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

const SettingsShape = {
  httpPort: Type.Integer({ minimum: 1, maximum: 65535 }),
  httpsPort: Type.Integer({ minimum: 1, maximum: 65535 }),
  httpsEnabled: Type.Boolean(),
  apiConcurrency: Type.Integer({ minimum: 1, maximum: 8 }),
  hostname: Type.String({ maxLength: 10 }),
  welcome: Type.String({ maxLength: 100 }),
  proxy: Type.String({ maxLength: 200 }),
  javFallback: Type.Boolean(),
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
    /** 时间正序（最早 → 最新），只保留最后 N 行 */
    lines: Type.Array(LogEntry),
    /** 是否因为行数 / 字节上限只截取了尾部 */
    truncated: Type.Boolean(),
  },
  { $id: 'SystemLogsResponse' },
);

const SCHEMAS = [
  ErrorResponse,
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

/**
 * 读文件尾部最多 maxLines 行。
 *
 * 日志单文件上限 10 MB，整读会拖慢设置页；只从末尾倒读 `maxBytes`，
 * 并丢弃第一行（可能是被切断的半行 JSON）。
 */
function tailLines(
  file: string,
  maxLines: number,
  maxBytes = 2 * 1024 * 1024,
): { lines: string[]; truncated: boolean } {
  let st: fs.Stats;
  try {
    st = fs.statSync(file);
  } catch {
    return { lines: [], truncated: false };
  }
  if (st.size === 0) return { lines: [], truncated: false };

  const start = Math.max(0, st.size - maxBytes);
  const buf = Buffer.alloc(st.size - start);
  let fd: number | null = null;
  try {
    fd = fs.openSync(file, 'r');
    fs.readSync(fd, buf, 0, buf.length, start);
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }

  const all = buf
    .toString('utf8')
    .split(/\r?\n/)
    .filter((line) => line.length > 0);
  if (start > 0 && all.length > 0) all.shift();
  const lines = all.slice(-Math.max(1, maxLines));
  return { lines, truncated: start > 0 || all.length > lines.length };
}

export function registerSystemSettings(app: FastifyInstance, k: KernelApi): void {
  for (const schema of SCHEMAS) app.addSchema(schema);

  app.get(
    '/api/v1/system/settings',
    secured('system:read', {
      schema: {
        operationId: 'systemSettingsGet',
        tags: TAG,
        summary: '全局设置（端口 / 并发 / 主机名 / 欢迎语 / 代理 / 日系兜底）',
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
        summary: '服务端日志尾部（logs/kernel.log，按时间正序返回最后 N 行）',
        querystring: Type.Object({
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
      const q = (req.query || {}) as { lines?: number; file?: string; level?: string };
      // 只允许读 logs 目录下的 kernel.log 及轮转文件，避免任意路径读取
      const name = q.file && /^kernel\.log(\.\d+)?$/.test(q.file) ? q.file : 'kernel.log';
      const file = path.join(k.paths.dataDir, 'logs', name);
      const maxLines = Math.min(Math.max(q.lines ?? 200, 1), 1000);
      // 级别筛选必须在截断之前：请求日志一秒几十条，先取最后 200 行再筛的话，
      // 错误几乎全被 info 挤出窗口 —— 表现就是「日志页里啥也看不到」（2026-11-03 反馈）。
      const want = q.level === 'warn' || q.level === 'error' || q.level === 'info' ? q.level : '';
      const tail = tailLines(file, want ? Math.min(maxLines * 12, 4000) : maxLines);
      const parsed = tail.lines.map(parseLogLine);
      const filtered = want ? parsed.filter((l) => levelMatch(l.level, want)) : parsed;
      const lines = filtered.slice(-maxLines);

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
        lines,
        truncated: tail.truncated || filtered.length > lines.length,
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
