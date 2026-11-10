import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { KernelApi } from '../../../kernel/types';

/**
 * 开发期客户端日志批量上报（只在 dev 内核注册，不进契约）。
 *
 * 为什么单独开一个口：正式的 `/api/v1/system/client-log` 要 `system:write`，
 * 而普通登录用户 token 只有 `events:read` / `tasks:read`，上报一直 403
 * （日志里 `[client]` 记录极少）。这个口不改正式端点的权限，也不进契约，
 * 客户端只在连 7888 时切过来 —— 正式服务端行为零变化。
 *
 * 写入复用 `k.log` → `<dataDir>/logs/kernel.log`，日志页直接可查，
 * 沿用启动时 10 MB × 3 轮转；这里再加一层服务端侧的频率/体积兜底，
 * 避免开发期全量日志把单文件撑爆。
 */
const MAX_BATCH = 50;
const MAX_PER_MINUTE = 300;
const MAX_MESSAGE = 2000;
const MAX_DETAIL = 4000;
// 单进程内按天硬封顶：轮转只在内核启动时做，dev 内核可能长时间不重启，
// 光靠频率限制仍可能被长堆栈撑爆。超出预算直接丢弃（进程重启后清零）。
const MAX_BYTES_PER_DAY = 20 * 1024 * 1024;

type RawEntry = {
  level?: unknown;
  message?: unknown;
  route?: unknown;
  detail?: unknown;
  app?: unknown;
  platform?: unknown;
  ts?: unknown;
};

export function registerDevClientLog(app: FastifyInstance, k: KernelApi): void {
  const window: number[] = [];
  let dayStart = Date.now();
  let bytesToday = 0;

  app.post(
    '/api/v1/system/dev-log',
    // hide:true → 不进 openapi.json，gen / gen:client / sdk 产物不变。
    // 不加 secured：仍走全局 Bearer 校验，但不额外要求 scope。
    { schema: { hide: true, tags: ['system'] } },
    async (req: FastifyRequest) => {
      const body = (req.body || {}) as { entries?: unknown };
      const raw = Array.isArray(body.entries)
        ? body.entries.slice(0, MAX_BATCH)
        : [];
      const now = Date.now();
      if (now - dayStart > 86_400_000) {
        dayStart = now;
        bytesToday = 0;
      }
      while (window.length > 0 && now - window[0] > 60_000) window.shift();

      let accepted = 0;
      for (const item of raw) {
        if (window.length >= MAX_PER_MINUTE) break;
        const e = (item || {}) as RawEntry;
        const message = String(e.message ?? '').trim().slice(0, MAX_MESSAGE);
        if (!message) continue;

        const level =
          e.level === 'error' || e.level === 'info' ? e.level : 'warn';
        const appName = String(e.app ?? 'app').slice(0, 40);
        const platform = String(e.platform ?? '').slice(0, 20);
        const route = String(e.route ?? '').trim().slice(0, 300);
        const src = platform ? `${appName}/${platform}` : appName;
        const line = `[client:${src}] ${message}${route ? ` (${route})` : ''}`;
        const meta = {
          client: true,
          dev: true,
          app: appName,
          platform,
          route,
          detail: String(e.detail ?? '').slice(0, MAX_DETAIL),
          ...(typeof e.ts === 'number' ? { clientTs: e.ts } : {}),
        };
        const cost =
          Buffer.byteLength(line) + Buffer.byteLength(JSON.stringify(meta));
        if (bytesToday + cost > MAX_BYTES_PER_DAY) break;
        bytesToday += cost;
        if (level === 'error') k.log.error(meta, line);
        else if (level === 'info') k.log.info(meta, line);
        else k.log.warn(meta, line);
        window.push(now);
        accepted += 1;
      }
      return {
        ok: true,
        accepted,
        dropped: raw.length - accepted,
        dailyBytes: bytesToday,
      };
    },
  );
}
