import { Type } from '@sinclair/typebox';

/**
 * 传输中心的契约。
 *
 * 注意两点（都踩过）：
 * 1. 列表响应**必须包成 `{ items, total }`**，直接返回数组会让 `gen-client` 只生成
 *    `Future<Map>`，客户端 `_asMap()` 把 List 静默吞成 `{}`。
 * 2. schema 里**不要写 `default:`**：ajv 会把默认值填进 `q.xxx`，让 handler 里的
 *    兼容别名判断永远走不到；默认值在 handler 里兜底。
 */

export const TransferSession = Type.Object(
  {
    id: Type.String(),
    owner: Type.String({ description: '发起者 uid；面板用来区分「我的」与「别人的」' }),
    ownerName: Type.Optional(Type.String({ description: '发起者用户名（查不到时为空）' })),
    direction: Type.String({ description: 'upload / download' }),
    path: Type.String({ description: '目标或源路径（相对文件根）' }),
    name: Type.String({ description: '路径末段，便于直接展示' }),
    size: Type.Integer({ minimum: 0 }),
    transferred: Type.Integer({ minimum: 0 }),
    totalChunks: Type.Integer({ minimum: 0 }),
    doneChunks: Type.Array(Type.Integer()),
    state: Type.String({ description: 'pending / active / paused / done / failed / canceled' }),
    origin: Type.String({ description: '发起端：desktop / web / android / ios / tv' }),
    device: Type.String({ description: '设备可读名（可空）' }),
    error: Type.Union([Type.String(), Type.Null()]),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
    finishedAt: Type.Union([Type.Integer(), Type.Null()]),
  },
  { $id: 'TransferSession' },
);

export const TransferStats = Type.Object(
  {
    active: Type.Integer(),
    done: Type.Integer(),
    failed: Type.Integer(),
    paused: Type.Integer(),
    activeBytes: Type.Integer(),
    speedBps: Type.Integer({ description: '整机最近 30 秒的平均吞吐（字节/秒，粗估）' }),
  },
  { $id: 'TransferStats' },
);

export const SessionsResponse = Type.Object(
  {
    items: Type.Array(TransferSession),
    total: Type.Integer(),
    stats: TransferStats,
  },
  { $id: 'TransferSessionsResponse' },
);

export const ListQuery = Type.Object(
  {
    state: Type.Optional(Type.String({ description: '按状态过滤；all 或省略 = 全部' })),
    direction: Type.Optional(Type.String({ description: 'upload / download' })),
    owner: Type.Optional(Type.String({ description: '只看某个 uid 的传输' })),
    q: Type.Optional(Type.String({ description: '按路径或文件名模糊搜索' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
    offset: Type.Optional(Type.Integer({ minimum: 0 })),
  },
  { $id: 'TransferListQuery' },
);

export const BeginBody = Type.Object(
  {
    id: Type.Optional(Type.String({ description: '客户端生成的会话 id；重复调用即续传' })),
    direction: Type.Optional(Type.String({ description: '缺省 upload' })),
    path: Type.String({ minLength: 1 }),
    size: Type.Optional(Type.Integer({ minimum: 0 })),
    totalChunks: Type.Optional(Type.Integer({ minimum: 0 })),
    origin: Type.Optional(Type.String({ description: '发起端标识' })),
    device: Type.Optional(Type.String({ description: '设备可读名' })),
  },
  { $id: 'TransferBeginBody' },
);

export const BeginResponse = Type.Object(
  { session: TransferSession },
  { $id: 'TransferBeginResponse' },
);

export const IdBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'TransferIdBody' },
);

export const OkResponse = Type.Object(
  { ok: Type.Boolean(), affected: Type.Optional(Type.Integer()) },
  { $id: 'TransferOkResponse' },
);
