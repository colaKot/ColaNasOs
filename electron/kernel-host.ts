import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { startKernel } from '../kernel';
import { initDataDir } from '../kernel/updater';
import type { WatchdogMetrics } from '../kernel/watchdog';

const base = process.env.APPDATA || path.join(os.homedir(), '.config');
const dataDir = process.env.COLANAS_DATA_DIR || path.join(base, 'colanas_os_server');

// SP4-03：安装后首次启动即幂等准备数据目录（logs / tmp / backup + config.json），
// 并清掉上次异常退出遗留的 kernel.pid。
const init = initDataDir(dataDir);
if (init.created.length) {
  console.log(`[kernel] data dir initialized: ${init.created.join(', ')}`);
}

// 供外壳与运维探活：内核真实 pid
fs.writeFileSync(path.join(dataDir, 'kernel.pid'), String(process.pid), 'utf-8');

/**
 * 进程外监督心跳：Electron `utilityProcess` 子进程通过 `process.parentPort` 发给外壳。
 * 外壳 5 分钟收不到心跳即判定「闷死」，杀进程树重启（见 `electron/main.ts`）。
 */
const parentPort = (process as { parentPort?: { postMessage(msg: unknown): void; on?(ev: string, cb: (msg: unknown) => void): void } }).parentPort;
const onBeat = parentPort
  ? (metrics: WatchdogMetrics) => {
      try {
        parentPort.postMessage({ type: 'heartbeat', metrics });
      } catch {
        /* 外壳已退出：忽略 */
      }
    }
  : undefined;

void startKernel({
  dataDir,
  port: Number(process.env.PORT || 7788),
  onBeat,
  onListening: parentPort
    ? (port: number) => {
        try {
          parentPort.postMessage({ type: 'listening', port });
        } catch {
          /* 外壳已退出：忽略 */
        }
      }
    : undefined,
}).then((k) => {
  /**
   * 外壳「退出应用」时发来的优雅关闭请求。
   *
   * 和「内核被重启」必须分开处理：
   * - 内核被 kill（开发期改代码 / 崩溃重启）：不执行这里，daemon 继续做种，
   *   tracker 也不会因为新 peer-id 又多一个「做种位置」；
   * - 用户退出应用：走 app.close() → Fastify onClose → 停种子（发 stopped）→ 杀 daemon。
   *
   * 停完再回 ack，外壳等这个 ack（最多几秒）才真正退出。
   */
  parentPort?.on?.('message', (event: unknown) => {
    // utilityProcess 的 parentPort 给的是 MessageEvent（载荷在 .data），
    // 不是裸消息对象；兼容两种形态，免得 shutdown 永远被当成普通 message。
    const msg = (event as { data?: unknown } | null)?.data ?? event;
    const payload = msg as { type?: string } | null;
    if (payload?.type !== 'shutdown') return;
    void (async () => {
      try {
        await k.app.close();
      } catch (err) {
        console.error('[kernel] graceful shutdown failed', err);
      }
      try {
        parentPort?.postMessage({ type: 'shutdown-done' });
      } catch {
        /* 外壳已退出 */
      }
      // 给日志落盘一个 tick，别让 SonicBoom 在退出路径上二次崩溃
      setTimeout(() => process.exit(0), 120);
    })();
  });
}).catch((err) => {
  console.error('[kernel] fatal', err);
  // 不能直接 process.exit(1)：pino 的 SonicBoom 会在 `onExit` 里同步 flush，
  // 若它自己还没 ready 就抛 `sonic boom is not ready yet` —— 退出路径二次崩溃，
  // 进程卡在「活着但不监听」的半死状态（占内存、端口不释放），
  // 下一次启动就必然 EADDRINUSE。给事件循环一个 tick 让日志落盘，再退。
  setTimeout(() => process.exit(1), 150);
});