import { Type } from '@sinclair/typebox';

/**
 * book 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 */
const NullableInteger = Type.Union([Type.Integer(), Type.Null()]);
const NullableString = Type.Union([Type.String(), Type.Null()]);

export const LibraryItem = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    path: Type.String({ description: '相对 files 根的 POSIX 路径' }),
    type: Type.String({ description: 'book 书籍 / comic 漫画' }),
    items: Type.Integer({ description: '已索引书籍数' }),
    scanWhenStart: Type.Integer({ description: '1 启动时自动扫描' }),
    scanWhenChange: Type.Integer({ description: '1 目录变化时自动扫描' }),
    scanIntervalHours: Type.Integer({ description: '定时扫描间隔（小时，0 = 关闭）' }),
    createdAt: Type.Integer(),
    lastScanAt: NullableInteger,
  },
  { $id: 'BookLibraryItem' },
);

export const LibraryListResponse = Type.Object(
  { items: Type.Array(Type.Ref(LibraryItem)) },
  { $id: 'BookLibraryListResponse' },
);

export const LibraryCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    path: Type.String({ minLength: 1, description: '相对 files 根的目录' }),
    type: Type.Optional(
      Type.Union([Type.Literal('book'), Type.Literal('comic')], {
        default: 'book',
        description: 'book 书籍 / comic 漫画',
      }),
    ),
  },
  { $id: 'BookLibraryCreateBody' },
);

export const LibraryUpdateBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
    type: Type.Optional(Type.Union([Type.Literal('book'), Type.Literal('comic')])),
    scanWhenStart: Type.Optional(Type.Boolean()),
    scanWhenChange: Type.Optional(Type.Boolean()),
    scanIntervalHours: Type.Optional(Type.Integer({ minimum: 0, maximum: 24 })),
  },
  { $id: 'BookLibraryUpdateBody' },
);

export const LibraryRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BookLibraryRemoveBody' },
);

export const ScanBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String({ description: '缺省扫描全部库' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20000 })),
    prune: Type.Optional(
      Type.Boolean({ description: '清理磁盘上已不存在的书（仅整库扫描生效，默认关闭）' }),
    ),
  },
  { $id: 'BookScanBody' },
);

export const ScanResponse = Type.Object(
  {
    libraries: Type.Integer(),
    books: Type.Integer(),
    added: Type.Integer(),
    updated: Type.Integer(),
    skipped: Type.Integer(),
    parsed: Type.Integer({ description: '解析出元数据的条数' }),
    missing: Type.Optional(Type.Integer({ description: '索引有、磁盘已不存在（整库扫描）' })),
    pruned: Type.Optional(Type.Integer({ description: '本次实际清理的行数' })),
  },
  { $id: 'BookScanResponse' },
);

export const Book = Type.Object(
  {
    id: Type.String(),
    libraryId: Type.String(),
    path: Type.String({ description: '相对 files 根' }),
    type: Type.String({ description: 'book 书籍 / comic 漫画' }),
    title: Type.String(),
    author: NullableString,
    language: NullableString,
    publisher: NullableString,
    format: Type.String({ description: '扩展名，如 epub / pdf / cbz' }),
    pageCount: NullableInteger,
    hasCover: Type.Boolean(),
    size: Type.Integer(),
    favorite: Type.Boolean({ description: '当前用户是否收藏' }),
    progressPercent: Type.Union([Type.Integer(), Type.Null()], {
      description: '当前用户阅读进度 0-100',
    }),
    collection: NullableString,
    collectionIndex: NullableInteger,
    archived: Type.Boolean({ description: '当前用户是否已归档' }),
  },
  { $id: 'BookItem' },
);

export const ListQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    type: Type.Optional(
      Type.Union([Type.Literal('book'), Type.Literal('comic')], {
        description: '只看书籍或只看漫画',
      }),
    ),
    q: Type.Optional(Type.String({ maxLength: 200, description: '标题 / 作者关键词' })),
    format: Type.Optional(Type.String({ maxLength: 16, description: '按扩展名过滤' })),
    favorite: Type.Optional(
      Type.String({ description: '1 / true 表示只看当前用户收藏（避免 query 布尔解析歧义）' }),
    ),
    archived: Type.Optional(
      Type.String({ description: '1 只看归档；0 只看未归档；缺省为全部' }),
    ),
    listId: Type.Optional(Type.String({ description: '只看某个自定义列表内的书' })),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'BookListQuery' },
);

