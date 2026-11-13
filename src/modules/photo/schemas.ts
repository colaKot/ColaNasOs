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
    items: Type.Integer({ description: '已索引媒体数（图片 + 视频）' }),
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
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 60000, description: '本次最多扫描的文件数（默认 60000）' })),
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
    images: Type.Integer({ description: '本批扫描到的媒体数（图片 + 视频）' }),
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
    // 用 String 而不是 Literal 联合：契约生成器会把字面量联合映射成 Dart `dynamic`，
    // 客户端还得做类型判断；这里保持和 mime 一样的宽松口径。
    mediaKind: Type.String({ description: "媒体类型：image 静态图 / video 视频" }),
    durationMs: Type.Union([Type.Integer(), Type.Null()], {
      description: '视频时长（毫秒）；图片为 null',
    }),
    liveKind: Type.String({
      description: "动态照片：'' 不是 / motion 尾部 mp4 / apple 配对 MOV",
    }),
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
    petEnabled: Type.Boolean(),
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
    /** 该模块自己的真实产出数（人脸数 / 标签数 / 向量条数…），用来区分同批产出的几项 */
    detail: Type.String(),
    status: Type.String({ description: 'running / idle / disabled' }),
    /** 剩余条数（= total - done），保留给旧客户端 */
    pending: Type.Integer(),
    /** 已完成条数：面板显示「已完成/总数」 */
    done: Type.Integer(),
    /** 该模块的总条数（照片库总量） */
    total: Type.Integer(),
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
    petEnabled: Type.Optional(Type.Boolean()),
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
    // 三个数组都按 limit 截断过，tab 上要显示的是**截断前的真实总数**。
    // 可选字段：别的复用该 schema 的 handler 不用跟着补（否则 fast-json-stringify 会 500）。
    totalCandidates: Type.Optional(Type.Integer()),
    totalMemories: Type.Optional(Type.Integer()),
    totalIgnored: Type.Optional(Type.Integer()),
  },
  { $id: 'PhotoMemoryList' },
);

