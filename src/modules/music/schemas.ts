import { Type } from '@sinclair/typebox';

/**
 * music 模块路由契约（唯一真源：运行时校验 + OpenAPI + Dart 客户端）。
 */
const NullableInteger = Type.Union([Type.Integer(), Type.Null()]);
const NullableString = Type.Union([Type.String(), Type.Null()]);

export const LibraryItem = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    path: Type.String({ description: '相对 files 根的 POSIX 路径' }),
    items: Type.Integer({ description: '已索引曲目数' }),
    createdAt: Type.Integer(),
    lastScanAt: NullableInteger,
  },
  { $id: 'MusicLibraryItem' },
);

export const LibraryListResponse = Type.Object(
  { items: Type.Array(Type.Ref(LibraryItem)) },
  { $id: 'MusicLibraryListResponse' },
);

export const LibraryCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    path: Type.String({ minLength: 1, description: '相对 files 根的目录' }),
  },
  { $id: 'MusicLibraryCreateBody' },
);

/** 音乐缓存（转码产出）占用：客户端设置页显示 / 清理用 */
export const CacheStatsResponse = Type.Object(
  {
    files: Type.Integer({ description: '缓存的音频文件数' }),
    bytes: Type.Integer({ description: '缓存占用字节数' }),
  },
  { $id: 'MusicCacheStatsResponse' },
);

export const CacheClearResponse = Type.Object(
  {
    removed: Type.Integer({ description: '删掉的文件数' }),
    bytes: Type.Integer({ description: '释放的字节数' }),
  },
  { $id: 'MusicCacheClearResponse' },
);

export const LibraryRemoveBody = Type.Object(
  { id: Type.String({ minLength: 1 }) },
  { $id: 'MusicLibraryRemoveBody' },
);

export const ScanBody = Type.Object(
  {
    libraryId: Type.Optional(Type.String({ description: '缺省扫描全部库' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20000 })),
    prune: Type.Optional(
      Type.Boolean({ description: '清理磁盘上已不存在的曲目（仅整库扫描生效，默认关闭）' }),
    ),
  },
  { $id: 'MusicScanBody' },
);

export const ScanResponse = Type.Object(
  {
    libraries: Type.Integer(),
    tracks: Type.Integer(),
    added: Type.Integer(),
    updated: Type.Integer(),
    skipped: Type.Integer(),
    probed: Type.Integer({ description: 'ffmpeg 探测成功的条数' }),
    missing: Type.Optional(Type.Integer({ description: '索引有、磁盘已不存在（整库扫描）' })),
    pruned: Type.Optional(Type.Integer({ description: '本次实际清理的行数' })),
  },
  { $id: 'MusicScanResponse' },
);

export const Track = Type.Object(
  {
    id: Type.String(),
    libraryId: Type.String(),
    path: Type.String({ description: '相对 files 根，可直接播放 / 下载' }),
    title: Type.String(),
    artist: NullableString,
    album: NullableString,
    albumArtist: NullableString,
    genre: NullableString,
    trackNo: NullableInteger,
    year: NullableInteger,
    durationMs: NullableInteger,
    bitrate: Type.Union([Type.Integer(), Type.Null()], { description: 'kbps' }),
    sampleRate: Type.Union([Type.Integer(), Type.Null()], { description: 'Hz' }),
    channels: NullableString,
    codec: NullableString,
    hasCover: Type.Boolean(),
    size: Type.Integer(),
  },
  { $id: 'MusicTrack' },
);

