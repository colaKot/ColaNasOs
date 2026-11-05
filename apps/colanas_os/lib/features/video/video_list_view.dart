import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'video_card.dart';
import 'video_detail_page.dart';
import 'video_scrape_dialogs.dart';

/// 影片列表（一个影库 / 全部库 / 某个人 / 某个类型）。
///
/// 对照参考实现 `app_video_list_page.dart` 的能力面：
///   顶栏：搜索（防抖）/ 排序 / 筛选 / 海报大小 / 竖版↔横版 / 刷新
///   网格：列宽由「海报大小 × 屏宽」算，格子比例按 2:3 或 3:2 **反算**（不在固定比例里裁图）
///   卡片：评分 / 番号 / 已看 / 收藏 / 画质徽章 / 进度 / 更多菜单
///   多选：全选 / 标记已看 / 退出
///
/// 排序与筛选全部走服务端（`/video/list` 的 sortBy / years / genres / regions / watched / scraped），
/// 客户端不做二次过滤 —— 否则分页游标会和筛选结果错位。
class VideoListView extends StatefulWidget {
  const VideoListView({
    super.key,
    this.libraryId,
    this.title,
    this.initialActor,
    this.initialDirector,
    this.initialGenre,
    this.initialFlag,
    this.embedded = false,
  });

  final String? libraryId;
  final String? title;
  final String? initialActor;
  final String? initialDirector;
  final String? initialGenre;
  final String? initialFlag;
  final bool embedded;

  @override
  State<VideoListView> createState() => _VideoListViewState();
}

