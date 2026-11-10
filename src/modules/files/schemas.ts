import { Type } from '@sinclair/typebox';

/**
 * files 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）
 * 每个 schema 带 `$id`，@fastify/swagger 会提升到 components.schemas 并用 $ref 引用。
 */

export const ListQuery = Type.Object(
  {
    path: Type.Optional(
      Type.String({
        description: '目录路径：相对文件根（缺省为根），或绝对路径（D:/Photos、\\\\host\\share）',
      }),
    ),
    cursor: Type.Optional(Type.String({ description: '游标（当前未启用）' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 200 })),
  },
  { $id: 'FilesListQuery' },
);

export const ListItem = Type.Object(
  {
    name: Type.String(),
    dir: Type.Boolean(),
  },
  { $id: 'FilesListItem' },
);

export const ListResponse = Type.Object(
  {
    path: Type.String(),
    items: Type.Array(Type.Ref(ListItem)),
    nextCursor: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'FilesListResponse' },
);

export const RootItem = Type.Object(
  {
    path: Type.String({ description: 'POSIX 风格绝对路径，如 C:/ 或 \\\\host\\share' }),
    label: Type.String({ description: '展示名，如 C:' }),
    kind: Type.Union([Type.Literal('drive'), Type.Literal('home'), Type.Literal('share')]),
  },
  { $id: 'FilesRootItem' },
);

export const RootsResponse = Type.Object(
  {
    home: Type.String({ description: '文件根（相对路径以此为基准）' }),
    roots: Type.Array(Type.Ref(RootItem)),
  },
  { $id: 'FilesRootsResponse' },
);

export const CheckBody = Type.Object(
  {
    path: Type.String({ minLength: 1, description: '目标文件相对路径' }),
    size: Type.Optional(Type.Integer({ minimum: 0 })),
    hash: Type.Optional(Type.String({ description: '整体 sha256（可选）' })),
  },
  { $id: 'FilesCheckBody' },
);

export const CheckResponse = Type.Object(
  {
    path: Type.String(),
    exists: Type.Boolean(),
    uploadId: Type.String(),
    uploaded: Type.Array(Type.Integer()),
    chunkSize: Type.Integer(),
    /** 传输中心会话 id：客户端把它带进 chunk / merge，进度就能被所有设备看到 */
    sessionId: Type.Optional(Type.String()),
  },
  { $id: 'FilesCheckResponse' },
);

export const ChunkQuery = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    index: Type.Integer({ minimum: 0 }),
    total: Type.Optional(Type.Integer({ minimum: 1 })),
    /** 传输会话 id（可选）：带了就把这一片计入该会话的进度 */
    sid: Type.Optional(Type.String()),
  },
  { $id: 'FilesChunkQuery' },
);

export const ChunkResponse = Type.Object(
  {
    ok: Type.Boolean(),
    uploadId: Type.String(),
    index: Type.Integer(),
    size: Type.Integer(),
  },
  { $id: 'FilesChunkResponse' },
);

export const MergeBody = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    total: Type.Integer({
      minimum: 0,
      description: '分片数；0 表示空文件（直接落盘空文件，无需 chunk）',
    }),
    size: Type.Optional(Type.Integer({ minimum: 0 })),
    hash: Type.Optional(Type.String()),
    mtimeMs: Type.Optional(
      Type.Number({
        minimum: 0,
        description: '写入后的修改时间（毫秒）。同步业务用它让两端 mtime 对齐，避免下一轮误判为已修改',
      }),
    ),
  },
  { $id: 'FilesMergeBody' },
);

export const MergeResponse = Type.Object(
  {
    ok: Type.Boolean(),
    path: Type.String(),
    size: Type.Integer(),
    skipped: Type.Boolean(),
  },
  { $id: 'FilesMergeResponse' },
);

export const DownloadQuery = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    inline: Type.Optional(Type.String({ description: '1 = 内联打开，默认附件下载' })),
  },
  { $id: 'FilesDownloadQuery' },
);

/** 二进制请求体：仅用于契约描述，运行时跳过 ajv body 校验 */
export const BinaryBody = Type.Unsafe({ type: 'string', format: 'binary' });

export const ThumbQuery = Type.Object(
  {
    path: Type.String({ minLength: 1, description: '图片/视频相对路径（files 根内）' }),
    size: Type.Optional(
      Type.Integer({
        minimum: 32,
        maximum: 2048,
        default: 256,
        description: '目标宽度（px），高度按比例；默认 256',
      }),
    ),
    at: Type.Optional(
      Type.Number({
        minimum: 0,
        maximum: 10800,
        description: '视频抽帧位置（秒），仅对视频生效；默认 0.5',
      }),
    ),
  },
  { $id: 'FilesThumbQuery' },
);

// ---------------------------------------------------------------- 索引 / 搜索（蓝图 §8/§9）

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'FilesErrorResponse' },
);

export const IndexStartResponse = Type.Object(
  {
    taskId: Type.String({ description: '任务队列 id，可查 /api/v1/tasks' }),
    reused: Type.Boolean({ description: '已有同参数任务在队列中时复用' }),
  },
  { $id: 'FilesIndexStartResponse' },
);

