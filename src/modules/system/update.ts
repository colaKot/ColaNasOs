import fs from 'node:fs';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { hasScope } from '../../../kernel/auth';
import type { KernelApi } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import { resolvePackageVersion, versionId } from '../../../kernel/updater';
import { UpdateService, type JobStatus, type UpdateSettings } from '../../../kernel/update/service';

/**
 * 自动更新：检查 / 下载 / 切换 / 回滚 / 离线导入。
 *
 * 三条默认行为（方案 §13）：
 *   1. 服务端**不主动轮询**，只在有人打开界面时被动查一次（缓存 6h）；
 *   2. 不自动下载、不自动安装 —— 必须用户点；
 *   3. 切版本会重启内核（打断转码 / 做种），所以安装是显式动作。
 */

const TAG = ['system'];

const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
  },
  { $id: 'SystemUpdateErrorResponse' },
);

const UpdateCheckResponse = Type.Object(
  {
    /* ---- 兼容字段（设置页原来就只读这几个） ---- */
    currentId: Type.Union([Type.String(), Type.Null()]),
    currentVersion: Type.Union([Type.Integer(), Type.Null()]),
    latestId: Type.Union([Type.String(), Type.Null()]),
    latestVersion: Type.Union([Type.Integer(), Type.Null()]),
    hasUpdate: Type.Boolean(),
    versions: Type.Integer(),
    /* ---- 新字段 ---- */
    currentSemver: Type.String(),
    latestSemver: Type.String(),
    releasedAt: Type.String(),
    notes: Type.Record(Type.String(), Type.String()),
    /** delta = 只下变化文件（2~4 MB）；full = 下整包；none = 没有可用包 */
    mode: Type.String(),
    /** 增量包字节数（压缩后），给界面显示「约 3 MB」 */
    deltaBytes: Type.Integer(),
    /** 这一版能不能走增量（当前版本不在基线里 = 只能全量） */
    deltaAvailable: Type.Boolean(),
    /** 全量安装包字节数（0 = 清单里没有全量包） */
    fullBytes: Type.Integer(),
    /** 需要重装服务端（Electron 大版本变了） */
    needsReshell: Type.Boolean(),
    /** 版本目录是否已拆壳（false = 老安装，只能全量） */
    managed: Type.Boolean(),
    minShell: Type.String(),
    /** 本次结果是否来自缓存（6h 内不重复打网络） */
    cached: Type.Boolean(),
    checkedAt: Type.Integer(),
    /** 检查失败的原因（空串 = 正常）。离线 NAS 是常态，所以失败也返回 200 */
    error: Type.String(),
    /** 客户端组件（query 带 component 时才有内容） */
    client: Type.Optional(
      Type.Object({
        component: Type.String(),
        hasUpdate: Type.Boolean(),
        latestSemver: Type.String(),
        latestVersionCode: Type.Integer(),
        assets: Type.Array(
          Type.Object({
            kind: Type.String(),
            size: Type.Integer(),
            sha256: Type.String(),
            urls: Type.Array(Type.String()),
          }),
        ),
      }),
    ),
  },
  { $id: 'SystemUpdateCheckResponse' },
);

const JobSchema = Type.Object(
  {
    phase: Type.String(),
    percent: Type.Integer(),
    loaded: Type.Integer(),
    total: Type.Integer(),
    speed: Type.Integer(),
    asset: Type.String(),
    source: Type.String(),
    message: Type.String(),
    error: Type.String(),
    hint: Type.String(),
    startedAt: Type.Integer(),
    updatedAt: Type.Integer(),
    targetId: Type.String(),
    mode: Type.String(),
    /** 全量包是否已交给安装程序自动执行（true 时界面不再让人手动双击） */
    autoRun: Type.Boolean(),
  },
  { $id: 'SystemUpdateJob' },
);

const JobResponse = Type.Object({ job: Type.Ref('SystemUpdateJob') }, { $id: 'SystemUpdateJobResponse' });
const OkResponse = Type.Object(
  { ok: Type.Boolean(), job: Type.Optional(Type.Ref('SystemUpdateJob')), id: Type.Optional(Type.String()) },
  { $id: 'SystemUpdateOkResponse' },
);