export const MemoryQuery = Type.Object(
  {
    days: Type.Optional(Type.Integer({ minimum: 1, maximum: 3650 })),
    minPhotos: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
    // 记忆列表真分页：三个数组各自按 offset/limit 切片，total* 仍是截断前总数
    offset: Type.Optional(Type.Integer({ minimum: 0 })),
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

/**
 * 规则相册的一条命中条件。多条之间是 **OR**：命中任意一条就归入。
 *
 *   · `kind=face`     → `value` 是人脸聚类 id（`photo_face_clusters.id`）
 *   · `kind=scene`    → `value` 是场景标签（`photo_scenes.label`，如 海滩 / 夜景）
 *   · `kind=activity` → `value` 是活动标签（`photo_activities.label`，如 游泳 / 聚餐）
 *   · `kind=date`     → `from` / `to` 是拍摄时间区间（秒，含端点；单边可省）
 */
export const AlbumRule = Type.Object(
  {
    kind: Type.Union([
      Type.Literal('face'),
      Type.Literal('scene'),
      Type.Literal('activity'),
      Type.Literal('date'),
    ]),
    value: Type.Optional(
      Type.String({
        maxLength: 128,
        description: 'face = 聚类 id；scene / activity = 标签',
      }),
    ),
    from: Type.Optional(Type.Integer({ description: 'date 规则起始（秒，含）' })),
    to: Type.Optional(Type.Integer({ description: 'date 规则结束（秒，含）' })),
  },
  { $id: 'PhotoAlbumRule' },
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
    rules: Type.Array(Type.Ref('PhotoAlbumRule'), {
      description: '规则相册的命中条件（OR 关系）；空数组 = 纯手工相册',
    }),
    ruleCount: Type.Integer({ description: '规则数量（客户端不解析 rules 时用它显示角标）' }),
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
    coverItemId: Type.Optional(
      Type.Union([Type.String({ minLength: 1 }), Type.Null()], {
        description: '建相册时手选的封面，可以不给（回落到最早成员）',
      }),
    ),
    rules: Type.Optional(Type.Array(Type.Ref('PhotoAlbumRule'), { maxItems: 20 })),
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
    rules: Type.Optional(Type.Array(Type.Ref('PhotoAlbumRule'), { maxItems: 20 })),
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

/** 年视图卡片封面：每年一张「有人像」的代表图（优先常出现的 3 个人） */
export const YearCover = Type.Object(
  {
    year: Type.Integer({ minimum: 1970, maximum: 2200 }),
    count: Type.Integer(),
    coverPath: Type.Union([Type.String(), Type.Null()], {
      description: '该年代表图的相对路径；没有任何照片时为 null',
    }),
  },
  { $id: 'PhotoYearCover' },
);

export const YearCoversResponse = Type.Object(
  { years: Type.Array(Type.Ref(YearCover)) },
  { $id: 'PhotoYearCoversResponse' },
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

/** 时光对照：一侧照片里识别到的人脸（最多返回前三张，按面积 × 清晰度排序） */
export const TimeContrastFace = Type.Object(
  {
    id: Type.String({ description: '人脸 id，头像拼 /photo/face/image?id=' }),
    clusterId: Type.Union([Type.String(), Type.Null()]),
    name: Type.Union([Type.String(), Type.Null()]),
    score: Type.Number(),
    quality: Type.Union([Type.Number(), Type.Null()]),
    area: Type.Number({ description: '人脸框占整图面积比（0..1），用于解释排序' }),
  },
  { $id: 'PhotoTimeContrastFace' },
);

export const TimeContrastSide = Type.Object(
  {
    year: Type.Integer(),
    item: Type.Ref(Item),
    faces: Type.Array(Type.Ref(TimeContrastFace), { description: '最多 3 张，面积 × 清晰度倒序' }),
    faceCount: Type.Integer({ description: '这张照片识别到的人脸总数' }),
  },
  { $id: 'PhotoTimeContrastSide' },
);

export const TimeContrastPerson = Type.Object(
  {
    id: Type.String({ description: '人脸聚类 id' }),
    name: Type.Union([Type.String(), Type.Null()], { description: '用户命名；未命名时为空' }),
  },
  { $id: 'PhotoTimeContrastPerson' },
);

export const TimeContrastAlbum = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
  },
  { $id: 'PhotoTimeContrastAlbum' },
);

export const TimeContrastResponse = Type.Object(
  {
    month: Type.Integer(),
    day: Type.Integer(),
    // 用 String 而不是 Literal 联合：契约生成器会把字面量联合映射成 Dart `dynamic`
    mode: Type.String({ description: "person = 锁定同一人物；fallback = 降级配对" }),
    person: Type.Union([Type.Ref(TimeContrastPerson), Type.Null()]),
    album: Type.Union([Type.Ref(TimeContrastAlbum), Type.Null()]),
    reason: Type.String({
      description: 'person / same_album / similar / time_span，界面据此解释配对依据',
    }),
    similarity: Type.Union([Type.Number(), Type.Null()], {
      description: '降级配对时的感知哈希相似度（0..1），无指纹时为空',
    }),
    gapYears: Type.Integer(),
    left: Type.Union([Type.Ref(TimeContrastSide), Type.Null()]),
    right: Type.Union([Type.Ref(TimeContrastSide), Type.Null()]),
  },
  { $id: 'PhotoTimeContrastResponse' },
);
/** 异步扫描入队结果（进度查 /api/v1/tasks/{id}） */
export const ScanTask = Type.Object(
  {
    taskId: Type.String({ description: '任务 id' }),
    reused: Type.Boolean({ description: 'true = 已有同类任务在排队或运行，复用了它' }),
  },
  { $id: 'PhotoScanTask' },
);

/**
 * 成长轨迹（Growth Track）。
 *
 * 设计文档的 Asset → Event → Stage → Track 四层里，接口只暴露 Stage 与 Track：
 * Event 是分段过程里的隐式 burst，Track 是某个人名下 Stage 的有序序列。
 * 文案一律由前端按 i18n 拼装（服务端只给结构化数据：地点、时间、枚举），
 * UI 不硬编码文案；title/subtitle 两列是给后续 VLM 阶段文案预留的缓存位。
 */

/** 顶部人脸条的一项；coverFaceId 直接拼 /photo/face/image 得到圆形头像 */
export const GrowthPerson = Type.Object(
  {
    id: Type.String({ description: 'photo_face_clusters.id' }),
    name: Type.Union([Type.String(), Type.Null()]),
    size: Type.Integer({ description: '该人脸簇的照片数' }),
    coverFaceId: Type.Union([Type.String(), Type.Null()]),
    stageCount: Type.Integer({ description: '已生成的阶段数' }),
    lastAt: Type.Integer({ description: '最近一张照片的拍摄时间（epoch 秒）' }),
  },
  { $id: 'PhotoGrowthPerson' },
);

export const GrowthPersonQuery = Type.Object(
  { limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 })) },
  { $id: 'PhotoGrowthPersonQuery' },
);