class _VideoListViewState extends State<VideoListView> {
  /// 首屏只拉 4 行（6 列 × 4 = 24）；滚到底再续一页。
  /// 一次 60 条时，SMB 库上要连着出 60 张「首帧海报」，每张都要从网络盘读几个 MB，
  /// 打开列表能卡十几秒（2026-11-03 反馈）。宁可多拉几页，也别让首屏等图。
  static const _pageSize = 24;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<VideoItem> _items = const [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _q = '';
  int _total = 0;
  int _scraped = 0;
  /// itemId → 0..1 进度（继续观看画在卡片顶部）
  Map<String, double> _progress = const {};

  String _sortBy = 'name';
  String _sortOrder = 'asc';
  final Set<String> _years = {};
  final Set<String> _genres = {};
  final Set<String> _regions = {};
  bool? _watched;
  bool? _scrapedFilter;

  double _scale = 1.0;
  bool _fanart = false;

  bool _selectionMode = false;
  final Set<String> _selected = {};

  /// 每个库独立：海报大小 / 封面⇄缩略图都按库 id 记，不再串库
  String get _settingScope => widget.libraryId ?? 'all';
  String get _keyScale => 'video.lib.$_settingScope.posterScale';
  String get _keyFanart => 'video.lib.$_settingScope.fanart';

  @override
  void initState() {
    super.initState();
    // 只认本库自己的键：旧版本的全局键会串库，不再回退
    final savedScale = SettingsStore.instance.getInt(_keyScale) ?? 100;
    _scale = (savedScale / 100.0).clamp(0.7, 1.15);
    _fanart = SettingsStore.instance.getBool(_keyFanart) ?? false;
    if ((widget.initialGenre ?? '').isNotEmpty) _genres.add(widget.initialGenre!);
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
    // 提前一屏（约 2 行）预取：够顺滑，又不会一进页面就囤几页数据
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
      final c = ApiSession.instance.client;
      final page = await c.videoList(
        libraryId: widget.libraryId,
        q: _q.isEmpty ? null : _q,
        sortBy: _sortBy,
        sortOrder: _sortOrder,
        years: _years.isEmpty ? null : _years.join(','),
        genres: _genres.isEmpty ? null : _genres.join(','),
        regions: _regions.isEmpty ? null : _regions.join(','),
        actor: widget.initialActor,
        director: widget.initialDirector,
        flag: widget.initialFlag,
        watched: _watched == null ? null : (_watched! ? 'true' : 'false'),
        scraped: _scrapedFilter == null ? null : (_scrapedFilter! ? 'true' : 'false'),
        cursor: more ? _nextCursor : null,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...page.items] : page.items;
        _nextCursor = page.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
      if (!more) unawaited(_loadCount());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 计数 + 进度角标：两者都不影响列表主体，失败就静默降级
  Future<void> _loadCount() async {
    try {
      final c = await ApiSession.instance.client.videoListCount(
        libraryId: widget.libraryId,
      );
      if (!mounted) return;
      setState(() {
        _total = c.total;
        _scraped = c.scraped;
      });
    } catch (_) {
      // 计数失败不影响列表
    }
    try {
      final p = await ApiSession.instance.client.videoProgressList(
        libraryId: widget.libraryId,
        limit: 300,
      );
      if (!mounted) return;
      setState(() {
        _progress = {
          for (final it in p.items)
            if (it.percent > 0) it.itemId: (it.percent / 100).clamp(0.0, 1.0),
        };
      });
    } catch (_) {
      // 没有进度是常态
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

  Future<void> _toggleWatched(List<String> ids, bool watched) async {
    try {
      await ApiSession.instance.client.videoWatchMark(
        body: VideoWatchBody(ids: ids, watched: watched),
      );
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < _items.length; i++) {
          if (ids.contains(_items[i].id)) {
            _items[i] = VideoItem.fromJson({
              ..._items[i].toJson(),
              'watched': watched,
            });
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _scrapeAll() async {
    final count = _scraped == _total ? _total : _total - _scraped;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.home.scrapeAll')),
        content: Text(tr('video.scrape.batchConfirm', {'count': '$count'})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.ok'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    NasSnack.showOn(messenger, tr('common.loading'));
    try {
      final res = await ApiSession.instance.client.videoScrapeBatch(
        body: VideoScrapeBatchBody(
          libraryId: widget.libraryId,
          scope: 'missing',
          limit: 300,
        ),
      );
      NasSnack.showOn(
        messenger,
        tr('video.scrape.batchDone', {
          'scraped': '${res.scraped}',
          'skipped': '${res.skipped}',
          'notfound': '${res.notfound}',
          'unavailable': '${res.unavailable}',
        }),
        duration: const Duration(seconds: 5),
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  // ---------------------------------------------------------------- 顶栏

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
            Icons.sort_by_alpha,
            tr('video.list.sort'),
            _openSortSheet,
          ),
          _iconBtn(
            context,
            Icons.filter_alt_outlined,
            tr('video.list.filter'),
            _openFilterSheet,
            active: _years.isNotEmpty ||
                _genres.isNotEmpty ||
                _regions.isNotEmpty ||
                _watched != null ||
                _scrapedFilter != null,
          ),
          _iconBtn(
            context,
            _fanart ? Icons.crop_16_9 : Icons.crop_portrait,
            _fanart ? tr('video.list.showFanart') : tr('video.list.showPoster'),
            () {
              setState(() => _fanart = !_fanart);
              SettingsStore.instance.setBool(_keyFanart, _fanart);
            },
            active: _fanart,
          ),
          _iconBtn(context, Icons.auto_awesome_outlined, tr('video.home.scrapeAll'), _scrapeAll),
          PopupMenuButton<String>(
            tooltip: tr('video.card.more'),
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'scale') _openScaleSheet();
              if (v == 'refresh') _load();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'scale',
                child: Text(tr('video.list.posterSize')),
              ),
              PopupMenuItem(
                value: 'refresh',
                child: Text(tr('common.refresh')),
              ),
            ],
          ),
          if (_selectionMode)
            _iconBtn(context, Icons.close, tr('common.cancel'), () {
              setState(() {
                _selectionMode = false;
                _selected.clear();
              });
            }),
        ],
      ),
    );
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

  Widget _countLine(BuildContext context) {
    if (_total == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 0, NasTokens.spaceMd, NasTokens.spaceXs),
      child: Text(
        tr('video.list.count', {'count': '$_total', 'scraped': '$_scraped'}),
        style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasTextSecondary),
      ),
    );
  }

  // ---------------------------------------------------------------- 排序 / 筛选 / 缩放

  Future<void> _openSortSheet() async {
    const entries = <(String, String, String)>[
      ('name', 'asc', 'video.list.sort.nameAsc'),
      ('name', 'desc', 'video.list.sort.nameDesc'),
      ('createTime', 'desc', 'video.list.sort.createDesc'),
      ('createTime', 'asc', 'video.list.sort.createAsc'),
      ('viewTime', 'desc', 'video.list.sort.viewDesc'),
      ('year', 'desc', 'video.list.sort.yearDesc'),
      ('year', 'asc', 'video.list.sort.yearAsc'),
      ('score', 'desc', 'video.list.sort.scoreDesc'),
      ('score', 'asc', 'video.list.sort.scoreAsc'),
    ];
    final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final (by, order, label) in entries)
              ListTile(
                dense: true,
                leading: (_sortBy == by && _sortOrder == order)
                    ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                    : const SizedBox(width: 24),
                title: Text(tr(label)),
                onTap: () => Navigator.pop(ctx, (by, order)),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (!mounted) return;
    setState(() {
      _sortBy = picked.$1;
      _sortOrder = picked.$2;
    });
    await _load();
  }

  Future<void> _openFilterSheet() async {
    // 可选项从当前库里已有的值来（避免给一个空列表让用户无从下手）：
    // 拉 200 条已刮削条目聚合一下，够用且不额外加接口。
    Set<String> years = {};
    Set<String> genres = {};
    Set<String> regions = {};
    try {
      final sample = await ApiSession.instance.client.videoList(
        libraryId: widget.libraryId,
        limit: 200,
        sortBy: 'createTime',
        sortOrder: 'desc',
      );
      for (final it in sample.items) {
        if ((it.year ?? 0) > 0) years.add('${it.year}');
        genres.addAll(it.genres);
        regions.addAll(it.regions);
      }
    } catch (_) {
      // 取不到就只给「无年份 / 已刮削」这几个固定项
    }
    if (!mounted) return;
    final yearsSorted = years.toList()..sort((a, b) => b.compareTo(a));
    final result = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              Widget chips(String label, Iterable<String> values, Set<String> target, {String? emptyLabel}) {
                final list = values.toList();
                return Padding(
                  padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          NasChip(
                            label: Text(tr('video.list.filter.all')),
                            selected: target.isEmpty,
                            onSelected: (_) => setLocal(target.clear),
                          ),
                          for (final v in list)
                            NasChip(
                              label: Text(v),
                              selected: target.contains(v),
                              onSelected: (on) => setLocal(() {
                                if (on) {
                                  target.add(v);
                                } else {
                                  target.remove(v);
                                }
                              }),
                            ),
                          if (emptyLabel != null)
                            NasChip(
                              label: Text(emptyLabel),
                              selected: target.contains('0'),
                              onSelected: (on) => setLocal(() {
                                if (on) {
                                  target.add('0');
                                } else {
                                  target.remove('0');
                                }
                              }),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  NasTokens.spaceMd,
                  0,
                  NasTokens.spaceMd,
                  NasTokens.spaceMd,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (years.isEmpty && genres.isEmpty && regions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
                        child: Text(
                          tr('video.list.filter.empty'),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    chips(tr('video.list.filter.years'), yearsSorted, _years,
                        emptyLabel: tr('video.list.filter.noYear')),
                    chips(tr('video.list.filter.genres'), genres.toList()..sort(), _genres),
                    chips(tr('video.list.filter.regions'), regions.toList()..sort(), _regions),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        NasChip(
                          label: Text(tr('video.list.filter.scraped')),
                          selected: _scrapedFilter == true,
                          onSelected: (on) => setLocal(() => _scrapedFilter = on ? true : null),
                        ),
                        NasChip(
                          label: Text(tr('video.list.filter.unscraped')),
                          selected: _scrapedFilter == false,
                          onSelected: (on) => setLocal(() => _scrapedFilter = on ? false : null),
                        ),
                        NasChip(
                          label: Text(tr('video.list.filter.watched')),
                          selected: _watched == true,
                          onSelected: (on) => setLocal(() => _watched = on ? true : null),
                        ),
                        NasChip(
                          label: Text(tr('video.list.filter.unwatched')),
                          selected: _watched == false,
                          onSelected: (on) => setLocal(() => _watched = on ? false : null),
                        ),
                      ],
                    ),
                    const SizedBox(height: NasTokens.spaceSm),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => setLocal(() {
                            _years.clear();
                            _genres.clear();
                            _regions.clear();
                            _watched = null;
                            _scrapedFilter = null;
                          }),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(tr('video.list.reset')),
                        ),
                        const Spacer(),
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
        );
      },
    );
    if (result != true) return;
    await _load();
  }

  /// 海报大小：固定 150 高的紧凑弹窗。
  ///
  /// 为什么不用 `AlertDialog`：M3 的 AlertDialog 自带 title/content/actions 三段 padding
  /// 与 IntrinsicWidth，在窄屏上会被撑成整屏高度，里面只有一个滑块，看着像"空面板"
  /// （用户反馈「这个设置界面太大了」）。这里直接用 `Dialog` + 固定尺寸自己排版：
  /// 标题行（含百分比 / 重置）、滑块行、按钮行，一共 150 高，宽度仍是 360。
  Future<void> _openScaleSheet() async {
    // 上限收窄：原来 1.8 倍会把海报撑到两百多像素，整页显得过大
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
                    // 标题行：图标 + 标题 + 当前百分比 + 重置
                    // 不写死行高：系统字号放大时由内容撑开，靠下面的 Expanded 吸收差额
                    Row(
                      children: [
                        const Icon(Icons.aspect_ratio, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('video.list.posterSize'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
                          child: Text(tr('video.list.reset'), style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    // 滑块行：小图标 —— 滑轨 —— 大图标
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.photo_size_select_small,
                              size: 18, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(ctx).copyWith(
                                trackHeight: 3,
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
                          Icon(Icons.photo_size_select_large,
                              size: 18, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                    // 按钮行
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

  // ---------------------------------------------------------------- 网格

  Widget _grid(BuildContext context) {
    final p = _progressMap();
    return LayoutBuilder(
      builder: (context, c) {
        final maxWidth = c.maxWidth;
        final spacing = maxWidth < 480 ? 8.0 : 12.0;
        // 标题 + 副标题占的高度（两行 12/11 号字 + 间距），两种视图共用一个常量
        const textBlock = 42.0;
        // 列数由「海报大小 × 屏宽」算，不写死 2/4/6 —— 用户能调，屏越大越密
        final baseWidth = (maxWidth < 480 ? 108.0 : 132.0) * _scale;

        // 竖版海报：格子高 = 宽 × 1.5 + 文字区
        final posterTileHeight = baseWidth * 1.5 + textBlock;
        // 横版剧照（3:2）：**保持和竖版一样的格子高度**，靠变宽来换行数变少。
        // 之前两种模式都按「宽度优先」算列数，横版格子只有竖版的 2/3 高，
        // 一按「横版剧照」卡片反而变小、看不清 —— 这与用户预期正好相反。
        final targetWidth = _fanart ? (posterTileHeight - textBlock) * (3 / 2) : baseWidth;

        final columns = (maxWidth / targetWidth).floor().clamp(2, 9);
        final itemWidth = ((maxWidth - spacing * (columns - 1) - spacing) / columns).floorToDouble();
        // 关键：图片区按真实比例预留，再加标题两行的高度。
        // 旧实现写死 0.72 导致 2:3 海报被 BoxFit.cover 上下裁掉一截。
        final imageHeight = _fanart ? itemWidth / (3 / 2) : itemWidth * 1.5;
        final tileHeight = imageHeight + textBlock;
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
            final item = _items[i];
            final selected = _selected.contains(item.id);
            // 桌面 / Web 右键：与长按菜单同一批动作
            return NasContextMenuRegion(
              entries: _videoMenuEntries(item),
              child: VideoPosterCard(
              item: item,
              width: itemWidth,
              showFanart: _fanart,
              progress: p[item.id],
              selectionMode: _selectionMode,
              selected: selected,
              onTap: () {
                if (_selectionMode) {
                  setState(() {
                    if (selected) {
                      _selected.remove(item.id);
                    } else {
                      _selected.add(item.id);
                    }
                  });
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
              },
              onMore: () => _showCardMenu(item),
              ),
            );
          },
        );
      },
    );
  }

  Map<String, double> _progressMap() => _progress;

  Future<void> _showCardMenu(VideoItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: Icon(item.watched ? Icons.remove_done : Icons.done_all, size: 22),
              title: Text(
                item.watched
                    ? tr('video.action.markUnwatched')
                    : (item.series != null
                        ? tr('video.action.markTvWatched')
                        : tr('video.action.markWatched')),
              ),
              onTap: () => Navigator.pop(ctx, 'watched'),
            ),
            ListTile(
              leading: const Icon(Icons.checklist, size: 22),
              title: Text(tr('video.list.selected', {'count': '0'})),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new, size: 22),
              title: Text(tr('video.action.locateFile')),
              onTap: () => Navigator.pop(ctx, 'detail'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined, size: 22),
              title: Text(tr('video.action.scrape')),
              onTap: () => Navigator.pop(ctx, 'scrape'),
            ),
            ListTile(
              leading: const Icon(Icons.search, size: 22),
              title: Text(tr('video.action.matchTmdb')),
              onTap: () => Navigator.pop(ctx, 'match'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, size: 22),
              title: Text(tr('video.action.scrapeCleanup')),
              onTap: () => Navigator.pop(ctx, 'cleanup'),
            ),
            ListTile(
              leading: const Icon(Icons.block, size: 22),
              title: Text(tr('video.action.excludeScrape')),
              onTap: () => Navigator.pop(ctx, 'exclude'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await _videoAction(action, item);
  }

  /// 卡片右键菜单（桌面 / Web）：与长按菜单同一批动作
  List<NasMenuEntry> _videoMenuEntries(VideoItem item) => [
    NasMenuEntry(
      label: tr(
        item.watched
            ? 'video.action.markUnwatched'
            : (item.series != null
                  ? 'video.action.markTvWatched'
                  : 'video.action.markWatched'),
      ),
      icon: item.watched ? Icons.remove_done : Icons.done_all,
      onSelected: () => _videoAction('watched', item),
    ),
    NasMenuEntry(
      label: tr('video.list.selected', {'count': '0'}),
      icon: Icons.checklist,
      onSelected: () => _videoAction('select', item),
    ),
    NasMenuEntry(
      label: tr('video.action.locateFile'),
      icon: Icons.open_in_new,
      onSelected: () => _videoAction('detail', item),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('video.action.scrape'),
      icon: Icons.auto_awesome_outlined,
      onSelected: () => _videoAction('scrape', item),
    ),
    NasMenuEntry(
      label: tr('video.action.matchTmdb'),
      icon: Icons.search,
      onSelected: () => _videoAction('match', item),
    ),
    NasMenuEntry(
      label: tr('video.action.scrapeCleanup'),
      icon: Icons.delete_outline,
      onSelected: () => _videoAction('cleanup', item),
    ),
    NasMenuEntry(
      label: tr('video.action.excludeScrape'),
      icon: Icons.block,
      onSelected: () => _videoAction('exclude', item),
    ),
  ];

  /// 长按菜单与右键菜单共用的动作分发（原来内联在 _showCardMenu 里）
  Future<void> _videoAction(String action, VideoItem item) async {
    switch (action) {
      case 'watched':
        await _toggleWatched([item.id], !item.watched);
      case 'select':
        setState(() {
          _selectionMode = true;
          _selected
            ..clear()
            ..add(item.id);
        });
      case 'detail':
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => VideoDetailPage(
              item: item,
              posterUrl: videoPosterUrl(item),
              headers: videoArtHeaders,
            ),
          ),
        );
      case 'scrape':
        await _scrapeOne(item);
      case 'match':
        final ok = await showTmdbMatchDialog(context, item: item);
        if (ok) await _load();
      case 'cleanup':
        try {
          await ApiSession.instance.client.videoScrapeCleanup(
            body: VideoScrapeCleanupBody(id: item.id),
          );
          if (!mounted) return;
          NasSnack.show(context, tr('video.scrape.cleaned'));
          await _load();
        } catch (e) {
          if (!mounted) return;
          NasSnack.show(context, '$e');
        }
      case 'exclude':
        try {
          await ApiSession.instance.client.videoScrapeMatch(
            body: VideoMatchNfoBody(id: item.id, match: false),
          );
          if (!mounted) return;
          NasSnack.show(context, tr('video.scrape.excluded'));
        } catch (e) {
          if (!mounted) return;
          NasSnack.show(context, '$e');
        }
    }
  }

  Future<void> _scrapeOne(VideoItem item) async {
    try {
      final res = await ApiSession.instance.client.videoScrapeStart(
        body: VideoScrapeBody(id: item.id),
      );
      if (!mounted) return;
      await showScrapeOutcome(context, res);
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Widget _selectionBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd, vertical: 4),
      child: Row(
        children: [
          Text(tr('video.list.selected', {'count': '${_selected.length}'})),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              _selected
                ..clear()
                ..addAll(_items.map((e) => e.id));
            }),
            child: Text(tr('video.list.filter.all')),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => _toggleWatched(_selected.toList(), true),
            child: Text(tr('video.action.markWatched')),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => _toggleWatched(_selected.toList(), false),
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

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _toolbar(context),
        _countLine(context),
        if (_selectionMode) _selectionBar(context),
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
                  ? NasErrorState(message: _error!, onRetry: () => _load())
                  : _items.isEmpty
                      ? ListView(
                          children: [
                            NasEmptyState(
                              title: tr('common.empty'),
                              icon: Icons.movie_outlined,
                            ),
                          ],
                        )
                      : RefreshIndicator(
                          onRefresh: () => _load(),
                          child: _grid(context),
                        ),
        ),
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.all(NasTokens.spaceSm),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? tr('app.video'))),
      body: body,
    );
  }
}

/// 打开「某个人的作品」列表（演员 / 导演）。从详情页的人物 chip 进来。
Future<void> openVideoListByPerson(
  BuildContext context, {
  required String kind,
  required String name,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideoListView(
        title: name,
        initialActor: kind == 'actor' ? name : null,
        initialDirector: kind == 'director' ? name : null,
      ),
    ),
  );
}