const UpdateConfigResponse = Type.Object(
  {
    manifestUrls: Type.Array(Type.String()),
    channel: Type.String(),
    autoCheck: Type.Boolean(),
    /** 当前版本目录（空串 = 未拆壳） */
    versionDir: Type.String(),
    /** 离线包投放目录，界面上要显示给用户拷 U 盘用 */
    inboxDir: Type.String(),
    offline: Type.Array(
      Type.Object({ name: Type.String(), size: Type.Integer(), mtime: Type.Integer() }),
    ),
    cacheBytes: Type.Integer(),
    cacheFiles: Type.Integer(),
  },
  { $id: 'SystemUpdateConfigResponse' },
);

const UpdateConfigBody = Type.Object(
  {
    manifestUrls: Type.Optional(Type.Array(Type.String({ maxLength: 500 }), { maxItems: 8 })),
    channel: Type.Optional(Type.String({ maxLength: 20 })),
    autoCheck: Type.Optional(Type.Boolean()),
  },
  { $id: 'SystemUpdateConfigBody' },
);

const InstallBody = Type.Object(
  {
    force: Type.Optional(Type.Boolean()),
    /**
     * 装哪种：`auto`（默认，能增量就增量）/ `delta` / `full`。
     * 界面上「增量更新」「下载并安装完整包」两个按钮分别对应后两个。
     */
    mode: Type.Optional(Type.String({ maxLength: 8, pattern: '^(auto|delta|full)$' })),
  },
  { $id: 'SystemUpdateInstallBody' },
);
const OfflineBody = Type.Object({ name: Type.String({ maxLength: 200 }) }, { $id: 'SystemUpdateOfflineBody' });

const SCHEMAS = [
  ErrorResponse,
  UpdateCheckResponse,
  JobSchema,
  JobResponse,
  OkResponse,
  UpdateConfigResponse,
  UpdateConfigBody,
  InstallBody,
  OfflineBody,
];

/** 进程内单例：任务状态在内存里，重启即清（下载缓存落盘，可续传） */
let singleton: UpdateService | null = null;

function serviceFor(k: KernelApi): UpdateService {
  if (singleton) return singleton;
  singleton = new UpdateService({
    dataDir: k.paths.dataDir,
    currentSemver: process.env.COLANAS_APP_VERSION || undefined,
    shellVersion: process.env.COLANAS_SHELL_VERSION || undefined,
    log: (msg, extra) => {
      // 走 app.log 更合适，但 service 是纯模块；这里用 stderr，由内核日志管道收走
      void msg;
      void extra;
    },
    /**
     * 切指针前做一次 DB 快照。
     *
     * 用 `VACUUM INTO` 而不是复制 `.db`：库开着 WAL，复制出来可能缺最后几个事务；
     * `VACUUM INTO` 是 SQLite 官方的在线备份，产出的是自洽单文件。
     */
    beforeActivate: async (targetId) => {
      try {
        const dir = path.join(k.paths.dataDir, 'backup', 'db-snapshots');
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, `${targetId}-${Date.now()}.db`);
        await sql`VACUUM INTO ${file}`.execute(k.db);
      } catch (err) {
        // 快照失败不该拦住更新：继续，但把原因留在日志里
        k.log?.warn?.({ err: String((err as Error).message) }, 'update: db snapshot failed');
      }
    },
  });
  return singleton;
}

/** 版本目录根（`<dataDir>/versions`），也用于统计已有版本数 */
function countVersions(dataDir: string): number {
  try {
    return fs
      .readdirSync(path.join(dataDir, 'versions'), { withFileTypes: true })
      .filter((e) => e.isDirectory() && /^D\d+$/.test(e.name)).length;
  } catch {
    return 0;
  }
}

function lanBase(req: FastifyRequest): string {
  const host = String(req.headers.host || '');
  if (!host) return '';
  const proto = String(req.headers['x-forwarded-proto'] || 'http');
  return `${proto}://${host}`;
}

function jobOf(s: UpdateService): JobStatus {
  return s.jobStatus();
}

/** 进程内只装一次「自动检查」定时器（默认关，设置里打开才真的联网） */
let autoCheckTimer: NodeJS.Timeout | null = null;

