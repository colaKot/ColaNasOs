import { Type } from '@sinclair/typebox';

/**
 * video 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 */
const NullableInteger = Type.Union([Type.Integer(), Type.Null()]);
const NullableString = Type.Union([Type.String(), Type.Null()]);

/**
 * 影视库的一个来源（一个库可以有多个）。
 *
 * 旧模型是「库 = 一个目录」，用户把同一类片子放在几个盘上就只能建几个同名库。
 * 现在来源独立成行，`path` 是来源根（本地绝对/相对路径，或 SMB 的 UNC）。
 */
export const SourceItem = Type.Object(
  {
    id: Type.String(),
    connType: Type.String({ description: 'local / smb' }),
    path: Type.String({ description: '来源根：本地路径或 UNC' }),
    host: Type.Optional(NullableString),
    share: Type.Optional(NullableString),
    subPath: Type.Optional(NullableString),
    username: Type.Optional(NullableString),
    onlineState: Type.Optional(Type.Integer({ description: '0 未知 / 1 在线 / 2 离线' })),
    onlineCheckedAt: Type.Optional(NullableInteger),
    items: Type.Optional(Type.Integer({ description: '该来源已索引条目数' })),
    lastScanAt: Type.Optional(NullableInteger),
  },
  { $id: 'VideoSourceItem' },
);

/** 提交来源用（密码只在创建/修改时传，服务端从不回传） */
export const SourceInput = Type.Object(
  {
    connType: Type.Optional(
      Type.Union([Type.Literal('local'), Type.Literal('smb')], { default: 'local' }),
    ),
    path: Type.Optional(Type.String({ maxLength: 1024, description: '本地目录（local）' })),
    host: Type.Optional(Type.String({ maxLength: 128 })),
    share: Type.Optional(Type.String({ maxLength: 128 })),
    subPath: Type.Optional(Type.String({ maxLength: 512 })),
    username: Type.Optional(Type.String({ maxLength: 128 })),
    password: Type.Optional(Type.String({ maxLength: 256, description: '留空表示不改密码' })),
  },
  { $id: 'VideoSourceInput' },
);

export const LibraryItem = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    path: Type.String({ description: '相对 files 根的 POSIX 路径' }),
    items: Type.Integer({ description: '已索引条目数（视频 + 图片）' }),
    createdAt: Type.Integer(),
    lastScanAt: NullableInteger,
    libType: Type.String({ description: 'movie / jp_movie / tv / image / mixed' }),
    connType: Type.Optional(Type.String({ description: 'local / smb' })),
    /** 0 未知 / 1 在线 / 2 离线（离线源不返回内容，也不阻塞列表） */
    onlineState: Type.Optional(Type.Integer()),
    /** 上次探测在线性的时间（epoch 秒）；null = 从未探测过。此前只写不读，界面上看不到 */
    onlineCheckedAt: Type.Optional(NullableInteger),
    /** 库级设置：此前这些列只有读没有写，客户端也看不到 */
    showInHome: Type.Optional(Type.Integer({ description: '1 = 首页出现该库' })),
    sortOrder: Type.Optional(Type.Integer({ description: '左栏排序，小的在前' })),
    audioNormalize: Type.Optional(Type.Integer({ description: '1 = 播放时响度归一' })),
    scrapeEnabled: Type.Optional(Type.Integer({ description: '1 = 允许刮削（含手动）' })),
    autoScrape: Type.Optional(
      Type.Integer({ description: '1 = 扫描入库后自动排队刮削（默认关）' }),
    ),
    autoSubtitle: Type.Optional(
      Type.Integer({ description: '1 = 扫描后自动补字幕（日本片走番号，普通影视走多源）' }),
    ),
    /** 该库的全部来源（顺序即展示顺序；第一项同时写回 `path`） */
    sources: Type.Optional(Type.Array(Type.Ref(SourceItem))),
  },
  { $id: 'VideoLibraryItem' },
);

/** 库级开关（不动来源路径，所以单独一个轻量接口） */
export const LibraryFlagsBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    showInHome: Type.Optional(Type.Boolean()),
    sortOrder: Type.Optional(Type.Integer({ minimum: 0, maximum: 99999 })),
    audioNormalize: Type.Optional(Type.Boolean()),
    scrapeEnabled: Type.Optional(Type.Boolean()),
    autoScrape: Type.Optional(Type.Boolean()),
    autoSubtitle: Type.Optional(Type.Boolean()),
  },
  { $id: 'VideoLibraryFlagsBody' },
);

export const LibraryListResponse = Type.Object(
  { items: Type.Array(Type.Ref(LibraryItem)) },
  { $id: 'VideoLibraryListResponse' },
);

export const LibraryCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    /** 本地库必填：相对 files 根的目录 */
    path: Type.Optional(Type.String({ minLength: 1, description: '相对 files 根的目录（local）' })),
    connType: Type.Optional(
      Type.Union([Type.Literal('local'), Type.Literal('smb')], { default: 'local' }),
    ),
    host: Type.Optional(Type.String({ maxLength: 128, description: 'SMB 主机名 / IP' })),
    share: Type.Optional(Type.String({ maxLength: 128, description: 'SMB 共享名' })),
    subPath: Type.Optional(Type.String({ maxLength: 512, description: '共享下的子路径' })),
    username: Type.Optional(Type.String({ maxLength: 128 })),
    password: Type.Optional(Type.String({ maxLength: 256, description: 'AES-256-GCM 密文落库' })),
    libType: Type.Optional(
      Type.String({
        description: 'movie / jp_movie / tv / image / mixed（创建后不可改）',
        default: 'movie',
      }),
    ),
    /** 多来源：给了就以它为准（legacy 的 path/host/share 只在没给 sources 时生效） */
    sources: Type.Optional(Type.Array(Type.Ref(SourceInput), { minItems: 1, maxItems: 32 })),
  },
  { $id: 'VideoLibraryCreateBody' },
);