export const GrowthPersonList = Type.Object(
  { items: Type.Array(Type.Ref(GrowthPerson)) },
  { $id: 'PhotoGrowthPersonList' },
);

/** 顶部一句话看板：从 X 记录到 Y · 走过 N 个地方 · M 个阶段 */
export const GrowthSummary = Type.Object(
  {
    personId: Type.String(),
    personName: Type.Union([Type.String(), Type.Null()]),
    stageCount: Type.Integer(),
    cityCount: Type.Integer(),
    photoCount: Type.Integer(),
    firstAt: Type.Integer(),
    lastAt: Type.Integer(),
    granularity: Type.String(),
    rebuilt: Type.Boolean({ description: '本次请求是否触发了重算' }),
  },
  { $id: 'PhotoGrowthSummary' },
);

/** UI 上的一条记录 = 一个阶段 = 一张图（次图为可选） */
export const GrowthStage = Type.Object(
  {
    id: Type.String(),
    seq: Type.Integer(),
    startAt: Type.Integer(),
    endAt: Type.Integer(),
    placeKey: Type.String({ description: '地点归并键（城市/网格/未知）' }),
    placeName: Type.String({ description: '离线逆地理得到的中文地名，无 GPS 时为空' }),
    spanKind: Type.String({ description: '实际采用的时间粒度：month/quarter/year/auto' }),
    coverAssetId: Type.Union([Type.String(), Type.Null()]),
    coverPath: Type.String({ description: '封面相对路径，客户端拼 files/thumb' }),
    secondaryPath: Type.Union([Type.String(), Type.Null()], {
      description: '同阶段次图（去重后第二高分），没有则 null',
    }),
    // 原始宽高：前端按真实比例自适应高度，避免固定高度把竖图裁成横条
    coverWidth: Type.Union([Type.Integer(), Type.Null()]),
    coverHeight: Type.Union([Type.Integer(), Type.Null()]),
    secondaryWidth: Type.Union([Type.Integer(), Type.Null()]),
    secondaryHeight: Type.Union([Type.Integer(), Type.Null()]),
    photoCount: Type.Integer(),
    coverScore: Type.Number(),
    milestone: Type.String({ description: '里程碑枚举：firstPlace / firstScene / anniversary / 空' }),
    hint: Type.String({ description: '降级提示枚举：noScenePortrait / 空' }),
    locked: Type.Boolean({ description: '封面是否由人工指定（重算不再覆盖）' }),
    hidden: Type.Boolean(),
    version: Type.Integer(),
  },
  { $id: 'PhotoGrowthStage' },
);

export const GrowthItemsQuery = Type.Object(
  {
    person: Type.String({ minLength: 1 }),
    /** asc / desc，缺省 desc；不写 default，避免 ajv 填值影响兼容别名 */
    order: Type.Optional(Type.String()),
    /** auto / month / quarter / year，缺省 auto */
    granularity: Type.Optional(Type.String()),
    cursor: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
  },
  { $id: 'PhotoGrowthItemsQuery' },
);