export const ListQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    q: Type.Optional(Type.String({ maxLength: 200, description: '标题 / 艺术家 / 专辑关键词' })),
    artist: Type.Optional(Type.String({ maxLength: 200, description: '艺术家精确过滤' })),
    album: Type.Optional(Type.String({ maxLength: 200, description: '专辑精确过滤' })),
    albumArtist: Type.Optional(Type.String({ maxLength: 200, description: '专辑艺术家精确过滤' })),
    genre: Type.Optional(Type.String({ maxLength: 100, description: '流派精确过滤' })),
    year: Type.Optional(Type.Integer({ minimum: 0, maximum: 2200, description: '年份精确过滤' })),
    sort: Type.Optional(
      Type.Union(
        [
          Type.Literal('title'),
          Type.Literal('artist'),
          Type.Literal('album'),
          Type.Literal('created'),
          Type.Literal('duration'),
          Type.Literal('year'),
        ],
        { default: 'title', description: '排序字段' },
      ),
    ),
    order: Type.Optional(
      Type.Union([Type.Literal('asc'), Type.Literal('desc')], { default: 'asc' }),
    ),
    cursor: Type.Optional(Type.String({ description: '上一页 nextCursor' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 60 })),
  },
  { $id: 'MusicListQuery' },
);

/** 专辑聚合项 */
export const AlbumItem = Type.Object(
  {
    name: Type.String(),
    artist: Type.Union([Type.String(), Type.Null()]),
    year: Type.Union([Type.Integer(), Type.Null()]),
    tracks: Type.Integer(),
    durationMs: Type.Integer(),
    coverTrackId: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'MusicAlbum' },
);

export const AlbumListResponse = Type.Object(
  { items: Type.Array(Type.Ref(AlbumItem)) },
  { $id: 'MusicAlbumListResponse' },
);

export const AlbumsQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    q: Type.Optional(Type.String({ maxLength: 200 })),
    sort: Type.Optional(
      Type.Union([Type.Literal('name'), Type.Literal('tracks'), Type.Literal('year')], {
        default: 'name',
      }),
    ),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 1000, default: 200 })),
  },
  { $id: 'MusicAlbumsQuery' },
);

/** 艺人聚合项 */
export const ArtistItem = Type.Object(
  {
    name: Type.String(),
    tracks: Type.Integer(),
    albums: Type.Integer(),
    durationMs: Type.Integer(),
    coverTrackId: Type.Union([Type.String(), Type.Null()]),
  },
  { $id: 'MusicArtist' },
);

export const ArtistListResponse = Type.Object(
  { items: Type.Array(Type.Ref(ArtistItem)) },
  { $id: 'MusicArtistListResponse' },
);

export const ArtistsQuery = Type.Object(
  {
    libraryId: Type.Optional(Type.String()),
    q: Type.Optional(Type.String({ maxLength: 200 })),
    sort: Type.Optional(
      Type.Union([Type.Literal('name'), Type.Literal('tracks')], { default: 'name' }),
    ),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 1000, default: 200 })),
  },
  { $id: 'MusicArtistsQuery' },
);

export const ListResponse = Type.Object(
  {
    items: Type.Array(Type.Ref(Track)),
    nextCursor: NullableString,
  },
  { $id: 'MusicListResponse' },
);

export const IdQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（仅外部播放器使用，见 /music/stream-url）' }),
    ),
  },
  { $id: 'MusicIdQuery' },
);

export const StreamUrlQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（外部播放器可直接复用，见 /music/stream-url）' }),
    ),
    format: Type.Optional(
      Type.String({
        maxLength: 16,
        description: 'auto = Web 不支持时按需转 AAC；缺省 original',
      }),
    ),
  },
  { $id: 'MusicStreamUrlQuery' },
);

export const StreamQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（仅外部播放器使用，见 /music/stream-url）' }),
    ),
    format: Type.Optional(
      Type.String({ maxLength: 16, description: 'transcoded = 读取 AAC 转码缓存' }),
    ),
  },
  { $id: 'MusicStreamQuery' },
);

export const StreamUrlResponse = Type.Object(
  {
    url: Type.String({ description: '带短期令牌的播放地址，可直接交给外部播放器' }),
    expiresInSec: Type.Integer(),
    transcoded: Type.Boolean({ description: 'true 表示返回的是按需转码后的 AAC 缓存' }),
  },
  { $id: 'MusicStreamUrlResponse' },
);

