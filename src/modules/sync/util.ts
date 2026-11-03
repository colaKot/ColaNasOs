import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Type } from '@sinclair/typebox';
import { filesRoot, resolveInRoot } from '../files/fs-root';
import { buildPlan, inScope, type SyncEntry, type SyncMode } from './plan';

export const TAG = ['sync'];
export const ErrorResponse = Type.Object({
  error: Type.String(),
  message: Type.Optional(Type.String()),
  code: Type.Optional(Type.String()),
  traceId: Type.Optional(Type.String()),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
});
export const RunBody = Type.Object({
  source: Type.String({ minLength: 1 }),
  target: Type.String({ minLength: 1 }),
  policy: Type.Optional(
    Type.Union([Type.Literal('overwrite'), Type.Literal('skip'), Type.Literal('rename')]),
  ),
});
export const RunResponse = Type.Object({
  id: Type.String(),
  copied: Type.Integer(),
  skipped: Type.Integer(),
  conflicts: Type.Integer(),
  bytes: Type.Integer(),
});
export const JobItem = Type.Object({
  id: Type.String(),
  source: Type.String(),
  target: Type.String(),
  policy: Type.String(),
  copied: Type.Integer(),
  skipped: Type.Integer(),
  conflicts: Type.Integer(),
  bytes: Type.Integer(),
  createdAt: Type.Integer(),
});
export const JobListResponse = Type.Object({ items: Type.Array(JobItem) });
export const DiffResponse = Type.Object({
  onlySource: Type.Array(Type.String()),
  onlyTarget: Type.Array(Type.String()),
  changed: Type.Array(Type.String()),
});
export const ConflictItem = Type.Object({
  id: Type.String(),
  jobId: Type.String(),
  path: Type.String(),
  createdAt: Type.Integer(),
  resolved: Type.Boolean(),
  resolution: Type.Union([Type.String(), Type.Null()]),
});
export const ConflictListResponse = Type.Object({ items: Type.Array(ConflictItem) });
export const ResolveBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  action: Type.Union([Type.Literal('source'), Type.Literal('target')]),
});
export const OkResponse = Type.Object({ ok: Type.Boolean() });
// ---------------------------------------------------------------- 多端同步（三向比对）
export const SyncModeSchema = Type.Union([
  Type.Literal('bidirectional'),
  Type.Literal('download_only'),
  Type.Literal('upload_only'),
]);
export const SyncEntrySchema = Type.Object({
  path: Type.String({ minLength: 1, maxLength: 1024 }),
  size: Type.Integer({ minimum: 0 }),
  mtimeMs: Type.Number({ minimum: 0 }),
});
export const SyncActionSchema = Type.Object(
  {
    kind: Type.String(),
    path: Type.String(),
    reason: Type.String(),
    size: Type.Optional(Type.Number()),
    mtimeMs: Type.Optional(Type.Number()),
    remoteSize: Type.Optional(Type.Number()),
    remoteMtimeMs: Type.Optional(Type.Number()),
  },
  { additionalProperties: true },
);
// ---------------------------------------------------------------- 任务级配置
const SizeUnit = Type.Union([Type.Literal('KB'), Type.Literal('MB'), Type.Literal('GB')]);
export const SyncFilterConfigSchema = Type.Object({
  excludeSmallEnabled: Type.Optional(Type.Boolean()),
  excludeSmallSize: Type.Optional(Type.Number({ minimum: 0, maximum: 1048576 })),
  excludeSmallUnit: Type.Optional(SizeUnit),
  excludeLargeEnabled: Type.Optional(Type.Boolean()),
  excludeLargeSize: Type.Optional(Type.Number({ minimum: 0, maximum: 1048576 })),
  excludeLargeUnit: Type.Optional(SizeUnit),
  excludeHidden: Type.Optional(Type.Boolean()),
  excludeExtensionEnabled: Type.Optional(Type.Boolean()),
  excludeExtensions: Type.Optional(
    Type.Array(Type.String({ maxLength: 32 }), { maxItems: 200 }),
  ),
});
export const SyncConflictStrategySchema = Type.Union([
  Type.Literal('prefer_newer'),
  Type.Literal('prefer_local'),
  Type.Literal('prefer_remote'),
  Type.Literal('manual'),
]);
export const SyncTaskConfigSchema = Type.Object({
  realtime: Type.Optional(Type.Boolean()),
  intervalMinutes: Type.Optional(Type.Integer({ minimum: 0, maximum: 1440 })),
  conflictStrategy: Type.Optional(SyncConflictStrategySchema),
  deleteExtra: Type.Optional(Type.Boolean()),
});