export const ListResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(Book)),
    nextCursor: NullableString,
  },
  { $id: 'BookListResponse' },
);

export const IdQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（仅外部阅读器使用，见 /book/file-url）' }),
    ),
  },
  { $id: 'BookIdQuery' },
);

export const FileUrlResponse = Type.Object(
  {
    url: Type.String({ description: '带短期令牌的阅读地址，可直接交给外部阅读器' }),
    expiresInSec: Type.Integer(),
  },
  { $id: 'BookFileUrlResponse' },
);

export const StatsResponse = Type.Object(
  {
    libraries: Type.Integer(),
    books: Type.Integer({ description: '全部书籍 + 漫画' }),
    bookCount: Type.Integer({ description: '书籍数' }),
    comicCount: Type.Integer({ description: '漫画数' }),
    favorites: Type.Integer({ description: '当前用户收藏数' }),
  },
  { $id: 'BookStatsResponse' },
);

export const FavoriteBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BookFavoriteBody' },
);

export const ProgressBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    position: Type.String({ maxLength: 2000, description: '阅读位置（章节 / 页码 / 字符偏移）' }),
    percent: Type.Integer({ minimum: 0, maximum: 100 }),
  },
  { $id: 'BookProgressBody' },
);

export const Progress = Type.Object(
  {
    bookId: Type.String(),
    position: Type.String(),
    percent: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'BookProgress' },
);

export const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'BookOkResponse' });

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'BookErrorResponse' },
);

export const TocPageItem = Type.Object(
  {
    index: Type.Integer({ minimum: 0 }),
    title: Type.String(),
  },
  { $id: 'BookTocPage' },
);

export const TocResponse = Type.Object(
  {
    kind: Type.String({
      description:
        '阅读器数据形态：text 章节文本 / image 图片页 / pdf 由服务端渲染页图 / none 暂不支持',
    }),
    total: Type.Integer(),
    pages: Type.Array(TocPageItem),
  },
  { $id: 'BookTocResponse' },
);

export const PageQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    index: Type.Integer({ minimum: 0, description: '页 / 章序号，从 0 开始' }),
  },
  { $id: 'BookPageQuery' },
);

/**
 * 单页响应用**一个对象 + 可选字段**而不是 anyOf：
 * anyOf 在 Dart 生成器里没有对应类，客户端无法反序列化（实测会生成引用不存在类型的代码）。
 */
export const PageResponse = Type.Object(
  {
    kind: Type.String({ description: 'text 时给 text，image 时给 mime + data(base64)' }),
    index: Type.Integer(),
    title: Type.String(),
    text: Type.Optional(Type.String({ description: '纯文本（HTML 已剥离标签）' })),
    truncated: Type.Optional(Type.Boolean({ description: '单页超过 200 KB 时截断' })),
    mime: Type.Optional(Type.String({ description: '图片页 MIME' })),
    data: Type.Optional(Type.String({ description: 'base64 图片数据（单页 ≤ 8 MB）' })),
  },
  { $id: 'BookPageResponse' },
);

// ---------------------------------------------------------------- 合集 / 归档 / 自定义列表

/** 合集：由 `books.collection` 聚合而来（书系是书的客观属性，不按用户隔离） */
export const CollectionItem = Type.Object(
  {
    name: Type.String(),
    books: Type.Integer({ description: '该合集内的书数' }),
    coverId: NullableString,
  },
  { $id: 'BookCollectionItem' },
);

export const CollectionsQuery = Type.Object(
  {
    q: Type.Optional(Type.String({ maxLength: 200, description: '合集名关键词' })),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'BookCollectionsQuery' },
);

export const CollectionsResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(CollectionItem)),
    nextCursor: NullableString,
  },
  { $id: 'BookCollectionsResponse' },
);

export const CollectionItemsQuery = Type.Object(
  {
    name: Type.String({ minLength: 1, description: '合集名' }),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'BookCollectionItemsQuery' },
);

export const CollectionBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.Optional(NullableString),
    index: Type.Optional(NullableInteger),
  },
  { $id: 'BookCollectionBody' },
);

