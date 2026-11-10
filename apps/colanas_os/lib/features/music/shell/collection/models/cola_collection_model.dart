import '../../compat/json_read.dart';

/// 合集卡片上的封面小图（最多几张，用来拼缩略图墙）
class MusicCollectionPreviewItem {
  final int id;
  final String path;
  final String filename;
  final String showType;
  final String firstFilePath;

  /// 1 = 有内嵌封面；0 = 没有，卡片改用占位图标
  final int hasInnerCover;

  const MusicCollectionPreviewItem({
    required this.id,
    required this.path,
    required this.filename,
    required this.showType,
    required this.firstFilePath,
    this.hasInnerCover = 0,
  });

  factory MusicCollectionPreviewItem.fromJson(Map<String, dynamic> json) =>
      MusicCollectionPreviewItem(
        id: json.readInt(const ['id']),
        path: json.readString(const ['path']),
        filename: json.readString(const ['filename']),
        showType: json.readString(const ['show_type', 'showType']),
        firstFilePath: json.readString(const [
          'first_file_path',
          'firstFilePath',
        ]),
        hasInnerCover: json.readInt(const ['has_inner_cover', 'hasInnerCover']),
      );

  /// 目录 + 文件名拼成可直接交给播放器的完整路径（目录已带斜杠就不重复加）
  String get fullPath {
    final dir = path.trim();
    if (dir.isEmpty) return '';
    final name = filename.trim();
    if (name.isEmpty) return dir;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }
}

/// 一个音乐合集：一组目录的集合，按用户隔离
///
/// 注意 `ownerId` 后端字段叫 `uid`，不是 `owner_id`，解析时两个都认。
class MusicCollectionItem {
  final int id;
  final int ownerId;
  final String name;

  /// 合集包含的目录列表（绝对路径）
  final List<String> pathList;

  /// 创建时间：后端直接给字符串，展示层原样用，不在这里做时间戳换算
  final String createTime;

  final List<MusicCollectionPreviewItem> previews;

  const MusicCollectionItem({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.pathList,
    required this.createTime,
    required this.previews,
  });

  factory MusicCollectionItem.fromJson(Map<String, dynamic> json) =>
      MusicCollectionItem(
        id: json.readInt(const ['id']),
        ownerId: json.readInt(const ['uid', 'owner_id', 'ownerId']),
        name: json.readString(const ['name']),
        pathList: json.readStringList(const ['path_list', 'pathList']),
        createTime: json.readString(const ['create_time', 'createTime']),
        // 空壳预览没有意义，直接丢（id <= 0 的一律不展示）
        previews: json
            .readList(const ['previews'], MusicCollectionPreviewItem.fromJson)
            .where((item) => item.id > 0)
            .toList(),
      );
}

/// 合集列表接口的一次返回
class MusicCollectionListResult {
  final List<MusicCollectionItem> items;
  final int total;
  final int page;
  final int pageSize;

  const MusicCollectionListResult({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory MusicCollectionListResult.fromJson(Map<String, dynamic> json) {
    final pagination = json.readMap(const ['pagination']);
    return MusicCollectionListResult(
      items: json
          .readList(const ['items'], MusicCollectionItem.fromJson)
          .where((item) => item.id > 0)
          .toList(),
      total: pagination?.readInt(const ['total']) ?? 0,
      page: pagination?.readInt(const ['page'], fallback: 1) ?? 1,
      pageSize:
          pagination?.readInt(const ['pageSize', 'page_size'], fallback: 20) ??
          20,
    );
  }
}
