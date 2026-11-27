import { Type } from '@sinclair/typebox';

/**
 * 本地博客 / 博客合集的接口契约。
 *
 * 与 AI 新闻分开一组 $id：AI 新闻是「服务端生成的一期」，本地博客是
 * 「用户目录里的音频文件」，两者的 id 语义完全不同，混在一套 schema 里
 * 会让生成出来的 Dart 模型含糊。
 */

export const BlogLocalSource = Type.Object(
  {
    id: Type.String(),
    name: Type.String({ description: '展示名（默认取目录名，可改名）' }),
    path: Type.String({ description: '本地绝对路径（POSIX 风格）' }),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'BlogLocalSource' },
);

export const BlogLocalSourceListResponse = Type.Object(
  { items: Type.Array(Type.Ref(BlogLocalSource)) },
  { $id: 'BlogLocalSourceListResponse' },
);

export const BlogLocalSourceBody = Type.Object(
  {
    path: Type.String({ minLength: 1, maxLength: 2000, description: '本地目录绝对路径' }),
    name: Type.Optional(Type.String({ maxLength: 120 })),
  },
  { $id: 'BlogLocalSourceBody' },
);

export const BlogLocalSourceRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BlogLocalSourceRemoveBody' },
);

/** 浏览目录里的一层子目录 */
export const BlogLocalDir = Type.Object(
  {
    name: Type.String(),
    path: Type.String({ description: 'POSIX 风格绝对路径（回传给 browse 的 path）' }),
  },
  { $id: 'BlogLocalDir' },
);

/** 目录里的一条音频（封面 = 同目录同名图片） */
export const BlogLocalAudio = Type.Object(
  {
    name: Type.String({ description: '文件名（含扩展名）' }),
    title: Type.String({ description: '主文件名（不含扩展名），作为播放标题' }),
    path: Type.String({ description: '音频文件绝对路径' }),
    size: Type.Integer(),
    coverUrl: Type.Union([Type.String(), Type.Null()], {
      description: '同名封面图地址（带令牌）；没有同名图片时为 null',
    }),
    // 进度三件套标 Optional：新服务端一定返回，但 1.5.x 不返回，
    // 客户端要按「没听过」处理而不是整页报错（2026-11-26 反馈）。
    // 标 required 会让生成的 Dart 模型变非空，`json['listened'] as bool`
    // 在旧服务端上直接抛异常。
    listened: Type.Optional(
      Type.Boolean({ description: '听到 ≥90% 后置为已听，重听也不会回落；1.5.x 服务端不返回（按未听处理）' }),
    ),
    positionMs: Type.Optional(
      Type.Integer({ description: '上次播放位置（毫秒）；没听过为 0；1.5.x 服务端不返回（按 0 处理）' }),
    ),
  },
  { $id: 'BlogLocalAudio' },
);

export const BlogLocalBrowseQuery = Type.Object(
  {
    sourceId: Type.String({ minLength: 1 }),
    path: Type.Optional(Type.String({ description: '要浏览的目录；空 = 目录源根目录' })),
  },
  { $id: 'BlogLocalBrowseQuery' },
);

export const BlogLocalBrowseResponse = Type.Object(
  {
    path: Type.String({ description: '当前目录（POSIX 风格绝对路径）' }),
    parent: Type.Union([Type.String(), Type.Null()], {
      description: '上一级目录；已在目录源根目录时为 null',
    }),
    dirs: Type.Array(Type.Ref(BlogLocalDir)),
    audios: Type.Array(Type.Ref(BlogLocalAudio)),
  },
  { $id: 'BlogLocalBrowseResponse' },
);

/** 本地音频播放地址 / 流地址共用：path 为音频绝对路径 */
export const BlogLocalPathQuery = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    format: Type.Optional(
      Type.String({
        maxLength: 16,
        description: 'auto = Web 端播放：浏览器不支持的格式实时转 PCM 推流',
      }),
    ),
  },
  { $id: 'BlogLocalPathQuery' },
);

export const BlogLocalAudioUrlResponse = Type.Object(
  { url: Type.String(), expiresInSec: Type.Integer() },
  { $id: 'BlogLocalAudioUrlResponse' },
);

export const BlogLocalDeleteBody = Type.Object(
  { paths: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }) },
  { $id: 'BlogLocalDeleteBody' },
);

