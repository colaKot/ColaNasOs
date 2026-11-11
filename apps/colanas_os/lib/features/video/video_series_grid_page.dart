import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'video_card.dart';
import 'series_display.dart';
import 'video_series_detail_page.dart';
import 'video_series_widgets.dart';

/// 电视剧库的列表：**一部剧一张卡**。
///
/// 为什么不用 `VideoListView`：那个页面是「一个文件一张卡」，一部剧 40 集会铺
/// 40 张卡，列表完全没法看（用户 2026-11-11 反馈）。这里改成按剧聚合，
/// 右上角圆角标显示总集数，点进去才分层看季 / 集。
class VideoSeriesGridPage extends StatefulWidget {
  const VideoSeriesGridPage({
    super.key,
    required this.libraryId,
    this.embedded = false,
  });

  final String libraryId;
  final bool embedded;

  @override
  State<VideoSeriesGridPage> createState() => _VideoSeriesGridPageState();
}

class _VideoSeriesGridPageState extends State<VideoSeriesGridPage> {
  /// 一屏 6 列 × 4 行 = 24 部剧；和影片列表同一口径，不一次拉全库
  static const _pageSize = 24;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<VideoSeriesItem> _items = const [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _q = '';
  double _scale = 1.0;

  String get _keyScale => 'video.lib.${widget.libraryId}.seriesScale';

  @override
  void initState() {
    super.initState();
    // 剧中文名 / TMDB 竖版海报是展示层补充，拉到后重画一次即可
    SeriesDisplayStore.ensure().then((_) {
      if (mounted) setState(() {});
    });
    final saved = SettingsStore.instance.getInt(_keyScale) ?? 100;
    _scale = (saved / 100.0).clamp(0.7, 1.15);
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || _nextCursor == null) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final res = await ApiSession.instance.client.videoSeriesList(
        libraryId: widget.libraryId,
        q: _q.isEmpty ? null : _q,
        cursor: more ? _nextCursor : null,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...res.items] : res.items;
        _nextCursor = res.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      setState(() => _q = v.trim());
      _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _toolbar(context),
        Expanded(child: _body(context)),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('app.video'))),
      body: body,
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: () => _load());
    }
    if (_items.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.nav.emptyFiles'),
            icon: Icons.video_library_outlined,
          ),
        ],
      );
    }
    return _grid(context);
  }

  Widget _toolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: tr('video.list.searchHint'),
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _q = '');
                            _load();
                          },
                        ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          ),
          const SizedBox(width: NasTokens.spaceXs),
          _iconBtn(
            context,
            Icons.photo_size_select_large,
            tr('video.list.posterSize'),
            _openScaleSheet,
          ),
          _iconBtn(
            context,
            Icons.refresh,
            tr('common.refresh'),
            () => _load(),
          ),
        ],
      ),
    );
  }

  Widget _iconBtn(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _grid(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxWidth = c.maxWidth;
        final spacing = maxWidth < 480 ? 8.0 : 12.0;
        const textBlock = 42.0;
        final baseWidth = (maxWidth < 480 ? 108.0 : 132.0) * _scale;
        final columns = (maxWidth / baseWidth).floor().clamp(2, 9);
        final itemWidth =
            ((maxWidth - spacing * (columns - 1) - spacing) / columns)
                .floorToDouble();
        final tileHeight = itemWidth * 1.5 + textBlock;
        return GridView.builder(
          controller: _scroll,
          padding: EdgeInsets.all(spacing),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: itemWidth / tileHeight,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final s = _items[i];
            return SeriesPosterCard(
              item: s,
              width: itemWidth,
              onTap: () => openVideoSeries(
                context,
                name: s.name,
                coverId: s.coverId,
                libraryId: widget.libraryId,
                headers: videoArtHeaders,
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openScaleSheet() async {
    var value = _scale.clamp(0.7, 1.15);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 360,
          height: 150,
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              final pct = (value * 100).round();
              return Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.aspect_ratio, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('video.list.posterSize'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '$pct%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () => setLocal(() => value = 1.0),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 28),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            tr('video.list.reset'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Icon(
                            Icons.photo_size_select_small,
                            size: 18,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(ctx).copyWith(
                                trackHeight: 3,
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                              ),
                              child: Slider(
                                value: value,
                                min: 0.7,
                                max: 1.15,
                                divisions: 9,
                                label: '$pct%',
                                onChanged: (v) => setLocal(() => value = v),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.photo_size_select_large,
                            size: 18,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(tr('common.cancel')),
                        ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(tr('common.ok')),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    setState(() => _scale = value);
    await SettingsStore.instance.setInt(_keyScale, (value * 100).round());
  }
}

/// 剧卡片：海报 + 右上角「总集数」圆角标 + 剧名 + 季/集数。
class SeriesPosterCard extends StatelessWidget {
  const SeriesPosterCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
  });

  final VideoSeriesItem item;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wantSize = (width * 2).round();
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, box) {
            final bounded = box.maxHeight.isFinite;
            final poster = AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                    child: SeriesCoverImage(
                      artUrl: seriesArtUrl(item.coverId, size: wantSize),
                      // 本地竖版海报拿不到就用 TMDB 剧海报，仍不要用横版剧照
                      posterUrl: SeriesDisplayStore.posterOf(item.name),
                      fallbackText:
                          SeriesDisplayStore.nameOf(item.name) ?? item.name,
                      cacheWidth: wantSize,
                    ),
                  ),
                  // 底部渐变：让角标在任何封面上都读得清
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            NasTokens.radiusSm,
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.6),
                              Colors.transparent,
                            ],
                            stops: const [0, 0.4],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 右上角：总集数（用户 2026-11-11 指定样式：半透明圆形角标）
                  if (item.episodes > 0)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 26),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2AA7B8).withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Text(
                          '${item.episodes}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
            return Column(
              mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bounded)
                  Flexible(fit: FlexFit.loose, child: poster)
                else
                  poster,
                const SizedBox(height: 4),
                Text(
                  SeriesDisplayStore.nameOf(item.name) ?? item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  tr('video.seasonsEpisodes', {
                    'seasons': '${item.seasons}',
                    'episodes': '${item.episodes}',
                  }),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
