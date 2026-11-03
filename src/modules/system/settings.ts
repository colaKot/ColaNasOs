import fs from 'node:fs';
import path from 'node:path';
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

const SCHEMAS = [
  ErrorResponse,
  SystemSettingsSchema,
  SystemSettingsBody,
  SettingsResponse,
  CacheClearResponse,
  CacheInfoResponse,
  RestartResponse,
  UpdateCheckResponse,
  TlsInfoResponse,
  TlsUploadBody,
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
}