/// 曲目条目的路径解析、封面地址与分页信封（纯 Dart，无 Flutter 依赖）。
///
/// 之前「可播放路径」在 7 处各写一份、「封面地址」在 3 个入口各写一份，
/// 「分页信封」在两个 PagedResult 里各写一份；任何一处改动都可能让歌词缓存键、
/// 封面路径与起始曲目匹配错位。这里收成单一实现。
library;

import '../compat/json_read.dart';
import '../list/models/cola_list_models.dart';

extension MusicItemLogic on MusicListItem {
  /// 可播放文件：整碟取首曲；单曲优先 fullPath，其次 path/filename，最后退 path。
  String get playablePath {
    if (isSeries) return firstFilePath.trim();
    final full = fullPath.trim();
    if (full.isNotEmpty) return full;
    final base = path.trim();
    final name = filename.trim();
    return base.isNotEmpty && name.isNotEmpty ? '$base/$name' : base;
  }

  /// 封面接口需要的路径：整碟取首曲，单曲取 fullPath（没有则退回 playablePath）。
  String get coverFilePath {
    if (isSeries) return firstFilePath.trim();
    final full = fullPath.trim();
    return full.isNotEmpty ? full : playablePath;
  }

  /// 是否能做「需要索引 id」的操作（收藏、加入歌单、属性等）。
  bool get canShowIndexActions =>
      id > 0 && !isFromFile && showType.trim().toLowerCase() != 'file_browser';

  bool get hasPlayableFile => playablePath.isNotEmpty;

  String get displaySubtitleText => isSeries ? '' : artist.trim();
}

typedef MusicCoverUrlBuilder = String Function({
  required String filePath,
  required int size,
});

/// 用注入的 urlBuilder 生成封面地址，避免纯逻辑层依赖 ApiController。
String musicCoverUrlOf(
  MusicListItem item, {
  required int size,
  required MusicCoverUrlBuilder build,
}) {
  final path = item.coverFilePath;
  if (path.isEmpty) return '';
  return build(filePath: path, size: size);
}

/// 列表接口统一信封：分页信息 + 有效路径列表。
class MusicPagedEnvelope {
  const MusicPagedEnvelope({
    required this.pagination,
    required this.validPaths,
  });

  final MusicListPagination pagination;
  final List<MusicListPathItem> validPaths;

  factory MusicPagedEnvelope.read(Map<String, dynamic> json) {
    final page = json.readMap(const ['pagination']);
    return MusicPagedEnvelope(
      pagination: page == null
          ? const MusicListPagination.empty()
          : MusicListPagination.fromJson(page),
      validPaths: MusicListPathItem.parseList(
        json.pick(const ['validPaths', 'valid_paths']),
      ),
    );
  }
}

/// 网格度量：把「按宽度算列数 / 封面边长 / 预估行高」集中到一处。
class GridMetrics {
  const GridMetrics({
    required this.crossAxisCount,
    required this.itemWidth,
    required this.coverSize,
    required this.estimatedHeight,
    required this.aspectRatio,
    required this.spacing,
  });

  final int crossAxisCount;
  final double itemWidth;
  final double coverSize;
  final double estimatedHeight;
  final double aspectRatio;
  final double spacing;

  factory GridMetrics.forWidth(
    double maxWidth, {
    double desiredWidth = 150,
    int minColumns = 2,
    int maxColumns = 10,
    double footerHeight = 54,
    double spacing = 4,
    double coverScale = 0.98,
  }) {
    final columns = (maxWidth / desiredWidth).floor().clamp(
      minColumns,
      maxColumns,
    );
    // SliverGridDelegateWithFixedCrossAxisCount 会先扣掉列间距再平分宽度。
    // 这里必须同步，否则 coverSize 比实际格子还宽，卡片高度超过 grid 给的
    // mainAxisExtent —— 音乐专辑列表实测溢出 2.7px（2026-11-09）。
    final width = (maxWidth - spacing * (columns - 1)) / columns;
    final cover = width * coverScale;
    final height = cover + footerHeight;
    return GridMetrics(
      crossAxisCount: columns,
      itemWidth: width,
      coverSize: cover,
      estimatedHeight: height,
      aspectRatio: width / height,
      spacing: spacing,
    );
  }
}
