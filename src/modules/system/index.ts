import fs from 'node:fs';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Type } from '@sinclair/typebox';
import { secured } from '../../../kernel/route';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import type { ServerModule } from '../../../kernel/types';
import { Err } from '../../../kernel/errors';
import { registerSystemSettings } from './settings';
import { registerDevClientLog } from './dev-log';
import { gpuProbe } from '../../../kernel/gpu-probe';
import type { FastifyRequest, FastifyReply } from 'fastify';

/**
 * SP3-10 的 system 部分：**monitor / process**（docker 与 service 已明确不做）。
 *
 * 只暴露只读监控与受限的进程终止：
 *   - 监控：CPU 采样、内存、磁盘（dataDir 所在卷）、负载、运行时长
 *   - 进程：平台命令解析（Windows tasklist / POSIX ps）
 *   - 终止：拒绝 pid <= 4 与自身进程；不存在返回 404
 */
const TAG = ['system'];
const run = promisify(execFile);

const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});

const DiskItem = Type.Object({
  mount: Type.String(),
  total: Type.Integer(),
  free: Type.Integer(),
  used: Type.Integer(),
});

const GpuInfo = Type.Object({
  name: Type.String(),
  /** 驱动版本（Windows 取自显卡注册表；nvidia-smi 路径可能为空串） */
  driverVersion: Type.String(),
  usagePercent: Type.Number(),
  memUsed: Type.Integer(),
  memTotal: Type.Integer(),
});

const MonitorResponse = Type.Object({
  cpu: Type.Object({
    cores: Type.Integer(),
    loadavg: Type.Array(Type.Number()),
    usagePercent: Type.Number(),
    perCore: Type.Array(Type.Number()),
  }),
  mem: Type.Object({
    total: Type.Integer(),
    free: Type.Integer(),
    used: Type.Integer(),
  }),
  disk: Type.Object({
    total: Type.Integer(),
    free: Type.Integer(),
    used: Type.Integer(),
  }),
  /** 所有本地磁盘（Windows 逐盘符，POSIX 仅根卷） */
  disks: Type.Array(DiskItem),
  /** 独立显卡（nvidia-smi 可用时才有，否则 null） */
  gpu: Type.Union([Type.Null(), GpuInfo]),
  uptimeSec: Type.Integer(),
  platform: Type.String(),
  arch: Type.String(),
  node: Type.String(),
});

const ProcessItem = Type.Object({
  pid: Type.Integer(),
  name: Type.String(),
  memKB: Type.Integer(),
});

const ProcessListResponse = Type.Object({ items: Type.Array(ProcessItem), total: Type.Integer() });

const KillBody = Type.Object({ pid: Type.Integer({ minimum: 1 }) });
const OkResponse = Type.Object({ ok: Type.Boolean(), pid: Type.Integer() });

/** 通过两次采样计算整机 CPU 使用率 */
async function cpuUsage(sampleMs = 200): Promise<{ total: number; perCore: number[] }> {
  const snap = () =>
    os.cpus().map((c) => {
      let total = 0;
      for (const v of Object.values(c.times)) total += v;
      return { idle: c.times.idle, total };
    });

  const a = snap();
  await new Promise((r) => setTimeout(r, sampleMs));
  const b = snap();
  const perCore = a.map((x, i) => {
    const y = b[i] ?? x;
    const dTotal = y.total - x.total;
    const dIdle = y.idle - x.idle;
    return dTotal > 0 ? Math.round((1 - dIdle / dTotal) * 1000) / 10 : 0;
  });
  let all = 0;
  let busy = 0;
  for (let i = 0; i < a.length; i += 1) {
    const y = b[i] ?? a[i];
    all += y.total - a[i].total;
    busy += y.total - a[i].total - (y.idle - a[i].idle);
  }
  return { total: all > 0 ? Math.round((busy / all) * 1000) / 10 : 0, perCore };
}