export const LibraryUpdateBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    name: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
    /** movie / jp_movie / tv / image / mixed */
    libType: Type.Optional(Type.String({ maxLength: 16 })),
    connType: Type.Optional(Type.Union([Type.Literal('local'), Type.Literal('smb')])),
    /** 本地库：相对 files 根的目录 */
    path: Type.Optional(Type.String({ minLength: 1, description: '相对 files 根的目录（local）' })),
    host: Type.Optional(Type.String({ maxLength: 128, description: 'SMB 主机名 / IP' })),
    share: Type.Optional(Type.String({ maxLength: 128, description: 'SMB 共享名' })),
    subPath: Type.Optional(Type.String({ maxLength: 512, description: '共享下的子路径' })),
    username: Type.Optional(Type.String({ maxLength: 128 })),
    password: Type.Optional(Type.String({ maxLength: 256, description: '留空表示不改密码' })),
    /** 多来源：给了就整体替换（按来源根对齐复用旧行，密码留空表示沿用） */
    sources: Type.Optional(Type.Array(Type.Ref(SourceInput), { minItems: 1, maxItems: 32 })),
  },
  { $id: 'VideoLibraryUpdateBody' },
);

export const SourceProbeBody = Type.Object(
  {
    id: Type.Optional(Type.String({ description: '影视库 id（SMB 来源）' })),
    sourceId: Type.Optional(Type.String({ description: '只探测某个来源；缺省探测库的第一个 SMB 来源' })),
    host: Type.Optional(Type.String({ maxLength: 128, description: '直接探测某个主机' })),
  },
  { $id: 'VideoSourceProbeBody' },
);

export const SourceProbeResponse = Type.Object(
  {
    id: NullableString,
    sourceId: Type.Optional(NullableString),
    host: Type.String(),
    onlineState: Type.Integer({ description: '0 未知 / 1 在线 / 2 离线' }),
    checkedAt: Type.Integer(),
  },
  { $id: 'VideoSourceProbeResponse' },
);

export const LibraryRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'VideoLibraryRemoveBody' },
);

export const ScanBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String({ description: '缺省扫描全部库' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200000 })),
    prune: Type.Optional(
      Type.Boolean({ description: '清理磁盘上已不存在的条目（仅整库扫描生效，默认开启）' }),
    ),
  },
  { $id: 'VideoScanBody' },
);

export const ScanResponse = Type.Object(
  {
    libraries: Type.Integer(),
    videos: Type.Integer(),
    images: Type.Integer(),
    added: Type.Integer(),
    updated: Type.Integer(),
    skipped: Type.Integer(),
    probed: Type.Integer({ description: 'ffmpeg 探测成功的条数' }),
    missing: Type.Optional(Type.Integer({ description: '索引有、磁盘已不存在（整库扫描）' })),
    pruned: Type.Optional(Type.Integer({ description: '本次实际清理的行数' })),
    nfoFilled: Type.Optional(
      Type.Integer({ description: '文件没变、只补读了本地 NFO / 海报的条数' }),
    ),
    errors: Type.Optional(
      Type.Array(Type.String(), {
        description: '扫不动的来源及原因（目录不存在 / 越界 / 离线）；空表示全部正常',
      }),
    ),
  },
  { $id: 'VideoScanResponse' },
);

export const Item = Type.Object(
  {
    id: Type.String(),
    libraryId: Type.String(),
    mediaType: Type.String({ description: 'video / image' }),
    path: Type.String({ description: '相对 files 根，可直接播放 / 下载' }),
    title: Type.String({ description: '展示用片名：刮削名优先，回退文件名' }),
    fileTitle: Type.String({ description: '文件名派生的标题（未刮削时的原始名）' }),
    durationMs: NullableInteger,
    width: NullableInteger,
    height: NullableInteger,
    videoCodec: NullableString,
    audioCodec: NullableString,
    container: Type.String(),
    hasSubtitle: Type.Boolean(),
    size: Type.Integer(),
    series: NullableString,
    season: NullableInteger,
    episode: NullableInteger,
    takenAt: NullableInteger,
    code: NullableString,
    uncensored: Type.Boolean({ description: '日本库角标：无码 / 流出' }),
    chineseSub: Type.Boolean({ description: '日本库角标：中文字幕' }),
    rankDaily: Type.Optional(
      Type.Union([Type.Integer(), Type.Null()], {
        description: '最近一期日榜名次（来自落库快照）；null = 不在榜或没有快照',
      }),
    ),
    rankWeekly: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
    rankMonthly: Type.Optional(Type.Union([Type.Integer(), Type.Null()])),
    favorite: Type.Boolean({ description: '是否收藏' }),
    is4k: Type.Boolean({ description: '分辨率 ≥ 3840×2160' }),
    hdr10: Type.Boolean({ description: 'HDR10（smpte2084 / 母带元数据）' }),
    hdr10plus: Type.Boolean({ description: 'HDR10+' }),
    hlg: Type.Boolean({ description: 'HLG' }),
    dolbyVision: Type.Boolean({ description: '杜比视界' }),
    dolbyAtmos: Type.Boolean({ description: '杜比全景声' }),
    // —— 媒体信息（迁移 080_video_nfo）；未刮削时全为 null / 空数组
    originalName: NullableString,
    year: NullableInteger,
    score: Type.Union([Type.Number(), Type.Null()], { description: '评分（0-10）' }),
    overview: NullableString,
    runtimeMin: NullableInteger,
    releaseDate: NullableString,
    studio: NullableString,
    genres: Type.Array(Type.String(), { description: '类型（中文优先，取自 NFO / TMDB）' }),
    regions: Type.Array(Type.String(), { description: '地区 / 国家' }),
    actors: Type.Array(Type.String(), { description: '演员名（按 NFO 顺序，最多 15）' }),
    directors: Type.Array(Type.String()),
    hasArt: Type.Boolean({ description: '是否已有刮削海报；false 时客户端回退首帧' }),
    imdbId: NullableString,
    doubanId: NullableString,
    tmdbId: NullableInteger,
    nfoSource: Type.Union(
      [
        Type.Literal('nfo'),
        Type.Literal('tmdb'),
        Type.Literal('javdb'),
        Type.Literal('javbus'),
        Type.Literal('avsox'),
        Type.Literal('manual'),
        Type.Literal('none'),
        Type.Null(),
      ],
      { description: '元数据来源' },
    ),
    watched: Type.Boolean({ description: '当前用户已观看' }),
  },
  { $id: 'VideoItem' },
);