export type SizeUnitValue = 'KB' | 'MB' | 'GB';
export interface SyncFilterConfig {
  excludeSmallEnabled: boolean;
  excludeSmallSize: number;
  excludeSmallUnit: SizeUnitValue;
  excludeLargeEnabled: boolean;
  excludeLargeSize: number;
  excludeLargeUnit: SizeUnitValue;
  excludeHidden: boolean;
  excludeExtensionEnabled: boolean;
  excludeExtensions: string[];
}
export interface SyncTaskConfig {
  realtime: boolean;
  intervalMinutes: number;
  conflictStrategy: 'prefer_newer' | 'prefer_local' | 'prefer_remote' | 'manual';
  deleteExtra: boolean;
}
export const DEFAULT_FILTER: SyncFilterConfig = {
  excludeSmallEnabled: false,
  excludeSmallSize: 0,
  excludeSmallUnit: 'KB',
  excludeLargeEnabled: false,
  excludeLargeSize: 0,
  excludeLargeUnit: 'MB',
  excludeHidden: false,
  excludeExtensionEnabled: false,
  excludeExtensions: [],
};
/** 老任务（sync_json='{}'）保持「删除传播开 + 不猜冲突」，避免升级后行为突变 */
export const DEFAULT_TASK_CONFIG: SyncTaskConfig = {
  realtime: false,
  intervalMinutes: 30,
  conflictStrategy: 'manual',
  deleteExtra: true,
};
function pickUnit(v: unknown): SizeUnitValue {
  return v === 'MB' || v === 'GB' ? v : 'KB';
}
export function parseFilter(raw: string | null | undefined): SyncFilterConfig {
  let v: Record<string, unknown>;
  try {
    v = raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
  } catch {
    v = {};
  }
  return {
    excludeSmallEnabled: v.excludeSmallEnabled === true,
    excludeSmallSize: Math.max(0, Number(v.excludeSmallSize) || 0),
    excludeSmallUnit: pickUnit(v.excludeSmallUnit),
    excludeLargeEnabled: v.excludeLargeEnabled === true,
    excludeLargeSize: Math.max(0, Number(v.excludeLargeSize) || 0),
    excludeLargeUnit:
      v.excludeLargeUnit === 'KB' || v.excludeLargeUnit === 'GB'
        ? v.excludeLargeUnit
        : 'MB',
    excludeHidden: v.excludeHidden === true,
    excludeExtensionEnabled: v.excludeExtensionEnabled === true,
    excludeExtensions: Array.isArray(v.excludeExtensions)
      ? (v.excludeExtensions as unknown[]).map((e) => String(e)).filter(Boolean).slice(0, 200)
      : [],
  };
}
export function parseTaskConfig(raw: string | null | undefined): SyncTaskConfig {
  let v: Record<string, unknown>;
  try {
    v = raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
  } catch {
    v = {};
  }
  const strategy = v.conflictStrategy;
  // 缺省 30 分钟与旧全局调度口径一致；显式 0 = 仅手动
  const rawInterval =
    v.intervalMinutes === undefined || v.intervalMinutes === null
      ? 30
      : Number(v.intervalMinutes) || 0;
  return {
    realtime: v.realtime === true,
    intervalMinutes: Math.max(0, Math.min(1440, rawInterval)),
    conflictStrategy:
      strategy === 'prefer_newer' || strategy === 'prefer_local' || strategy === 'prefer_remote'
        ? strategy
        : 'manual',
    deleteExtra: v.deleteExtra !== false,
  };
}
const UNIT_BYTES: Record<SizeUnitValue, number> = {
  KB: 1024,
  MB: 1024 * 1024,
  GB: 1024 * 1024 * 1024,
};
/** 结构化过滤（大小 / 隐藏文件 / 扩展名）；include/exclude 仍由 inScope 负责 */
export function filterExcluded(
  relPath: string,
  size: number,
  f: SyncFilterConfig,
): boolean {
  const p = relPath.replace(/\\/g, '/');
  if (f.excludeHidden && p.split('/').some((s) => s.startsWith('.'))) return true;
  if (f.excludeExtensionEnabled && f.excludeExtensions.length > 0) {
    const dot = p.lastIndexOf('.');
    const ext = dot >= 0 ? p.slice(dot + 1).toLowerCase() : '';
    if (ext) {
      const hit = f.excludeExtensions.some(
        (e) => e.toLowerCase().replace(/^\./, '') === ext,
      );
      if (hit) return true;
    }
  }
  if (f.excludeSmallEnabled && f.excludeSmallSize > 0) {
    if (size < f.excludeSmallSize * UNIT_BYTES[f.excludeSmallUnit]) return true;
  }
  if (f.excludeLargeEnabled && f.excludeLargeSize > 0) {
    if (size > f.excludeLargeSize * UNIT_BYTES[f.excludeLargeUnit]) return true;
  }
  return false;
}

