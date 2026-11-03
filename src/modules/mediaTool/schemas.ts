import { Type } from '@sinclair/typebox';

/**
 * mediaTool 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 * 每个 schema 带 `$id`，@fastify/swagger 提升到 components.schemas 后用 $ref 引用。
 */

export const JobKind = Type.Union([Type.Literal('thumbnails'), Type.Literal('transcode')]);

export const JobStatus = Type.Union([
  Type.Literal('pending'),
  Type.Literal('running'),
  Type.Literal('done'),
  Type.Literal('failed'),
  Type.Literal('canceled'),
]);

export const ThumbnailsBody = Type.Object(
  {
    source: Type.String({ minLength: 1, description: 'files 根内目录（递归一层以上）' }),
    target: Type.Optional(
      Type.String({ description: '输出目录（相对 files 根）；缺省为 media-thumbnails/<jobId>' }),
    ),
    size: Type.Optional(Type.Integer({ minimum: 32, maximum: 2048, default: 256 })),
  },
  { $id: 'MediaToolThumbnailsBody' },
);

export const TranscodeBody = Type.Object(
  {
    source: Type.String({ minLength: 1, description: 'files 根内源文件' }),
    target: Type.String({ minLength: 1, description: '输出文件（相对 files 根，不能与源相同）' }),
    preset: Type.Optional(
      Type.Union([Type.Literal('audio'), Type.Literal('web720'), Type.Literal('copy')], {
        default: 'audio',
      }),
    ),
  },
  { $id: 'MediaToolTranscodeBody' },
);

export const JobCreated = Type.Object({ id: Type.String() }, { $id: 'MediaToolJobCreated' });

export const JobItem = Type.Object(
  {
    id: Type.String(),
    kind: JobKind,
    source: Type.String(),
    target: Type.String(),
    status: JobStatus,
    total: Type.Integer(),
    done: Type.Integer(),
    failed: Type.Integer(),
    error: Type.Union([Type.String(), Type.Null()]),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'MediaToolJobItem' },
);

export const JobListResponse = Type.Object(
  { items: Type.Array(Type.Ref(JobItem)) },
  { $id: 'MediaToolJobListResponse' },
);

export const JobListQuery = Type.Object(
  {
    status: Type.Optional(JobStatus),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })),
  },
  { $id: 'MediaToolJobListQuery' },
);

export const IdBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'MediaToolIdBody' },
);

export const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'MediaToolOkResponse' });

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'MediaToolErrorResponse' },
);

export const MEDIA_TOOL_SCHEMAS = [
  ThumbnailsBody,
  TranscodeBody,
  JobCreated,
  JobItem,
  JobListResponse,
  JobListQuery,
  IdBody,
  OkResponse,
  ErrorResponse,
];
