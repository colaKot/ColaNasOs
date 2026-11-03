import { Type } from '@sinclair/typebox';

/**
 * photo 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 * 每个 schema 带 `$id`，@fastify/swagger 提升到 components.schemas。
 */

export const LibraryItem = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    path: Type.String({ description: '相对 files 根的 POSIX 路径' }),
    items: Type.Integer({ description: '已索引图片数' }),
    createdAt: Type.Integer(),
    lastScanAt: Type.Union([Type.Integer(), Type.Null()]),
  },
  { $id: 'PhotoLibraryItem' },
);

export const LibraryListResponse = Type.Object(
  { items: Type.Array(Type.Ref(LibraryItem)) },
  { $id: 'PhotoLibraryListResponse' },
);

export const LibraryCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    path: Type.String({ minLength: 1, description: '相对 files 根的目录' }),
  },
  { $id: 'PhotoLibraryCreateBody' },
);

export const LibraryRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoLibraryRemoveBody' },
);

/** 设置当前用户默认库的来源目录（每用户只有一个库，不再提供建库） */
export const LibraryUpdateBody = Type.Object(
  {
    path: Type.String({ minLength: 1, description: '相对 files 根的目录' }),
  },
  { $id: 'PhotoLibraryUpdateBody' },
);

export const ScanBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String({ description: '缺省扫描全部库' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20000 })),
    prune: Type.Optional(
      Type.Boolean({ description: '清理磁盘上已不存在的图片（仅整库扫描生效，默认关闭）' }),
    ),
    force: Type.Optional(
      Type.Boolean({ description: '忽略 size/mtime 直接重读元数据（修正拍摄时间等）' }),
    ),
  },
  { $id: 'PhotoScanBody' },
);

export const ScanResponse = Type.Object(
  {
    libraries: Type.Integer(),
    images: Type.Integer(),
    added: Type.Integer(),
    updated: Type.Integer(),
    skipped: Type.Integer(),
    missing: Type.Optional(Type.Integer({ description: '索引有、磁盘已不存在（整库扫描）' })),
    pruned: Type.Optional(Type.Integer({ description: '本次实际清理的行数' })),
  },
  { $id: 'PhotoScanResponse' },
);

export const Item = Type.Object(
  {
    id: Type.String(),
    libraryId: Type.String(),
    path: Type.String({ description: '相对 files 根，可直接用于 files/download' }),
    takenAt: Type.Integer({ description: '拍摄时间（epoch 秒），无 EXIF 时为 mtime' }),
    size: Type.Integer(),
    width: Type.Union([Type.Integer(), Type.Null()]),
    height: Type.Union([Type.Integer(), Type.Null()]),
    mime: Type.String(),
    favorite: Type.Boolean({ description: '是否已收藏' }),
  },
  { $id: 'PhotoItem' },
);

export const TimelineQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    favorite: Type.Optional(Type.Boolean({ description: '只看收藏' })),
    folder: Type.Optional(Type.String({ description: '只看某个子目录（相对 files 根）' })),
    order: Type.Optional(Type.Union([Type.Literal('asc'), Type.Literal('desc')])),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoTimelineQuery' },
);

/** 批量收藏 / 取消收藏 */
export const FavoriteBody = Type.Object(
  {
    ids: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    favorite: Type.Boolean(),
  },
  { $id: 'PhotoFavoriteBody' },
);

export const FavoriteResponse = Type.Object(
  { updated: Type.Integer() },
  { $id: 'PhotoFavoriteResponse' },
);

export const TimelineResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(Item)),
    nextCursor: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoTimelineResponse' },
);

export const ItemQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoItemQuery' },
);

