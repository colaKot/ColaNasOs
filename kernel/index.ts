import fs from 'node:fs';
import path from 'node:path';
import Fastify from 'fastify';
import swagger from '@fastify/swagger';
import { Type } from '@sinclair/typebox';
import pino from 'pino';
import { sql } from 'kysely';
import { createDb, checkIntegrity, closeDb, analyzeTables } from './db';
import { Migrator } from './migrator';
import { createConfig } from './config';
import { readSystemSettings } from './system-settings';
import { configureProxy } from './proxy-fetch';
import { readTls } from './tls';
import { startHttpsProxy } from './https-proxy';
import { EventBus } from './bus';
import { I18nRegistry } from './i18n';
import { resolveContractFile } from './contracts';
import { ContractRegistry } from './contract';
import { TaskQueue } from './queue';
import { CacheStats } from './cache-stats';
import { hasScope, resolveSecret, signToken, verifyToken } from './auth';
import { secured } from './route';
import { MediaBridge } from './sidecar/media-bridge';
import { IndexerService } from './sidecar/indexer-service';
import { gpuProbe } from './gpu-probe';
import type { KernelApi } from './types';
import { createRegistry } from './modules';
import websocket from '@fastify/websocket';
import { attachTerminal } from '../src/modules/system/pty';
import { resolveApiToken } from '../src/modules/auth/api-token';
import { BASE_MIGRATIONS } from './migrations/base';
import { MIGRATION_ORDER } from './migrations/manifest';
import { checkAppAccess, checkPathAccess, readPolicy, requestPathOf } from './access-policy';
import { createWatchdog, type WatchdogMetrics } from './watchdog';
import { WatchService, DEFAULT_DEBOUNCE_MS } from './fs-watch';
import { PollService, DEFAULT_POLL_INTERVAL_MS } from './poll';
import { Err } from './errors';
import { registerDevCors, registerWebUi, resolveWebDir } from './static-web';

export interface KernelOptions {
  dataDir: string;
  port: number;
  /** false 时只装配不监听（供契约生成器使用） */
  listen?: boolean;
  /** 每次心跳回调（Electron 外壳用它做进程外监督） */
  onBeat?: (metrics: WatchdogMetrics) => void;
  /** 实际监听端口回调（Electron 用它加载设置里的自定义端口） */
  onListening?: (port: number) => void;
}

/** 无需认证的路径 */
const PUBLIC_PATHS = new Set([
  '/health',
  '/ready',
  '/openapi.json',
  '/api/v1/auth/dev-token',
  '/api/v1/auth/login',
  // 首次安装引导：库里没有账号时允许匿名创建第一个管理员（有账号即 409）
  '/api/v1/auth/bootstrap',
  '/api/v1/share/info',
  '/api/v1/share/download',
  // MCP 客户端使用独立访问令牌（不是会话 JWT），由 MCP 路由自行校验
  '/api/mcp',
]);

/** 允许用 `?token=` 认证的路径（外部播放器无法带请求头） */
const QUERY_TOKEN_PATHS = new Set([
  '/api/v1/video/stream',
  '/api/v1/music/stream',
  '/api/v1/book/file',
  '/api/v1/mount/download',
  // 浏览器 WebSocket 不能自定义请求头，只能把会话 JWT 放 query
  '/api/v1/system/terminal/ws',
]);

/** 启动期按大小轮转日志（蓝图 §54）：`kernel.log` → `.1` → `.2` …，只保留 N 份 */
function rotateLog(file: string, maxBytes: number, keep: number): void {
  try {
    if (fs.statSync(file).size < maxBytes) return;
  } catch {
    return; // 文件还不存在
  }
  for (let i = keep - 1; i >= 1; i -= 1) {
    const from = `${file}.${i}`;
    if (fs.existsSync(from)) fs.renameSync(from, `${file}.${i + 1}`);
  }
  fs.renameSync(file, `${file}.1`);
}

/** 错误响应里属于「结构化上下文」的字段，统一收进 `details` */
const DETAIL_KEYS = ['need', 'rule', 'path', 'required', 'scopes', 'reason', 'limit'];