/** 逐盘符统计；不存在/无权限的盘符直接跳过 */
function diskList(): { mount: string; total: number; free: number; used: number }[] {
  const out: { mount: string; total: number; free: number; used: number }[] = [];
  const mounts =
    process.platform === 'win32'
      ? [...'CDEFGHIJKLMNOPQRSTUVWXYZ'].map((c) => `${c}:\\`)
      : ['/'];
  for (const mount of mounts) {
    try {
      const st = fs.statfsSync(mount);
      const total = st.blocks * st.bsize;
      if (!Number.isFinite(total) || total <= 0) continue;
      const free = st.bavail * st.bsize;
      out.push({ mount: mount.replace(/[\\/]+$/, '') || mount, total, free, used: total - free });
    } catch {
      /* 盘符不存在 */
    }
  }
  return out;
}

type GpuValue = {
  name: string;
  driverVersion: string;
  usagePercent: number;
  memUsed: number;
  memTotal: number;
};

let nvidiaCache: { at: number; value: GpuValue | null } = { at: 0, value: null };

/**
 * 显卡信息：
 * - Windows 走 `gpuProbe`（注册表静态信息 + GPU 性能计数器；后台每 3s 采样，请求只读内存缓存）
 *   —— 绝不在请求路径上起子进程，否则接口会被 `Get-Counter` 的 1.6s 固定开销拖住；
 * - 其它平台保留 `nvidia-smi`（Linux 上通常 20~50ms），带 5s 缓存。
 * 两条路都拿不到就返回 null，不阻塞监控接口。
 */
async function gpuInfo(): Promise<GpuValue | null> {
  if (process.platform === 'win32') return gpuProbe.info();
  if (Date.now() - nvidiaCache.at < 5000) return nvidiaCache.value;
  let value: GpuValue | null = null;
  try {
    const { stdout } = await run(
      'nvidia-smi',
      [
        '--query-gpu=name,utilization.gpu,memory.used,memory.total',
        '--format=csv,noheader,nounits',
      ],
      { timeout: 2000, maxBuffer: 256 * 1024 },
    );
    const line = stdout.split(/\r?\n/).find((l) => l.trim());
    if (line) {
      const [name, usage, memUsed, memTotal] = line.split(',').map((s) => s.trim());
      value = {
        name: name || 'GPU',
        driverVersion: '',
        usagePercent: Number(usage) || 0,
        memUsed: Math.round((Number(memUsed) || 0) * 1024 * 1024),
        memTotal: Math.round((Number(memTotal) || 0) * 1024 * 1024),
      };
    }
  } catch {
    value = null;
  }
  nvidiaCache = { at: Date.now(), value };
  return value;
}

async function listProcesses(): Promise<{ pid: number; name: string; memKB: number }[]> {
  if (process.platform === 'win32') {
    const { stdout } = await run('tasklist', ['/FO', 'CSV', '/NH'], { maxBuffer: 16 * 1024 * 1024 });
    const out: { pid: number; name: string; memKB: number }[] = [];
    for (const line of stdout.split(/\r?\n/)) {
      if (!line.trim() || line.startsWith('INFO:')) continue;
      // "name","pid","session","mem","..."
      const cols = line.match(/"([^"]*)"/g);
      if (!cols || cols.length < 4) continue;
      const name = cols[0].slice(1, -1);
      const pid = Number(cols[1].slice(1, -1));
      const memRaw = cols[3].slice(1, -1).replace(/[^\d]/g, '');
      if (!Number.isInteger(pid)) continue;
      out.push({ pid, name, memKB: Number(memRaw) || 0 });
    }
    return out;
  }

  const { stdout } = await run('ps', ['-eo', 'pid=,comm=,rss='], { maxBuffer: 16 * 1024 * 1024 });
  const out: { pid: number; name: string; memKB: number }[] = [];
  for (const line of stdout.split('\n')) {
    const m = /^\s*(\d+)\s+(.+?)\s+(\d+)\s*$/.exec(line);
    if (!m) continue;
    out.push({ pid: Number(m[1]), name: m[2], memKB: Number(m[3]) });
  }
  return out;
}