export const SearchQuery = Type.Object(
  {
    q: Type.Optional(Type.String({ maxLength: 200, description: '路径关键词' })),
    from: Type.Optional(Type.Integer({ description: '起始时间（epoch 秒，含）' })),
    to: Type.Optional(Type.Integer({ description: '结束时间（epoch 秒，含）' })),
    libraryId: Type.Optional(Type.String()),
    folder: Type.Optional(Type.String({ description: '只看某个子目录（相对 files 根）' })),
    order: Type.Optional(Type.Union([Type.Literal('asc'), Type.Literal('desc')])),
    cursor: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoSearchQuery' },
);

/**
 * 搜索框混合检索：语义（场景/活动/OCR/路径）+ 结构化，按相关度排序后分页。
 *
 * 与 `/photo/search` 的区别：那个是「按路径关键词 + 时间范围」的纯结构化查询，
 * 用来做文件名精确搜与时间过滤；这个是**用户在主搜索框里打字**时该走的那个，
 * 由服务端把「场景标签命中」也算进来。
 */
export const HybridSearchQuery = Type.Object(
  {
    q: Type.String({ minLength: 1, maxLength: 200 }),
    /** 偏移分页：语义结果是按相关度排好的有限集合，用 offset 比时间游标更自然 */
    offset: Type.Optional(Type.Integer({ minimum: 0, default: 0 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoHybridSearchQuery' },
);

export const HybridSearchResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(Item)),
    /** 下一页 offset；null = 没有更多 */
    nextOffset: Type.Union([Type.Integer(), Type.Null()]),
    total: Type.Integer({ description: '命中的总条数（语义集合上限 300）' }),
    /** 查询被解析出的场景/活动标签，界面可显示「已识别：海边 / 沙滩」 */
    tags: Type.Array(Type.String()),
    /** 没识别出来的片段，界面提示「未识别：xxx」 */
    unmatched: Type.Array(Type.String()),
    /** 语义词表不可用时为 true（已降级为 OCR / 路径文字搜） */
    degraded: Type.Boolean(),
    reason: Type.String(),
  },
  { $id: 'PhotoHybridSearchResponse' },
);

export const StatsResponse = Type.Object(
  {
    libraries: Type.Integer(),
    items: Type.Integer(),
    earliest: Type.Union([Type.Integer(), Type.Null()]),
    latest: Type.Union([Type.Integer(), Type.Null()]),
    /** 按年计数（降序），用于时间轴右侧年份刻度 */
    byYear: Type.Array(
      Type.Object({ year: Type.Integer(), count: Type.Integer() }),
    ),
    /** 视频数（当前扫描只收图片，通常为 0，保留字段供首页统计） */
    videos: Type.Integer(),
    /** 媒体文件占用字节数 */
    bytes: Type.Integer(),
    /** 今天新索引的张数（按 created_at 当天统计） */
    todayNew: Type.Integer(),
    /** 有照片的拍摄天数（按 taken_at 本地日期去重） */
    activeDays: Type.Integer(),
    /** 近 365 天每日张数（升序），用于热力图 */
    byDay: Type.Array(Type.Object({ date: Type.String(), count: Type.Integer() })),
  },
  { $id: 'PhotoStatsResponse' },
);

/** 首页看板：我的照片（总数 / 今日新增 / 占用空间 / 视频） */
export const HomeLibraryStat = Type.Object(
  {
    photos: Type.Integer(),
    videos: Type.Integer(),
    todayNew: Type.Integer(),
    bytes: Type.Integer(),
  },
  { $id: 'PhotoHomeLibraryStat' },
);

/** 首页看板：拍摄时光（总量 / 活跃天数 / 按年 / 近一年每日 / 最忙月份） */
export const HomeHeat = Type.Object(
  {
    total: Type.Integer(),
    activeDays: Type.Integer(),
    byYear: Type.Array(Type.Object({ year: Type.Integer(), count: Type.Integer() })),
    byDay: Type.Array(Type.Object({ date: Type.String(), count: Type.Integer() })),
    peakMonth: Type.Union(
      [
        Type.Object({ year: Type.Integer(), month: Type.Integer(), count: Type.Integer() }),
        Type.Null(),
      ],
    ),
  },
  { $id: 'PhotoHomeHeat' },
);

export const HomeFootprint = Type.Object(
  {
    cities: Type.Integer(),
    places: Type.Integer(),
    days: Type.Integer(),
  },
  { $id: 'PhotoHomeFootprint' },
);

export const HomePerson = Type.Object(
  {
    id: Type.String(),
    name: Type.Union([Type.String(), Type.Null()]),
    size: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoHomePerson' },
);

export const HomePeople = Type.Object(
  {
    items: Type.Array(Type.Ref(HomePerson)),
    pending: Type.Integer({ description: '未命名人脸簇数量' }),
  },
  { $id: 'PhotoHomePeople' },
);

export const HomeOnThisDay = Type.Object(
  {
    date: Type.String(),
    year: Type.Integer(),
    photoCount: Type.Integer(),
    items: Type.Array(Type.Ref(Item)),
  },
  { $id: 'PhotoHomeOnThisDay' },
);

export const HomeSummaryResponse = Type.Object(
  {
    library: Type.Ref(HomeLibraryStat),
    heat: Type.Ref(HomeHeat),
    footprint: Type.Ref(HomeFootprint),
    people: Type.Ref(HomePeople),
    onThisDay: Type.Array(Type.Ref(HomeOnThisDay)),
  },
  { $id: 'PhotoHomeSummary' },
);

/** AI 设置：人脸聚类参数 */
export const AiTuning = Type.Object(
  {
    matchSim: Type.Number(),
    minVotes: Type.Integer(),
    threads: Type.Integer(),
  },
  { $id: 'PhotoAiTuning' },
);

export const AiConfig = Type.Object(
  {
    faceEnabled: Type.Boolean(),
    placeEnabled: Type.Boolean(),
    activityEnabled: Type.Boolean(),
    ocrEnabled: Type.Boolean(),
    similarEnabled: Type.Boolean(),
    faceMinShowCount: Type.Integer(),
    gpuPrefer: Type.Boolean(),
    paused: Type.Boolean(),
    tuning: Type.Ref(AiTuning),
  },
  { $id: 'PhotoAiConfig' },
);

export const AiProgress = Type.Object(
  {
    face: Type.Integer(),
    place: Type.Integer(),
    activity: Type.Integer(),
    ocr: Type.Integer(),
    clip: Type.Integer(),
    similarScan: Type.Integer(),
    similarCompare: Type.Integer(),
  },
  { $id: 'PhotoAiProgress' },
);

export const AiQueueJob = Type.Object(
  {
    key: Type.String(),
    label: Type.String(),
    status: Type.String({ description: 'running / idle / disabled' }),
    pending: Type.Integer(),
    percent: Type.Integer(),
  },
  { $id: 'PhotoAiQueueJob' },
);

export const AiQueue = Type.Object(
  {
    paused: Type.Boolean(),
    jobs: Type.Array(Type.Ref(AiQueueJob)),
  },
  { $id: 'PhotoAiQueue' },
);

export const AiSettingsResponse = Type.Object(
  {
    config: Type.Ref(AiConfig),
    progress: Type.Ref(AiProgress),
    queue: Type.Ref(AiQueue),
  },
  { $id: 'PhotoAiSettings' },
);

export const AiConfigBody = Type.Object(
  {
    faceEnabled: Type.Optional(Type.Boolean()),
    placeEnabled: Type.Optional(Type.Boolean()),
    activityEnabled: Type.Optional(Type.Boolean()),
    ocrEnabled: Type.Optional(Type.Boolean()),
    similarEnabled: Type.Optional(Type.Boolean()),
    faceMinShowCount: Type.Optional(Type.Integer({ minimum: 0, maximum: 1000 })),
    gpuPrefer: Type.Optional(Type.Boolean()),
    paused: Type.Optional(Type.Boolean()),
    matchSim: Type.Optional(Type.Number({ minimum: 0.3, maximum: 0.75 })),
    minVotes: Type.Optional(Type.Integer({ minimum: 1, maximum: 8 })),
    threads: Type.Optional(Type.Integer({ minimum: 1, maximum: 8 })),
  },
  { $id: 'PhotoAiConfigBody' },
);

export const AiTuningBody = Type.Object(
  {
    matchSim: Type.Number({ minimum: 0.3, maximum: 0.75 }),
    minVotes: Type.Integer({ minimum: 1, maximum: 8 }),
    threads: Type.Integer({ minimum: 1, maximum: 8 }),
  },
  { $id: 'PhotoAiTuningBody' },
);

export const AiTuningResponse = Type.Object(
  {
    ok: Type.Boolean(),
    restarted: Type.Boolean(),
  },
  { $id: 'PhotoAiTuningResponse' },
);

export const AiQueuePauseBody = Type.Object(
  { paused: Type.Boolean() },
  { $id: 'PhotoAiQueuePauseBody' },
);

export const AiOpResponse = Type.Object(
  {
    ok: Type.Boolean(),
    count: Type.Integer(),
    message: Type.Optional(Type.String()),
  },
  { $id: 'PhotoAiOpResponse' },
);

export const AiResetBody = Type.Object(
  {
    kind: Type.Union([
      Type.Literal('ocr'),
      Type.Literal('place'),
      Type.Literal('activity'),
      Type.Literal('similar'),
    ]),
  },
  { $id: 'PhotoAiResetBody' },
);

export const McpStatusResponse = Type.Object(
  {
    enabled: Type.Boolean(),
    tokenMasked: Type.String(),
    uid: Type.String(),
    tools: Type.Array(Type.String()),
    baseUrl: Type.String(),
  },
  { $id: 'PhotoMcpStatus' },
);

export const McpConfigBody = Type.Object(
  {
    enabled: Type.Optional(Type.Boolean()),
    uid: Type.Optional(Type.String()),
  },
  { $id: 'PhotoMcpConfigBody' },
);

export const McpTokenResponse = Type.Object(
  { token: Type.String() },
  { $id: 'PhotoMcpTokenResponse' },
);

/** 记忆（人生章节 / 每日发现） */
export const MemoryItem = Type.Object(
  {
    date: Type.String(),
    photoCount: Type.Integer(),
    coverPath: Type.String(),
    place: Type.String(),
    scenes: Type.Array(Type.String()),
    activities: Type.Array(Type.String()),
    people: Type.Array(Type.String()),
    note: Type.String(),
    status: Type.String({ description: 'candidate / saved / ignored' }),
    updatedAt: Type.Integer(),
  },
  { $id: 'PhotoMemoryItem' },
);

export const MemoryChapter = Type.Object(
  {
    year: Type.Integer(),
    coverPath: Type.String(),
    photoCount: Type.Integer(),
    start: Type.String(),
    end: Type.String(),
  },
  { $id: 'PhotoMemoryChapter' },
);

export const MemoryListResponse = Type.Object(
  {
    candidates: Type.Array(Type.Ref(MemoryItem)),
    memories: Type.Array(Type.Ref(MemoryItem)),
    ignored: Type.Array(Type.Ref(MemoryItem)),
    chapters: Type.Array(Type.Ref(MemoryChapter)),
  },
  { $id: 'PhotoMemoryList' },
);

export const MemoryQuery = Type.Object(
  {
    days: Type.Optional(Type.Integer({ minimum: 1, maximum: 3650 })),
    minPhotos: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
  },
  { $id: 'PhotoMemoryQuery' },
);

export const MemorySaveBody = Type.Object(
  {
    date: Type.String({ minLength: 8, maxLength: 10 }),
    note: Type.Optional(Type.String({ maxLength: 500 })),
  },
  { $id: 'PhotoMemorySaveBody' },
);

export const MemoryTargetBody = Type.Object(
  { date: Type.String({ minLength: 8, maxLength: 10 }) },
  { $id: 'PhotoMemoryTargetBody' },
);

/** 感知哈希扫描 / 比对进度 */
export const PhashStatusResponse = Type.Object(
  {
    running: Type.Boolean(),
    phase: Type.String({ description: 'idle / scan / compare / done' }),
    done: Type.Integer(),
    total: Type.Integer(),
    percent: Type.Integer(),
    groups: Type.Integer(),
    failed: Type.Integer(),
    threshold: Type.Integer({ description: '汉明距离阈值（默认 6）' }),
  },
  { $id: 'PhotoPhashStatus' },
);

export const PhashScanResponse = Type.Object(
  { started: Type.Boolean() },
  { $id: 'PhotoPhashScanResponse' },
);

/** GPS 参考照片（已带经纬度的近期照片） */
export const GeoReferenceItem = Type.Object(
  {
    id: Type.String(),
    path: Type.String(),
    takenAt: Type.Integer(),
    latitude: Type.Number(),
    longitude: Type.Number(),
    place: Type.String(),
  },
  { $id: 'PhotoGeoReference' },
);

export const GeoReferenceList = Type.Object(
  { items: Type.Array(Type.Ref(GeoReferenceItem)) },
  { $id: 'PhotoGeoReferenceList' },
);

/** GPS 视觉候选 */
export const GeoVisionCandidate = Type.Object(
  {
    id: Type.String(),
    photoId: Type.String(),
    path: Type.String(),
    anchorId: Type.String(),
    anchorPath: Type.String(),
    latitude: Type.Number(),
    longitude: Type.Number(),
    similarity: Type.Number(),
    status: Type.String(),
  },
  { $id: 'PhotoGeoVisionCandidate' },
);

export const GeoVisionList = Type.Object(
  {
    items: Type.Array(Type.Ref(GeoVisionCandidate)),
    total: Type.Integer(),
  },
  { $id: 'PhotoGeoVisionList' },
);

export const GeoVisionStatus = Type.Object(
  {
    running: Type.Boolean(),
    done: Type.Integer(),
    total: Type.Integer(),
    generated: Type.Integer(),
  },
  { $id: 'PhotoGeoVisionStatus' },
);

export const GeoVisionApplyBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    latitude: Type.Optional(Type.Number()),
    longitude: Type.Optional(Type.Number()),
  },
  { $id: 'PhotoGeoVisionApplyBody' },
);

export const GeoVisionRejectBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoGeoVisionRejectBody' },
);