export const BlogLocalDeleteResponse = Type.Object(
  { ok: Type.Boolean(), deleted: Type.Integer() },
  { $id: 'BlogLocalDeleteResponse' },
);

/** 上报本地音频播放进度（前端节流上报；90% 由服务端判定已听） */
export const BlogLocalProgressBody = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    positionMs: Type.Integer({ minimum: 0 }),
    durationMs: Type.Integer({ minimum: 0 }),
  },
  { $id: 'BlogLocalProgressBody' },
);

/** 博客合集（列表卡） */
export const BlogCollection = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    description: Type.String(),
    tracks: Type.Integer(),
    coverUrl: Type.Union([Type.String(), Type.Null()], {
      description: '合集内第一首带同名封面的音频封面；没有时为 null',
    }),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'BlogCollection' },
);

export const BlogCollectionListResponse = Type.Object(
  { items: Type.Array(Type.Ref(BlogCollection)) },
  { $id: 'BlogCollectionListResponse' },
);

export const BlogCollectionBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 120 }),
    description: Type.Optional(Type.String({ maxLength: 500 })),
  },
  { $id: 'BlogCollectionBody' },
);

export const BlogCollectionUpdateBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.Optional(Type.String({ minLength: 1, maxLength: 120 })),
    description: Type.Optional(Type.String({ maxLength: 500 })),
  },
  { $id: 'BlogCollectionUpdateBody' },
);

export const BlogCollectionIdBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BlogCollectionIdBody' },
);

export const BlogCollectionItem = Type.Object(
  {
    id: Type.String(),
    path: Type.String({ description: '音频绝对路径' }),
    title: Type.String(),
    size: Type.Integer(),
    coverUrl: Type.Union([Type.String(), Type.Null()]),
    // 同 BlogLocalAudio：兼容 1.5.x 服务端不返回进度字段
    listened: Type.Optional(
      Type.Boolean({ description: '听到 ≥90% 后置为已听，重听也不会回落；1.5.x 服务端不返回（按未听处理）' }),
    ),
    positionMs: Type.Optional(
      Type.Integer({ description: '上次播放位置（毫秒）；没听过为 0；1.5.x 服务端不返回（按 0 处理）' }),
    ),
    playedAt: Type.Optional(
      Type.Integer({ description: '最后一次播放时间戳；没听过为 0；1.5.x 服务端不返回（按 0 处理）' }),
    ),
  },
  { $id: 'BlogCollectionItem' },
);

export const BlogCollectionItemsQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BlogCollectionItemsQuery' },
);

export const BlogCollectionItemsResponse = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    description: Type.String(),
    items: Type.Array(Type.Ref(BlogCollectionItem)),
  },
  { $id: 'BlogCollectionItemsResponse' },
);

export const BlogCollectionAddBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    paths: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
  },
  { $id: 'BlogCollectionAddBody' },
);

export const BlogCollectionAddResponse = Type.Object(
  { ok: Type.Boolean(), added: Type.Integer(), skipped: Type.Integer() },
  { $id: 'BlogCollectionAddResponse' },
);

export const BlogCollectionRemoveItemBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    itemId: Type.String({ minLength: 1 }),
  },
  { $id: 'BlogCollectionRemoveItemBody' },
);

export const BlogCollectionReorderBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    itemIds: Type.Array(Type.String({ minLength: 1 })),
  },
  { $id: 'BlogCollectionReorderBody' },
);

export const BLOG_LOCAL_SCHEMAS = [
  BlogLocalSource,
  BlogLocalSourceListResponse,
  BlogLocalSourceBody,
  BlogLocalSourceRemoveBody,
  BlogLocalDir,
  BlogLocalAudio,
  BlogLocalBrowseQuery,
  BlogLocalBrowseResponse,
  BlogLocalPathQuery,
  BlogLocalAudioUrlResponse,
  BlogLocalDeleteBody,
  BlogLocalDeleteResponse,
  BlogLocalProgressBody,
  BlogCollection,
  BlogCollectionListResponse,
  BlogCollectionBody,
  BlogCollectionUpdateBody,
  BlogCollectionIdBody,
  BlogCollectionItem,
  BlogCollectionItemsQuery,
  BlogCollectionItemsResponse,
  BlogCollectionAddBody,
  BlogCollectionAddResponse,
  BlogCollectionRemoveItemBody,
  BlogCollectionReorderBody,
];
