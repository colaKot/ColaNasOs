/**
 * 同步「三向比对」纯算法（无 IO，可单测）。
 *
 * 输入三份清单：
 *   - local    客户端当前文件
 *   - baseline 上一次同步完成时的公共状态（服务端 `sync_baseline` 表）
 *   - remote   服务端远端目录当前文件
 *
 * 判定「同一文件」：`size` 相等且 `|mtime 差| ≤ 2000ms`。
 * 2 秒容差来自 FAT/exFAT 的 2 秒时间戳粒度；`Math.round` 收敛 Node 的
 * 亚毫秒 mtime（NTFS 100ns 精度），否则老客户端按整数解析会判成不同 → 每轮重复传输。
 *
 * 只有「本地变了」或「远端变了」才产生动作；两边都变且与基线都不同 → conflict，不猜。
 */
export const MTIME_TOLERANCE_MS = 2000;

export type SyncMode = 'bidirectional' | 'download_only' | 'upload_only';

/** 冲突策略：manual 为保守默认（不猜），与既有实现的三选一并存 */
export type ConflictStrategy = 'prefer_newer' | 'prefer_local' | 'prefer_remote' | 'manual';

export interface SyncOptions {
  conflictStrategy?: ConflictStrategy;
  /** 删除传播：仅在双向模式下生效；关闭时一端删除不会删另一端 */
  deleteExtra?: boolean;
}

export interface SyncEntry {
  path: string;
  size: number;
  /** 毫秒时间戳（服务端会 Math.round 后比较） */
  mtimeMs: number;
}

export type SyncActionKind =
  | 'upload'
  | 'download'
  | 'deleteLocal'
  | 'deleteRemote'
  | 'conflict'
  | 'skip';

export interface SyncAction {
  kind: SyncActionKind;
  path: string;
  reason: string;
  size?: number;
  mtimeMs?: number;
  remoteSize?: number;
  remoteMtimeMs?: number;
}

export interface PlanStats {
  upload: number;
  download: number;
  deleteLocal: number;
  deleteRemote: number;
  conflict: number;
  skip: number;
  bytes: number;
}

export interface PlanResult {
  actions: SyncAction[];
  stats: PlanStats;
  /** 本次比对的有效条目数（三份清单的并集） */
  compared: number;
}

function norm(p: string): string {
  return String(p || '')
    .replace(/\\/g, '/')
    .replace(/^\/+/, '')
    .replace(/\/+$/, '');
}

function sameTime(a: number, b: number): boolean {
  return Math.abs(Math.round(a) - Math.round(b)) <= MTIME_TOLERANCE_MS;
}

function sameFile(a: SyncEntry, b: SyncEntry): boolean {
  return a.size === b.size && sameTime(a.mtimeMs, b.mtimeMs);
}

function indexOf(list: SyncEntry[]): Map<string, SyncEntry> {
  const map = new Map<string, SyncEntry>();
  for (const e of list) map.set(norm(e.path), e);
  return map;
}

