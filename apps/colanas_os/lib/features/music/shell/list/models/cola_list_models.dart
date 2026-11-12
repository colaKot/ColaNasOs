import '../../compat/json_read.dart';
import '../../shared/music_item_logic.dart';

/// 音乐列表的条目视图模型（单曲或「系列」整包）。
///
/// 字段与服务端 compat 层约定一一对应；`duration` 使用接口口径的**秒**，
/// 需要 `Duration` 的地方由调用方换算。对象本身不可变，局部修改走 `copyWith`，
/// 避免列表状态被就地改写后与 UI 不一致。
class MusicListItem {
  // ---- 唯一标识与文件定位 ----
  final int id;
  final String path;
  final String filename;
  final String fileHash;

  // ---- 展示信息 ----
  final String title;
  final String artist;
  final String album;
  final String year;
  final String genre;

  // ---- 音频属性 ----
  /// 时长，单位秒（与数据库、接口保持一致）。
  final int duration;
  final int size;
  final String ext;
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  final int hasInnerCover;
  final String showType;

  // ---- 多曲聚合与绝对路径 ----
  final int musicCount;
  final String firstFilePath;
  final String fullPath;

  // ---- 状态标记 ----
  final bool isFavorite;
  final bool isFromFile;

  // ---- 文件时间 ----
  final String? ctime;
  final String? mtime;
  final String? birthtime;

  const MusicListItem({
    required this.id,
    required this.path,
    required this.filename,
    required this.fileHash,
    required this.title,
    required this.artist,
    required this.album,
    required this.year,
    required this.genre,
    required this.duration,
    required this.size,
    required this.ext,
    required this.bitrate,
    required this.sampleRate,
    required this.bitDepth,
    required this.hasInnerCover,
    required this.showType,
    required this.musicCount,
    required this.firstFilePath,
    required this.fullPath,
    required this.isFavorite,
    this.isFromFile = false,
    required this.ctime,
    required this.mtime,
    required this.birthtime,
  });

  /// 整张碟 / 整张专辑作为一个条目播放时，`showType` 为 series。
  bool get isSeries => showType.trim().toLowerCase() == 'series';

  /// 列表展示名优先用文件名：刮削前后 title 可能变化，文件名与用户磁盘一致。
  String get displayTitle => filename.trim();

  /// 「艺人 · 专辑」；缺一边就只显示另一边，都没有则为空串。
  String get displaySubtitle {
    final parts = <String>[
      if (artist.trim().isNotEmpty) artist.trim(),
      if (album.trim().isNotEmpty) album.trim(),
    ];
    return parts.join(' · ');
  }

  MusicListItem copyWith({
    bool? isFavorite,
    int? id,
    String? showType,
    bool? isFromFile,
  }) {
    return MusicListItem(
      id: id ?? this.id,
      path: path,
      filename: filename,
      fileHash: fileHash,
      title: title,
      artist: artist,
      album: album,
      year: year,
      genre: genre,
      duration: duration,
      size: size,
      ext: ext,
      bitrate: bitrate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      hasInnerCover: hasInnerCover,
      showType: showType ?? this.showType,
      musicCount: musicCount,
      firstFilePath: firstFilePath,
      fullPath: fullPath,
      isFavorite: isFavorite ?? this.isFavorite,
      isFromFile: isFromFile ?? this.isFromFile,
      ctime: ctime,
      mtime: mtime,
      birthtime: birthtime,
    );
  }

  factory MusicListItem.fromJson(Map<String, dynamic> json) => MusicListItem(
    id: json.readInt(const ['id']),
    path: json.readString(const ['path']),
    filename: json.readString(const ['filename']),
    fileHash: json.readString(const ['file_hash', 'fileHash']),
    title: json.readString(const ['title']),
    artist: json.readString(const ['artist']),
    album: json.readString(const ['album']),
    year: json.readString(const ['year']),
    genre: json.readString(const ['genre']),
    duration: json.readInt(const ['duration']),
    size: json.readInt(const ['size']),
    ext: json.readString(const ['ext']),
    bitrate: json.readIntOrNull(const ['bitrate']),
    sampleRate: json.readIntOrNull(const ['sample_rate', 'sampleRate']),
    bitDepth: json.readIntOrNull(const ['bit_depth', 'bitDepth']),
    hasInnerCover: json.readInt(const ['has_inner_cover', 'hasInnerCover']),
    showType: json.readString(const ['show_type', 'showType']),
    musicCount: json.readInt(const ['music_count', 'musicCount']),
    firstFilePath: json.readString(const ['first_file_path', 'firstFilePath']),
    fullPath: json.readString(const ['full_path', 'fullPath']),
    isFavorite: json.readBool(const ['is_favorite', 'isFavorite']),
    isFromFile: json.readBool(const ['is_from_file', 'isFromFile']),
    ctime: json.readStringOrNull(const ['ctime']),
    mtime: json.readStringOrNull(const ['mtime']),
    birthtime: json.readStringOrNull(const ['birthtime']),
  );
}