export const ListQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    q: Type.Optional(Type.String({ maxLength: 200, description: '标题 / 路径 / 番号关键词' })),
    mediaType: Type.Optional(
      Type.String({ description: 'video / image；缺省按库类型自动决定（混合库两者都出）' }),
    ),
    series: Type.Optional(
      Type.String({
        maxLength: 200,
        description: '剧名精确过滤；传 `none` 只看影片（不属于任何剧集）',
      }),
    ),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
    /** 排序字段：name / createTime / viewTime / year / score / takenTime / duration */
    sortBy: Type.Optional(Type.String({ maxLength: 20, description: '缺省 name' })),
    /** asc / desc（缺省按字段给一个合理默认：名字升序、时间降序） */
    sortOrder: Type.Optional(Type.String({ maxLength: 8 })),
    /** 年份多选，逗号分隔；`0` 表示「未刮削 / 无年份」 */
    years: Type.Optional(Type.String({ maxLength: 400 })),
    /** 类型多选（genre 名称，逗号分隔，按 JSON 数组包含匹配） */
    genres: Type.Optional(Type.String({ maxLength: 600 })),
    /** 地区多选（同上） */
    regions: Type.Optional(Type.String({ maxLength: 600 })),
    /** 演员精确匹配（点人物墙跳过来时用） */
    actor: Type.Optional(Type.String({ maxLength: 200 })),
    /** 导演精确匹配 */
    director: Type.Optional(Type.String({ maxLength: 200 })),
    /** 只看已看 / 未看 */
    watched: Type.Optional(Type.String({ maxLength: 8, description: 'true / false' })),
    /** 只看已刮削 / 未刮削 */
    scraped: Type.Optional(Type.String({ maxLength: 8 })),
    /** 只看某种画质：4k / hdr / atmos */
    flag: Type.Optional(Type.String({ maxLength: 16 })),
    /** 图片 / 混合库文件夹视图：当前目录（带来源根的完整 rel_path 前缀） */
    folderPath: Type.Optional(Type.String({ maxLength: 1024 })),
    /** exact = 只看本目录；subtree = 看整棵子树（搜索用）；缺省 = 整库平铺 */
    folderMode: Type.Optional(Type.String({ maxLength: 16 })),
    /** 首字母筛选（# / A-Z），图片库用 */
    letter: Type.Optional(Type.String({ maxLength: 2 })),
  },
  { $id: 'VideoListQuery' },
);

export const ListCountQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    series: Type.Optional(Type.String({ maxLength: 200 })),
    mediaType: Type.Optional(Type.String()),
    q: Type.Optional(Type.String({ maxLength: 200 })),
    folderPath: Type.Optional(Type.String({ maxLength: 1024 })),
    folderMode: Type.Optional(Type.String({ maxLength: 16 })),
    letter: Type.Optional(Type.String({ maxLength: 2 })),
  },
  { $id: 'VideoListCountQuery' },
);

export const ImageFolderQuery = Type.Object(
  {
    libraryId: Type.String({ minLength: 1 }),
    folderPath: Type.Optional(Type.String({ maxLength: 1024 })),
  },
  { $id: 'VideoImageFolderQuery' },
);

export const ImageFolderNode = Type.Object(
  {
    name: Type.String(),
    path: Type.String({ description: '带来源根的完整 rel_path' }),
    count: Type.Integer(),
    imageCount: Type.Integer(),
    videoCount: Type.Integer(),
    /** 该目录第一张图 / 第一个视频，用于文件夹封面；空目录为 null */
    cover: Type.Union([Type.Ref(Item), Type.Null()]),
  },
  { $id: 'VideoImageFolderNode' },
);

export const ImageFolderPathSegment = Type.Object(
  { name: Type.String(), path: Type.String() },
  { $id: 'VideoImageFolderSegment' },
);