export function registerSystemUpdate(app: FastifyInstance, k: KernelApi): void {
  for (const schema of SCHEMAS) app.addSchema(schema);

  if (!autoCheckTimer) {
    /**
     * 每 6 小时一次，只有开关打开才发请求（方案 §13.2：默认完全不轮询）。
     * 只是**刷新清单缓存**，不下载、不安装 —— 安装永远是用户点的动作。
     */
    autoCheckTimer = setInterval(() => {
      try {
        const svc = serviceFor(k);
        if (!svc.settings().autoCheck) return;
        void svc.loadManifest({ force: true }).catch(() => undefined);
      } catch {
        /* 内核正在退出 */
      }
    }, 6 * 60 * 60 * 1000);
    autoCheckTimer.unref?.();
  }

  /**
   * 检查更新。
   *
   * `component` 省略 = 只查服务端；带 `client_pc` / `client_android` 时附带该组件的
   * 资产列表（客户端登录后就走这个接口，不需要知道 GitCode 地址）。
   *
   * 权限分两层（不用 `secured('system:read')` 一刀切）：
   * - **客户端自查**（`client_pc` / `client_android`）是每个登录端的基础能力：
   *   受限账号（例如只给视频 / 音乐的电视账号）没有 `system:read`，但它照样要能升级
   *   自己的 APK。要求 `system:read` 的结果是电视上「检查更新」永远 403 → 界面
   *   显示「检查失败，点此重试」，看起来像网络问题。
   * - **服务端更新信息**（`component` 缺省 / `server`）属于系统域，仍要 `system:read`。
   */
  app.get(
    '/api/v1/system/update/check',
    secured('', {
      schema: {
        operationId: 'systemUpdateCheck',
        tags: TAG,
        summary: '检查更新（服务端增量 / 客户端整包；默认 6 小时缓存）',
        querystring: Type.Object({
          component: Type.Optional(
            Type.Union([Type.Literal('server'), Type.Literal('client_pc'), Type.Literal('client_android')]),
          ),
          current: Type.Optional(Type.String({ maxLength: 32, description: '客户端当前 semver' })),
          currentCode: Type.Optional(Type.Integer({ minimum: 0 })),
          build: Type.Optional(
            Type.Union([Type.Literal('phone'), Type.Literal('tv'), Type.Literal('photo')], {
              description: '安卓客户端构建形态：TV 只下发 apk_tv，手机只下发 apk，相册端只下发 apk_photo',
            }),
          ),
          force: Type.Optional(Type.Union([Type.Literal('1'), Type.Literal('0')])),
        }),
        response: { 200: Type.Ref('SystemUpdateCheckResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as {
        component?: string;
        current?: string;
        currentCode?: number;
        build?: string;
        force?: string;
      };
      const svc = serviceFor(k);
      const isClient = q.component === 'client_pc' || q.component === 'client_android';
      const canSeeSystem = req.user ? hasScope(req.user, 'system:read') : false;
      if (!isClient && !canSeeSystem) {
        return reply.code(403).send({ error: Err.forbidden, message: '需要 system:read', required: 'system:read' });
      }
      // 受限账号不许强刷清单源（`force=1` 会主动打 GitCode），只用 6 小时缓存
      const force = canSeeSystem && q.force === '1';
      /**
       * 本地调试包优先：安卓 + 调试目录里有 APK 时，连清单源都不碰。
       * 否则离线 NAS 会先在 GitCode / GitHub 上等满超时，用户看到的是「检查半天」。
       */
      const buildKind =
        q.build === 'tv' ? 'tv' : q.build === 'photo' ? 'photo' : q.build === 'phone' ? 'phone' : undefined;
      const useLocalApk = q.component === 'client_android' && svc.hasLocalApk(buildKind);
      /**
       * 检查失败**不是**接口错误：内网 NAS 常年离线，清单源也可能临时不可达。
       * 这里返回 200 + `error` 字段，让界面显示「检查失败，可稍后重试」，
       * 而不是把一个登录后的红点检查变成一条报错日志。
       *
       * 客户端检查（安卓）不能因为服务端清单拉不到就整个失败：本地调试包
       * 目录里有 APK 时，客户端更新完全不依赖清单源，必须继续往下走。
       *
       * 只有拿到 `system:read` 的账号才查服务端：受限账号的这次请求只为客户端
       * 自查，既不该让它等清单源超时，也不该把服务端版本号透露出去。
       */
      let server: Awaited<ReturnType<UpdateService['checkServer']>> | null = null;
      let failure = '';
      if (canSeeSystem && !useLocalApk) {
        try {
          server = await svc.checkServer({ force });
        } catch (err) {
          failure = String((err as Error).message || err);
          app.log.info({ err: failure }, 'update check unavailable');
        }
      }
      const cur = server?.current ?? svc.current();

      const payload: Record<string, unknown> = {
        currentId: cur.id,
        currentVersion: cur.version,
        latestId: server?.latest ? versionId(server.latest.version) : null,
        latestVersion: server?.latest?.version ?? null,
        hasUpdate: server?.hasUpdate ?? false,
        versions: countVersions(k.paths.dataDir),
        currentSemver: cur.semver || resolvePackageVersion().semver,
        latestSemver: server?.latest?.semver ?? '',
        releasedAt: server?.latest?.releasedAt ?? '',
        notes: server?.latest?.notes ?? {},
        mode: server?.mode ?? 'none',
        deltaBytes: server?.deltaBytes ?? 0,
        deltaAvailable: server?.deltaAvailable ?? false,
        fullBytes: server?.fullBytes ?? 0,
        needsReshell: server?.needsReshell ?? false,
        managed: cur.managed,
        minShell: server?.minShell ?? '',
        cached: server ? !force : false,
        checkedAt: Date.now(),
        error: failure,
      };

      if (isClient) {
        try {
          const component = q.component as 'client_pc' | 'client_android';
          const client = await svc.checkClient(component, {
            currentSemver: q.current,
            currentVersionCode: q.currentCode,
            lanBase: lanBase(req),
            force,
            build: buildKind,
          });
          // 顺手把安装包缓存到本机：下次客户端来要时，局域网地址就是第一条。
          // 本地调试包本身就是局域网文件，再去拉清单预取只会白等超时。
          if (client.hasUpdate) {
            if (!useLocalApk) void svc.prefetchClientAsset(component);
            // 本地调试包不依赖清单源：服务端清单失败也别把整次检查判成失败
            payload.error = '';
          }
          payload.client = {
            component: client.component,
            hasUpdate: client.hasUpdate,
            latestSemver: client.latest?.semver ?? '',
            latestVersionCode: client.latest?.versionCode ?? 0,
            assets: client.assets.map((a) => ({
              kind: a.kind,
              size: a.size,
              sha256: a.sha256,
              urls: a.urls,
            })),
          };
        } catch (err) {
          const message = String((err as Error).message || err);
          if (!payload.error) payload.error = message;
        }
      }

      return payload;
    },
  );

  /** 开始安装（异步任务）：立刻返回 job，进度看 /status */
  app.post(
    '/api/v1/system/update/install',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateInstall',
        tags: TAG,
        summary: '开始更新服务端（增量优先，失败回退全量）',
        body: Type.Optional(Type.Ref('SystemUpdateInstallBody')),
        response: { 200: Type.Ref('SystemUpdateJobResponse'), 409: Type.Ref('SystemUpdateErrorResponse') },
      },
    }),
    async (req, reply) => {
      const svc = serviceFor(k);
      if (svc.isBusy()) {
        return reply.code(409).send({
          error: Err.conflict,
          message: '已有更新任务在进行',
        });
      }
      const body = (req.body || {}) as { force?: boolean; mode?: 'auto' | 'delta' | 'full' };
      const job = await svc.install({ force: body.force, mode: body.mode });
      return { job: { ...job } };
    },
  );

  app.get(
    '/api/v1/system/update/status',
    secured('system:read', {
      schema: {
        operationId: 'systemUpdateStatus',
        tags: TAG,
        summary: '更新任务进度',
        response: { 200: Type.Ref('SystemUpdateJobResponse') },
      },
    }),
    async () => ({ job: { ...jobOf(serviceFor(k)) } }),
  );

  app.post(
    '/api/v1/system/update/cancel',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateCancel',
        tags: TAG,
        summary: '取消更新（保留已下载片段，可续传）',
        response: { 200: Type.Ref('SystemUpdateJobResponse') },
      },
    }),
    async () => ({ job: { ...serviceFor(k).cancel() } }),
  );

  app.post(
    '/api/v1/system/update/rollback',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateRollback',
        tags: TAG,
        summary: '回滚到上一版本（允许降级）',
        response: { 200: Type.Ref('SystemUpdateOkResponse'), 400: Type.Ref('SystemUpdateErrorResponse') },
      },
    }),
    async (_req, reply) => {
      try {
        const { id } = serviceFor(k).rollback();
        return { ok: true, id };
      } catch (err) {
        return reply.code(400).send({ error: Err.badRequest, message: String((err as Error).message) });
      }
    },
  );

  /**
   * 重启内核使新版本生效。
   *
   * 会话侧由一个短定时器退出：先回包，再退出。外壳监听到 exit(0) 会重新 fork
   * `versions/current` 指向的内核 —— 这正是「切换版本」的最后一步。
   */
  app.post(
    '/api/v1/system/update/restart',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateRestart',
        tags: TAG,
        summary: '重启内核使更新生效',
        response: { 200: Type.Ref('SystemUpdateOkResponse') },
      },
    }),
    async () => {
      /**
       * 先回包，再优雅关闭：`app.close()` 会停 sidecar / 释放 DB / 停内置下载器
       * （与 `/system/restart` 同一套收尾）；直接 process.exit 会跳过这些。
       */
      setTimeout(async () => {
        try {
          await app.close();
        } catch {
          /* 关闭失败也要退出，交给外壳重启 */
        }
        process.exit(0);
      }, 400);
      return { ok: true };
    },
  );

  app.get(
    '/api/v1/system/update/config',
    secured('system:read', {
      schema: {
        operationId: 'systemUpdateConfig',
        tags: TAG,
        summary: '更新设置 / 离线包目录 / 缓存占用',
        response: { 200: Type.Ref('SystemUpdateConfigResponse') },
      },
    }),
    async () => {
      const svc = serviceFor(k);
      const s = svc.settings();
      const usage = svc.cacheUsage();
      return {
        manifestUrls: s.manifestUrls,
        channel: s.channel,
        autoCheck: s.autoCheck,
        versionDir: svc.current().dir ?? '',
        inboxDir: path.join(k.paths.dataDir, 'update', 'inbox'),
        offline: svc.listOffline().map((o) => ({ name: o.name, size: o.size, mtime: Math.round(o.mtime) })),
        cacheBytes: usage.bytes,
        cacheFiles: usage.files,
      };
    },
  );

  app.put(
    '/api/v1/system/update/config',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateConfigSave',
        tags: TAG,
        summary: '保存更新设置',
        body: Type.Ref('SystemUpdateConfigBody'),
        response: { 200: Type.Ref('SystemUpdateConfigResponse') },
      },
    }),
    async (req) => {
      const svc = serviceFor(k);
      const body = (req.body || {}) as Partial<UpdateSettings>;
      svc.saveSettings(body);
      const s = svc.settings();
      const usage = svc.cacheUsage();
      return {
        manifestUrls: s.manifestUrls,
        channel: s.channel,
        autoCheck: s.autoCheck,
        versionDir: svc.current().dir ?? '',
        inboxDir: path.join(k.paths.dataDir, 'update', 'inbox'),
        offline: svc.listOffline().map((o) => ({ name: o.name, size: o.size, mtime: Math.round(o.mtime) })),
        cacheBytes: usage.bytes,
        cacheFiles: usage.files,
      };
    },
  );

  app.post(
    '/api/v1/system/update/cache/clear',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateCacheClear',
        tags: TAG,
        summary: '清理更新下载缓存',
        response: {
          200: Type.Object(
            { ok: Type.Boolean(), freedBytes: Type.Integer(), files: Type.Integer() },
            { $id: 'SystemUpdateCacheClearResponse' },
          ),
        },
      },
    }),
    async () => {
      const freed = serviceFor(k).clearCache();
      return { ok: true, freedBytes: freed.bytes, files: freed.files };
    },
  );

  /** 导入 `update/inbox` 里的离线包（断网 NAS 用 U 盘拷进来） */
  app.post(
    '/api/v1/system/update/offline',
    secured('system:write', {
      schema: {
        operationId: 'systemUpdateOffline',
        tags: TAG,
        summary: '导入离线更新包（update/inbox/<目录>/）',
        body: Type.Ref('SystemUpdateOfflineBody'),
        response: { 200: Type.Ref('SystemUpdateOkResponse'), 400: Type.Ref('SystemUpdateErrorResponse') },
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { name?: string };
      const name = path.basename(String(body.name || ''));
      if (!name) return reply.code(400).send({ error: Err.badRequest, message: '缺离线包名' });
      const dir = path.join(k.paths.dataDir, 'update', 'inbox', name);
      if (!fs.existsSync(path.join(dir, 'update.json'))) {
        return reply.code(400).send({ error: Err.notFound, message: `离线包不存在或不是有效目录: ${name}` });
      }
      try {
        const r = await serviceFor(k).importOffline(name);
        return { ok: true, id: r.targetId };
      } catch (err) {
        return reply.code(400).send({ error: Err.badRequest, message: String((err as Error).message) });
      }
    },
  );

  /**
   * 资产缓存（局域网分发）。
   *
   * 客户端拿到 `urls` 时，服务端已缓存过的资产会以本机地址排第一 —— 内网满速，
   * 也不消耗公网流量。支持 Range，客户端下载器可以续传。
   * `hide: true`：不进 OpenAPI（纯文件流，没有客户端存根的必要）。
   */
  app.get('/api/v1/system/update/asset/:sha/:name', { schema: { hide: true } }, async (req, reply) => {
    const params = req.params as { sha?: string; name?: string };
    const sha = String(params.sha || '');
    if (!/^[a-f0-9]{16,64}$/i.test(sha)) {
      return reply.code(400).send({ error: Err.badRequest, message: 'bad sha' });
    }
    const svc = serviceFor(k);
    const file = svc.cachedAssetPath(sha);
    if (!file || !fs.existsSync(file)) {
      return reply.code(404).send({ error: Err.notFound, message: 'asset not cached' });
    }
    const size = fs.statSync(file).size;
    reply.header('accept-ranges', 'bytes');
    reply.header('content-type', 'application/octet-stream');
    const range = String(req.headers.range || '');
    const m = /^bytes=(\d+)-(\d*)$/.exec(range);
    if (m) {
      const start = Number(m[1]);
      const end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
      if (start >= size) {
        reply.header('content-range', `bytes */${size}`);
        return reply.code(416).send();
      }
      reply.code(206);
      reply.header('content-range', `bytes ${start}-${end}/${size}`);
      reply.header('content-length', String(end - start + 1));
      return reply.send(fs.createReadStream(file, { start, end }));
    }
    reply.header('content-length', String(size));
    return reply.send(fs.createReadStream(file));
  });

  /**
   * 本地调试包分发。
   *
   * APK 放在 `<dataDir>/update/local-apk/`（或 `COLANAS_LOCAL_APK_DIR`），
   * 客户端检查更新时会拿到这个地址 —— 局域网直连，不经过 GitCode / GitHub。
   * 与资产缓存一样支持 Range 续传。
   */
  app.get('/api/v1/system/update/local-apk/:sha/:name', { schema: { hide: true } }, async (req, reply) => {
    const params = req.params as { sha?: string; name?: string };
    const sha = String(params.sha || '');
    if (!/^[a-f0-9]{64}$/i.test(sha)) {
      return reply.code(400).send({ error: Err.badRequest, message: 'bad sha' });
    }
    const file = serviceFor(k).localAssetPath(sha);
    if (!file || !fs.existsSync(file)) {
      return reply.code(404).send({ error: Err.notFound, message: 'local apk not found' });
    }
    const size = fs.statSync(file).size;
    reply.header('accept-ranges', 'bytes');
    reply.header('content-type', 'application/vnd.android.package-archive');
    const range = String(req.headers.range || '');
    const m = /^bytes=(\d+)-(\d*)$/.exec(range);
    if (m) {
      const start = Number(m[1]);
      const end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
      if (start >= size) {
        reply.header('content-range', `bytes */${size}`);
        return reply.code(416).send();
      }
      reply.code(206);
      reply.header('content-range', `bytes ${start}-${end}/${size}`);
      reply.header('content-length', String(end - start + 1));
      return reply.send(fs.createReadStream(file, { start, end }));
    }
    reply.header('content-length', String(size));
    return reply.send(fs.createReadStream(file));
  });
}