export const IndexStatusResponse = Type.Object(
  {
    root: Type.String(),
    indexed: Type.Integer({ description: '已落库条数' }),
    lastSeq: Type.Integer({ description: '断点批次序号' }),
    updatedAt: Type.Union([Type.Integer(), Type.Null()]),
    running: Type.Boolean({ description: 'indexer sidecar 是否在跑' }),
    batches: Type.Integer(),
    maxTxMs: Type.Number({ description: '单批事务最大耗时（ms）' }),
  },
  { $id: 'FilesIndexStatusResponse' },
);

export const SearchQuery = Type.Object(
  {
    q: Type.String({ minLength: 1, maxLength: 200 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
  },
  { $id: 'FilesSearchQuery' },
);

export const SearchItem = Type.Object({
  path: Type.String(),
  size: Type.Integer(),
  mtime: Type.Integer(),
});

export const SearchResponse = Type.Object(
  { items: Type.Array(SearchItem) },
  { $id: 'FilesSearchResponse' },
);

// ---------------------------------------------------------------- 写操作（新建 / 改名 / 移动 / 删到回收站）

export const OpPathBody = Type.Object(
  { path: Type.String({ minLength: 1, description: '相对 files 根的路径' }) },
  { $id: 'FilesOpPathBody' },
);

export const MkdirResponse = Type.Object(
  { path: Type.String({ description: '创建后的相对路径' }) },
  { $id: 'FilesMkdirResponse' },
);

export const RenameBody = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    name: Type.String({
      minLength: 1,
      maxLength: 255,
      description: '新名字（只允许单段，不含路径分隔符）',
    }),
  },
  { $id: 'FilesRenameBody' },
);

export const RenameResponse = Type.Object(
  { path: Type.String(), from: Type.String() },
  { $id: 'FilesRenameResponse' },
);

export const MoveBody = Type.Object(
  {
    paths: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    to: Type.String({ description: '目标目录（相对根，必须已存在）' }),
    copy: Type.Optional(Type.Boolean({ description: 'true = 复制而非移动' })),
  },
  { $id: 'FilesMoveBody' },
);

export const DeleteBody = Type.Object(
  {
    paths: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    permanent: Type.Optional(
      Type.Boolean({ description: 'true = 直接从磁盘删除；缺省移入回收站' }),
    ),
  },
  { $id: 'FilesDeleteBody' },
);

export const OpFailure = Type.Object(
  { path: Type.String(), error: Type.String() },
  { $id: 'FilesOpFailure' },
);

export const OpResult = Type.Object(
  {
    done: Type.Array(Type.String()),
    failed: Type.Array(Type.Ref(OpFailure)),
    trashedTo: Type.Optional(
      Type.String({ description: '回收站批次名，原样传给 /files/trash/restore 的 batch' }),
    ),
  },
  { $id: 'FilesOpResult' },
);

export const TrashItem = Type.Object(
  {
    name: Type.String({ description: '相对批次目录的路径' }),
    dir: Type.Boolean(),
    size: Type.Integer(),
  },
  { $id: 'FilesTrashItem' },
);

export const TrashBatch = Type.Object(
  {
    batch: Type.String({ description: '批次目录名（删除时间）' }),
    items: Type.Array(Type.Ref(TrashItem)),
  },
  { $id: 'FilesTrashBatch' },
);

export const TrashListResponse = Type.Object(
  { batches: Type.Array(Type.Ref(TrashBatch)) },
  { $id: 'FilesTrashListResponse' },
);

export const TrashRestoreBody = Type.Object(
  {
    batch: Type.String({ minLength: 1 }),
    paths: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
  },
  { $id: 'FilesTrashRestoreBody' },
);

export const TrashEmptyBody = Type.Object(
  { batch: Type.Optional(Type.String({ description: '只清某个批次；缺省清空整个回收站' })) },
  { $id: 'FilesTrashEmptyBody' },
);

export const TrashEmptyResponse = Type.Object(
  { removed: Type.Integer() },
  { $id: 'FilesTrashEmptyResponse' },
);
export const OpLogQuery = Type.Object(
  {
    uid: Type.Optional(Type.String({ description: '按操作者过滤；缺省为全部用户' })),
    action: Type.Optional(
      Type.String({
        description:
          'mkdir / rename / move / copy / upload / download / trash / delete / restore / empty',
      }),
    ),
    status: Type.Optional(
      Type.Union([Type.Literal('ok'), Type.Literal('failed')], {
        description: 'ok = 成功；failed = 失败',
      }),
    ),
    q: Type.Optional(Type.String({ description: '关键词（路径 / 明细 / 用户名）' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })),
    offset: Type.Optional(Type.Integer({ minimum: 0, default: 0 })),
  },
  { $id: 'FilesOpLogQuery' },
);

export const OpLogItem = Type.Object(
  {
    id: Type.String(),
    uid: Type.String(),
    username: Type.String(),
    action: Type.String(),
    status: Type.String(),
    path: Type.String(),
    detail: Type.String(),
    ip: Type.String(),
    createdAt: Type.Integer({ description: 'Unix 秒' }),
  },
  { $id: 'FilesOpLogItem' },
);

export const OpLogListResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(OpLogItem)),
    total: Type.Integer({ description: '过滤后的总条数（分页用）' }),
    limit: Type.Integer(),
    offset: Type.Integer(),
  },
  { $id: 'FilesOpLogListResponse' },
);
