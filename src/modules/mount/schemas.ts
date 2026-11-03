import { Type } from '@sinclair/typebox';

/**
 * mount（fileMount / 网盘挂载）模块路由契约。
 *
 * 一期支持 WebDAV（内置客户端）与 rclone（调用本机 rclone，支持 SMB / NFS / 网盘）。
 * 挂载是「远程目录代理」：不落 FUSE，读写都经服务端转发，跨平台一致。
 */
const NullableInteger = Type.Union([Type.Integer(), Type.Null()]);
const NullableString = Type.Union([Type.String(), Type.Null()]);

export const Mount = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    kind: Type.String({ description: 'webdav / rclone' }),
    baseUrl: Type.String({ description: 'WebDAV 基地址，或 rclone remote 规格（如 smb:dir）' }),
    username: Type.String(),
    rootPath: Type.String(),
    readOnly: Type.Boolean(),
    status: Type.String({ description: 'unknown / ok / error' }),
    lastError: NullableString,
    lastCheckAt: NullableInteger,
    createdAt: Type.Integer(),
  },
  { $id: 'MountItem' },
);

export const MountListResponse = Type.Object(
  { items: Type.Array(Type.Ref(Mount)) },
  { $id: 'MountListResponse' },
);

export const MountCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    kind: Type.String({ enum: ['webdav', 'rclone'] }),
    baseUrl: Type.String({ minLength: 1, maxLength: 1000 }),
    username: Type.Optional(Type.String({ maxLength: 200 })),
    password: Type.Optional(Type.String({ maxLength: 500 })),
    rootPath: Type.Optional(Type.String({ maxLength: 500 })),
    readOnly: Type.Optional(Type.Boolean()),
  },
  { $id: 'MountCreateBody' },
);

export const MountRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'MountRemoveBody' },
);

export const MountTestBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'MountTestBody' },
);

export const MountBrowseQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    path: Type.Optional(Type.String({ maxLength: 1000, description: '相对挂载根的路径' })),
  },
  { $id: 'MountBrowseQuery' },
);

export const MountEntry = Type.Object(
  {
    name: Type.String(),
    path: Type.String({ description: '相对挂载根' }),
    dir: Type.Boolean(),
    size: Type.Integer(),
    mtime: NullableInteger,
  },
  { $id: 'MountEntry' },
);

export const MountBrowseResponse = Type.Object(
  {
    path: Type.String(),
    items: Type.Array(Type.Ref(MountEntry)),
  },
  { $id: 'MountBrowseResponse' },
);

export const MountPathQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    path: Type.String({ minLength: 1, maxLength: 1000 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（仅外部下载器使用，见 /mount/download-url）' }),
    ),
  },
  { $id: 'MountPathQuery' },
);

export const DownloadUrlResponse = Type.Object(
  {
    url: Type.String({ description: '带短期令牌的下载地址，可直接交给外部下载器' }),
    expiresInSec: Type.Integer(),
  },
  { $id: 'MountDownloadUrlResponse' },
);

export const MountPathBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    path: Type.String({ minLength: 1, maxLength: 1000 }),
  },
  { $id: 'MountPathBody' },
);

export const MountUploadQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    path: Type.String({ minLength: 1, maxLength: 1000 }),
    size: Type.Optional(Type.Integer({ minimum: 0 })),
  },
  { $id: 'MountUploadQuery' },
);

export const MountTargetResponse = Type.Object(
  {
    mount: Type.Ref(Mount),
    path: Type.String(),
  },
  { $id: 'MountTargetResponse' },
);

export const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'MountOkResponse' });

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'MountErrorResponse' },
);

export const MOUNT_SCHEMAS = [
  Mount,
  MountListResponse,
  MountCreateBody,
  MountRemoveBody,
  MountTestBody,
  MountBrowseQuery,
  MountEntry,
  MountBrowseResponse,
  MountPathQuery,
  DownloadUrlResponse,
  MountPathBody,
  MountUploadQuery,
  MountTargetResponse,
  OkResponse,
  ErrorResponse,
];