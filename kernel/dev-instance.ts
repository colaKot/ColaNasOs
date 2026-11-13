import fs from 'node:fs';
import path from 'node:path';

/**
 * 开发版重叠实例守卫。
 *
 * 背景：开发版（7888）默认与正式版（7788）共用 `%APPDATA%\colanas_os_server`
 * 与同一个 SQLite。两套同时运行时，后台任务会各跑一遍、互相抢写锁；更糟的是
 * 任务表也是共享的，开发内核的 worker 会把正式版排队的任务领走执行。
 *
 * 因此只对**显式标记为开发实例**的进程启用：启动时短超时探活正式内核，
 * 命中后由调用方跳过所有自动后台任务（不启动 worker、不写任务表）。
 * 正式版 / 安装版从不设置 `COLANAS_DEV_INSTANCE`，行为完全不变。
 */

export interface PeerInstance {
  /** 命中的监听端口（默认 7788） */
  port: number;
  /** 对方 `/health` 返回的内核 pid */
  pid: number;
}

export interface BackgroundMode {
  /** false = 已检测到另一个实例，跳过自动后台任务 */
  enabled: boolean;
  reason: 'normal' | 'peer-instance';
  /** 命中的另一个实例 */
  peer?: PeerInstance;
  /** 被跳过的后台任务清单（供日志 / `/ready` / 开发界面展示） */
  skipped: string[];
}

/** 重叠模式下跳过的自动后台任务（逐项，与模块侧门控保持一致） */
export const SKIPPED_BACKGROUND_TASKS = [
  '任务队列恢复与 worker（queue.recover / queue.start）',
  '自动入队（enqueue / enqueueIfIdle）',
  '文件监控 fs.watch 与远程目录轮询订阅',
  '媒体库周期全量校验与每库间隔扫描',
  '影视 SMB 在线探测（启动 + 每 20s）',
  '影视每日字幕补全 / 刮削统计定时器',
  '音乐启动扫描',
  '相册 AI 识别自动续跑 / content_md5 回填 / 回收站清理',
  '博客 AI 新闻定时生成与启动补跑',
  'RSS 规则 15 分钟扫描',
  'PT 订阅 / 收藏 / 进度同步定时器',
  '播放器 HLS 会话领取与分片清理',
  '发现页榜单快照启动清理',
] as const;

/** 重叠标记文件：dev 退出时的 stop-daemon 据此避免停掉正式版的 transmission */
export const DEV_OVERLAP_MARKER = 'dev-overlap.marker';

/** 是否是显式标记的开发实例（不含探活开关） */
export function devInstanceMarked(): boolean {
  return process.env.COLANAS_DEV_INSTANCE === '1' && process.env.NODE_ENV !== 'production';
}

/** 是否启用本守卫（开发实例 + 未被显式关闭） */
export function devInstanceEnabled(): boolean {
  return devInstanceMarked() && process.env.COLANAS_DEV_PEER_CHECK !== '0';
}

/** 候选探活端口：`COLANAS_PEER_PORT` 优先，其次正式版默认 7788；跳过自身端口 */
export function peerPorts(ownPort?: number): number[] {
  const out: number[] = [];
  for (const raw of [Number(process.env.COLANAS_PEER_PORT), 7788]) {
    if (!Number.isInteger(raw) || raw <= 0) continue;
    if (ownPort && raw === ownPort) continue;
    if (!out.includes(raw)) out.push(raw);
  }
  return out;
}

async function probeOne(port: number, timeoutMs: number): Promise<PeerInstance | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  timer.unref?.();
  try {
    const res = await fetch(`http://127.0.0.1:${port}/health`, {
      signal: controller.signal,
      headers: { accept: 'application/json' },
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { ok?: unknown; pid?: unknown };
    const pid = Number(body?.pid);
    if (body?.ok !== true || !Number.isInteger(pid) || pid <= 0) return null;
    // 自己探到自己（端口配置写错时）不算重叠
    if (pid === process.pid) return null;
    return { port, pid };
  } catch {
    // 连接拒绝 / 超时 / 非 JSON：都视为没有另一个实例
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 探活另一个 ColaNasOs 内核。默认 800ms 超时，调用方应与启动流程并行执行，
 * 避免拖慢开发内核启动。
 */
export async function probePeerInstance(
  opts: { ownPort?: number; timeoutMs?: number } = {},
): Promise<PeerInstance | null> {
  const ports = peerPorts(opts.ownPort);
  if (ports.length === 0) return null;
  const results = await Promise.all(ports.map((p) => probeOne(p, opts.timeoutMs ?? 800)));
  return results.find((r) => r !== null) ?? null;
}

/**
 * 写入 / 清理重叠标记。
 *
 * 只对开发实例生效；正式版路径不会产生该文件。标记写入失败不影响启动。
 */
export function writeOverlapMarker(dataDir: string, peer: PeerInstance | null): void {
  if (!devInstanceMarked()) return;
  const file = path.join(dataDir, DEV_OVERLAP_MARKER);
  try {
    if (peer) {
      fs.writeFileSync(file, JSON.stringify({ at: Date.now(), peer }), 'utf-8');
    } else {
      fs.rmSync(file, { force: true });
    }
  } catch {
    /* 标记失败只影响 dev 退出时是否停 daemon，不影响主流程 */
  }
}