export const Album = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    items: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()]),
    createdAt: Type.Integer(),
    description: Type.Union([Type.String(), Type.Null()], {
      description: '相册简介（一句话），未填为 null',
    }),
    coverItemId: Type.Union([Type.String(), Type.Null()], {
      description: '用户手选的封面照片 id；null 表示回落到最早的成员',
    }),
    sortOrder: Type.Integer({ description: '手排顺序，小的在前；同值按创建时间倒序' }),
  },
  { $id: 'PhotoAlbum' },
);

export const AlbumListResponse = Type.Object(
  { items: Type.Array(Type.Ref(Album)) },
  { $id: 'PhotoAlbumListResponse' },
);

export const AlbumCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    itemIds: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { maxItems: 500 })),
  },
  { $id: 'PhotoAlbumCreateBody' },
);

export const AlbumMembersBody = Type.Object(
  {
    albumId: Type.String({ minLength: 1 }),
    itemIds: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
  },
  { $id: 'PhotoAlbumMembersBody' },
);

export const AlbumItemsQuery = Type.Object(
  {
    albumId: Type.String({ minLength: 1 }),
    cursor: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoAlbumItemsQuery' },
);

export const AlbumDeleteBody = Type.Object(
  { albumId: Type.String({ minLength: 1 }) },
  { $id: 'PhotoAlbumDeleteBody' },
);

/** 相册元数据编辑（改名 / 简介 / 封面 / 手排顺序），只传要改的字段 */
export const AlbumUpdateBody = Type.Object(
  {
    albumId: Type.String({ minLength: 1 }),
    name: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
    description: Type.Optional(
      Type.Union([Type.String({ maxLength: 500 }), Type.Null()], {
        description: '传 null 清空简介',
      }),
    ),
    coverItemId: Type.Optional(
      Type.Union([Type.String({ minLength: 1 }), Type.Null()], {
        description: '传 null 回落成最早的成员',
      }),
    ),
    sortOrder: Type.Optional(Type.Integer({ minimum: 0, maximum: 99999 })),
  },
  { $id: 'PhotoAlbumUpdateBody' },
);

/** 年视图：某年 12 个月的张数与封面（年 → 月下钻用，替代"全年拉一遍再分组"） */
export const CalendarQuery = Type.Object(
  {
    year: Type.Optional(
      Type.Integer({ minimum: 1970, maximum: 2200, description: '缺省为当前年' }),
    ),
  },
  { $id: 'PhotoCalendarQuery' },
);

export const CalendarMonth = Type.Object(
  {
    month: Type.Integer({ minimum: 1, maximum: 12 }),
    count: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoCalendarMonth' },
);

export const CalendarResponse = Type.Object(
  {
    year: Type.Integer(),
    total: Type.Integer(),
    months: Type.Array(Type.Ref(CalendarMonth)),
  },
  { $id: 'PhotoCalendarResponse' },
);

export const PhotoDeleteBody = Type.Object(
  {
    ids: Type.Array(Type.String(), { minItems: 1, maxItems: 500 }),
    toTrash: Type.Optional(
      Type.Boolean({
        description: 'true = 放入回收站（保留 30 天）；false = 永久删除索引与派生数据',
        default: false,
      }),
    ),
  },
  { $id: 'PhotoDeleteBody' },
);

export const PhotoDeleteResponse = Type.Object(
  {
    count: Type.Integer(),
    trashed: Type.Boolean(),
    batchId: Type.Optional(
      Type.Union([Type.String(), Type.Null()], {
        description: '放入回收站时的删除批次 id（整批还原用）；永久删除为 null',
      }),
    ),
  },
  { $id: 'PhotoDeleteResponse' },
);
export const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'PhotoOkResponse' });

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'PhotoErrorResponse' },
);