export const TaskUpsertBody = Type.Object({
  id: Type.Optional(Type.String({ maxLength: 64 })),
  name: Type.Optional(Type.String({ maxLength: 32 })),
  deviceId: Type.String({ minLength: 1, maxLength: 128 }),
  deviceName: Type.Optional(Type.String({ maxLength: 128 })),
  mode: Type.Optional(SyncModeSchema),
  localDir: Type.String({ minLength: 1, maxLength: 1024 }),
  remoteDir: Type.String({ minLength: 1, maxLength: 1024 }),
  include: Type.Optional(Type.Array(Type.String({ maxLength: 256 }), { maxItems: 100 })),
  exclude: Type.Optional(Type.Array(Type.String({ maxLength: 256 }), { maxItems: 100 })),
  filterConfig: Type.Optional(SyncFilterConfigSchema),
  syncConfig: Type.Optional(SyncTaskConfigSchema),
});
export const TaskItem = Type.Object({
  id: Type.String(),
  name: Type.String(),
  deviceId: Type.String(),
  deviceName: Type.String(),
  mode: Type.String(),
  status: Type.String(),
  localDir: Type.String(),
  remoteDir: Type.String(),
  include: Type.Array(Type.String()),
  exclude: Type.Array(Type.String()),
  filterConfig: SyncFilterConfigSchema,
  syncConfig: SyncTaskConfigSchema,
  createdAt: Type.Integer(),
  updatedAt: Type.Integer(),
  lastRunAt: Type.Union([Type.Integer(), Type.Null()]),
  lastError: Type.Union([Type.String(), Type.Null()]),
});
export const TaskListResponse = Type.Object({ items: Type.Array(TaskItem) });
export const TaskIdBody = Type.Object({ id: Type.String({ minLength: 1 }) });
export const PlanBody = Type.Object({
  taskId: Type.String({ minLength: 1 }),
  local: Type.Array(SyncEntrySchema, { maxItems: 500000 }),
  /** 客户端本地基线（可选）；不传则用服务端 `sync_baseline` */
  baseline: Type.Optional(Type.Array(SyncEntrySchema, { maxItems: 500000 })),
});
export const PlanResponse = Type.Object(
  {
    taskId: Type.String(),
    mode: Type.String(),
    compared: Type.Integer(),
    remoteCount: Type.Integer(),
    stats: Type.Object(
      {
        upload: Type.Integer(),
        download: Type.Integer(),
        deleteLocal: Type.Integer(),
        deleteRemote: Type.Integer(),
        conflict: Type.Integer(),
        skip: Type.Integer(),
        bytes: Type.Integer(),
      },
      { additionalProperties: true },
    ),
    actions: Type.Array(SyncActionSchema),
  },
  { additionalProperties: true },
);
export const ReportBody = Type.Object({
  taskId: Type.String({ minLength: 1 }),
  applied: Type.Optional(
    Type.Array(
      Type.Object({
        path: Type.String({ maxLength: 1024 }),
        kind: Type.String({ maxLength: 32 }),
        ok: Type.Boolean(),
      }),
      { maxItems: 500000 },
    ),
  ),
  bytes: Type.Optional(Type.Integer({ minimum: 0 })),
  status: Type.Optional(
    Type.Union([Type.Literal('done'), Type.Literal('failed'), Type.Literal('partial')]),
  ),
  error: Type.Optional(Type.String({ maxLength: 500 })),
});
export const ReportResponse = Type.Object({
  runId: Type.String(),
  baseline: Type.Integer(),
  conflicts: Type.Integer(),
});
export const DeleteRemoteBody = Type.Object({
  taskId: Type.String({ minLength: 1 }),
  paths: Type.Array(Type.String({ minLength: 1, maxLength: 1024 }), { maxItems: 10000 }),
});
export const MkdirBody = Type.Object({
  taskId: Type.String({ minLength: 1 }),
  path: Type.String({ minLength: 1, maxLength: 1024 }),
});
export const ProbeBody = Type.Object({
  remoteDir: Type.String({ minLength: 1, maxLength: 1024 }),
});
export const ProbeResponse = Type.Object({
  exists: Type.Boolean(),
  writable: Type.Boolean(),
  allowed: Type.Boolean(),
  message: Type.String(),
});
export const StatusBody = Type.Object({
  id: Type.String({ minLength: 1 }),
  status: Type.Union([
    Type.Literal('idle'),
    Type.Literal('running'),
    Type.Literal('paused'),
    Type.Literal('error'),
  ]),
});
export const ClaimLegacyBody = Type.Object({
  deviceId: Type.String({ minLength: 1, maxLength: 128 }),
});
export const ClaimLegacyResponse = Type.Object({ claimed: Type.Integer() });
export const SummaryResponse = Type.Object({
  tasks: Type.Integer(),
  byStatus: Type.Record(Type.String(), Type.Integer()),
  byDevice: Type.Array(
    Type.Object({
      deviceId: Type.String(),
      deviceName: Type.String(),
      tasks: Type.Integer(),
      lastRunAt: Type.Union([Type.Integer(), Type.Null()]),
    }),
  ),
});
export function sha256File(p: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}
export function walk(dir: string, rel = ''): string[] {
  const out: string[] = [];
  for (const e of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const child = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(dir, child));
    else if (e.isFile()) out.push(child);
  }
  return out.sort();
}
/** 递归扫描远端目录（相对 files 根），按 include/exclude 过滤；不跟随符号链接 */
export function scanRemote(
  root: string,
  relDir: string,
  include: string[],
  exclude: string[],
  filter: SyncFilterConfig = DEFAULT_FILTER,
): SyncEntry[] {
  const abs = resolveInRoot(root, relDir);
  if (!fs.existsSync(abs) || !fs.statSync(abs).isDirectory()) return [];
  const out: SyncEntry[] = [];
  const stack: Array<{ rel: string }> = [{ rel: '' }];
  while (stack.length > 0) {
    const { rel } = stack.pop()!;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(path.join(abs, rel), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        stack.push({ rel: childRel });
      } else if (e.isFile()) {
        if (!inScope(childRel, include, exclude)) continue;
        try {
          const st = fs.statSync(path.join(abs, childRel));
          if (filterExcluded(childRel, st.size, filter)) continue;
          out.push({ path: childRel, size: st.size, mtimeMs: st.mtimeMs });
        } catch {
          /* 扫描期间被删：跳过 */
        }
      }
    }
  }
  return out.sort((a, b) => a.path.localeCompare(b.path));
}
/** 同步任务的行 → API 对象 */
export function toTask(r: SyncTaskRow) {
  return {
    id: r.id,
    name: r.name ?? '',
    deviceId: r.device_id,
    deviceName: r.device_name,
    mode: r.mode,
    status: r.status,
    localDir: r.local_dir,
    remoteDir: r.remote_dir,
    include: JSON.parse(r.include_json || '[]') as string[],
    exclude: JSON.parse(r.exclude_json || '[]') as string[],
    filterConfig: parseFilter(r.filter_json),
    syncConfig: parseTaskConfig(r.sync_json),
    createdAt: Number(r.created_at),
    updatedAt: Number(r.updated_at),
    lastRunAt: r.last_run_at === null ? null : Number(r.last_run_at),
    lastError: r.last_error,
  };
}
export interface SyncTaskRow {
  id: string;
  uid: string;
  name: string;
  device_id: string;
  device_name: string;
  mode: string;
  status: string;
  local_dir: string;
  remote_dir: string;
  include_json: string;
  exclude_json: string;
  filter_json: string;
  sync_json: string;
  created_at: number;
  updated_at: number;
  last_run_at: number | null;
  last_error: string | null;
}
export interface JobRow {
  id: string;
  source: string;
  target: string;
  policy: string;
  copied: number;
  skipped: number;
  conflicts: number;
  bytes: number;
  created_at: number;
}
export interface ConflictRow {
  id: string;
  job_id: string;
  path: string;
  created_at: number;
  resolved: number;
  resolution: string | null;
}