export async function startKernel(opts: KernelOptions) {
  // stream 直链用 `?token=` 认证，日志里必须脱敏，避免令牌落盘
  const redactUrl = (url: string) => url.replace(/([?&]token=)[^&]*/gi, '$1***');

  // 日志落盘（蓝图 §54）：启动时按 10 MB 轮转、保留 3 份；`COLANAS_LOG_FILE=0` 只留 stdout
  const logToFile = process.env.COLANAS_LOG_FILE !== '0';
  let logDest: ReturnType<typeof pino.destination> | null = null;
  let logStream: ReturnType<typeof pino.multistream> | null = null;
  if (logToFile) {
    const logDir = path.join(opts.dataDir, 'logs');
    fs.mkdirSync(logDir, { recursive: true });
    const logFile = path.join(logDir, 'kernel.log');
    rotateLog(logFile, 10 * 1024 * 1024, 3);
    logDest = pino.destination({ dest: logFile, sync: false, mkdir: false });
    // 目录被外部清理（测试 / 卸载）时不要因为日志文件打不开而拖垮进程
    logDest.on('error', () => {});
    logStream = pino.multistream([{ stream: logDest }, { stream: process.stdout }]);
  }

  const app = Fastify({
    logger: {
      level: process.env.LOG_LEVEL || 'info',
      serializers: {
        req: (req: any) => ({
          method: req.method,
          url: redactUrl(String(req.url || '')),
          host: req.host,
          remoteAddress: req.remoteAddress,
        }),
      },
      ...(logStream ? { stream: logStream } : {}),
    },
  });

  // 统一错误落日志：Fastify 默认只把 5xx 打进日志，业务侧 `throw httpError(...)`
  // 的 4xx（参数校验 / 权限不足 / 路径越界 / 资源不存在）在日志页里一条都看不到，
  // 用户排查「为什么删不掉」时等于瞎猜（2026-11-03 反馈）。
  app.setErrorHandler((error, req, reply) => {
    const err = error as Error & { statusCode?: number; code?: string };
    const status = Number(err.statusCode) || 500;
    const base = { status, method: req.method, url: redactUrl(String(req.url || '')) };
    if (status >= 500) {
      req.log.error({ ...base, err }, 'request failed');
    } else {
      req.log.warn({ ...base, err: { message: err.message, name: err.name } }, 'request rejected');
    }
    if (reply.sent) return;
    const code = err.code;
    void reply.code(status).send({
      statusCode: status,
      error: status >= 500 ? 'Internal Server Error' : code || err.name || 'Error',
      ...(code ? { code } : {}),
      message: err.message,
    });
  });

  await app.register(swagger, {
    openapi: {
      info: { title: 'ColaNasOs API', version: 'v1' },
      components: {
        securitySchemes: {
          bearerAuth: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' },
        },
      },
    },
    // 用 TypeBox 的 $id 作为 components.schemas 名，避免默认的 def-N
    refResolver: {
      buildLocalReference: (json: any, _baseUri: any, _fragment: any, i: number) =>
        (json.$id as string | undefined) ?? `def-${i}`,
    },
  });

  // WebSocket：交互式终端用（普通 HTTP 路由不受影响）
  await app.register(websocket);

  // 测试提速（可选）：`COLANAS_KERNEL_TEMPLATE` 指向「已跑完迁移」的空库目录时，
  // 直接复制模板库再打开，省掉每个 smoke / behavior 域重复跑迁移的固定成本。
  // 生产不设置该变量，走原有流程；模板 key 由 tool/gen-kernel-template.js 按迁移文件内容派生。
  const dbFile = path.join(opts.dataDir, 'colanas.sqlite');
  const templateDir = process.env.COLANAS_KERNEL_TEMPLATE;
  if (templateDir && !fs.existsSync(dbFile)) {
    const tpl = path.join(templateDir, 'colanas.sqlite');
    if (fs.existsSync(tpl)) {
      fs.mkdirSync(opts.dataDir, { recursive: true });
      fs.copyFileSync(tpl, dbFile);
    }
  }

  const handle = createDb(dbFile);
  const { db, raw } = handle;

  // 进程内看门狗：先起采样，再逐阶段 mark，卡死时能看出卡在启动哪一步
  const watchdog = createWatchdog({ dataDir: opts.dataDir, log: app.log, onBeat: opts.onBeat });
  watchdog.start();
  watchdog.mark('db');

  // 启动完整性检查（§47）：失败直接拒绝启动，交由上层重启/告警
  const integrity = checkIntegrity(raw);
  if (!integrity.ok) {
    app.log.error({ integrity }, 'database integrity check failed');
    throw new Error('database integrity check failed: ' + integrity.messages.join('; '));
  }

  const migrator = new Migrator(db);
  watchdog.mark('migrate');
  const baseApplied = await migrator.run(BASE_MIGRATIONS, MIGRATION_ORDER);

  const config = await createConfig(db);
  // 全局设置：代理立即生效；端口 / 并发在本次启动读取（保存后需重启）
  const systemSettings = readSystemSettings(config);
  configureProxy(systemSettings.proxy);

  const localesPath = resolveContractFile('locales.json');
  const locales = JSON.parse(fs.readFileSync(localesPath, 'utf-8'));
  const i18n = I18nRegistry.fromJSON(locales);

  const queue = await TaskQueue.create(db, raw, (level, message, meta) => {
    if (level === 'warn') app.log.warn({ meta }, message);
    else app.log.info({ meta }, message);
  });
  const recovered = await queue.recover();
  if (recovered > 0) app.log.warn({ recovered }, 'recovered running tasks back to pending');

  const secret = resolveSecret();
  // 开发令牌（`/auth/dev-token`）与开发期 CORS：**必须显式开启**，production 下永不启用。
  // 旧写法是 `COLANAS_DEV_TOKEN === '1' || NODE_ENV !== 'production'` —— 等于「默认开机就给任何人发 * scope 令牌」，已修正。
  const devTokenEnabled =
    process.env.COLANAS_DEV_TOKEN === '1' && process.env.NODE_ENV !== 'production';

  // media sidecar：按需启动（第一次缩略图请求才拉起子进程）
  const mediaBridge = new MediaBridge({
    log: (level, message) => {
      if (level === 'error') app.log.error(message);
      else if (level === 'warn') app.log.warn(message);
      else app.log.info(message);
    },
  });

  // 文件监控（蓝图 §56）：只负责观测与合批，不认识业务表；增量扫描由模块订阅后自己触发
  const watchEnabled = process.env.COLANAS_WATCH !== '0';
  const watchDebounceMs =
    Number(process.env.COLANAS_WATCH_DEBOUNCE_MS) > 0
      ? Number(process.env.COLANAS_WATCH_DEBOUNCE_MS)
      : DEFAULT_DEBOUNCE_MS;
  const watch = new WatchService((level, message, meta) => {
    if (level === 'warn') app.log.warn({ meta }, message);
    else app.log.info({ meta }, message);
  });

  // 远程目录轮询（蓝图 §56）：SMB / WebDAV / rclone 没有可靠事件，只能周期性取快照比对
  // `COLANAS_POLL_INTERVAL_MS=0` 关闭轮询（全部改手动扫描）
  const pollEnv = Number(process.env.COLANAS_POLL_INTERVAL_MS);
  const pollIntervalMs = Number.isFinite(pollEnv) && pollEnv >= 0 ? pollEnv : DEFAULT_POLL_INTERVAL_MS;
  const pollEnabled = pollIntervalMs > 0;
  const poll = new PollService(
    (level, message, meta) => {
      if (level === 'warn') app.log.warn({ meta }, message);
      else app.log.info({ meta }, message);
    },
    { intervalMs: pollIntervalMs },
  );

  // 索引器：按需拉起（第一次 scan 才 spawn），批次由 IndexerBridge 在单事务里落库
  const indexer = new IndexerService(raw, {
    dataDir: opts.dataDir,
    log: (level, message) => {
      if (level === 'error') app.log.error(message);
      else if (level === 'warn') app.log.warn(message);
      else app.log.info(message);
    },
  });

  const cacheStats = new CacheStats();

  const k: KernelApi = {
    db,
    log: app.log,
    events: new EventBus(),
    tasks: {
      enqueue: (type, payload, o) => queue.enqueue(type, payload, o),
      enqueueIfIdle: (type, payload, o) => queue.enqueueIfIdle(type, payload, o),
      register: (type, handler) => queue.register(type, handler),
      registered: () => queue.registered(),
      stats: () => queue.stats(),
    },
    config,
    i18n,
    contract: new ContractRegistry(app),
    paths: { dataDir: opts.dataDir },
    cache: {
      record: (name, hit) => cacheStats.record(name, hit),
      snapshot: () => cacheStats.snapshot(),
      reset: () => cacheStats.reset(),
    },
    media: {
      thumb: (src, dst, size) => mediaBridge.thumb(src, dst, size),
      transcode: (src, dst, preset) => mediaBridge.transcode(src, dst, preset),
      hls: (src, dir, opts) => mediaBridge.hls(src, dir, opts),
      cancel: (dir) => mediaBridge.cancel(dir),
      subtitleTracks: (src) => mediaBridge.subtitleTracks(src),
      extractSubtitle: (src, index, dst, format) =>
        mediaBridge.extractSubtitle(src, index, dst, format),
      available: () => mediaBridge.available(),
    },
    /** 认证：用内核同一 secret 签发 token（模块登录用） */
    auth: {
      sign: (payload, ttlSec) => signToken(payload, secret, ttlSec ? { ttlSec } : {}),
    },
    indexer: {
      scan: (root) => indexer.scan(root),
      stats: () => indexer.stats(),
      get running() {
        return indexer.running;
      },
    },
    watch: {
      subscribe: (root, handler, opts) =>
        watchEnabled
          ? watch.subscribe(root, handler, { ...opts, debounceMs: opts?.debounceMs ?? watchDebounceMs })
          : () => {},
      stats: () => watch.stats(),
    },
    poll: {
      subscribe: (root, handler, opts) => (pollEnabled ? poll.subscribe(root, handler, opts) : () => {}),
      stats: () => poll.stats(),
    },
  };

  // 认证与授权（§41）：先认证，再校验路由声明的 scope
  app.addHook('preHandler', async (req, reply) => {
    const url = req.routeOptions.url ?? req.url.split('?')[0];
    // Web UI 静态资源：内核没有任何路由匹配、且不是 `/api/**` —— 交给静态托管兜底，不需要认证
    // （`/api/**` 的未匹配请求保持原有 401 行为，避免暴露「接口存在与否」）
    if (!req.routeOptions?.url && !url.startsWith('/api/')) return;
    if (PUBLIC_PATHS.has(url)) return;
    // HLS 分片由播放器按 m3u8 里的相对名拉取，无法携带请求头；
    // 用**会话级短期签名令牌**（?t=，sub 必须是 hls:<session>）代替裸会话 UUID。
    const hlsPrefix = '/api/v1/player/hls/';
    const hlsPath = req.url.split('?')[0];
    if (hlsPath.startsWith(hlsPrefix)) {
      const q = (req.query ?? {}) as { t?: string };
      const payload = typeof q.t === 'string' && q.t ? verifyToken(q.t, secret) : null;
      const sessionId = hlsPath.slice(hlsPrefix.length).split('/')[0];
      if (!payload || payload.sub !== `hls:${sessionId}` || !payload.scopes.includes('player:read')) {
        return reply.code(401).send({ error: Err.unauthorized, message: 'missing or invalid hls token' });
      }
      return;
    }

    // 认证：优先 Authorization 头；外部播放器无法带头的场景（video 直链）允许 query token
    let raw: string | null = null;
    const header = req.headers.authorization;
    if (header && header.startsWith('Bearer ')) raw = header.slice(7);
    if (!raw && QUERY_TOKEN_PATHS.has(url)) {
      const q = (req.query ?? {}) as { token?: unknown };
      if (typeof q.token === 'string' && q.token) raw = q.token;
    }
    if (!raw) {
      return reply.code(401).send({ error: Err.unauthorized, message: 'missing bearer token' });
    }

    let payload = verifyToken(raw, secret);
    // 长期访问令牌（Scoped Token）：JWT 校验失败时按 hash 查表；撤销/过期即失效
    if (!payload) payload = await resolveApiToken(db, raw);
    if (!payload) {
      return reply.code(401).send({ error: Err.unauthorized, message: 'invalid or expired token' });
    }

    const scope = req.routeOptions.config?.scope;
    if (scope && !hasScope(payload, scope)) {
      return reply.code(403).send({ error: Err.forbidden, required: scope, scopes: payload.scopes });
    }

    // 双层授权（服务端强制，与 UI 无关）：
    //   ① 应用级：配置了 appKey 白名单就只放行这些应用对应的 API 前缀
    //   ② 路径级：路由声明 pathScope 时，按 path 参数做读写 ACL
    const policy = readPolicy(config, payload.sub);
    const pathname = req.url.split('?')[0];
    const appDecision = checkAppAccess(policy.apps, pathname);
    if (!appDecision.ok) {
      return reply.code(403).send({
        error: Err.appForbidden,
        appKey: appDecision.appKey,
        apps: policy.apps,
      });
    }
    const pathScope = req.routeOptions.config?.pathScope;
    if (pathScope) {
      const target = requestPathOf(req as { query?: unknown; body?: unknown });
      if (target) {
        const pathDecision = checkPathAccess(policy.paths, pathScope, target);
        if (!pathDecision.ok) {
          return reply.code(403).send({
            error: Err.pathForbidden,
            need: pathScope,
            rule: pathDecision.rule,
            path: target,
          });
        }
      }
    }

    req.user = payload;
  });

  // 错误响应统一补齐 `code` / `traceId`（docs/03 §9.2 的形态；`error` 保留以兼容旧客户端）。
  // 只在 4xx/5xx 的 JSON 响应上补，不动二进制下载与 2xx。
  app.addHook('onSend', async (req, reply, payload) => {
    if (reply.statusCode < 400 || typeof payload !== 'string' || payload.length > 64 * 1024) return payload;
    try {
      const body = JSON.parse(payload) as Record<string, unknown>;
      if (!body || typeof body !== 'object' || typeof body.error !== 'string') return payload;
      if (body.code === undefined) body.code = body.error;
      if (body.traceId === undefined) body.traceId = String(req.id);
      // 把结构化上下文收进 details（docs/03 §9.2）；原字段保留，旧客户端不受影响
      if (body.details === undefined) {
        const details: Record<string, unknown> = {};
        for (const key of DETAIL_KEYS) {
          if (body[key] !== undefined) details[key] = body[key];
        }
        if (Object.keys(details).length > 0) body.details = details;
      }
      return JSON.stringify(body);
    } catch {
      return payload;
    }
  });

  app.get(
    '/openapi.json',
    { schema: { operationId: 'openapiJson', tags: ['system'], summary: '导出 OpenAPI 文档' } },
    async () => app.swagger(),
  );
  app.get(
    '/health',
    { schema: { operationId: 'healthCheck', tags: ['system'], summary: '存活检查' } },
    async () => {
      const live = readSystemSettings(config);
      return {
        ok: true,
        pid: process.pid,
        // 公开字段：客户端登录页 / 首页 / 桌面窗口标题用；不含凭据
        hostname: live.hostname,
        welcome: live.welcome,
      };
    },
  );
  app.get(
    '/ready',
    { schema: { operationId: 'readyCheck', tags: ['system'], summary: '就绪检查' } },
    async () => ({
      ok: state.db && state.modules,
      db: state.db,
      integrity: integrity.ok,
      modules: state.modules,
      degraded: state.degraded,
      skipped: state.skipped,
      tasksRecovered: recovered,
      locales: i18n.enabledCodes().length,
      watch: watch.stats(),
      poll: poll.stats(),
    }),
  );

  if (devTokenEnabled) {
    app.post(
      '/api/v1/auth/dev-token',
      {
        schema: {
          operationId: 'authDevToken',
          tags: ['auth'],
          summary: '开发用临时令牌（仅当 COLANAS_DEV_TOKEN=1 且非 production 时可用）',
        },
      },
      async (req) => {
        const body = (req.body ?? {}) as { sub?: string; scopes?: string[] };
        const scopes = Array.isArray(body.scopes) && body.scopes.length > 0 ? body.scopes : ['*'];
        const token = signToken({ sub: body.sub || 'dev', scopes }, secret, { ttlSec: 3600 });
        return { token, scopes, expiresIn: 3600 };
      },
    );
  }

  app.get(
    '/api/v1/tasks',
    secured('tasks:read', {
      schema: { operationId: 'tasksList', tags: ['tasks'], summary: '任务列表与统计' },
    }),
    async (req) => {
      const q = (req.query || {}) as { state?: string; limit?: string };
      const limit = Math.min(Number(q.limit || 50) || 50, 200);
      const items = await queue.list(q.state as any, limit);
      return { items, stats: await queue.stats() };
    },
  );

  // 事件增量拉取：客户端每几秒拉一次做局部刷新（比 SSE 省事，Web / 桌面 / 移动同一份实现）
  app.get(
    '/api/v1/events/recent',
    secured('events:read', {
      schema: {
        operationId: 'eventsRecent',
        tags: ['events'],
        summary: '事件增量拉取（按序号，供客户端局部刷新）',
        querystring: Type.Object({
          since: Type.Optional(Type.Integer({ minimum: 0, description: '上次拿到的 nextSeq，缺省 0' })),
          limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
        }),
        response: {
          200: Type.Object({
            items: Type.Array(
              Type.Object({
                seq: Type.Integer(),
                topic: Type.String(),
                at: Type.Integer(),
                data: Type.Unknown(),
              }),
            ),
            nextSeq: Type.Integer(),
          }),
        },
      },
    }),
    async (req) => {
      const q = (req.query || {}) as { since?: string; limit?: string };
      const since = Math.max(0, Number(q.since || 0) || 0);
      const limit = Math.max(1, Math.min(Number(q.limit || 64) || 64, 100));
      return k.events.eventsSince(since, limit);
    },
  );

  // 单个任务：客户端拿 taskId 后轮询这一条（比每次拉整个列表省）
  app.get(
    '/api/v1/tasks/:id',
    secured('tasks:read', {
      schema: {
        operationId: 'tasksGet',
        tags: ['tasks'],
        summary: '单个任务状态与进度',
      },
    }),
    async (req, reply) => {
      const id = String((req.params as { id?: string }).id || '');
      const task = await queue.get(id);
      if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
      return task;
    },
  );

  // 取消任务（排队中的立即停；运行中的由 handler 在下一个检查点看到 isCanceled）
  app.post(
    '/api/v1/tasks/cancel',
    secured('tasks:write', {
      schema: {
        operationId: 'tasksCancel',
        tags: ['tasks'],
        summary: '取消任务（pending 立即停；running 由 handler 的检查点退出）',
      },
    }),
    async (req, reply) => {
      const body = (req.body || {}) as { id?: string };
      if (!body.id) return reply.code(400).send({ error: Err.badRequest, message: 'id required' });
      const task = await queue.get(body.id);
      if (!task) return reply.code(404).send({ error: Err.notFound, message: 'task not found' });
      await queue.cancel(body.id);
      return { ok: true };
    },
  );

  // 暂停 / 恢复（蓝图 §8 的 paused 状态）：worker 只 claim pending，所以 paused 立即不再被取
  for (const [op, opId, summary] of [
    ['pause', 'tasksPause', '暂停任务（按 id / type，或缺省全部 pending）'],
    ['resume', 'tasksResume', '恢复任务（paused → pending）'],
  ] as const) {
    app.post(
      `/api/v1/tasks/${op}`,
      secured('tasks:write', {
        schema: { operationId: opId, tags: ['tasks'], summary },
      }),
      async (req) => {
        const body = (req.body || {}) as { id?: string; type?: string };
        const affected = op === 'pause' ? await queue.pause(body) : await queue.resume(body);
        return { ok: true, affected };
      },
    );
  }

  // 开发期（非 production）放行跨域：`flutter run -d chrome --web-port 5173` 的页面要直连本内核
  if (devTokenEnabled) registerDevCors(app);

  const state = {
    db: true,
    modules: false,
    degraded: [] as string[],
    skipped: [] as string[],
  };

  const registry = createRegistry();
  watchdog.mark('modules');
  const mounted = await registry.mount(app, k, migrator, MIGRATION_ORDER);

  // 交互式终端（SP3-10 二期）：完整 PTY 会话。
  // 鉴权走全局钩子（query token + `system:write`），这里只负责把 socket 交给会话管理器。
  app.get(
    '/api/v1/system/terminal/ws',
    // `schema.hide`：WS 路由不进 OpenAPI（契约里没有 WS，不能污染 `gen.check`）
    { websocket: true, schema: { hide: true }, config: { scope: 'system:write' } },
    (socket, req) => {
      const url = new URL(req.url || '/', 'http://127.0.0.1');
      attachTerminal(socket, {
        owner: req.user?.sub || 'anonymous',
        cols: Number(url.searchParams.get('cols') || 80),
        rows: Number(url.searchParams.get('rows') || 24),
        log: app.log,
      });
    },
  );

  // Web UI：把 Flutter 产物挂到「未匹配任何路由」的兜底（`/api/**` 仍返回 JSON 404）。
  // 目录可用 `COLANAS_WEB_DIR` 覆盖；没有产物就跳过，不影响纯 API 部署与冒烟。
  registerWebUi(app, resolveWebDir());

  state.modules = mounted.degraded.length === 0;
  state.degraded = mounted.degraded;
  state.skipped = mounted.skipped;

  // 本次启动真的跑过迁移（建表 / 建索引）才刷统计信息：ANALYZE 在大库上要几百 ms，
  // 不该每次启动都付这个代价。没有迁移时 sqlite_stat1 仍是上次的结果，够用。
  if (baseApplied.length > 0 || (mounted.applied?.length ?? 0) > 0) {
    analyzeTables(raw);
    app.log.info('sqlite statistics refreshed (ANALYZE)');
  }

  app.log.info({ baseApplied, ...mounted }, 'kernel ready');

  // 任务 worker：必须在模块注册完毕后再启动（handler 已就绪）；`COLANAS_TASK_CONCURRENCY` 默认 1
  const taskConcurrency = Math.max(
    1,
    Math.min(
      Number(process.env.COLANAS_TASK_CONCURRENCY) || systemSettings.apiConcurrency || 1,
      8,
    ),
  );
  queue.start({
    concurrency: taskConcurrency,
    pollMs: Math.max(50, Number(process.env.COLANAS_TASK_POLL_MS) || 500),
  });

  // 优雅关闭：关闭 media sidecar → 关闭 Fastify → 释放 DB
  app.addHook('onClose', async () => {
    watchdog.stop();
    watch.stopAll();
    poll.stopAll();
    gpuProbe.stop();
    await queue.stop();
    await indexer.stop();
    await mediaBridge.stop();
    await closeDb(handle);
    // 只 flush、不销毁：模块的收尾日志（如 mediaTool pump）在 close 之后仍可能写日志，
    // 提前 end() 会让它们抛 SonicBoom destroyed；进程退出时 SonicBoom 自行 flush。
    try {
      logDest?.flushSync();
    } catch {
      /* 尚未 ready 或已关闭 */
    }
  });

  // HTTPS 额外入口（用户上传证书）；HTTP 主监听保持不动，Electron/内部仍走 HTTP
  let httpsProxy: { close(): void } | null = null;
  app.addHook('onClose', async () => {
    httpsProxy?.close();
  });

  if (opts.listen !== false) {
    watchdog.mark('listen');
    // 端口优先级：显式 0（冒烟/测试：由系统挑空闲端口）> `PORT` 环境变量 > 设置页 httpPort > 默认。
    // 以前 `0` 会被 `systemSettings.httpPort`（默认 7788）吃掉，本机开着桌面端时
    // 所有 `startKernel({ port: 0 })` 的冒烟都会撞 EADDRINUSE。
    const listenPort =
      opts.port === 0
        ? 0
        : process.env.PORT
          ? opts.port
          : systemSettings.httpPort || opts.port;
    await app.listen({ port: listenPort, host: '0.0.0.0' });
    app.log.info({ port: listenPort }, 'kernel listening');
    // 预热 GPU 探针（仅 Windows，且只在真正监听时）：首轮采样要 ~2.5s，
    // 等用户打开监控页再启动会先显示「未检测到」。60s 无请求自动退出。
    // 冒烟用 listen:false，不会因此多起子进程。
    gpuProbe.info();
    if (systemSettings.httpsEnabled) {
      const pair = readTls(opts.dataDir);
      if (!pair) {
        app.log.warn('https enabled but certificate missing; https entry skipped');
      } else {
        httpsProxy = startHttpsProxy({
          port: systemSettings.httpsPort,
          targetPort: listenPort,
          cert: pair.cert,
          key: pair.key,
          log: {
            info: (message) => app.log.info(message),
            warn: (message, err) =>
              app.log.warn({ err: err ? String(err) : undefined }, message),
          },
        });
      }
    }
    try {
      opts.onListening?.(listenPort);
    } catch {
      /* 宿主未就绪：不影响监听 */
    }
  }
  watchdog.mark('ready');

  return {
    app,
    db,
    handle,
    queue,
    i18n,
    config,
    integrity,
    baseApplied,
    recovered,
    /** media sidecar 句柄（状态 / pid，供冒烟与监控用） */
    media: mediaBridge,
    /** 进程内看门狗（指标快照 / 阶段） */
    watchdog,
    ...mounted,
  };
}