/** 集合：把照片聚成一组（按用户隔离） */
export const Collection = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    items: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()]),
    createdAt: Type.Integer(),
  },
  { $id: 'PhotoCollection' },
);

export const CollectionListResponse = Type.Object(
  { items: Type.Array(Type.Ref(Collection)) },
  { $id: 'PhotoCollectionListResponse' },
);

export const CollectionCreateBody = Type.Object(
  { name: Type.String({ minLength: 1, maxLength: 64 }) },
  { $id: 'PhotoCollectionCreateBody' },
);

export const CollectionDeleteBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoCollectionDeleteBody' },
);

export const CollectionMembersBody = Type.Object(
  {
    collectionId: Type.String({ minLength: 1 }),
    itemIds: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
  },
  { $id: 'PhotoCollectionMembersBody' },
);

export const CollectionItemsQuery = Type.Object(
  {
    collectionId: Type.String({ minLength: 1 }),
    cursor: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoCollectionItemsQuery' },
);

/** GPS 补全：给没有经纬度的照片手动打点 */
export const GeoMissingQuery = Type.Object(
  {
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
    cursor: Type.Optional(Type.String()),
  },
  { $id: 'PhotoGeoMissingQuery' },
);

export const GeoSetBody = Type.Object(
  {
    ids: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    latitude: Type.Number({ minimum: -90, maximum: 90 }),
    longitude: Type.Number({ minimum: -180, maximum: 180 }),
  },
  { $id: 'PhotoGeoSetBody' },
);

export const GeoSetResponse = Type.Object(
  { updated: Type.Integer() },
  { $id: 'PhotoGeoSetResponse' },
);


/** 文件视图：按目录聚合照片 */
export const FolderQuery = Type.Object(
  { path: Type.Optional(Type.String({ description: '相对 files 根的目录，空为根' })) },
  { $id: 'PhotoFolderQuery' },
);

export const FolderItem = Type.Object(
  {
    name: Type.String(),
    path: Type.String(),
    items: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoFolderItem' },
);

export const FolderListResponse = Type.Object(
  {
    path: Type.String(),
    files: Type.Integer({ description: '当前目录直接文件数（不含子目录）' }),
    fileItems: Type.Array(Type.Ref(Item), { description: '当前目录直接照片（最多 200）' }),
    dirs: Type.Array(Type.Ref(FolderItem)),
  },
  { $id: 'PhotoFolderList' },
);

/** 文件视图根：当前用户的相册来源目录 */
export const FolderRootItem = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    path: Type.String(),
    items: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'PhotoFolderRoot' },
);