export function buildPlan(
  local: SyncEntry[],
  baseline: SyncEntry[],
  remote: SyncEntry[],
  mode: SyncMode,
  options: SyncOptions = {},
): PlanResult {
  const conflictStrategy = options.conflictStrategy ?? 'manual';
  const deleteExtra = options.deleteExtra !== false;
  const L = indexOf(local);
  const B = indexOf(baseline);
  const R = indexOf(remote);

  const paths = new Set<string>([...L.keys(), ...B.keys(), ...R.keys()]);
  const actions: SyncAction[] = [];
  const stats: PlanStats = {
    upload: 0,
    download: 0,
    deleteLocal: 0,
    deleteRemote: 0,
    conflict: 0,
    skip: 0,
    bytes: 0,
  };

  const push = (a: SyncAction) => {
    actions.push(a);
    stats[a.kind] += 1;
    if (a.kind === 'upload') stats.bytes += a.size ?? 0;
    if (a.kind === 'download') stats.bytes += a.remoteSize ?? 0;
  };

  /** 冲突按策略落地：local→upload / remote→download / newer→较新一侧 / manual→上报 */
  const resolveConflict = (
    p: string,
    l: SyncEntry,
    r: SyncEntry,
    reason: string,
  ): SyncAction => {
    if (conflictStrategy === 'prefer_local' || conflictStrategy === 'prefer_remote') {
      const toLocal = conflictStrategy === 'prefer_remote';
      return toLocal
        ? {
            kind: 'download',
            path: p,
            reason: `${reason}:prefer_remote`,
            remoteSize: r.size,
            remoteMtimeMs: r.mtimeMs,
          }
        : {
            kind: 'upload',
            path: p,
            reason: `${reason}:prefer_local`,
            size: l.size,
            mtimeMs: l.mtimeMs,
          };
    }
    if (conflictStrategy === 'prefer_newer') {
      const lm = Math.round(l.mtimeMs);
      const rm = Math.round(r.mtimeMs);
      if (lm > rm) {
        return {
          kind: 'upload',
          path: p,
          reason: `${reason}:prefer_newer`,
          size: l.size,
          mtimeMs: l.mtimeMs,
        };
      }
      if (rm > lm) {
        return {
          kind: 'download',
          path: p,
          reason: `${reason}:prefer_newer`,
          remoteSize: r.size,
          remoteMtimeMs: r.mtimeMs,
        };
      }
    }
    return {
      kind: 'conflict',
      path: p,
      reason,
      size: l.size,
      mtimeMs: l.mtimeMs,
      remoteSize: r.size,
      remoteMtimeMs: r.mtimeMs,
    };
  };

  for (const p of [...paths].sort()) {
    const l = L.get(p);
    const b = B.get(p);
    const r = R.get(p);

    // 两端都有
    if (l && r) {
      if (sameFile(l, r)) {
        push({ kind: 'skip', path: p, reason: 'identical', size: l.size, mtimeMs: l.mtimeMs });
        continue;
      }
      const localChanged = !b || !sameFile(l, b);
      const remoteChanged = !b || !sameFile(r, b);

      if (b && !localChanged && remoteChanged) {
        push({
          kind: 'download',
          path: p,
          reason: 'remoteChanged',
          remoteSize: r.size,
          remoteMtimeMs: r.mtimeMs,
        });
        continue;
      }
      if (b && localChanged && !remoteChanged) {
        push({ kind: 'upload', path: p, reason: 'localChanged', size: l.size, mtimeMs: l.mtimeMs });
        continue;
      }
      if (!b) {
        // 首次同步：两边不一致且没有共同基线，按方向模式决策，双向模式不猜
        if (mode === 'download_only') {
          push({
            kind: 'download',
            path: p,
            reason: 'noBaseline',
            remoteSize: r.size,
            remoteMtimeMs: r.mtimeMs,
          });
        } else if (mode === 'upload_only') {
          push({ kind: 'upload', path: p, reason: 'noBaseline', size: l.size, mtimeMs: l.mtimeMs });
        } else {
          push(resolveConflict(p, l, r, 'noBaseline'));
        }
        continue;
      }
      // 两边都改过
      if (mode === 'download_only') {
        push({
          kind: 'download',
          path: p,
          reason: 'bothChanged',
          remoteSize: r.size,
          remoteMtimeMs: r.mtimeMs,
        });
      } else if (mode === 'upload_only') {
        push({ kind: 'upload', path: p, reason: 'bothChanged', size: l.size, mtimeMs: l.mtimeMs });
      } else {
        push(resolveConflict(p, l, r, 'bothChanged'));
      }
      continue;
    }

    // 仅本地有
    if (l && !r) {
      if (b) {
        // 基线有、远端没了 ⇒ 远端被删除
        if (mode === 'upload_only') {
          push({ kind: 'upload', path: p, reason: 'remoteDeleted', size: l.size, mtimeMs: l.mtimeMs });
        } else if (mode === 'download_only') {
          push({ kind: 'skip', path: p, reason: 'remoteDeletedDownloadOnly', size: l.size });
        } else if (deleteExtra) {
          push({ kind: 'deleteLocal', path: p, reason: 'remoteDeleted', size: l.size });
        } else {
          push({ kind: 'skip', path: p, reason: 'remoteDeletedKeep', size: l.size });
        }
        continue;
      }
      // 新本地文件
      if (mode === 'download_only') {
        push({ kind: 'skip', path: p, reason: 'localOnlyDownloadOnly', size: l.size });
      } else {
        push({ kind: 'upload', path: p, reason: 'localNew', size: l.size, mtimeMs: l.mtimeMs });
      }
      continue;
    }

    // 仅远端有
    if (r && !l) {
      if (b) {
        // 基线有、本地没了 ⇒ 本地被删除
        if (mode === 'upload_only') {
          push({ kind: 'skip', path: p, reason: 'localDeletedUploadOnly' });
        } else if (mode === 'download_only') {
          // 下载模式只往本地走：本地删除不代表要删远端
          push({ kind: 'skip', path: p, reason: 'localDeletedDownloadOnly' });
        } else if (!deleteExtra) {
          push({ kind: 'skip', path: p, reason: 'localDeletedKeep' });
        } else {
          push({
            kind: 'deleteRemote',
            path: p,
            reason: 'localDeleted',
            remoteSize: r.size,
            remoteMtimeMs: r.mtimeMs,
          });
        }
        continue;
      }
      if (mode === 'upload_only') {
        push({ kind: 'skip', path: p, reason: 'remoteOnlyUploadOnly' });
      } else {
        push({
          kind: 'download',
          path: p,
          reason: 'remoteNew',
          remoteSize: r.size,
          remoteMtimeMs: r.mtimeMs,
        });
      }
      continue;
    }

    // 仅基线有：两端都没了 ⇒ 从基线清理（客户端无需动作）
    push({ kind: 'skip', path: p, reason: 'goneBothSides' });
  }

  return { actions, stats, compared: paths.size };
}

/** 简单的 include/exclude 匹配（`*` 不跨目录、`**` 跨目录、`?` 单字符），并覆盖其子路径 */
export function matchPattern(relPath: string, pattern: string): boolean {
  const p = norm(relPath);
  const pat = norm(pattern);
  if (!pat) return false;

  let out = '';
  for (let i = 0; i < pat.length; i += 1) {
    const ch = pat[i];
    if (ch === '*') {
      if (pat[i + 1] === '*') {
        out += '.*';
        i += 1;
      } else {
        out += '[^/]*';
      }
    } else if (ch === '?') {
      out += '[^/]';
    } else {
      out += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }

  try {
    return new RegExp(`^${out}(/.*)?$`).test(p);
  } catch {
    return false;
  }
}

export function inScope(relPath: string, include: string[], exclude: string[]): boolean {
  if (exclude.some((x) => matchPattern(relPath, x))) return false;
  if (include.length === 0) return true;
  return include.some((x) => matchPattern(relPath, x));
}