export const ImageFolderResponse = Type.Object(
  {
    path: Type.String(),
    parentPath: NullableString,
    segments: Type.Array(Type.Ref(ImageFolderPathSegment)),
    folders: Type.Array(Type.Ref(ImageFolderNode)),
    selfCount: Type.Integer(),
    selfImageCount: Type.Integer(),
    selfVideoCount: Type.Integer(),
    hasSubFolders: Type.Boolean(),
  },
  { $id: 'VideoImageFolderResponse' },
);

export const ImageFolderDeleteBody = Type.Object(
  {
    libraryId: Type.String(),
    path: Type.String({ minLength: 1 }),
  },
  { $id: 'VideoImageFolderDeleteBody' },
);

export const ImageFolderDeleteResponse = Type.Object(
  {
    removed: Type.Integer(),
    trashedTo: Type.String(),
  },
  { $id: 'VideoImageFolderDeleteResponse' },
);

export const ListCountResponse = Type.Object(
  { total: Type.Integer(), scraped: Type.Integer() },
  { $id: 'VideoListCountResponse' },
);

export const StatsQuery = Type.Object(
  { libraryId: Type.Optional(Type.String({ description: '缺省为全部库合计' })) },
  { $id: 'VideoStatsQuery' },
);

export const ListResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(Item)),
    nextCursor: NullableString,
  },
  { $id: 'VideoListResponse' },
);

export const IdQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（仅外部播放器使用，见 /video/stream-url）' }),
    ),
  },
  { $id: 'VideoIdQuery' },
);

export const StreamUrlResponse = Type.Object(
  {
    url: Type.String({ description: '带短期令牌的播放地址，可直接交给外部播放器' }),
    expiresInSec: Type.Integer(),
  },
  { $id: 'VideoStreamUrlResponse' },
);

export const StatsResponse = Type.Object(
  {
    libraries: Type.Integer(),
    items: Type.Integer(),
    durationMs: Type.Integer({ description: '已索引影片总时长' }),
  },
  { $id: 'VideoStatsResponse' },
);

/** 剧集：剧名 + 季数 / 集数 + 封面用的首集 id */
export const SeriesItem = Type.Object(
  {
    name: Type.String({ description: '剧名（库根下第一层目录名）' }),
    seasons: Type.Integer({ description: '不同季号的数量（无季号算 1 季）' }),
    episodes: Type.Integer({ description: '该剧已索引的文件数' }),
    coverId: NullableString,
  },
  { $id: 'VideoSeriesItem' },
);

export const SeriesListQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    q: Type.Optional(Type.String({ maxLength: 200, description: '剧名关键词' })),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'VideoSeriesListQuery' },
);

export const SeriesListResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(SeriesItem)),
    nextCursor: NullableString,
  },
  { $id: 'VideoSeriesListResponse' },
);

export const SeriesItemsQuery = Type.Object(
  {
    name: Type.String({ minLength: 1, description: '剧名（来自 /video/series）' }),
    libraryId: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 2000, default: 500 })),
  },
  { $id: 'VideoSeriesItemsQuery' },
);

/** 整季缺集（只含真有缺口的季） */
export const SeasonGap = Type.Object(
  {
    season: Type.Integer({ description: '季号' }),
    episodes: Type.Array(Type.Integer(), { description: '该季缺的集号（升序）' }),
  },
  { $id: 'VideoSeasonGap' },
);

/** 剧集级收藏（每用户）：按 series + 库记录，避免同名剧跨库冲突 */
export const SeriesFavoriteBody = Type.Object(
  {
    series: Type.String({ minLength: 1, maxLength: 300 }),
    libraryId: Type.Optional(Type.String()),
    favorite: Type.Boolean(),
  },
  { $id: 'VideoSeriesFavoriteBody' },
);

export const SeriesFavoriteResponse = Type.Object(
  { favorite: Type.Boolean() },
  { $id: 'VideoSeriesFavoriteResponse' },
);

export const SeriesFavoriteItem = Type.Object(
  {
    series: Type.String(),
    libraryId: Type.String(),
    seasons: Type.Integer({ description: '已索引季数（distinct season）' }),
    episodes: Type.Integer({ description: '已索引集数' }),
    coverId: Type.Optional(Type.String({ description: '封面取该剧任一已索引 item id' })),
    createdAt: Type.Integer(),
  },
  { $id: 'VideoSeriesFavoriteItem' },
);

export const SeriesFavoriteListResponse = Type.Object(
  { items: Type.Array(Type.Ref(SeriesFavoriteItem)) },
  { $id: 'VideoSeriesFavoriteListResponse' },
);

export const SeriesItemsResponse = Type.Object(
  {
    name: Type.String(),
    items: Type.Array(Type.Ref(Item)),
    missing: Type.Array(Type.Ref(SeasonGap), {
      description: '整季缺集：按季列出中间缺的集号，只返回真有缺口的季',
    }),
  },
  { $id: 'VideoSeriesItemsResponse' },
);

export const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'VideoOkResponse' });

/** 观看进度：按用户隔离 */
export const ProgressBody = Type.Object(
  {
    id: Type.String({ minLength: 1, description: '影片 / 剧集条目 id' }),
    position: Type.Optional(
      Type.String({ maxLength: 200, description: '播放位置（如 `120s`），缺省为空' }),
    ),
    percent: Type.Integer({ minimum: 0, maximum: 100 }),
  },
  { $id: 'VideoProgressBody' },
);