export const FolderRootsResponse = Type.Object(
  { items: Type.Array(Type.Ref(FolderRootItem)) },
  { $id: 'PhotoFolderRoots' },
);

/** 模型目录（只读浏览） */
export const ModelItem = Type.Object(
  {
    name: Type.String(),
    size: Type.Integer(),
    modified: Type.Integer(),
  },
  { $id: 'PhotoModelItem' },
);

export const ModelListResponse = Type.Object(
  {
    dir: Type.String(),
    exists: Type.Boolean(),
    items: Type.Array(Type.Ref(ModelItem)),
  },
  { $id: 'PhotoModelList' },
);


/** 本机目录浏览（选择来源目录用） */
export const FsRootsResponse = Type.Object(
  { items: Type.Array(Type.String()) },
  { $id: 'PhotoFsRoots' },
);

export const FsListQuery = Type.Object(
  { path: Type.Optional(Type.String({ description: '绝对路径，空表示列出盘符/根' })) },
  { $id: 'PhotoFsListQuery' },
);

export const FsDirItem = Type.Object(
  { name: Type.String(), path: Type.String() },
  { $id: 'PhotoFsDirItem' },
);

export const FsListResponse = Type.Object(
  {
    path: Type.String(),
    parent: Type.Union([Type.String(), Type.Null()]),
    dirs: Type.Array(Type.Ref(FsDirItem)),
  },
  { $id: 'PhotoFsList' },
);