export const ArchiveBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    archived: Type.Optional(Type.Boolean({ default: true, description: 'false 表示取消归档' })),
  },
  { $id: 'BookArchiveBody' },
);

/** 自定义列表按 JWT `sub` 隔离；一本书可进多个列表 */
export const ListItem = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    books: Type.Integer(),
    createdAt: Type.Integer(),
  },
  { $id: 'BookListItem' },
);

export const ListsResponse = Type.Object(
  { items: Type.Array(Type.Ref(ListItem)) },
  { $id: 'BookListsResponse' },
);

export const ListCreateBody = Type.Object(
  { name: Type.String({ minLength: 1, maxLength: 64 }) },
  { $id: 'BookListCreateBody' },
);

export const ListRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'BookListRemoveBody' },
);

export const ListRenameBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.String({ minLength: 1, maxLength: 64 }),
  },
  { $id: 'BookListRenameBody' },
);

export const ListRefBody = Type.Object(
  {
    listId: Type.String({ minLength: 1 }),
    bookId: Type.String({ minLength: 1 }),
  },
  { $id: 'BookListRefBody' },
);

export const ListItemsQuery = Type.Object(
  { listId: Type.String({ minLength: 1 }) },
  { $id: 'BookListItemsQuery' },
);

export const ListItemsResponse = Type.Object(
  { items: Type.Array(Type.Ref(Book)) },
  { $id: 'BookListItemsResponse' },
);

// ---------------------------------------------------------------- 阅读历史 / 用户合集

export const HistoryQuery = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })) },
  { $id: 'BookHistoryQuery' },
);

export const CacheStatsResponse = Type.Object(
  { files: Type.Integer(), bytes: Type.Integer() },
  { $id: 'BookCacheStatsResponse' },
);

export const CacheClearResponse = Type.Object(
  { files: Type.Integer(), bytes: Type.Integer() },
  { $id: 'BookCacheClearResponse' },
);

/** 用户自建合集：按目录整理（和音乐合集同一模型），按 owner 隔离 */
export const UserCollection = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    paths: Type.Array(Type.String()),
    books: Type.Integer({ description: '这些目录下已索引的书数' }),
    coverId: Type.Union([Type.String(), Type.Null()]),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'BookUserCollection' },
);

export const UserCollectionListResponse = Type.Object(
  { items: Type.Array(Type.Ref(UserCollection)) },
  { $id: 'BookUserCollectionListResponse' },
);

export const UserCollectionBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    paths: Type.Array(Type.String({ minLength: 1, maxLength: 1024 }), {
      minItems: 1,
      maxItems: 200,
    }),
  },
  { $id: 'BookUserCollectionBody' },
);

export const UserCollectionUpdateBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
    paths: Type.Optional(
      Type.Array(Type.String({ minLength: 1, maxLength: 1024 }), {
        minItems: 1,
        maxItems: 200,
      }),
    ),
  },
  { $id: 'BookUserCollectionUpdateBody' },
);

export const UserCollectionItemsQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 200 })),
  },
  { $id: 'BookUserCollectionItemsQuery' },
);

export const BOOK_SCHEMAS = [
  LibraryItem,
  LibraryListResponse,
  LibraryCreateBody,
  LibraryUpdateBody,
  LibraryRemoveBody,
  ScanBody,
  ScanResponse,
  Book,
  ListQuery,
  ListResponse,
  IdQuery,
  FileUrlResponse,
  StatsResponse,
  FavoriteBody,
  ProgressBody,
  Progress,
  TocPageItem,
  TocResponse,
  PageQuery,
  PageResponse,
  OkResponse,
  CollectionItem,
  CollectionsQuery,
  CollectionsResponse,
  CollectionItemsQuery,
  CollectionBody,
  ArchiveBody,
  ListItem,
  ListsResponse,
  ListCreateBody,
  ListRemoveBody,
  ListRenameBody,
  ListRefBody,
  ListItemsQuery,
  ListItemsResponse,
  HistoryQuery,
  CacheStatsResponse,
  CacheClearResponse,
  UserCollection,
  UserCollectionListResponse,
  UserCollectionBody,
  UserCollectionUpdateBody,
  UserCollectionItemsQuery,
  ErrorResponse,
];