/// 服务端返回的 `pagination` 块。
class MusicListPagination {
  final int total;
  final int page;
  final int limit;
  final int totalPages;
  final bool hasPrevPage;
  final bool hasNextPage;

  const MusicListPagination({
    required this.total,
    required this.page,
    required this.limit,
    required this.totalPages,
    required this.hasPrevPage,
    required this.hasNextPage,
  });

  const MusicListPagination.empty()
    : total = 0,
      page = 1,
      limit = 30,
      totalPages = 0,
      hasPrevPage = false,
      hasNextPage = false;

  factory MusicListPagination.fromJson(Map<String, dynamic> json) =>
      MusicListPagination(
        total: json.readInt(const ['total']),
        page: json.readInt(const ['page'], fallback: 1),
        limit: json.readInt(const ['limit'], fallback: 30),
        totalPages: json.readInt(const ['totalPages', 'total_pages']),
        hasPrevPage: json.readBool(const ['hasPrevPage', 'has_prev_page']),
        hasNextPage: json.readBool(const ['hasNextPage', 'has_next_page']),
      );
}

/// 列表筛选下拉的候选值。
class MusicListFilterOptions {
  final List<String> genres;
  final List<String> artists;
  final List<String> albums;

  const MusicListFilterOptions({
    required this.genres,
    required this.artists,
    required this.albums,
  });

  factory MusicListFilterOptions.fromJson(Map<String, dynamic> json) =>
      MusicListFilterOptions(
        genres: json.readStringList(const ['genres']),
        artists: json.readStringList(const ['artists']),
        albums: json.readStringList(const ['albums']),
      );
}

/// 来源目录及其可达状态（盘符离线或路径变化时为 false）。
class MusicListPathItem {
  final String path;
  final bool valid;

  const MusicListPathItem({required this.path, required this.valid});

  factory MusicListPathItem.fromJson(Map<String, dynamic> json) =>
      MusicListPathItem(
        path: json.readString(const ['path']).trim(),
        valid: json.readBool(const ['valid']),
      );

  /// 兼容两种返回形态：老接口是纯字符串数组，新接口是 `{path, valid}`。
  static List<MusicListPathItem> parseList(Object? raw) {
    if (raw is! List) return const <MusicListPathItem>[];

    final parsed = <MusicListPathItem>[];
    for (final entry in raw) {
      switch (entry) {
        case String text:
          final path = text.trim();
          if (path.isNotEmpty) {
            parsed.add(MusicListPathItem(path: path, valid: true));
          }
        case Map map:
          final item = MusicListPathItem.fromJson(
            map.cast<String, dynamic>(),
          );
          if (item.path.isNotEmpty) parsed.add(item);
        default:
          break;
      }
    }
    return parsed;
  }
}

/// 一次列表请求的完整结果。
class MusicListPagedResult {
  final List<MusicListItem> items;
  final MusicListPagination pagination;
  final MusicListFilterOptions? filters;
  final List<MusicListPathItem> validPaths;

  const MusicListPagedResult({
    required this.items,
    required this.pagination,
    required this.filters,
    required this.validPaths,
  });

  const MusicListPagedResult.empty()
    : items = const <MusicListItem>[],
      pagination = const MusicListPagination.empty(),
      filters = null,
      validPaths = const <MusicListPathItem>[];

  factory MusicListPagedResult.fromJson(Map<String, dynamic> json) {
    final envelope = MusicPagedEnvelope.read(json);
    final filters = json.readMap(const ['filters', 'filterOptions']);

    return MusicListPagedResult(
      // id 非正的行是历史脏数据，不进入列表。
      items: json
          .readList(const ['items'], MusicListItem.fromJson)
          .where((item) => item.id > 0)
          .toList(),
      pagination: envelope.pagination,
      filters: filters == null
          ? null
          : MusicListFilterOptions.fromJson(filters),
      validPaths: envelope.validPaths,
    );
  }
}

/// 翻页游标：打包「列表来源 + 页码 + 筛选条件」，翻页时只替换 page。
class MusicListPagingQuery {
  final int page;
  final int pageSize;
  final bool hasMore;
  final String? listType;
  final int? listId;
  final int? seriesIndexId;
  final int? collectionId;
  final bool isFavorite;
  final bool isHistory;
  final String? search;
  final List<String>? artists;
  final List<String>? albums;
  final List<String>? genres;
  final List<String>? sourceList;
  final String? sortBy;
  final String? sortOrder;

  const MusicListPagingQuery({
    required this.page,
    required this.pageSize,
    required this.hasMore,
    this.listType,
    this.listId,
    this.seriesIndexId,
    this.collectionId,
    this.isFavorite = false,
    this.isHistory = false,
    this.search,
    this.artists,
    this.albums,
    this.genres,
    this.sourceList,
    this.sortBy,
    this.sortOrder,
  });
}