/** 相册扫描策略（库级配置） */
export const PhotoScanPolicySchema = Type.Object(
  {
    autoWatch: Type.Boolean({ description: '自动监视新文件（本地 fs.watch / 远程轮询）' }),
    verifyHours: Type.Integer({
      minimum: 0,
      maximum: 168,
      description: '周期全量校验间隔（小时；0 = 关闭）',
    }),
    skipHidden: Type.Boolean({ description: '跳过隐藏文件与系统目录（. 开头 / @eaDir 等）' }),
  },
  { $id: 'PhotoScanPolicy' },
);

export const PhotoScanPolicyUpdateBody = Type.Object(
  {
    autoWatch: Type.Optional(Type.Boolean()),
    verifyHours: Type.Optional(Type.Integer({ minimum: 0, maximum: 168 })),
    skipHidden: Type.Optional(Type.Boolean()),
  },
  { $id: 'PhotoScanPolicyUpdateBody' },
);

/** 智能相册规则：用户自定义条件组合（场景 / 人物 / 地点 / 时间 / 收藏） */
export const SmartRulePlace = Type.Object(
  {
    latitude: Type.Number({ minimum: -90, maximum: 90 }),
    longitude: Type.Number({ minimum: -180, maximum: 180 }),
    radiusKm: Type.Optional(
      Type.Number({ minimum: 0.1, maximum: 500, description: '半径（公里），缺省 10' }),
    ),
  },
  { $id: 'PhotoSmartRulePlace' },
);

