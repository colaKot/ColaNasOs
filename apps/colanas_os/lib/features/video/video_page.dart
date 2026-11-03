/// 影视模块的公共出口。
///
/// 详情页 / 海报卡 / 剧集详情原先都塞在 `video_page.dart` 里，现在拆成独立文件，
/// 这里统一 re-export，保持既有 import 路径（`import 'video_page.dart'`）继续可用。
library;

import 'package:flutter/material.dart';

import 'video_home_page.dart';
import 'video_list_view.dart';

export 'video_card.dart'
    show MediaFlagsRow, openVideoDetail, openVideoDetailOn, videoPosterUrl;
export 'video_detail_page.dart';
export 'video_series_detail_page.dart';

/// 影视入口（二级导航 `video_shell` 直接用它）。
///
/// 语义变化（对齐参考实现）：
///   - **没有 libraryId** → 首页（四段式浏览：来源 / 推荐 / 继续观看 / 每库最近添加）
///   - **带 libraryId**   → 该库的影片列表（顶栏可排序 / 筛选 / 调海报大小）
///
/// 旧版两种情况都渲染「搜索框 + 一整面无限网格」，所以首页看着不像首页、
/// 列表又缺所有工具；现在把两件事拆成两个页面。
class VideoPage extends StatelessWidget {
  const VideoPage({super.key, this.embedded = false, this.libraryId});

  /// 嵌入影视二级导航内容区时去掉自带 AppBar
  final bool embedded;

  /// 只看某个影视库；null = 首页
  final String? libraryId;

  @override
  Widget build(BuildContext context) {
    final id = libraryId;
    if (id == null || id.isEmpty) {
      return VideoHomePage(key: const ValueKey('video-home'), embedded: embedded);
    }
    // key 必须带库 id：否则左栏切库时 Flutter 会复用同一个 State，
    // initState 不会再跑，列表还停在上一个库的数据上。
    return VideoListView(
      key: ValueKey('video-lib-$id'),
      libraryId: id,
      embedded: embedded,
    );
  }
}