export const Progress = Type.Object(
  {
    itemId: Type.String(),
    position: Type.String(),
    percent: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'VideoProgress' },
);

export const ProgressQuery = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'VideoProgressQuery' },
);

export const ProgressListQuery = Type.Object(
  {
    series: Type.Optional(Type.String({ maxLength: 200, description: '只看某部剧的集' })),
    libraryId: Type.Optional(Type.String()),
    state: Type.Optional(
      Type.Union(
        [Type.Literal('all'), Type.Literal('finished'), Type.Literal('unfinished')],
        { default: 'all', description: 'finished = 进度 ≥ 95%' },
      ),
    ),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 100 })),
  },
  { $id: 'VideoProgressListQuery' },
);

/** 清空观看历史（默认清全部，可只清"已看完"的） */
export const ProgressClearBody = Type.Object(
  {
    onlyFinished: Type.Optional(Type.Boolean({ description: '只清进度 ≥ 95% 的记录' })),
    series: Type.Optional(Type.String({ maxLength: 200, description: '只清某部剧' })),
  },
  { $id: 'VideoProgressClearBody' },
);

export const ProgressClearResponse = Type.Object(
  { cleared: Type.Integer() },
  { $id: 'VideoProgressClearResponse' },
);

export const ProgressItem = Type.Object(
  {
    itemId: Type.String(),
    title: Type.String(),
    series: NullableString,
    season: NullableInteger,
    episode: NullableInteger,
    position: Type.String(),
    percent: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'VideoProgressItem' },
);

export const ProgressListResponse = Type.Object(
  { items: Type.Array(Type.Ref(ProgressItem)) },
  { $id: 'VideoProgressListResponse' },
);

/** 外挂字幕：与影片同目录、同主名的 .srt / .ass / .ssa / .vtt */
export const SubtitleFile = Type.Object(
  {
    name: Type.String({ description: '同目录下的文件名，取内容时按它索引' }),
    lang: NullableString,
    format: Type.String({ description: 'srt / ass / ssa / vtt' }),
    size: Type.Integer(),
  },
  { $id: 'VideoSubtitleFile' },
);

export const SubtitleListResponse = Type.Object(
  { items: Type.Array(Type.Ref(SubtitleFile)) },
  { $id: 'VideoSubtitleListResponse' },
);

export const SubtitleQuery = Type.Object(
  {
    id: Type.String({ minLength: 1, description: '影片 id' }),
    name: Type.String({ minLength: 1, description: '字幕文件名（取自 /video/subtitles）' }),
  },
  { $id: 'VideoSubtitleQuery' },
);

export const SubtitleCue = Type.Object(
  {
    startMs: Type.Integer(),
    endMs: Type.Integer(),
    text: Type.String(),
  },
  { $id: 'VideoSubtitleCue' },
);

export const SubtitleResponse = Type.Object(
  {
    name: Type.String(),
    lang: NullableString,
    format: Type.String(),
    cues: Type.Array(Type.Ref(SubtitleCue)),
    vtt: Type.String({ description: '转换后的 WebVTT 文本，播放器可直接加载' }),
  },
  { $id: 'VideoSubtitleResponse' },
);

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'VideoErrorResponse' },
);


/** 批量收藏 / 取消收藏 */
export const FavoriteBody = Type.Object(
  {
    ids: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    favorite: Type.Boolean(),
  },
  { $id: 'VideoFavoriteBody' },
);

export const FavoriteResponse = Type.Object(
  { updated: Type.Integer() },
  { $id: 'VideoFavoriteResponse' },
);

/** 自定义合集（每用户） */
export const Collection = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    kind: Type.String({ description: 'custom（智能合集后续按规则生成）' }),
    items: Type.Integer(),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
    description: Type.Optional(Type.Union([Type.String(), Type.Null()], {
      description: '一句话简介',
    })),
    coverItemId: Type.Optional(Type.Union([Type.String(), Type.Null()], {
      description: '手选封面（须是合集成员）；null 回落到最早加入的条目',
    })),
    coverPath: Type.Optional(Type.Union([Type.String(), Type.Null()])),
    sortOrder: Type.Optional(Type.Integer({ description: '手排顺序，小的在前' })),
  },
  { $id: 'VideoCollection' },
);

export const CollectionListResponse = Type.Object(
  { items: Type.Array(Type.Ref(Collection)) },
  { $id: 'VideoCollectionListResponse' },
);

export const CollectionUpsertBody = Type.Object(
  {
    id: Type.Optional(Type.String({ maxLength: 64 })),
    name: Type.String({ minLength: 1, maxLength: 64 }),
    kind: Type.Optional(Type.String({ maxLength: 16, default: 'custom' })),
    description: Type.Optional(
      Type.Union([Type.String({ maxLength: 500 }), Type.Null()], {
        description: '传 null 清空简介；不传则不改',
      }),
    ),
    coverItemId: Type.Optional(
      Type.Union([Type.String({ minLength: 1 }), Type.Null()], {
        description: '传 null 回落成最早加入的条目',
      }),
    ),
    sortOrder: Type.Optional(Type.Integer({ minimum: 0, maximum: 99999 })),
  },
  { $id: 'VideoCollectionUpsertBody' },
);

export const CollectionIdBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'VideoCollectionIdBody' },
);

export const CollectionItemsBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    itemIds: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    action: Type.Union([Type.Literal('add'), Type.Literal('remove')], { default: 'add' }),
  },
  { $id: 'VideoCollectionItemsBody' },
);

