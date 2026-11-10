import '../../compat/json_read.dart';
import '../../shared/music_item_logic.dart';

/// 一首歌（或一个「系列」条目）在列表 / 播放器里用的视图模型。
///
/// 字段与后端 compat 层一一对应；`duration` 单位是**秒**（接口口径），
/// 播放器内部的 `Duration` 由上层自己换算，模型层不做单位转换。
///
/// 这是一个纯值对象：所有字段 final，只提供 `copyWith` 做局部替换，
/// 避免列表里就地改状态导致 UI 与数据不同步。
class MusicListItem {
  final String year;
  final String title;
  final String path;
  final int id;
  final String genre;
  final String filename;
  final String fileHash;
  final String artist;
  final String album;

  /// 时长（秒），与数据库及接口约定一致。
  final int duration;

  final int size;
  final String ext;

  /// 是否带内嵌封面（1 = 有，0 = 没有）
  final String showType;
  final int? sampleRate;
  final int musicCount;
  final String? mtime;
  final bool isFromFile;
  final bool isFavorite;
  final int hasInnerCover;
  final String fullPath;
  final String firstFilePath;
  final String? ctime;
  final int? bitrate;
  final int? bitDepth;
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
    required this.hasInnerCover,
    required this.showType,
    required this.musicCount,
    required this.isFavorite,
    this.isFromFile = false,
    required this.ctime,
    required this.mtime,
    required this.birthtime,
    required this.firstFilePath,
    required this.fullPath,
    required this.bitrate,
    required this.sampleRate,
    required this.bitDepth,
  });

  /// 多曲打包的条目（整张碟 / 整张专辑当一个条目播）
  bool get isSeries => showType.trim().toLowerCase() == 'series';

  /// 列表里显示的名字：文件名优先。
  ///
  /// 故意不用 `title`：同一个文件被刮削前后 title 会变，用文件名能让用户
  /// 一眼对上自己磁盘上的东西（内部编号 / 音轨号都在文件名里）。
  String get displayTitle => filename.trim();

  /// 「艺人 · 专辑」，缺一个就只显示有的那个，都没有返回空串
  String get displaySubtitle {
    final localRecord = album.trim();
    final localName = artist.trim();
    if (localName.isNotEmpty && localRecord.isNotEmpty)
      return '$localName · $localRecord';
    if (localName.isNotEmpty) return localName;
    if (localRecord.isNotEmpty) return localRecord;
    return '';
  }

  MusicListItem copyWith({
    bool? isFavorite,
    int? id,
    String? showType,
    bool? isFromFile,
  }) => MusicListItem(
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
    hasInnerCover: hasInnerCover,
    showType: showType ?? this.showType,
    musicCount: musicCount,
    isFavorite: isFavorite ?? this.isFavorite,
    isFromFile: isFromFile ?? this.isFromFile,
    ctime: ctime,
    mtime: mtime,
    birthtime: birthtime,
    firstFilePath: firstFilePath,
    fullPath: fullPath,
    bitrate: bitrate,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );

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
    hasInnerCover: json.readInt(const ['has_inner_cover', 'hasInnerCover']),
    showType: json.readString(const ['show_type', 'showType']),
    musicCount: json.readInt(const ['music_count', 'musicCount']),
    isFavorite: json.readBool(const ['is_favorite', 'isFavorite']),
    isFromFile: json.readBool(const ['is_from_file', 'isFromFile']),
    ctime: json.readStringOrNull(const ['ctime']),
    mtime: json.readStringOrNull(const ['mtime']),
    birthtime: json.readStringOrNull(const ['birthtime']),
    firstFilePath: json.readString(const ['first_file_path', 'firstFilePath']),
    fullPath: json.readString(const ['full_path', 'fullPath']),
    bitrate: json.readIntOrNull(const ['bitrate']),
    sampleRate: json.readIntOrNull(const ['sample_rate', 'sampleRate']),
    bitDepth: json.readIntOrNull(const ['bit_depth', 'bitDepth']),
  );
}