export const SmartRuleConditions = Type.Object(
  {
    scene: Type.Optional(Type.String({ maxLength: 64, description: '场景标签（photo_scenes.label）' })),
    activity: Type.Optional(Type.String({ maxLength: 64, description: '活动标签（photo_activities.label）' })),
    faceClusterId: Type.Optional(Type.String({ maxLength: 64, description: '人脸簇 id' })),
    place: Type.Optional(Type.Ref(SmartRulePlace)),
    from: Type.Optional(Type.Integer({ minimum: 0, description: '拍摄时间下界（Unix 秒）' })),
    to: Type.Optional(Type.Integer({ minimum: 0, description: '拍摄时间上界（Unix 秒）' })),
    favorite: Type.Optional(Type.Boolean()),
  },
  { $id: 'PhotoSmartRuleConditions' },
);

export const SmartRule = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    conditions: Type.Ref(SmartRuleConditions),
    items: Type.Integer({ description: '当前命中张数' }),
    coverPath: Type.Union([Type.String(), Type.Null()]),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'PhotoSmartRule' },
);

/**
 * 时间轴交叉筛选：直接用智能规则的同一套条件，但不落库。
 *
 * 为什么不新写一套筛选 SQL：条件判据（场景要查 photo_scenes、活动有阈值门、
 * 地点是经纬度光边框）一旦有第二份实现，两边结果迟早不一样。
 */
export const FilterBody = Type.Object(
  {
    conditions: Type.Ref(SmartRuleConditions),
    /** 关键词：匹配文件名与 OCR 文本（照片没有标题字段） */
    q: Type.Optional(Type.String({ maxLength: 100 })),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
    order: Type.Optional(
      Type.Union([Type.Literal('asc'), Type.Literal('desc')], { default: 'desc' }),
    ),
  },
  { $id: 'PhotoFilterBody' },
);

export const FilterResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(Item)),
    nextCursor: Type.Union([Type.String(), Type.Null()]),
    total: Type.Optional(
      Type.Integer({ description: '命中的总张数（只在第一页返回，翻页时省略以免重复全量计数）' }),
    ),
  },
  { $id: 'PhotoFilterResponse' },
);

export const SmartRuleListResponse = Type.Object(
  { items: Type.Array(Type.Ref(SmartRule)) },
  { $id: 'PhotoSmartRuleListResponse' },
);

export const SmartRuleCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    conditions: Type.Ref(SmartRuleConditions),
  },
  { $id: 'PhotoSmartRuleCreateBody' },
);

export const SmartRuleUpdateBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
    conditions: Type.Optional(Type.Ref(SmartRuleConditions)),
  },
  { $id: 'PhotoSmartRuleUpdateBody' },
);