export const CollectionItemsResponse = Type.Object(
  { id: Type.String(), name: Type.String(), items: Type.Array(Type.Ref(Item)) },
  { $id: 'VideoCollectionItemsResponse' },
);

/** 媒体浏览：按库目录逐级浏览（文件夹 + 图片 + 视频） */
export const BrowseQuery = Type.Object(
  {
    libraryId: Type.String({ minLength: 1 }),
    path: Type.Optional(Type.String({ maxLength: 1024, description: '库内相对目录，缺省为库根' })),
  },
  { $id: 'VideoBrowseQuery' },
);

export const BrowseItem = Type.Object(
  {
    name: Type.String(),
    path: Type.String({ description: '相对库根的 POSIX 路径' }),
    dir: Type.Boolean(),
    mediaType: Type.String({ description: 'video / image / other / dir' }),
    id: Type.Union([Type.String(), Type.Null()], {
      description: '视频条目 id（可打开详情 / 海报）；图片与文件夹为 null',
    }),
    size: Type.Union([Type.Integer(), Type.Null()]),
    mtime: Type.Union([Type.Integer(), Type.Null()]),
  },
  { $id: 'VideoBrowseItem' },
);

export const BrowseResponse = Type.Object(
  {
    libraryId: Type.String(),
    path: Type.String(),
    rootPath: Type.String({ description: '库根（本地相对 files 根 / SMB 为 UNC）' }),
    items: Type.Array(Type.Ref(BrowseItem)),
  },
  { $id: 'VideoBrowseResponse' },
);

// ---------------------------------------------------------------- 刮削

export const ScrapeBody = Type.Object(
  {
    id: Type.String({ minLength: 1, description: '影片 / 条目 id' }),
    /** auto = 只补空位；force = 覆盖已有元数据（手动重新刮削） */
    mode: Type.Optional(
      Type.Union([Type.Literal('auto'), Type.Literal('force')], { default: 'auto' }),
    ),
    /** 手动匹配时指定 TMDB 条目 */
    mediaType: Type.Optional(Type.Union([Type.Literal('movie'), Type.Literal('tv')])),
    tmdbId: Type.Optional(Type.Integer({ minimum: 1 })),
    /** 是否把结果写到片源目录的 .nfo（缺省读设置） */
    writeSidecar: Type.Optional(Type.Boolean()),
  },
  { $id: 'VideoScrapeBody' },
);

export const ScrapeResponse = Type.Object(
  {
    status: Type.Union([
      Type.Literal('scraped'),
      Type.Literal('skipped'),
      Type.Literal('notfound'),
      Type.Literal('unavailable'),
      Type.Literal('failed'),
    ]),
    itemId: Type.String(),
    source: Type.Optional(Type.String()),
    title: Type.Optional(Type.String()),
    fields: Type.Optional(Type.Integer({ description: '本次写入了多少个非空字段' })),
    nfoWritten: Type.Optional(Type.Boolean()),
    sidecar: Type.Optional(
      Type.Union(
        [
          Type.Literal('written'),
          Type.Literal('exists'),
          Type.Literal('kept-user'),
          Type.Literal('error'),
        ],
        { description: 'kept-user = 磁盘上的 nfo 比我们上次写入更新（用户手改过），主动不覆盖' },
      ),
    ),
    reason: Type.Optional(Type.String()),
  },
  { $id: 'VideoScrapeResponse' },
);

export const ScrapeBatchBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String({ description: '缺省全部库' })),
    ids: Type.Optional(
      Type.Array(Type.String({ minLength: 1 }), { maxItems: 500, description: '指定条目' }),
    ),
    /** un scraped = 只刮还没元数据的（默认）；all = 全部重刮 */
    scope: Type.Optional(
      Type.Union([Type.Literal('missing'), Type.Literal('all')], { default: 'missing' }),
    ),
    mode: Type.Optional(
      Type.Union([Type.Literal('auto'), Type.Literal('force')], { default: 'auto' }),
    ),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 5000, default: 200 })),
  },
  { $id: 'VideoScrapeBatchBody' },
);

export const ScrapeBatchResponse = Type.Object(
  {
    queued: Type.Integer(),
    taskId: Type.Optional(Type.String()),
    scanned: Type.Integer(),
    scraped: Type.Integer(),
    skipped: Type.Integer(),
    notfound: Type.Integer(),
    unavailable: Type.Integer(),
  },
  { $id: 'VideoScrapeBatchResponse' },
);

export const ScrapeCleanupBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'VideoScrapeCleanupBody' },
);

export const ScrapeCleanupResponse = Type.Object(
  { cleared: Type.Boolean() },
  { $id: 'VideoScrapeCleanupResponse' },
);

export const MatchNfoBody = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    match: Type.Boolean({ description: 'false = 不再参与自动刮削' }),
  },
  { $id: 'VideoMatchNfoBody' },
);

export const TmdbSearchBody = Type.Object(
  {
    q: Type.String({ minLength: 1, maxLength: 200 }),
    mediaType: Type.Optional(
      Type.Union([Type.Literal('movie'), Type.Literal('tv')], { default: 'movie' }),
    ),
    year: Type.Optional(Type.Integer({ minimum: 1800, maximum: 2200 })),
  },
  { $id: 'VideoTmdbSearchBody' },
);

