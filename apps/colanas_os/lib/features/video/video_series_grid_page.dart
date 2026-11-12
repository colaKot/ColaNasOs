import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'video_card.dart';
import 'series_display.dart';
import 'video_collection_picker.dart';
import 'video_series_actions.dart';
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

  /// 排序 / 筛选（全部走服务端：剧是聚合出来的，客户端排序会把分页搞乱）
  String _sortBy = 'name';
  String _sortOrder = 'asc';
  String _watched = 'all';

  /// 多选：剧是聚合卡，选中记的是**剧名**，动作落到「这部剧的每一集」
  bool _selectionMode = false;
  final Set<String> _selected = {};
  bool _busy = false;

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

  Future<void> _load({bool more = false, bool silent = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else if (!silent) {
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
        sortBy: _sortBy,
        sortOrder: _sortOrder,
        watched: _watched == 'all' ? null : _watched,
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
        if (_selectionMode) _selectionBar(context),
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

  /// 顶栏：搜索（收窄，不再吃掉整行）+ 筛选 + 排序 + 更多。
  ///
  /// 「更多」里是与影片列表同一组低频操作：多选 / 海报大小 / 刷新 / 搜刮全部；
  /// 常驻的只有筛选与排序 —— 剧库最常做的就是「只看没看完的」和「按集数排」。
  Widget _toolbar(BuildContext context) {
    final hasFilter = _watched != 'all';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Flexible(
            child: SizedBox(
              width: 280,
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
          const Spacer(),
          _iconBtn(
            context,
            Icons.filter_alt_outlined,
            tr('video.list.filter'),
            _openFilterSheet,
            active: hasFilter,
          ),
          _iconBtn(
            context,
            Icons.sort_by_alpha,
            tr('video.list.sort'),
            _openSortSheet,
            active: _sortBy != 'name' || _sortOrder != 'asc',
          ),
          PopupMenuButton<String>(
            tooltip: tr('video.card.more'),
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'select') {
                setState(() {
                  _selectionMode = true;
                  _selected.clear();
                });
              }
              if (v == 'scale') _openScaleSheet();
              if (v == 'refresh') _load();
              if (v == 'scrape') _scrapeAll();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'select',
                child: Text(tr('video.list.multiSelect')),
              ),
              PopupMenuItem(
                value: 'scale',
                child: Text(tr('video.list.posterSize')),
              ),
              PopupMenuItem(
                value: 'refresh',
                child: Text(tr('common.refresh')),
              ),
              PopupMenuItem(
                value: 'scrape',
                child: Text(tr('video.home.scrapeAll')),
              ),
            ],
          ),
          if (_selectionMode)
            _iconBtn(
              context,
              Icons.close,
              tr('common.cancel'),
              () => setState(() {
                _selectionMode = false;
                _selected.clear();
              }),
            ),
        ],
      ),
    );
  }

  /// 筛选：观看状态三态（与角标、进度条同一口径）
  Future<void> _openFilterSheet() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                0,
                NasTokens.spaceMd,
                NasTokens.spaceSm,
              ),
              child: Text(
                tr('video.list.filter'),
                style: const TextStyle(
                  fontSize: NasTokens.fontSubtitle,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final (value, labelKey) in <(String, String)>[
              ('all', 'video.list.filter.all'),
              ('unwatched', 'video.series.watch.none'),
              ('watching', 'video.series.watch.partial'),
              ('watched', 'video.series.watch.done'),
            ])
              ListTile(
                title: Text(tr(labelKey)),
                leading: Icon(
                  value == _watched
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                ),
                selected: value == _watched,
                onTap: () => Navigator.pop(ctx, value),
              ),
            const SizedBox(height: NasTokens.spaceXs),
          ],
        ),
      ),
    );
    if (picked == null || !mounted || picked == _watched) return;
    setState(() => _watched = picked);
    await _load();
  }

  /// 排序：剧名 / 最近更新 / 集数 / 季数（升序降序都在同一张表里选）
  Future<void> _openSortSheet() async {
    const options = <(String, String, String)>[
      ('name', 'asc', 'video.list.sort.nameAsc'),
      ('name', 'desc', 'video.list.sort.nameDesc'),
      ('updated', 'desc', 'video.series.sort.updated'),
      ('episodes', 'desc', 'video.series.sort.episodes'),
      ('seasons', 'desc', 'video.series.sort.seasons'),
    ];
    final current = '$_sortBy|$_sortOrder';
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (by, order, labelKey) in options)
              ListTile(
                leading: Icon(
                  current == '$by|$order'
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                ),
                title: Text(tr(labelKey)),
                selected: current == '$by|$order',
                onTap: () => Navigator.pop(ctx, '$by|$order'),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final parts = picked.split('|');
    setState(() {
      _sortBy = parts[0];
      _sortOrder = parts[1];
    });
    await _load();
  }

  Widget _iconBtn(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 19,
      visualDensity: VisualDensity.compact,
      style: active
          ? IconButton.styleFrom(backgroundColor: scheme.primary.withValues(alpha: 0.14))
          : null,
      icon: Icon(icon, color: active ? scheme.primary : null),
    );
  }

  // ------------------------------------------------------------ 多选 / 批量

  /// 选中剧名的 → 每一集的 id（剧级动作最终都要落到条目上）
  Future<List<String>> _episodeIdsOf(Iterable<String> names) async {
    final out = <String>[];
    for (final name in names) {
      final eps = await loadSeriesEpisodes(name, libraryId: widget.libraryId);
      out.addAll(eps.map((e) => e.id));
    }
    return out;
  }

  Future<void> _markSelected(bool watched) async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final ids = await _episodeIdsOf(_selected.toList());
      if (!mounted) return;
      await markVideos(
        context,
        ids,
        watched: watched,
        count: ids.length,
        onChanged: () => _load(silent: true),
      );
      if (mounted) {
        setState(() {
          _selectionMode = false;
          _selected.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 加入合集：只在**最外层（整部剧封面）**提供 —— 合集里存的是条目 id，
  /// 把整部剧的每一集都放进去，点开合集才能在合集里连着看。
  Future<void> _addSelectedToCollection() async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final ids = await _episodeIdsOf(_selected.toList());
      if (!mounted || ids.isEmpty) return;
      await showAddToCollectionDialog(context, itemIds: ids);
      if (mounted) {
        setState(() {
          _selectionMode = false;
          _selected.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 搜刮全部：只刮**当前已加载**的剧（翻到哪刮到哪），整库几千集一次丢进去
  /// 会撞 30s 超时，而且用户也很难判断「到底刮了多少」。
  Future<void> _scrapeAll() async {
    if (_items.isEmpty) return;
    final ids = await _episodeIdsOf(_items.map((s) => s.name));
    if (!mounted || ids.isEmpty) return;
    await scrapeVideos(context, ids, onChanged: () => _load(silent: true));
  }

  Widget _selectionBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = _selected.isEmpty || _busy;
    return Container(
      color: scheme.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceMd,
        vertical: 4,
      ),
      child: Row(
        children: [
          Text(tr('video.list.selected', {'count': '${_selected.length}'})),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              _selected
                ..clear()
                ..addAll(_items.map((e) => e.name));
            }),
            child: Text(tr('video.list.filter.all')),
          ),
          TextButton(
            onPressed: empty ? null : _addSelectedToCollection,
            child: Text(tr('video.collection.addTo')),
          ),
          TextButton(
            onPressed: empty ? null : () => _markSelected(true),
            child: Text(tr('video.action.markWatched')),
          ),
          TextButton(
            onPressed: empty ? null : () => _markSelected(false),
            child: Text(tr('video.action.markUnwatched')),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: tr('common.cancel'),
            onPressed: () => setState(() {
              _selectionMode = false;
              _selected.clear();
            }),
          ),
        ],
      ),
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
            final selected = _selected.contains(s.name);
            // 桌面右键：整部剧口径的菜单（标记已看 / 定位文件 / 删除整部剧）
            return NasAsyncMenuRegion(
              entries: () => seriesMenuEntries(
                context,
                s,
                libraryId: widget.libraryId,
                onChanged: () => _load(silent: true),
              ),
              child: SeriesPosterCard(
                item: s,
                width: itemWidth,
                selectionMode: _selectionMode,
                selected: selected,
                onSelectToggle: () => setState(() {
                  if (selected) {
                    _selected.remove(s.name);
                  } else {
                    _selected.add(s.name);
                  }
                }),
                onTap: () => openVideoSeries(
                  context,
                  name: s.name,
                  coverId: s.coverId,
                  // 剧封面只认竖版海报那一集，没有就交给 TMDB 剧海报
                  posterId: s.posterId,
                  libraryId: widget.libraryId,
                  headers: videoArtHeaders,
                ),
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
    this.watchedEpisodes,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectToggle,
  });

  final VideoSeriesItem item;
  final double width;
  final VoidCallback onTap;

  /// 当前用户已看集数（服务端按 owner 汇总）；为空时按 0 处理
  final int? watchedEpisodes;

  /// 多选态：左上角换成勾选框，点击不再是打开剧详情
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectToggle;

  @override
  Widget build(BuildContext context) {
    final wantSize = (width * 2).round();
    final watched = (watchedEpisodes ?? item.watchedEpisodes ?? 0).clamp(0, item.episodes);
    final state = seriesWatchStateOf(watched, item.episodes);
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: selectionMode ? onSelectToggle : onTap,
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
                      // 只认「真有竖版海报的那一集」；整部剧都没刮到海报时
                      // 退到 TMDB 剧海报，最后才是文字占位 —— 绝不用剧照凑
                      artUrl: seriesArtUrl(
                        item.posterId,
                        size: wantSize,
                      ),
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
                  // 左上角：多选勾选框 / 观看三态（未看 · 已看 n/m · 已看完）
                  Positioned(
                    top: 6,
                    left: 6,
                    child: selectionMode
                        ? SeriesSelectChip(selected: selected)
                        : SeriesWatchBadge(
                            watched: watched,
                            total: item.episodes,
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
                  // 看了一半的剧，底部留一条细进度，扫一眼就知道追到哪儿
                  if (state == SeriesWatchState.partial)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(NasTokens.radiusSm),
                        ),
                        child: LinearProgressIndicator(
                          value: item.episodes > 0 ? watched / item.episodes : 0,
                          minHeight: 3,
                          backgroundColor: Colors.black26,
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