export const StatsResponse = Type.Object(
  {
    libraries: Type.Integer(),
    tracks: Type.Integer(),
    albums: Type.Integer(),
    artists: Type.Integer(),
    durationMs: Type.Integer({ description: '已索引曲目总时长' }),
  },
  { $id: 'MusicStatsResponse' },
);

/**
 * 音乐合集：用户自建的一组音乐目录（对齐参考实现的「音乐合集」）。
 *
 * 和歌单的区别：歌单收的是**曲目 id**；合集收的是**目录**（曲库里的相对 / 绝对路径），
 * 目录里后来新放进去的歌会自动进合集 —— 适合「这张专辑一个文件夹」这种整理方式。
 */
export const Collection = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    paths: Type.Array(Type.String()),
    tracks: Type.Integer({ description: '这些目录下已索引的曲目数' }),
    coverTrackId: Type.Union([Type.String(), Type.Null()], {
      description: '第一首带封面的曲目 id（用它请求 /music/cover）',
    }),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
  },
  { $id: 'MusicCollection' },
);

export const CollectionListResponse = Type.Object(
  { items: Type.Array(Type.Ref(Collection)) },
  { $id: 'MusicCollectionListResponse' },
);

export const CollectionBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    paths: Type.Array(Type.String({ minLength: 1, maxLength: 1024 }), {
      minItems: 1,
      maxItems: 200,
    }),
  },
  { $id: 'MusicCollectionBody' },
);

export const CollectionItemsQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 200 })),
  },
  { $id: 'MusicCollectionItemsQuery' },
);

export const CollectionUpdateBody = Type.Object(
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
  { $id: 'MusicCollectionUpdateBody' },
);

export const Playlist = Type.Object(
  {
    id: Type.String(),
    name: Type.String(),
    tracks: Type.Integer(),
    coverTrackId: Type.Union([Type.String(), Type.Null()], {
      description: '第一首带封面的曲目 id（用它请求 /music/cover）',
    }),
    createdAt: Type.Integer(),
  },
  { $id: 'MusicPlaylist' },
);

export const PlaylistListResponse = Type.Object(
  { items: Type.Array(Type.Ref(Playlist)) },
  { $id: 'MusicPlaylistListResponse' },
);

export const PlaylistCreateBody = Type.Object(
  {
    name: Type.String({ minLength: 1, maxLength: 64 }),
    trackIds: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { maxItems: 500 })),
  },
  { $id: 'MusicPlaylistCreateBody' },
);

export const PlaylistMembersBody = Type.Object(
  {
    playlistId: Type.String({ minLength: 1 }),
    trackIds: Type.Array(Type.String({ minLength: 1 }), { minItems: 1, maxItems: 500 }),
  },
  { $id: 'MusicPlaylistMembersBody' },
);

export const PlaylistItemsQuery = Type.Object(
  {
    playlistId: Type.String({ minLength: 1 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 500, default: 200 })),
  },
  { $id: 'MusicPlaylistItemsQuery' },
);

export const PlaylistDeleteBody = Type.Object(
  { playlistId: Type.String({ minLength: 1 }) },
  { $id: 'MusicPlaylistDeleteBody' },
);

export const PlaylistRenameBody = Type.Object(
  {
    playlistId: Type.String({ minLength: 1 }),
    name: Type.String({ minLength: 1, maxLength: 64 }),
  },
  { $id: 'MusicPlaylistRenameBody' },
);

/** 自动歌单：kind 由服务端校验，避免 OpenAPI 里出现 anyOf 让生成器难处理 */
export const AutoPlaylist = Type.Object(
  {
    kind: Type.String({
      description: 'recent_added / recently_played / most_played / never_played',
    }),
    count: Type.Integer({ minimum: 0 }),
    coverTrackId: Type.Union([Type.String(), Type.Null()], {
      description: '列表内第一首带封面的曲目 id',
    }),
  },
  { $id: 'MusicAutoPlaylist' },
);

