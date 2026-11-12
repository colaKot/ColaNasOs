import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import 'detail/video_detail_router.dart';
import 'series_display.dart';
import 'video_card.dart';
import 'video_item_actions.dart';
import 'video_page.dart';
import 'video_series_actions.dart';
import 'video_series_widgets.dart';

/// 智能合集（预设规则）：最近添加 / 未看 / 继续观看 / 4K / HDR / 全景声 / 长片。
///
/// 计数与条目由后端同一份 SQL 条件算出（`/video/smart-albums` + `/items`），
/// 不做「前端拉全库再过滤」，避免大库卡顿与计数不一致。
class VideoSmartAlbumsPage extends StatefulWidget {
  const VideoSmartAlbumsPage({super.key});

  @override
  State<VideoSmartAlbumsPage> createState() => _VideoSmartAlbumsPageState();
}

class _VideoSmartAlbumsPageState extends State<VideoSmartAlbumsPage> {
  static const _defs = <(String, String, IconData)>[
    ('recent30', 'video.smart.recent30', Icons.fiber_new_outlined),
    ('continue', 'video.smart.continue', Icons.play_circle_outline),
    ('unwatched', 'video.smart.unwatched', Icons.visibility_off_outlined),
    ('4k', 'video.smart.4k', Icons.hd_outlined),
    ('hdr', 'video.smart.hdr', Icons.hdr_on),
    ('atmos', 'video.smart.atmos', Icons.surround_sound_outlined),
    ('long', 'video.smart.long', Icons.timelapse_outlined),
  ];

