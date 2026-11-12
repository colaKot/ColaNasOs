import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../shell/app_widgets.dart';
import 'detail/video_detail_router.dart';
import 'video_card.dart';
import 'video_collection_picker.dart';
import 'cola_video_detail_page.dart';
import 'video_genre_labels.dart';
import 'video_item_actions.dart';
import 'video_jp_filters.dart';
import 'video_region_labels.dart';
import 'video_scrape_dialogs.dart';

/// 影片列表（一个影库 / 全部库 / 某个人 / 某个类型）。
///
/// 对照既有实现 `app_video_list_page.dart` 的能力面：
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
    this.embeddedHeader,
    this.jp = false,
    this.initialJpFilter,
  });

  final String? libraryId;
  final String? title;
  final String? initialActor;
  final String? initialDirector;
  final String? initialGenre;
  final String? initialFlag;
  final bool embedded;

  /// 嵌入且**作为三级页**时显示的页内标题（人物作品列表用）。
  /// 二级内容区不需要：那时标题在外壳顶栏上，这里留空就不画。
  final String? embeddedHeader;

  /// 日本电影库：四维筛选（分辨率 / 标签 / 来源 / 题材）也在顶栏筛选按钮里；
  /// 所有库都不显示「已刮削 N 部」计数行，给网格腾出高度。
  final bool jp;

  /// 从演员页切过来时的初始筛选（只作初值，之后各视图独立）
  final VideoJpFilter? initialJpFilter;

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

  /// 日本库专用筛选（空串 = 全部）。「题材」复用 `_genres`（单选 → 集合里最多一个），
  /// 这样通用筛选面板和这一行永远是同一份状态，不会互相打架。
  String _resolution = '';
  String _jpTag = '';
  String _sourceId = '';

  /// 筛选选项 + 条数：点开筛选入口时按需拉一次，之后复用
  VideoFacetsResponse? _facets;
  Future<VideoFacetsResponse?>? _facetsPending;

  double _scale = 1.0;
  bool _fanart = false;

  /// 多选：全站统一由 `NasSelectionController` 承载（进入 / 切换 / 全选 / 退出）
  final NasSelectionController _selection = NasSelectionController();
  bool get _selectionMode => _selection.active;
  Set<String> get _selected => _selection.ids;

  /// 每个库独立：海报大小 / 封面⇄缩略图都按库 id 记，不再串库
  String get _settingScope => widget.libraryId ?? 'all';
  String get _keyScale => 'video.lib.$_settingScope.posterScale';
  String get _keyFanart => 'video.lib.$_settingScope.fanart';

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    // 只认本库自己的键：旧版本的全局键会串库，不再回退
    final savedScale = SettingsStore.instance.getInt(_keyScale) ?? 100;
    _scale = (savedScale / 100.0).clamp(0.7, 1.15);
    _fanart = SettingsStore.instance.getBool(_keyFanart) ?? false;
    if ((widget.initialGenre ?? '').isNotEmpty) _genres.add(widget.initialGenre!);
    // 演员页切过来时沿用同一份筛选，避免两个视图口径不一致
    final jf = widget.initialJpFilter;
    if (jf != null) {
      _resolution = jf.resolution;
      _jpTag = jf.jpTag;
      _sourceId = jf.sourceId;
      if (jf.genre.isNotEmpty) {
        _genres
          ..clear()
          ..add(jf.genre);
      }
    }
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChanged)
      ..dispose();
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
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
        resolution: _resolution.isEmpty ? null : _resolution,
        jpTag: _jpTag.isEmpty ? null : _jpTag,
        sourceId: _sourceId.isEmpty ? null : _sourceId,
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
      if (!more) {
        unawaited(_loadCount());
        // facets 供筛选面板出选项，首屏就拉一次；有缓存时直接命中不发请求
        unawaited(_loadFacets());
      }
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

  /// 顶栏：搜索（弹性拉满）+ 筛选 / 排序 / 视图 + 更多，按钮组整体靠右。
  ///
  /// 与剧库列表保持同一套排布：窄屏放不下时常驻按钮收进「更多」，
  /// 搜索框继续弹性伸缩，整行不溢出。
  Widget _toolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          final hasFilter = _years.isNotEmpty ||
              _genres.isNotEmpty ||
              _regions.isNotEmpty ||
              _watched != null ||
              _scrapedFilter != null ||
              _resolution.isNotEmpty ||
              _jpTag.isNotEmpty ||
              _sourceId.isNotEmpty;
          return Row(
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
              const SizedBox(width: NasTokens.spaceSm),
              if (!compact) ...[
                // 筛选放排序前面：先收窄范围再决定怎么排，是更自然的操作顺序
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
                ),
                _iconBtn(
                  context,
                  _fanart ? Icons.crop_16_9 : Icons.crop_portrait,
                  _fanart
                      ? tr('video.list.showFanart')
                      : tr('video.list.showPoster'),
                  () {
                    setState(() => _fanart = !_fanart);
                    SettingsStore.instance.setBool(_keyFanart, _fanart);
                  },
                  active: _fanart,
                ),
              ],
              PopupMenuButton<String>(
                tooltip: tr('video.card.more'),
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  if (v == 'filter') _openFilterSheet();
                  if (v == 'sort') _openSortSheet();
                  if (v == 'view') {
                    setState(() => _fanart = !_fanart);
                    SettingsStore.instance.setBool(_keyFanart, _fanart);
                  }
                  if (v == 'scale') _openScaleSheet();
                  if (v == 'refresh') _load();
                  if (v == 'scrape') _scrapeAll();
                  if (v == 'select') _selection.enter();
                },
                itemBuilder: (_) => [
                  // 窄屏把常驻的筛选 / 排序 / 视图收进来
                  if (compact) ...[
                    PopupMenuItem(
                      value: 'filter',
                      child: Text(tr('video.list.filter')),
                    ),
                    PopupMenuItem(
                      value: 'sort',
                      child: Text(tr('video.list.sort')),
                    ),
                    PopupMenuItem(
                      value: 'view',
                      child: Text(
                        _fanart
                            ? tr('video.list.showPoster')
                            : tr('video.list.showFanart'),
                      ),
                    ),
                    const PopupMenuDivider(),
                  ],
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
                  // 低频但耗时：从常驻按钮收进「更多」，顶栏留筛选 / 排序 / 视图
                  PopupMenuItem(
                    value: 'scrape',
                    child: Text(tr('video.home.scrapeAll')),
                  ),
                ],
              ),
              if (_selectionMode)
                _iconBtn(context, Icons.close, tr('common.cancel'), _selection.exit),
            ],
          );
        },
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

  // ---------------------------------------------------------------- 筛选面板辅助

  /// 当前「题材」：通用筛选面板是复选，这一行只认第一个（单选语义）
  String get _jpGenre => _genres.isEmpty ? '' : _genres.first;

  String _jpTagLabel(String key) => switch (key) {
    'uncensored' => tr('video.filter.uncensored'),
    'cracked' => tr('video.filter.cracked'),
    'ltx' => tr('video.filter.ltx'),
    _ => key,
  };

  /// 选项 + 条数只在第一次点开时拉；同时点两下也只会发一次请求
  Future<VideoFacetsResponse?> _loadFacets() {
    final cached = _facets;
    if (cached != null) return Future<VideoFacetsResponse?>.value(cached);
    final pending = _facetsPending;
    if (pending != null) return pending;
    final fut = () async {
      try {
        final f = await ApiSession.instance.client.videoFacets(libraryId: widget.libraryId);
        if (mounted) setState(() => _facets = f);
        return f;
      } catch (_) {
        // 选项接口失败不该阻断筛选：面板退化成「没有条数」，选择照常生效
        return null;
      } finally {
        _facetsPending = null;
      }
    }();
    _facetsPending = fut;
    return fut;
  }

  String _jpValueLabelOfKey(String key) => switch (key) {
    '4k' => tr('video.filter.res4k'),
    '1080' => tr('video.filter.res1080'),
    _ => key,
  };

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
    // 日本库的四维选项来自 facets，打开面板前先确保拿到（首屏已异步拉过一次）
    await _loadFacets();
    if (!mounted) return;
    final facets = _facets;
    final yearsSorted = years.toList()..sort((a, b) => b.compareTo(a));
    // 面板里是就地改状态（chips 直接操作 Set）。点取消要把试选的条件退回去，
    // 否则「关掉面板」和「确定」看起来没区别，是很容易踩的坑。
    final snapshot = (
      years: _years.toSet(),
      genres: _genres.toSet(),
      regions: _regions.toSet(),
      watched: _watched,
      scraped: _scrapedFilter,
      resolution: _resolution,
      jpTag: _jpTag,
      sourceId: _sourceId,
    );
    final result = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              Widget chips(
                String label,
                Iterable<String> values,
                Set<String> target, {
                String? emptyLabel,
                String Function(String)? labelBuilder,
              }) {
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
                              label: Text(labelBuilder == null ? v : labelBuilder(v)),
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

              /// 地区：同一个国家在库里可能同时存着中英两种写法（真库
              /// 「日本」709 条 + "Japan" 179 条），先按 canonical 合并成一项，
              /// 显示名跟随界面语言；选中时把整组写法一起提交，
              /// 服务端 `likeJson` 是 OR，两种写法都能命中。
              Widget regionChips(
                String label,
                List<RegionOption> options,
                Set<String> target,
              ) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
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
                          for (final opt in options)
                            NasChip(
                              label: Text(opt.label),
                              selected: opt.queryValues.any(target.contains),
                              onSelected: (on) => setLocal(() {
                                final vals = opt.queryValues;
                                if (on) {
                                  target.addAll(vals);
                                } else {
                                  target.removeAll(vals);
                                }
                              }),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              /// 日本库四维（单选）：分组样式与上面的通用 chips 一致，
              /// 只是内容换成分辨率 / 标签 / 来源 / 题材。
              Widget facetChips(
                String label,
                List<(String, String)> values,
                String current,
                ValueChanged<String> onPick,
              ) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          NasChip(
                            label: Text(tr('video.filter.all')),
                            selected: current.isEmpty,
                            onSelected: (_) => setLocal(() => onPick('')),
                          ),
                          for (final (v, l) in values)
                            NasChip(
                              label: Text(l),
                              selected: current == v,
                              onSelected: (_) => setLocal(() => onPick(v)),
                            ),
                          if (values.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                tr('video.filter.noOptions'),
                                style: TextStyle(
                                  fontSize: NasTokens.fontCaption,
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              Widget jpFacets() {
                final resOpts = <(String, String)>[
                  for (final r
                      in facets?.resolutions ?? const <VideoFacetCount>[])
                    (r.key, _jpValueLabelOfKey(r.key)),
                ];
                final tagOpts = <(String, String)>[
                  for (final t in facets?.tags ?? const <VideoFacetCount>[])
                    (t.key, _jpTagLabel(t.key)),
                ];
                final sources = facets?.sources ?? const <VideoSourceFacet>[];
                final sourceOpts = <(String, String)>[
                  for (var i = 0; i < sources.length; i += 1)
                    (
                      sources[i].id,
                      tr('video.filter.sourceN', {'n': '${i + 1}'}),
                    ),
                ];
                final genreOpts = <(String, String)>[
                  for (final g in facets?.genres ?? const <VideoGenreFacet>[])
                    (g.name, genreLabel(g.name)),
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 普通库大多只有分辨率：没数据的维度不摆出来，免得面板里
                    // 一水儿的「暂无可选项」。已选中的值要兜底显示，方便清掉。
                    if (resOpts.isNotEmpty || _resolution.isNotEmpty)
                      facetChips(tr('video.filter.resolution'), resOpts,
                          _resolution, (v) => _resolution = v),
                    if (tagOpts.isNotEmpty || _jpTag.isNotEmpty)
                      facetChips(tr('video.filter.tag'), tagOpts, _jpTag,
                          (v) => _jpTag = v),
                    if (sourceOpts.length > 1 || _sourceId.isNotEmpty)
                      facetChips(tr('video.filter.source'), sourceOpts, _sourceId,
                          (v) => _sourceId = v),
                    // 普通库的「类型」由下面通用 chips 管（可多选）；
                    // 日本库的题材是单选，且口径要跟演员页一致，才单独列一组。
                    if (widget.jp &&
                        (genreOpts.isNotEmpty || _jpGenre.isNotEmpty))
                      facetChips(tr('video.filter.genre'), genreOpts, _jpGenre,
                          (v) {
                        _genres
                          ..clear()
                          ..addAll(v.isEmpty ? const <String>[] : [v]);
                      }),
                    const SizedBox(height: NasTokens.spaceXs),
                  ],
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
                    // 四维（有数据的）放最上面，其余通用维度照旧
                    jpFacets(),
                    if (!widget.jp &&
                        years.isEmpty &&
                        genres.isEmpty &&
                        regions.isEmpty)
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
                    // 日本库的「类型」由顶栏那一行（按数量排序的前 30 个题材）负责，
                    // 这里再放一份 200 条样本抽出来的类型列表只会互相打架。
                    if (!widget.jp)
                      chips(
                        tr('video.list.filter.genres'),
                        genres.toList()
                          ..sort((a, b) =>
                              genreLabel(a).compareTo(genreLabel(b))),
                        _genres,
                        labelBuilder: genreLabel,
                      ),
                    regionChips(
                      tr('video.list.filter.regions'),
                      groupRegions(regions, I18n.instance.locale),
                      _regions,
                    ),
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
                            // 「重置」= 清空所有筛选，日本库那行也要一起归零，
                            // 否则按钮写着重置、列表还少一截
                            _resolution = '';
                            _jpTag = '';
                            _sourceId = '';
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
    if (result != true) {
      if (!mounted) return;
      setState(() {
        _years
          ..clear()
          ..addAll(snapshot.years);
        _genres
          ..clear()
          ..addAll(snapshot.genres);
        _regions
          ..clear()
          ..addAll(snapshot.regions);
        _watched = snapshot.watched;
        _scrapedFilter = snapshot.scraped;
        _resolution = snapshot.resolution;
        _jpTag = snapshot.jpTag;
        _sourceId = snapshot.sourceId;
      });
      return;
    }
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
                  _selection.toggle(item.id);
                  return;
                }
                openVideoDetail(context, item);
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
            const Divider(),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                size: 22,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: Text(tr('common.delete')),
              onTap: () => Navigator.pop(ctx, 'delete'),
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
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('common.delete'),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () => _videoAction('delete', item),
    ),
  ];

  /// 长按菜单与右键菜单共用的动作分发（原来内联在 _showCardMenu 里）
  Future<void> _videoAction(String action, VideoItem item) async {
    switch (action) {
      case 'watched':
        await _toggleWatched([item.id], !item.watched);
      case 'select':
        _selection.enter(initialId: item.id);
      case 'detail':
        if (!mounted) return;
        openVideoDetail(context, item);
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
      case 'delete':
        final toTrash = await confirmVideoDelete(context);
        if (toTrash == null || !mounted) return;
        await deleteVideoItemsNow(context, [item.id], toTrash: toTrash);
        await _load();
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
    final ids = _items.map((e) => e.id);
    final empty = _selected.isEmpty;
    return NasSelectionBar(
      title: tr('video.list.selected', {'count': '${_selected.length}'}),
      allSelected: _selection.allSelected(ids),
      onToggleAll: () => _selection.toggleAll(ids),
      onClose: _selection.exit,
      actions: [
        NasSelectionAction(
          label: tr('video.collection.addTo'),
          icon: Icons.playlist_add,
          enabled: !empty,
          onPressed: () => showAddToCollectionDialog(
            context,
            itemIds: _selected.toList(),
          ),
        ),
        NasSelectionAction(
          label: tr('video.action.markWatched'),
          icon: Icons.done_all,
          enabled: !empty,
          onPressed: () => _toggleWatched(_selected.toList(), true),
        ),
        NasSelectionAction(
          label: tr('video.action.markUnwatched'),
          icon: Icons.remove_done,
          enabled: !empty,
          onPressed: () => _toggleWatched(_selected.toList(), false),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _toolbar(context),
        // 所有库：筛选全在顶栏按钮里，也不显示「已刮削 N 部」，高度留给网格。
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
    if (widget.embedded) {
      final header = widget.embeddedHeader;
      if (header == null) return body;
      // 三级页：不画 AppBar（返回在外壳上），但得自己给标题与底色 —— 它是叠在
      // 上一页之上的，透明会漏字（`scaffoldBackgroundColor` 在本项目是透明的）。
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
                            header,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: NasTokens.fontSubtitle,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        NasRefreshButton(onPressed: () => _load()),
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
  VideoListView build({required bool embedded}) => VideoListView(
    title: name,
    embedded: embedded,
    embeddedHeader: embedded ? name : null,
    initialActor: kind == 'actor' ? name : null,
    initialDirector: kind == 'director' ? name : null,
  );

  final router = VideoDetailRouter.instance;
  if (router.embeddableFrom(context)) {
    router.open(
      VideoDetailEntry(
        tag: 'person:$kind:$name',
        build: (_) => build(embedded: true),
      ),
    );
    return Future<void>.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => build(embedded: false)),
  );
}