export const SmartRuleDeleteBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'PhotoSmartRuleDeleteBody' },
);

export const SmartRuleItemsQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    cursor: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'PhotoSmartRuleItemsQuery' },
);

export const OnThisDayQuery = Type.Object(
  {
    month: Type.Optional(Type.Integer({ minimum: 1, maximum: 12 })),
    day: Type.Optional(Type.Integer({ minimum: 1, maximum: 31 })),
    perYear: Type.Optional(
      Type.Integer({ minimum: 1, maximum: 200, default: 60 }),
    ),
  },
  { $id: 'PhotoOnThisDayQuery' },
);

export const OnThisDayYear = Type.Object(
  {
    year: Type.Integer(),
    date: Type.String(),
    photoCount: Type.Integer(),
    items: Type.Array(Type.Ref(Item)),
  },
  { $id: 'PhotoOnThisDayYear' },
);

export const OnThisDayResponse = Type.Object(
  { years: Type.Array(Type.Ref(OnThisDayYear)) },
  { $id: 'PhotoOnThisDayResponse' },
);
/** 异步扫描入队结果（进度查 /api/v1/tasks/{id}） */
export const ScanTask = Type.Object(
  {
    taskId: Type.String({ description: '任务 id' }),
    reused: Type.Boolean({ description: 'true = 已有同类任务在排队或运行，复用了它' }),
  },
  { $id: 'PhotoScanTask' },
);

export const PHOTO_SCHEMAS = [
  OnThisDayQuery,
  OnThisDayYear,
  OnThisDayResponse,
  PhotoDeleteBody,
  PhotoDeleteResponse,
  CalendarQuery,
  CalendarMonth,
  CalendarResponse,
  PhotoScanPolicySchema,
  PhotoScanPolicyUpdateBody,
  SmartRulePlace,
  SmartRuleConditions,
  SmartRule,
  SmartRuleListResponse,
  SmartRuleCreateBody,
  SmartRuleUpdateBody,
  SmartRuleDeleteBody,
  SmartRuleItemsQuery,
  FilterBody,
  FilterResponse,
  LibraryItem,
  LibraryListResponse,
  LibraryCreateBody,
  LibraryRemoveBody,
  LibraryUpdateBody,
  ScanBody,
  ScanResponse,
  Item,
  TimelineQuery,
  TimelineResponse,
  FavoriteBody,
  FavoriteResponse,
  ItemQuery,
  SearchQuery,
  HybridSearchQuery,
  HybridSearchResponse,
  StatsResponse,
  Album,
  AlbumListResponse,
  AlbumCreateBody,
  AlbumMembersBody,
  AlbumItemsQuery,
  AlbumDeleteBody,
  AlbumUpdateBody,
  Collection,
  CollectionListResponse,
  CollectionCreateBody,
  CollectionDeleteBody,
  CollectionMembersBody,
  CollectionItemsQuery,
  GeoMissingQuery,
  GeoSetBody,
  GeoSetResponse,
  FolderQuery,
  FolderItem,
  FolderListResponse,
  FolderRootItem,
  FolderRootsResponse,
  PhashStatusResponse,
  PhashScanResponse,
  GeoReferenceItem,
  GeoReferenceList,
  GeoVisionCandidate,
  GeoVisionList,
  GeoVisionStatus,
  GeoVisionApplyBody,
  GeoVisionRejectBody,
  ModelItem,
  ModelListResponse,
  FsRootsResponse,
  FsListQuery,
  FsDirItem,
  FsListResponse,
  OkResponse,
  ErrorResponse,
  HomeLibraryStat,
  HomeHeat,
  HomeFootprint,
  HomePerson,
  HomePeople,
  HomeOnThisDay,
  HomeSummaryResponse,
  AiTuning,
  AiConfig,
  AiProgress,
  AiQueueJob,
  AiQueue,
  AiSettingsResponse,
  AiConfigBody,
  AiTuningBody,
  AiTuningResponse,
  AiQueuePauseBody,
  AiOpResponse,
  AiResetBody,
  McpStatusResponse,
  McpConfigBody,
  McpTokenResponse,
  MemoryItem,
  MemoryChapter,
  MemoryListResponse,
  MemoryQuery,
  MemorySaveBody,
  MemoryTargetBody,
  ScanTask,
];
