import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/scan_refresh.dart';
import 'video_card.dart';
import 'video_detail_page.dart';
import 'video_image_library_page.dart';
import 'video_list_view.dart';
import 'video_media_viewer_page.dart';

/// 影视首页：**来源 / 推荐 / 继续观看 / 每库最近添加** 四段式。
///
/// 这是与参考实现 `video_home_page` 对齐的关键改动。旧版把一个搜索框加一整面
/// 无限网格当首页，语义是「查找」；参考实现是「编辑精选」式的浏览页，
/// 看着完全不像，问题就出在这里 —— 不是样式细节，是信息架构不同。
class VideoHomePage extends StatefulWidget {
  const VideoHomePage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<VideoHomePage> createState() => _VideoHomePageState();
}

class _VideoHomePageState extends State<VideoHomePage> {
  bool _loading = true;
  String? _error;
  VideoHomeResponse? _home;
  VideoStatsResponse? _stats;
  late final void Function() _unsub;

  @override
  void initState() {
    super.initState();
    // 扫描完成后自动刷新首页（和列表页共用同一个刷新信号）
    _unsub = listenScanDone('video', _load);
    _load();
  }

  @override
  void dispose() {
    _unsub();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = ApiSession.instance.client;
      final home = await c.videoHome();
      VideoStatsResponse? stats;
      try {
        stats = await c.videoStats();
      } catch (_) {
        // 统计失败不影响首页
      }
      if (!mounted) return;
      setState(() {
        _home = home;
        _stats = stats;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _openItem(VideoItem item) {
    if (item.mediaType == 'image') {
      openMediaViewer(context, items: [item], initialIndex: 0);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailPage(
          item: item,
          posterUrl: videoPosterUrl(item),
          headers: videoArtHeaders,
        ),
      ),
    );
  }

  void _openAt(List<VideoItem> items, int index) {
    final item = items[index];
    if (item.mediaType == 'image') {
      openMediaViewer(context, items: items, initialIndex: index);
      return;
    }
    _openItem(item);
  }

  void _openLibrary(String id, String name, String libType) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => libType == 'image' || libType == 'mixed'
            ? VideoImageLibraryPage(
                libraryId: id,
                libType: libType,
                title: name,
              )
            : VideoListView(libraryId: id, title: name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    final home = _home;
    final empty = home == null ||
        (home.recommend.isEmpty &&
            home.recentPlay.isEmpty &&
            home.recentAdd.isEmpty &&
            home.sources.isEmpty);
    if (empty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.home.empty'),
            message: tr('video.home.emptyHint'),
            icon: Icons.movie_outlined,
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: NasTokens.spaceLg),
        children: [
          if (_stats != null && _stats!.items > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                NasTokens.spaceMd,
                NasTokens.spaceMd,
                0,
              ),
              child: Text(
                tr('video.stats', {
                  'count': '${_stats!.items}',
                  'duration': formatDurationMs(_stats!.durationMs),
                }),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ),
          if (home.sources.isNotEmpty) _sourcesSection(context, home.sources),
          if (home.recommend.isNotEmpty) _recommendSection(context, home.recommend),
          if (home.recentPlay.isNotEmpty) _recentPlaySection(context, home, home.progress),
          for (final row in home.recentAdd)
            if (row.items.isNotEmpty) _libraryRowSection(context, row),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, {VoidCallback? onMore}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: NasTokens.fontSubtitle, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (onMore != null)
            TextButton(onPressed: onMore, child: Text(tr('video.card.more'))),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 来源

  Widget _sourcesSection(BuildContext context, List<VideoHomeSource> sources) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, tr('video.home.sources')),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: sources.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) {
              final s = sources[i];
              return SizedBox(
                width: 210,
                child: InkWell(
                  borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                  onTap: () => _openLibrary(s.id, s.name, s.libType),
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
                    ),
                    padding: const EdgeInsets.all(NasTokens.spaceSm),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                          child: SizedBox(
                            width: 48,
                            height: 72,
                            child: s.coverId == null && (s.coverPath ?? '').isEmpty
                                ? Icon(Icons.movie_outlined, color: context.nasTextSecondary)
                                : NasCoverImage(
                                    url: s.coverPath != null && s.coverPath!.isNotEmpty
                                        ? '${ApiSession.instance.baseUrl}/api/v1/files/thumb?path=${Uri.encodeComponent(s.coverPath!)}&size=240'
                                        : '${ApiSession.instance.baseUrl}/api/v1/video/art?id=${Uri.encodeComponent(s.coverId!)}',
                                    headers: videoArtHeaders,
                                    fallbackText: s.name,
                                    icon: s.libType == 'image' || s.libType == 'mixed'
                                        ? Icons.image_outlined
                                        : Icons.movie_outlined,
                                  ),
                          ),
                        ),
                        const SizedBox(width: NasTokens.spaceSm),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${s.items}',
                                style: TextStyle(
                                  fontSize: NasTokens.fontCaption,
                                  color: context.nasTextSecondary,
                                ),
                              ),
                              if (s.onlineState == 2)
                                Text(
                                  tr('video.source.offline'),
                                  style: TextStyle(fontSize: NasTokens.fontMicro, color: scheme.error),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 推荐

  Widget _recommendSection(BuildContext context, List<VideoItem> items) {
    final width = MediaQuery.of(context).size.width;
    final cardW = width >= 1200 ? 360.0 : width >= 900 ? 320.0 : 270.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, tr('video.home.recommend')),
        SizedBox(
          height: cardW / (16 / 9),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) => SizedBox(
              height: cardW / (16 / 9),
              child: VideoHeroCard(
                item: items[i],
                width: cardW,
                onTap: () => _openItem(items[i]),
                onMore: () => _openItem(items[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 继续观看 / 最近添加

  Widget _recentPlaySection(
    BuildContext context,
    VideoHomeResponse home,
    List<VideoProgress> progress,
  ) {
    final byId = {for (final p in progress) p.itemId: p.percent / 100};
    return _hScroller(
      context,
      title: tr('video.home.continue'),
      items: home.recentPlay,
      progressOf: (it) => byId[it.id],
    );
  }

  Widget _libraryRowSection(BuildContext context, VideoHomeLibraryRow row) {
    return _hScroller(
      context,
      title: '${tr('video.home.recentAdd')} · ${row.libraryName}',
      items: row.items,
    );
  }

  Widget _hScroller(
    BuildContext context, {
    required String title,
    required List<VideoItem> items,
    double? Function(VideoItem)? progressOf,
  }) {
    final width = MediaQuery.of(context).size.width;
    final cardW = width < 480 ? 104.0 : width < 900 ? 120.0 : 136.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, title),
        SizedBox(
          height: cardW * 1.5 + 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceSm),
            itemBuilder: (context, i) => VideoPosterCard(
              item: items[i],
              width: cardW,
              progress: progressOf?.call(items[i]),
              onTap: () => _openAt(items, i),
              onMore: () => _openAt(items, i),
            ),
          ),
        ),
      ],
    );
  }
}