export const TmdbCandidate = Type.Object(
  {
    tmdbId: Type.Integer(),
    mediaType: Type.String({ description: 'movie / tv' }),
    title: Type.String(),
    originalTitle: Type.String(),
    year: NullableInteger,
    score: Type.Union([Type.Number(), Type.Null()]),
    overview: Type.String(),
    posterPath: NullableString,
  },
  { $id: 'VideoTmdbCandidate' },
);

export const TmdbSearchResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(TmdbCandidate)),
    configured: Type.Boolean({ description: 'false 时 items 恒为空，界面应提示先配 Key' }),
  },
  { $id: 'VideoTmdbSearchResponse' },
);

export const TmdbSettings = Type.Object(
  {
    apiKey: Type.String({ description: '留空表示沿用「发现页」的 Key' }),
    language: Type.String({ description: 'TMDB 语言，如 zh-CN' }),
    writeSidecar: Type.Boolean({ description: '刮削结果是否写到片源同目录 .nfo' }),
    minScore: Type.Number({ description: '自动匹配的最低置信度，低于此值只给候选不写库' }),
    configured: Type.Boolean({ description: '只读：是否已有可用 Key' }),
  },
  { $id: 'VideoTmdbSettings' },
);

export const TmdbSettingsBody = Type.Object(
  {
    apiKey: Type.Optional(Type.String({ maxLength: 200 })),
    language: Type.Optional(Type.String({ maxLength: 16 })),
    writeSidecar: Type.Optional(Type.Boolean()),
    minScore: Type.Optional(Type.Number({ minimum: 0, maximum: 20 })),
  },
  { $id: 'VideoTmdbSettingsBody' },
);

export const ArtQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    kind: Type.Optional(
      Type.Union([Type.Literal('poster'), Type.Literal('fanart')], { default: 'poster' }),
    ),
  },
  { $id: 'VideoArtQuery' },
);

// ---------------------------------------------------------------- 已观看

export const WatchBody = Type.Object(
  {
    ids: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
    watched: Type.Boolean(),
    /** 电视剧：把整部剧的所有集一起标（服务端展开） */
    expandSeries: Type.Optional(Type.Boolean({ default: false })),
  },
  { $id: 'VideoWatchBody' },
);

export const WatchResponse = Type.Object(
  { updated: Type.Integer(), items: Type.Integer() },
  { $id: 'VideoWatchResponse' },
);

// ---------------------------------------------------------------- 首页

export const HomeQuery = Type.Object(
  {
    recommendLimit: Type.Optional(Type.Integer({ minimum: 1, maximum: 30, default: 11 })),
    recentPlayLimit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50, default: 20 })),
    recentAddLimit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50, default: 20 })),
  },
  { $id: 'VideoHomeQuery' },
);

export const HomeSource = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    libType: Type.String(),
    items: Type.Integer(),
    onlineState: Type.Integer(),
    /** 该库最近添加条目的封面 id（无内容时为 null） */
    coverId: NullableString,
    /** 图片库 / 混合库的图片封面（带来源根的 rel_path），客户端走 /files/thumb */
    coverPath: Type.Optional(NullableString),
    coverKind: Type.Optional(Type.String({ description: 'video / image' })),
  },
  { $id: 'VideoHomeSource' },
);

export const HomeLibraryRow = Type.Object(
  {
    libraryId: Type.String(),
    libraryName: Type.String(),
    libType: Type.Optional(Type.String()),
    items: Type.Array(Type.Ref(Item)),
  },
  { $id: 'VideoHomeLibraryRow' },
);

export const HomeResponse = Type.Object(
  {
    sources: Type.Array(Type.Ref(HomeSource)),
    recommend: Type.Array(Type.Ref(Item)),
    recentPlay: Type.Array(Type.Ref(Item), { description: '继续观看（带 progress 语义，见 progress 字段）' }),
    recentAdd: Type.Array(Type.Ref(HomeLibraryRow)),
    progress: Type.Array(Type.Ref(Progress), { description: '与 recentPlay 对应的进度' }),
  },
  { $id: 'VideoHomeResponse' },
);

// ---------------------------------------------------------------- 排重（多钥匙）

export const DuplicatesQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 100 })),
  },
  { $id: 'VideoDuplicatesQuery' },
);

export const DuplicateItem = Type.Object(
  {
    id: Type.String(),
    title: Type.String(),
    path: Type.String(),
    size: Type.Integer(),
    durationMs: Type.Union([Type.Integer(), Type.Null()]),
    width: Type.Union([Type.Integer(), Type.Null()]),
    height: Type.Union([Type.Integer(), Type.Null()]),
    videoCodec: Type.Union([Type.String(), Type.Null()]),
    code: Type.Union([Type.String(), Type.Null()]),
    year: NullableInteger,
    score: Type.Union([Type.Number(), Type.Null()]),
    hasArt: Type.Boolean(),
    imdbId: NullableString,
    doubanId: NullableString,
    /** 无码（扫描期从文件名 / NFO 判定） */
    uncensored: Type.Boolean(),
    /** 中文字幕 */
    chineseSub: Type.Boolean(),
    is4k: Type.Boolean(),
    /** HDR10 / HDR10+ / HLG / 杜比视界 任一 */
    hdr: Type.Boolean(),
    dolbyVision: Type.Boolean(),
    dolbyAtmos: Type.Boolean(),
    /** 文件名里带 LTX 标记 */
    ltx: Type.Boolean(),
    /** 能提出番号 = 日本片；默认勾选与「建议保留」的取舍依赖它 */
    isJp: Type.Boolean(),
    /** 建议保留这条（分辨率/体积/清晰度综合最高的那条） */
    suggestedKeep: Type.Boolean(),
  },
  { $id: 'VideoDuplicateItem' },
);