export const AutoPlaylistListResponse = Type.Object(
  { items: Type.Array(Type.Ref(AutoPlaylist)) },
  { $id: 'MusicAutoPlaylistListResponse' },
);

export const AutoPlaylistQuery = Type.Object(
  {
    kind: Type.String({ minLength: 1, maxLength: 32 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, default: 50 })),
  },
  { $id: 'MusicAutoPlaylistQuery' },
);

export const AutoPlaylistTracksResponse = Type.Object(
  { items: Type.Array(Type.Ref(Track)) },
  { $id: 'MusicAutoPlaylistTracksResponse' },
);

export const OkResponse = Type.Object({ ok: Type.Boolean() }, { $id: 'MusicOkResponse' });

export const ErrorResponse = Type.Object(
  {
    error: Type.String(),
    message: Type.Optional(Type.String()),
    code: Type.Optional(Type.String()),
    traceId: Type.Optional(Type.String()),
    details: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
  },
  { $id: 'MusicErrorResponse' },
);

/** 歌词行：`timeMs` 缺省表示纯文本歌词（无时间戳） */
export const LyricsLine = Type.Object(
  {
    timeMs: Type.Optional(Type.Integer({ minimum: 0, description: '该行起始时间（毫秒）' })),
    text: Type.String(),
    translation: Type.Optional(
      Type.String({ description: '译文（来自旁挂 <base>.<lang>.lrc，已按时间轴对齐）' }),
    ),
  },
  { $id: 'MusicLyricsLine' },
);

/** 歌词查询：在通用 id/token 之外多了首选译文语言 */
export const LyricsQuery = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    token: Type.Optional(
      Type.String({ description: '短期令牌（仅外部播放器使用，见 /music/stream-url）' }),
    ),
    lang: Type.Optional(
      Type.String({
        maxLength: 20,
        description: '首选译文语言（如 zh-CN / en）；缺省时中文优先',
      }),
    ),
  },
  { $id: 'MusicLyricsQuery' },
);

export const LyricsResponse = Type.Object(
  {
    source: Type.String({
      description: 'lrc 旁挂 / embedded 内嵌（ID3 USLT、flac Vorbis）/ none 无歌词',
    }),
    synced: Type.Boolean({ description: 'true 表示逐行带时间戳' }),
    title: Type.Optional(Type.String()),
    artist: Type.Optional(Type.String()),
    album: Type.Optional(Type.String()),
    by: Type.Optional(Type.String()),
    lines: Type.Array(Type.Ref(LyricsLine)),
  },
  { $id: 'MusicLyricsResponse' },
);

export const MUSIC_SCHEMAS = [
  LibraryItem,
  LibraryListResponse,
  LibraryCreateBody,
  LibraryRemoveBody,
  CacheStatsResponse,
  CacheClearResponse,
  ScanBody,
  ScanResponse,
  Track,
  ListQuery,
  ListResponse,
  AlbumItem,
  AlbumListResponse,
  AlbumsQuery,
  ArtistItem,
  ArtistListResponse,
  ArtistsQuery,
  IdQuery,
  StreamUrlQuery,
  StreamQuery,
  StreamUrlResponse,
  StatsResponse,
  Collection,
  CollectionListResponse,
  CollectionBody,
  CollectionUpdateBody,
  CollectionItemsQuery,
  Playlist,
  PlaylistListResponse,
  PlaylistCreateBody,
  PlaylistMembersBody,
  PlaylistItemsQuery,
  PlaylistDeleteBody,
  PlaylistRenameBody,
  AutoPlaylist,
  AutoPlaylistListResponse,
  AutoPlaylistQuery,
  AutoPlaylistTracksResponse,
  OkResponse,
  ErrorResponse,
  LyricsLine,
  LyricsQuery,
  LyricsResponse,
];