/// 分页信息（服务端 `pagination` 块）
class MusicListPagination {
  final int totalPages;
  final int total;
  final int page;
  final int limit;
  final bool hasPrevPage;
  final bool hasNextPage;

  const MusicListPagination({
    required this.totalPages,
    required this.total,
    required this.page,
    required this.limit,
    required this.hasPrevPage,
    required this.hasNextPage,
  });

  const MusicListPagination.empty()
    : total = 0,
      page = 1,
      limit = 30,
      totalPages = 0,
      hasNextPage = false,
      hasPrevPage = false;

  factory MusicListPagination.fromJson(Map<String, dynamic> json) =>
      MusicListPagination(
        total: json.readInt(const ['total']),
        page: json.readInt(const ['page'], fallback: 1),
        limit: json.readInt(const ['limit'], fallback: 30),
        totalPages: json.readInt(const ['totalPages', 'total_pages']),
        hasNextPage: json.readBool(const ['hasNextPage', 'has_next_page']),
        hasPrevPage: json.readBool(const ['hasPrevPage', 'has_prev_page']),
      );
}

/// 筛选下拉里用的候选值
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
        artists: json.readStringList(const ['artists']),
        albums: json.readStringList(const ['albums']),
        genres: json.readStringList(const ['genres']),
      );
}

/// 来源目录 + 它当前是否可达（盘掉了 / 路径改了都会是 false）
class MusicListPathItem {
  final String path;
  final bool valid;

  const MusicListPathItem({required this.path, required this.valid});

  factory MusicListPathItem.fromJson(Map<String, dynamic> json) =>
      MusicListPathItem(
        path: json.readString(const ['path']).trim(),
        valid: json.readBool(const ['valid']),
      );

  /// 批量解析来源目录。
  ///
  /// 后端两种形态都有：一种是纯字符串数组（老接口），一种是 `{path, valid}`
  /// 对象数组（新接口，能告诉客户端哪个盘掉了）。专辑/歌手列表也要用同一套
  /// 规则，所以收口成静态方法，别在三个 `fromJson` 里各写一遍。
  static List<MusicListPathItem> parseList(Object? raw) {
    if (raw is! List) return const <MusicListPathItem>[];
    final out = <MusicListPathItem>[];
    for (final entry in raw) {
      if (entry is String) {
        final localText = entry.trim();
        if (localText.isNotEmpty)
          out.add(MusicListPathItem(path: localText, valid: true));
      } else if (entry is Map) {
        final item = MusicListPathItem.fromJson(entry.cast<String, dynamic>());
        if (item.path.isNotEmpty) out.add(item);
      }
    }
    return out;
  }
}

/// 一次列表请求的完整结果
class MusicListPagedResult {
  final List<MusicListPathItem> validPaths;
  final MusicListPagination pagination;
  final List<MusicListItem> items;
  final MusicListFilterOptions? filters;

  const MusicListPagedResult({
    required this.validPaths,
    required this.pagination,
    required this.items,
    required this.filters,
  });

  const MusicListPagedResult.empty()
    : items = const <MusicListItem>[],
      pagination = const MusicListPagination.empty(),
      filters = null,
      validPaths = const <MusicListPathItem>[];

  factory MusicListPagedResult.fromJson(Map<String, dynamic> json) {
    final filters = json.readMap(const ['filters', 'filterOptions']);
    final envelope = MusicPagedEnvelope.read(json);
    return MusicListPagedResult(
      // 没有真实 id 的行是脏数据（历史遗留的空壳条目），列表里不展示
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

/// 翻页游标：把「当前在哪个列表、第几页、带什么筛选」打包成一个不可变对象，
/// 翻页时只改 page，其余原样带过去，避免每次重新拼一长串参数。
class MusicListPagingQuery {
  final List<String>? sourceList;
  final String? sortOrder;
  final String? sortBy;
  final int? seriesIndexId;
  final String? search;
  final int pageSize;
  final int page;
  final String? listType;
  final int? listId;
  final bool isHistory;
  final bool isFavorite;
  final bool hasMore;
  final List<String>? genres;
  final int? collectionId;
  final List<String>? artists;
  final List<String>? albums;

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