const CacheStatItem = Type.Object({
  /** 计数器名：files.thumb / book.cover / music.cover */
  name: Type.String(),
  hits: Type.Integer({ minimum: 0 }),
  misses: Type.Integer({ minimum: 0 }),
  /** 命中率 0~1（3 位小数）；总数为 0 时为 0 */
  hitRate: Type.Number({ minimum: 0, maximum: 1 }),
});

const CacheStatsResponse = Type.Object({ items: Type.Array(CacheStatItem) }, { $id: 'SystemCacheStats' });

export const system: ServerModule = {
  id: 'system',
  prefix: '/api/v1/system',
  permissions: ['system:read', 'system:write'],
  migrations: [],

  async register(app, k) {

    // 缓存命中统计（**只测量**：不改变任何缓存策略，为「要不要做分层缓存」提供数据）
    app.get(
      '/api/v1/system/cache/stats',
      secured('system:read', {
        schema: {
          operationId: 'systemCacheStats',
          tags: TAG,
          summary: '缓存命中统计（进程内累计，重启清零）',
          response: { 200: CacheStatsResponse },
        },
      }),
      async () => ({ items: k.cache.snapshot() }),
    );

    app.get(
      '/api/v1/system/monitor',
      secured('system:read', {
        schema: {
          operationId: 'systemMonitor',
          tags: TAG,
          summary: '整机监控（CPU / 内存 / 磁盘 / 负载）',
          response: { 200: MonitorResponse },
        },
      }),
      async () => {
        const usage = await cpuUsage();
        const disks = diskList();
        const gpu = await gpuInfo();
        const mem = { total: os.totalmem(), free: os.freemem() };
        let disk = { total: 0, free: 0, used: 0 };
        try {
          const st = fs.statfsSync(k.paths.dataDir);
          const total = st.blocks * st.bsize;
          const free = st.bavail * st.bsize;
          disk = { total, free, used: total - free };
        } catch {
          /* 某些平台/路径不支持 statfs，保持 0 */
        }
        return {
          cpu: {
            cores: os.cpus().length,
            loadavg: os.loadavg().map((n) => Math.round(n * 100) / 100),
            usagePercent: usage.total,
            perCore: usage.perCore,
          },
          mem: { total: mem.total, free: mem.free, used: mem.total - mem.free },
          disk,
          disks,
          gpu,
          uptimeSec: Math.round(os.uptime()),
          platform: process.platform,
          arch: process.arch,
          node: process.version,
        };
      },
    );

    app.get(
      '/api/v1/system/processes',
      secured('system:read', {
        schema: {
          operationId: 'systemProcesses',
          tags: TAG,
          summary: '进程列表',
          querystring: Type.Object({
            limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 1000 })),
            filter: Type.Optional(Type.String({ maxLength: 64 })),
          }),
          response: { 200: ProcessListResponse },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { limit?: number; filter?: string };
        let items = await listProcesses();
        if (q.filter) {
          const f = q.filter.toLowerCase();
          items = items.filter((p) => p.name.toLowerCase().includes(f));
        }
        items.sort((a, b) => b.memKB - a.memKB);
        const total = items.length;
        const limit = Math.min(Math.max(q.limit ?? 100, 1), 1000);
        return { items: items.slice(0, limit), total };
      },
    );

    const EXEC_ALLOW = new Set(['pwd', 'ls', 'dir', 'df', 'free', 'ps', 'tasklist', 'uname', 'whoami']);
    const MAX_EXEC_OUT = 64 * 1024;

    app.post(
      '/api/v1/system/exec',
      secured('system:write', {
        schema: {
          operationId: 'systemExec',
          tags: TAG,
          summary: '受限命令执行（白名单 + 无 shell + 5 s 超时）',
          body: Type.Object({
            command: Type.String({ minLength: 1, maxLength: 64 }),
            args: Type.Optional(Type.Array(Type.String({ maxLength: 256 }), { maxItems: 16 })),
            cwd: Type.Optional(Type.String({ maxLength: 512 })),
          }),
          response: {
            200: Type.Object({
              code: Type.Integer(),
              stdout: Type.String(),
              stderr: Type.String(),
              ms: Type.Integer(),
            }),
            400: Type.Object({ error: Type.String(), message: Type.Optional(Type.String()) }),
          },
        },
      }),
      async (req: FastifyRequest, reply: FastifyReply) => {
        const body = (req.body || {}) as { command?: string; args?: string[]; cwd?: string };
        const command = String(body.command || '');
        if (!EXEC_ALLOW.has(command)) {
          return reply
            .code(400)
            .send({ error: Err.badRequest, message: `command not allowed: ${command}` });
        }
        const args = Array.isArray(body.args) ? body.args.map((a) => String(a)).slice(0, 16) : [];
        if (args.some((a) => a.includes('..'))) {
          return reply.code(400).send({ error: Err.badRequest, message: 'args must not contain ..' });
        }
        // cwd 限定在 files 根内（默认根目录）
        const cwd = body.cwd ? resolveInRoot(filesRoot(), body.cwd) : filesRoot();

        const started = Date.now();
        try {
          const { stdout, stderr } = await run(command, args, {
            cwd,
            timeout: 5000,
            windowsHide: true,
            maxBuffer: 1024 * 1024,
          });
          return {
            code: 0,
            stdout: String(stdout).slice(0, MAX_EXEC_OUT),
            stderr: String(stderr).slice(0, MAX_EXEC_OUT),
            ms: Date.now() - started,
          };
        } catch (err) {
          const e = err as { code?: number; stdout?: string; stderr?: string; message?: string };
          return {
            code: typeof e.code === 'number' ? e.code : 1,
            stdout: String(e.stdout || '').slice(0, MAX_EXEC_OUT),
            stderr: String(e.stderr || e.message || '').slice(0, MAX_EXEC_OUT),
            ms: Date.now() - started,
          };
        }
      },
    );

    app.post(
      '/api/v1/system/processes/kill',
      secured('system:write', {
        schema: {
          operationId: 'systemProcessKill',
          tags: TAG,
          summary: '终止进程（拒绝 pid<=4 与自身）',
          body: KillBody,
          response: { 200: OkResponse, 400: ErrorResponse, 404: ErrorResponse },
        },
      }),
      async (req, reply) => {
        const body = (req.body || {}) as { pid?: number };
        const pid = Number(body.pid);
        if (!Number.isInteger(pid) || pid <= 4) {
          return reply.code(400).send({ error: Err.badRequest, message: 'refuse to kill pid <= 4' });
        }
        if (pid === process.pid) {
          return reply.code(400).send({ error: Err.badRequest, message: 'refuse to kill self' });
        }
        try {
          process.kill(pid, 'SIGTERM');
          return { ok: true, pid };
        } catch (err) {
          const code = (err as NodeJS.ErrnoException).code;
          if (code === 'ESRCH') {
            return reply.code(404).send({ error: Err.notFound, message: 'no such process' });
          }
          if (code === 'EPERM') {
            return reply.code(400).send({ error: Err.forbidden, message: 'permission denied' });
          }
          return reply.code(400).send({ error: Err.badRequest, message: String((err as Error).message) });
        }
      },
    );

    // 全局设置 / 缓存清理 / 重启 / 更新检查（配置中心）
    registerSystemSettings(app, k);

    // 开发期客户端日志批量上报：与 kernel/index.ts 的 devTokenEnabled 同款判断，
    // 正式服务端不注册这个路由；hide:true 保证它也不进契约 / 不生成 client。
    // （tool/gen.js 会强制置 COLANAS_DEV_TOKEN=1，gen 时也会注册，但被 swagger 过滤。）
    if (
      process.env.COLANAS_DEV_TOKEN === '1' &&
      process.env.NODE_ENV !== 'production'
    ) {
      registerDevClientLog(app, k);
    }
  },
};