  bool _loading = true;
  String? _error;
  Map<String, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoSmartAlbums();
      if (!mounted) return;
      setState(() {
        _counts = {for (final s in res.items) s.key: s.count};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _open(String key, String labelKey) {
    final title = tr(labelKey);
    final router = VideoDetailRouter.instance;
    if (router.embeddableFrom(context)) {
      router.open(
        VideoDetailEntry(
          tag: 'smart:$key',
          build: (_) => _SmartAlbumItemsPage(
            albumKey: key,
            title: title,
            embedded: true,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SmartAlbumItemsPage(albumKey: key, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('video.smart.hint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              mainAxisSpacing: NasTokens.spaceSm,
              crossAxisSpacing: NasTokens.spaceSm,
              childAspectRatio: 1.6,
            ),
            itemCount: _defs.length,
            itemBuilder: (context, i) {
              final (key, labelKey, icon) = _defs[i];
              final count = _counts[key] ?? 0;
              return NasContextMenuRegion(
                entries: [
                  NasMenuEntry(
                    label: tr('common.open'),
                    icon: Icons.open_in_new,
                    onSelected: count == 0
                        ? null
                        : () => _open(key, labelKey),
                  ),
                  NasMenuEntry(
                    label: tr('common.refresh'),
                    icon: Icons.refresh,
                    onSelected: _load,
                  ),
                ],
                child: NasCard(
                  onTap: count == 0 ? null : () => _open(key, labelKey),
                  padding: const EdgeInsets.all(NasTokens.spaceMd),
                  child: Row(
                    children: [
                      Icon(icon, size: NasTokens.iconXl),
                      const SizedBox(width: NasTokens.spaceSm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              tr(labelKey),
                              style: const TextStyle(
                                fontSize: NasTokens.fontSubtitle,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: NasTokens.spaceXs),
                            Text(
                              tr('video.smart.count', {'count': count}),
                              style: TextStyle(
                                fontSize: NasTokens.fontCaption,
                                color: count == 0
                                    ? context.nasTextSecondary
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 智能合集里的条目：海报墙，点开详情。
class _SmartAlbumItemsPage extends StatefulWidget {
  const _SmartAlbumItemsPage({
    required this.albumKey,
    required this.title,
    this.embedded = false,
  });

  final String albumKey;
  final String title;

  /// true = 三级页（顶栏交给外壳，标题做成页内页头）
  final bool embedded;

  @override
  State<_SmartAlbumItemsPage> createState() => _SmartAlbumItemsPageState();
}

class _SmartAlbumItemsPageState extends State<_SmartAlbumItemsPage> {
  bool _loading = true;
  String? _error;
  List<VideoItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoSmartAlbumItems(
        key: widget.albumKey,
        limit: 120,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 与其它影视列表共用同一套影片动作（右键 + 长按）。
  /// 智能合集是按已看/未看筛出来的，动作后一律重拉，避免条目和计数对不上。
  Future<void> _runAction(VideoItem item, String action) async {
    final changed = await runVideoItemAction(context, action, item);
    if (changed && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            NasRefreshButton(onPressed: _load),
          ],
        ),
        body: body,
      );
    }

    // 三级页：顶栏交给外壳，标题 + 刷新做成页内页头；底色必须自己铺
    //（本项目 `scaffoldBackgroundColor` 是透明的，不铺会漏出下面的列表）
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(child: context.nasStyle.background),
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NasTokens.spaceMd,
                    NasTokens.spaceSm,
                    NasTokens.spaceXs,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: NasTokens.fontSubtitle,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      NasRefreshButton(onPressed: _load),
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    return _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _items.isEmpty
                  ? ListView(
                      children: [
                        NasEmptyState(
                          title: tr('video.smart.empty'),
                          icon: Icons.movie_outlined,
                        ),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, c) {
                        final columns = gridColumns(c.maxWidth);
                        return GridView.builder(
                          padding: const EdgeInsets.all(NasTokens.spaceSm),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: NasTokens.spaceSm,
                            mainAxisSpacing: NasTokens.spaceSm,
                            childAspectRatio: 0.72,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            // 服务端把电视剧按剧聚合过：这一条代表整部剧
                            // （一部剧一张卡），封面用竖版海报，不是某一集的截图
                            final info = item.seriesInfo;
                            if (info != null) return _seriesCard(context, item, info);
                            return _movieCard(context, item);
                          },
                        );
                      },
                    );
  }

  /// 剧卡：整部剧一张竖版封面（有刮削海报就用它，没有退 TMDB 剧海报）
  Widget _seriesCard(
    BuildContext context,
    VideoItem item,
    VideoSeriesItem info,
  ) {
    final name = SeriesDisplayStore.nameOf(info.name) ?? info.name;
    return NasAsyncMenuRegion(
      entries: () => seriesMenuEntries(
        context,
        info,
        libraryId: item.libraryId,
        onChanged: () => _load(),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: () => openVideoSeries(
          context,
          name: info.name,
          coverId: info.coverId,
          posterId: info.posterId,
          libraryId: item.libraryId,
          headers: videoArtHeaders,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                    child: SeriesCoverImage(
                      artUrl: seriesArtUrl(info.posterId, size: 480),
                      posterUrl: SeriesDisplayStore.posterOf(info.name),
                      fallbackText: name,
                      cacheWidth: 480,
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: SeriesWatchBadge(
                      watched: info.watchedEpisodes ?? 0,
                      total: info.episodes,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: NasTokens.spaceXs),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: NasTokens.fontBody),
            ),
            Text(
              tr('video.seasonsEpisodes', {
                'seasons': '${info.seasons}',
                'episodes': '${info.episodes}',
              }),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _movieCard(BuildContext context, VideoItem item) {
    return NasContextMenuRegion(
      entries: videoItemMenuEntries(
        item,
        onAction: (a) => _runAction(item, a),
        context: context,
      ),
      child: GestureDetector(
        onLongPress: () async {
          final a = await showVideoItemActionSheet(context, item);
          if (a != null && mounted) {
            await _runAction(item, a);
          }
        },
        child: InkWell(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          onTap: () => openVideoDetail(context, item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  child: NasCoverImage(
                    // 刮削海报优先；没有海报时服务端会退到缩略图 / 首帧，
                    // 但绝不再直接拿 `/video/poster`（那是视频截图）
                    url: videoPosterUrl(item, kind: 'poster', size: 480),
                    headers: videoArtHeaders,
                    cacheWidth: 480,
                    icon: Icons.movie_outlined,
                  ),
                ),
              ),
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: NasTokens.fontBody),
              ),
              MediaFlagsRow(item: item, compact: true),
            ],
          ),
        ),
      ),
    );
  }
}
