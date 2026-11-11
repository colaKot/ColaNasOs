import 'package:nas_core/nas_core.dart';

/// 影视库类型缓存（库 id → libType）。
///
/// `VideoItem` 里只有 `libraryId`、没有库类型，而「短剧」的播放要按库类型决定
/// 是否启用上下切换。外壳加载库列表时顺手记一份，页面同步查即可。
class VideoLibraryTypes {
  VideoLibraryTypes._();

  static final Map<String, String> _types = <String, String>{};

  static void update(List<VideoLibraryItem> libs) {
    _types
      ..clear()
      ..addEntries(libs.map((l) => MapEntry(l.id, l.libType)));
  }

  static String? of(String libraryId) => _types[libraryId];

  /// 短剧库：列表 / 详情与电视剧完全一致，只有播放器多一个上下切换。
  static bool isShortTv(String libraryId) => _types[libraryId] == 'short_tv';
}