export const GrowthStageList = Type.Object(
  {
    items: Type.Array(Type.Ref(GrowthStage)),
    nextCursor: Type.Union([Type.String(), Type.Null()]),
    summary: Type.Ref(GrowthSummary),
  },
  { $id: 'PhotoGrowthStageList' },
);

export const GrowthStagePhotosQuery = Type.Object(
  {
    stageId: Type.String({ minLength: 1 }),
    cursor: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
  },
  { $id: 'PhotoGrowthStagePhotosQuery' },
);

/** 二级页：阶段全量照片（真分页）+ 阶段摘要 */
export const GrowthStagePhotos = Type.Object(
  {
    items: Type.Array(Type.Ref(Item)),
    nextCursor: Type.Union([Type.String(), Type.Null()]),
    total: Type.Integer(),
    stage: Type.Ref(GrowthStage),
  },
  { $id: 'PhotoGrowthStagePhotos' },
);

/** 长按封面 → 「换一张」的三个候选 */
export const GrowthCandidate = Type.Object(
  {
    assetId: Type.String(),
    path: Type.String(),
    score: Type.Number(),
    reason: Type.String({ description: '可解释的选中原因（调试/展示用）' }),
  },
  { $id: 'PhotoGrowthCandidate' },
);

export const GrowthCandidatesQuery = Type.Object(
  { stageId: Type.String({ minLength: 1 }) },
  { $id: 'PhotoGrowthCandidatesQuery' },
);

export const GrowthCandidateList = Type.Object(
  { items: Type.Array(Type.Ref(GrowthCandidate)) },
  { $id: 'PhotoGrowthCandidateList' },
);

export const GrowthRepinBody = Type.Object(
  {
    stageId: Type.String({ minLength: 1 }),
    assetId: Type.String({ minLength: 1 }),
  },
  { $id: 'PhotoGrowthRepinBody' },
);

export const GrowthRepinResponse = Type.Object(
  { stage: Type.Ref(GrowthStage) },
  { $id: 'PhotoGrowthRepinResponse' },
);

/** 手动重建（新增照片、改粒度、AI 补识别之后） */
export const GrowthRebuildBody = Type.Object(
  {
    person: Type.String({ minLength: 1 }),
    granularity: Type.Optional(Type.String()),
  },
  { $id: 'PhotoGrowthRebuildBody' },
);

export const GrowthRebuildResponse = Type.Object(
  {
    stages: Type.Integer(),
    photos: Type.Integer(),
    version: Type.Integer(),
  },
  { $id: 'PhotoGrowthRebuildResponse' },
);

export const PHOTO_SCHEMAS = [
  OnThisDayQuery,
  OnThisDayYear,
  OnThisDayResponse,
  TimeContrastFace,
  TimeContrastSide,
  TimeContrastPerson,
  TimeContrastAlbum,
  TimeContrastResponse,
  PhotoDeleteBody,
  PhotoDeleteResponse,
  CalendarQuery,
  CalendarMonth,
  CalendarResponse,
  YearCover,
  YearCoversResponse,
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
  AlbumRule,
  Album,
  AlbumListResponse,
  AlbumCreateBody,
  AlbumMembersBody,
  AlbumItemsQuery,
  AlbumDeleteBody,
  AlbumUpdateBody,
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
  GrowthPerson,
  GrowthPersonQuery,
  GrowthPersonList,
  GrowthSummary,
  GrowthStage,
  GrowthItemsQuery,
  GrowthStageList,
  GrowthStagePhotosQuery,
  GrowthStagePhotos,
  GrowthCandidate,
  GrowthCandidatesQuery,
  GrowthCandidateList,
  GrowthRepinBody,
  GrowthRepinResponse,
  GrowthRebuildBody,
  GrowthRebuildResponse,
];