export const DuplicateGroup = Type.Object(
  {
    key: Type.String({ description: '组代表键（命中钥匙里优先级最高的一个）' }),
    title: Type.String({ description: '组内第一条的展示标题' }),
    count: Type.Integer(),
    /** 组内命中过哪些判重钥匙（imdb: / douban: / code: / title:），便于解释「为什么并在一起」 */
    keys: Type.Array(Type.String()),
    items: Type.Array(Type.Ref(DuplicateItem)),
  },
  { $id: 'VideoDuplicateGroup' },
);

export const DuplicatesResponse = Type.Object(
  {
    groups: Type.Array(Type.Ref(DuplicateGroup)),
    totalGroups: Type.Integer(),
    scanned: Type.Integer({ description: '参与比对的视频条数' }),
    tookMs: Type.Integer({ description: '服务端分组耗时（毫秒）' }),
  },
  { $id: 'VideoDuplicatesResponse' },
);

/** 智能合集（预设规则） */
export const SmartAlbum = Type.Object(
  {
    key: Type.String({ description: 'recent30 / unwatched / continue / 4k / hdr / atmos / long' }),
    count: Type.Integer(),
  },
  { $id: 'VideoSmartAlbum' },
);

export const SmartAlbumListResponse = Type.Object(
  { items: Type.Array(Type.Ref(SmartAlbum)) },
  { $id: 'VideoSmartAlbumListResponse' },
);

export const SmartAlbumItemsQuery = Type.Object(
  {
    key: Type.String({ minLength: 1 }),
    libraryId: Type.Optional(Type.String()),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'VideoSmartAlbumItemsQuery' },
);

/** 删除重复视频（移入回收站 + 清索引） */
export const DeleteItemsBody = Type.Object(
  {
    ids: Type.Array(Type.String({ minLength: 1 }), {
      minItems: 1,
      maxItems: 500,
      description: '要删除的 video_items.id',
    }),
  },
  { $id: 'VideoDeleteItemsBody' },
);

export const DeleteItemsResponse = Type.Object(
  {
    done: Type.Array(Type.String(), { description: '已删除的 id' }),
    failed: Type.Array(
      Type.Object({ path: Type.String(), error: Type.String() }),
    ),
    trashedTo: Type.String({ description: '回收站批次名，可在「回收站」里还原' }),
    sidecars: Type.Optional(
      Type.Array(Type.String(), {
        description: '一并移入回收站的字幕 / 图片 / NFO 文件名',
      }),
    ),
  },
  { $id: 'VideoDeleteItemsResponse' },
);

export const VIDEO_SCHEMAS = [
  SourceItem,
  SourceInput,
  LibraryItem,
  LibraryUpdateBody,
  LibraryFlagsBody,
  SourceProbeBody,
  SourceProbeResponse,
  LibraryListResponse,
  LibraryCreateBody,
  LibraryRemoveBody,
  ScanBody,
  ScanResponse,
  Item,
  FavoriteBody,
  FavoriteResponse,
  Collection,
  CollectionListResponse,
  CollectionUpsertBody,
  CollectionIdBody,
  CollectionItemsBody,
  CollectionItemsResponse,
  BrowseQuery,
  BrowseItem,
  BrowseResponse,
  DuplicatesQuery,
  DuplicateItem,
  DuplicateGroup,
  DuplicatesResponse,
  DeleteItemsBody,
  DeleteItemsResponse,
  SmartAlbum,
  SmartAlbumListResponse,
  SmartAlbumItemsQuery,
  ListQuery,
  ListResponse,
  ImageFolderQuery,
  ImageFolderNode,
  ImageFolderPathSegment,
  ImageFolderResponse,
  ImageFolderDeleteBody,
  ImageFolderDeleteResponse,
  IdQuery,
  StreamUrlResponse,
  StatsResponse,
  SeriesItem,
  SeriesListQuery,
  SeriesListResponse,
  SeriesItemsQuery,
  SeriesItemsResponse,
  SeasonGap,
  SeriesFavoriteBody,
  SeriesFavoriteResponse,
  SeriesFavoriteItem,
  SeriesFavoriteListResponse,
  ProgressBody,
  Progress,
  ProgressQuery,
  ProgressListQuery,
  ProgressClearBody,
  ProgressClearResponse,
  ProgressItem,
  ProgressListResponse,
  OkResponse,
  SubtitleFile,
  SubtitleListResponse,
  SubtitleQuery,
  SubtitleCue,
  SubtitleResponse,
  ErrorResponse,
  // 列表计数 / 统计（带库过滤）
  ListCountQuery,
  ListCountResponse,
  StatsQuery,
  // 刮削与 TMDB
  ScrapeBody,
  ScrapeResponse,
  ScrapeBatchBody,
  ScrapeBatchResponse,
  ScrapeCleanupBody,
  ScrapeCleanupResponse,
  MatchNfoBody,
  TmdbSearchBody,
  TmdbCandidate,
  TmdbSearchResponse,
  TmdbSettings,
  TmdbSettingsBody,
  ArtQuery,
  // 已观看
  WatchBody,
  WatchResponse,
  // 首页聚合
  HomeQuery,
  HomeSource,
  HomeLibraryRow,
  HomeResponse,
];
