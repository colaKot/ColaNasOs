import 'dart:async';
import 'dart:convert';
import '../../shell/app_widgets.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/scan_refresh.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../core/task_poll.dart';
import '../../shell/mobile_frame.dart';
import 'photo_download.dart';
import 'photo_place_picker.dart';
import 'photo_similar_page.dart';
import 'photo_viewer_page.dart';
import 'photo_year_view_page.dart';


/// 相册：时间轴 / 相册 / 搜索（一期，一套逻辑 + 两套布局）。
///
/// 宽屏（medium/expanded）：左侧相册栏 + 右侧时间轴网格；
/// 窄屏（compact）：顶部分段切换时间轴与相册。
/// 相册内容视图：由 `PhotoShellPage` 的二级导航决定显示哪一块。
enum PhotoPageView { timeline, album }

class PhotoPage extends StatefulWidget {
  const PhotoPage({
    super.key,
    this.view = PhotoPageView.timeline,
    this.favoriteOnly = false,
    this.todayOnly = false,
    this.initialYear,
    this.initialMonth,
  });

  final PhotoPageView view;

  /// 只看收藏（左侧「收藏」入口）
  final bool favoriteOnly;

  /// 只看今天（左侧「今天」入口）
  final bool todayOnly;

  /// 首屏就缩到某年（年视图下钻回来用）；[initialMonth] 非空再缩到某月
  final int? initialYear;
  final int? initialMonth;

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  static int get _pageSize =>
      SettingsStore.instance.getInt('photo.page.size') ?? 120;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _nextCursor;
  String _query = '';

  List<PhotoItem> _items = const [];

  /// 右侧年份刻度选中的年份（null = 全部）
  int? _yearFilter;

  /// 年视图 / 月份下钻传进来的闭区间（null = 不限）；与 _yearFilter 二选一优先
  int? _fromSec;
  int? _toSec;

  /// 交叉筛选条件（人物 / 场景 / 活动 / 地点 / 收藏）；非空时时间轴改走 /photo/filter
  PhotoSmartRuleConditions? _filter;
  int? _filterTotal;

  /// 生效条件的可读摘要（人物名 / 场景名 / 收藏 / 时间档），横幅直接用
  List<String> _filterSummary = const [];

  /// 当前滚动位置所在的年份（用于刻度高亮，不参与请求）
  int? _visibleYear;


  /// 排序：新→旧（desc）/ 旧→新（asc）
  bool _asc = false;

  /// 缩略图尺寸（缩放 ±）
  double _thumbExtent = 160;

  /// 多选
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  /// 手机端多选工具条的通道（外壳给的）。桌面端取不到 → 用页面内的 [_selectBar]
  NasBulkController? _bulkCtl;
  bool _bulkSyncScheduled = false;

  /// 搜索联想（防抖 320ms）；空关键词时改成热门推荐
  Timer? _suggestTimer;
  List<Map<String, dynamic>> _suggestions = const [];
  bool _suggestIsHot = false;

  /// 最近搜索：本地设置里存一份，刷新页面不丢
  static const _recentKey = 'photo.recentSearches';
  List<String> _recentSearches = const [];

  /// 搜索框走「混合检索」时的状态（语义标签命中 + offset 分页）
  int? _nextOffset;
  List<String> _hybridTags = const [];
  List<String> _hybridUnmatched = const [];
  bool _hybridDegraded = false;
  String _hybridReason = '';
  int _hybridTotal = 0;

  /// 本地收藏态覆盖：切换后不必整页重拉
  final Map<String, bool> _favOverride = <String, bool>{};
  List<PhotoAlbum> _albums = const [];
  List<PhotoLibraryItem> _libraries = const [];
  PhotoStatsResponse? _stats;

  late final void Function() _unsubScan;

  @override
  void initState() {
    final savedExtent = SettingsStore.instance.getInt('photo.grid.extent');
    if (savedExtent != null) _thumbExtent = savedExtent.toDouble();
    // 年视图下钻：首帧就带上筛选，否则 _bootstrap() 会先拉一遍全量再被覆盖（两次请求）
    final initYear = widget.initialYear;
    if (initYear != null) {
      _yearFilter = initYear;
      _visibleYear = initYear;
      final month = widget.initialMonth;
      if (month != null) {
        final from = DateTime(initYear, month, 1);
        final to = DateTime(initYear, month + 1, 1);
        _fromSec = from.millisecondsSinceEpoch ~/ 1000;
        _toSec = to.millisecondsSinceEpoch ~/ 1000 - 1;
      }
    }
    super.initState();
    _unsubScan = listenScanDone('photo', () {
      if (mounted) _bootstrap();
    });
    _scroll.addListener(_onScroll);
    _searchCtrl.addListener(_onSearchChanged);
    _loadRecent();
    _loadHot();
    _bootstrap();
  }

  @override
  void dispose() {
    // 多选态是"模式"，页面没了必须收回，否则工具条会挂在别的 tab 上
    _bulkCtl?.hide();
    _suggestTimer?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _unsubScan();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 热门推荐：以前 suggest 的「空 q 热门」分支服务端有、客户端从不调用，
  /// 现在空关键词（含刚进页面）就走独立的 /search/hot，同一份 SQL。
  Future<void> _loadHot() async {
    try {
      final res = await ApiSession.instance.client.photoSearchHot(
        body: const PhotoSearchHotBody(limit: 6),
      );
      if (!mounted || _searchCtrl.text.trim().isNotEmpty) return;
      setState(() {
        _suggestions = List<Map<String, dynamic>>.from(res.items);
        _suggestIsHot = true;
      });
    } catch (_) {
      // 推荐失败不影响搜索本身
    }
  }

  void _loadRecent() {
    final raw = SettingsStore.instance.getString(_recentKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List?)?.whereType<String>().take(6).toList() ?? [];
      _recentSearches = list;
    } catch (_) {
      // 本地快照坏了就当没有
    }
  }

  void _remember(String q) {
    if (q.isEmpty) return;
    final next = <String>[q, ..._recentSearches.where((e) => e != q)].take(6).toList();
    setState(() => _recentSearches = next);
    unawaited(SettingsStore.instance.setString(_recentKey, jsonEncode(next)));
  }

  void _onSearchChanged() {
    _suggestTimer?.cancel();
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      _loadHot();
      return;
    }
    _suggestTimer = Timer(const Duration(milliseconds: 320), () async {
      try {
        final res = await ApiSession.instance.client.photoSearchSuggest(
          body: {'q': q, 'limit': 6},
        );
        if (!mounted) return;
        final items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        setState(() {
          _suggestions = items;
          _suggestIsHot = false;
        });
      } catch (_) {
        // 联想失败不影响搜索本身
      }
    });
  }

  void _applySuggestion(String value) {
    _suggestTimer?.cancel();
    _searchCtrl.text = value;
    _remember(value);
    setState(() {
      _query = value;
      _suggestions = const [];
    });
    _loadTimeline();
  }

  String _suggestKindLabel(String kind) {
    switch (kind) {
      case 'person':
        return tr('photo.suggest.person');
      case 'scene':
        return tr('photo.suggest.scene');
      case 'activity':
        return tr('photo.suggest.activity');
      case 'camera':
        return tr('photo.suggest.camera');
      case 'filename':
        return tr('photo.suggest.filename');
      case 'ocr':
        return tr('photo.suggest.ocr');
      case 'year':
        return tr('photo.suggest.year');
      default:
        return kind;
    }
  }

  /// 「已识别：海边 / 沙滩 · 共 37 张」+「未识别：xx」+ 降级提示。
  ///
  /// 为什么要露这一行：语义搜索如果静默命中 0 条，用户只会觉得"搜索坏了"；
  /// 把「我认出了哪些词」「哪些没认出」「现在是降级状态」摊开，用户才知道下一步该改什么。
  Widget _hybridInfoBar() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        0,
        NasTokens.spaceMd,
        NasTokens.spaceXs,
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_hybridTags.isNotEmpty) ...[
            Text(
              tr('photo.hybrid.recognized'),
              style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasTextSecondary),
            ),
            for (final tag in _hybridTags.take(5))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
          if (_hybridUnmatched.isNotEmpty) ...[
            Text(
              tr('photo.hybrid.unmatched'),
              style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasTextSecondary),
            ),
            for (final word in _hybridUnmatched.take(3))
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(word, style: const TextStyle(fontSize: NasTokens.fontMicro)),
              ),
          ],
          if (_query.isNotEmpty && !_loading)
            Text(
              tr('photo.hybrid.total', {'count': '$_hybridTotal'}),
              style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasTextSecondary),
            ),
          if (_hybridDegraded)
            Text(
              _hybridReason.isEmpty ? tr('photo.hybrid.degraded') : _hybridReason,
              style: TextStyle(fontSize: NasTokens.fontMicro, color: scheme.error),
            ),
        ],
      ),
    );
  }

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  Map<String, String> get _imageHeaders {
    final token = ApiSession.instance.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }


  /// 网格 / 封面走服务端缩略图（懒生成 + 文件缓存），避免相册墙直接拉原图
  String _thumbUrl(String path, {int size = 320}) =>
      _media.thumbnail(path, size: size);

  bool get _hasMore => _nextCursor != null || _nextOffset != null;

  void _onScroll() {
    _updateVisibleYear();
    if (!_scroll.hasClients || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 2400) {
      _loadTimeline(more: true);
    }
  }

  /// 右侧年份刻度的宽度。手机端不显示（入口改成「照片」tab 的浮动胶囊「年份」），
  /// 否则 64px 会吃掉 390 宽屏幕的 1/6。
  double _railWidth(BuildContext context) => isCompactWidth(context) ? 0 : 64;

  /// 按网格几何估算当前可见的第一张照片，取其年份做刻度联动
  void _updateVisibleYear() {
    if (!mounted || !_scroll.hasClients || _items.isEmpty) return;
    final width =
        MediaQuery.sizeOf(context).width -
        _railWidth(context) -
        NasTokens.spaceSm * 2;
    final cell = _thumbExtent + NasTokens.spaceXs;
    final cols = (width / cell).floor().clamp(1, 50);
    final pos = _scroll.position;
    final row = ((pos.pixels + pos.viewportDimension * 0.08) / cell).floor();
    final index = (row * cols).clamp(0, _items.length - 1);
    final year = DateTime.fromMillisecondsSinceEpoch(
      _items[index].takenAt * 1000,
    ).year;
    if (year != _visibleYear) {
      setState(() => _visibleYear = year);
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      // 四个请求互不依赖，原先逐个 await —— 首屏要等 4 个 RTT 才出第一张图。
      // 先一起发出去，再用 Future.wait 等齐：任何一个失败都在这里统一抛出，
      // 不会留下「没 await 的 future 抛未捕获异常」。
      final fTimeline = widget.favoriteOnly
          ? client.photoTimeline(favorite: true, limit: _pageSize)
          : client.photoTimeline(limit: _pageSize);
      final fAlbums = client.photoAlbumList();
      final fStats = client.photoStats();
      final fLibraries = client.photoLibraryList();
      await Future.wait<dynamic>([fTimeline, fAlbums, fStats, fLibraries]);
      final timeline = await fTimeline;
      final albums = await fAlbums;
      final stats = await fStats;
      final libraries = await fLibraries;
      if (!mounted) return;
      setState(() {
        _items = timeline.items;
        _nextCursor = timeline.nextCursor;
        _albums = albums.items;
        _stats = stats;
        _libraries = libraries.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 搜索框混合检索：语义（场景/活动/OCR/路径）+ 相关度排序 + offset 分页。
  ///
  /// 这是「AI 搜索不好用」的修复点：以前搜索走 `/photo/search` 的 `rel_path like`，
  /// 联想 chip 显示「场景 · 海边 (37)」，点进去却是 0 条 —— 因为文件名里没有"海边"。
  Future<void> _loadHybrid({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
        _nextOffset = 0;
      }
    });
    try {
      final res = await ApiSession.instance.client.photoSearchHybrid(
        q: _query,
        offset: more ? (_nextOffset ?? 0) : 0,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...res.items] : res.items;
        _nextOffset = res.nextOffset;
        _nextCursor = null;
        _hybridTags = res.tags;
        _hybridUnmatched = res.unmatched;
        _hybridDegraded = res.degraded;
        _hybridReason = res.reason;
        _hybridTotal = res.total;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 清空检索态（退回时间轴）
  void _resetHybrid() {
    _nextOffset = null;
    _hybridTags = const [];
    _hybridUnmatched = const [];
    _hybridDegraded = false;
    _hybridReason = '';
    _hybridTotal = 0;
  }

  Future<void> _loadTimeline({bool more = false}) async {
    // 搜索框有内容且不在「收藏/今天/按年」这几种特殊视图时，用混合检索
    if (_query.isNotEmpty &&
        !widget.favoriteOnly &&
        !widget.todayOnly &&
        _yearFilter == null &&
        _fromSec == null &&
        _filter == null) {
      await _loadHybrid(more: more);
      return;
    }
    _resetHybrid();
    if (more && (_loadingMore || _nextCursor == null)) return;
    if (!mounted) return;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final filter = _filter;
      if (filter != null) {
        // 交叉筛选：条件走服务端同一套判据；年份刻度若选着，就把时间窗叠上去
        final res = await ApiSession.instance.client.photoFilter(
          body: PhotoFilterBody(
            conditions: PhotoSmartRuleConditions(
              scene: filter.scene,
              activity: filter.activity,
              faceClusterId: filter.faceClusterId,
              place: filter.place,
              favorite: filter.favorite,
              from: _fromSec ?? filter.from,
              to: _toSec ?? filter.to,
            ),
            q: _query.isEmpty ? null : _query,
            order: _asc ? 'asc' : 'desc',
            cursor: more ? _nextCursor : null,
            limit: _pageSize,
          ),
        );
        if (!mounted) return;
        setState(() {
          _items = more ? [..._items, ...res.items] : res.items;
          _nextCursor = res.nextCursor;
          if (res.total != null) _filterTotal = res.total;
          _loading = false;
          _loadingMore = false;
        });
        return;
      }
      final year = _yearFilter;
      final order = _asc ? 'asc' : 'desc';
      final todayStart = DateTime.now();
      final dayStart = DateTime(
        todayStart.year,
        todayStart.month,
        todayStart.day,
      ).millisecondsSinceEpoch ~/ 1000;
      // 年份 / 月份过滤必须是闭区间：此前只传 from，选 2022 年会一直串到今年
      final rangeFrom = _fromSec ??
          (year == null ? null : DateTime(year).millisecondsSinceEpoch ~/ 1000);
      final rangeTo = _toSec ??
          (year == null
              ? null
              : DateTime(year + 1).millisecondsSinceEpoch ~/ 1000 - 1);
      final res = rangeFrom != null
          ? await ApiSession.instance.client.photoSearch(
              from: rangeFrom,
              to: rangeTo,
              order: order,
              cursor: more ? _nextCursor : null,
              limit: _pageSize,
            )
          : widget.todayOnly
          ? await ApiSession.instance.client.photoSearch(
              from: dayStart,
              order: order,
              cursor: more ? _nextCursor : null,
              limit: _pageSize,
            )
          : _query.isEmpty || widget.favoriteOnly
          ? await ApiSession.instance.client.photoTimeline(
              favorite: widget.favoriteOnly ? true : null,
              order: order,
              cursor: more ? _nextCursor : null,
              limit: _pageSize,
            )
          : await ApiSession.instance.client.photoSearch(
              order: order,
              q: _query,
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
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 扫描：入队后立刻返回，进度靠轮询。
  ///
  /// 原先直接 await 同步的 `/photo/scan`，而它要等整个库扫完才返回 ——
  /// 数万张照片必然超过传输层的 30 s 超时，用户看到的是「扫描失败」，
  /// 服务端其实还在跑，于是再点一次（越点越乱）。
  Future<void> _scan() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final queued = await ApiSession.instance.client.photoScanTask(
        body: const PhotoScanBody(),
      );
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('photo.scanQueued'));

      final task = await waitTask(queued.taskId);
      if (!mounted) return;
      if (task == null) {
        NasSnack.showOn(messenger, tr('photo.scanTimeout'));
        return;
      }
      if ('${task['state']}' != 'done') {
        NasSnack.showOn(messenger, '${task['error'] ?? task['state']}');
        return;
      }
      await _bootstrap();
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('photo.scanFinished'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.scanFailed', {'error': '$e'}));
    }
  }

  /// 清理「索引有、磁盘无」的照片（服务端默认不删，需显式 prune）
  ///
  /// 扫描改异步后不再有「本次发现多少张缺失」这个数，所以确认文案不带数量；
  /// 清理本身也走任务队列（大库 prune 要遍历整表，同步会撞 30s 超时）。
  Future<void> _pruneMissing() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.photo.048')),
        content: Text(tr('photo.pruneConfirmNoCount')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.book.001')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final queued = await ApiSession.instance.client.photoScanTask(
        body: const PhotoScanBody(prune: true),
      );
      final task = await waitTask(queued.taskId);
      if (!mounted) return;
      if (task == null) {
        NasSnack.showOn(messenger, tr('photo.scanTimeout'));
        return;
      }
      if ('${task['state']}' != 'done') {
        NasSnack.showOn(messenger, '${task['error'] ?? task['state']}');
        return;
      }
      await _bootstrap();
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('photo.scanFinished'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.cleanupFailed', {'error': '$e'}));
    }
  }

  Future<void> _createAlbum() async {
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.photo.050')),
        content: TextField(
          controller: nameCtrl,
          decoration: InputDecoration(labelText: tr('ui.photo.051')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.create')),
          ),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      await ApiSession.instance.client.photoAlbumCreate(
        body: PhotoAlbumCreateBody(name: nameCtrl.text.trim()),
      );
      if (!mounted) return;
      await _refreshAlbums();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _refreshAlbums() async {
    final res = await ApiSession.instance.client.photoAlbumList();
    if (!mounted) return;
    setState(() => _albums = res.items);
  }

  Future<void> _deleteAlbum(PhotoAlbum album) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.photo.052')),
        content: Text(tr('photo.deleteConfirm', {'name': album.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiSession.instance.client.photoAlbumDelete(
        body: PhotoAlbumDeleteBody(albumId: album.id),
      );
      await _refreshAlbums();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  /// 编辑相册：名称 + 一句简介（封面在相册详情里长按照片设置）
  Future<void> _editAlbum(PhotoAlbum album) async {
    final nameCtrl = TextEditingController(text: album.name);
    final descCtrl = TextEditingController(text: album.description ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.album.edit')),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(labelText: tr('photo.album.name')),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              TextField(
                controller: descCtrl,
                maxLength: 200,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: tr('photo.album.description'),
                  hintText: tr('photo.album.descriptionHint'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    try {
      await ApiSession.instance.client.photoAlbumUpdate(
        body: PhotoAlbumUpdateBody(
          albumId: album.id,
          name: name,
          description: descCtrl.text.trim(),
        ),
      );
      await _refreshAlbums();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.saveFailed', {'error': '$e'}));
    }
  }

  /// 手排顺序：与相邻相册交换 sortOrder。
  /// 两边的 sortOrder 可能相同（都还是默认 0），所以按「索引 × 10」重排一次再交换，
  /// 否则互换同一个值等于没动。
  Future<void> _moveAlbum(PhotoAlbum album, int delta) async {
    final index = _albums.indexWhere((a) => a.id == album.id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= _albums.length) return;
    final next = <PhotoAlbum>[..._albums];
    final moved = next.removeAt(index);
    next.insert(target, moved);
    try {
      for (var i = 0; i < next.length; i += 1) {
        await ApiSession.instance.client.photoAlbumUpdate(
          body: PhotoAlbumUpdateBody(albumId: next[i].id, sortOrder: (i + 1) * 10),
        );
      }
      await _refreshAlbums();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.saveFailed', {'error': '$e'}));
    }
  }

  bool _isFavorite(PhotoItem item) => _favOverride[item.id] ?? item.favorite;

  Future<void> _toggleFavorite(PhotoItem item) async {
    final next = !_isFavorite(item);
    setState(() => _favOverride[item.id] = next);
    try {
      await ApiSession.instance.client.photoFavoriteSet(
        body: PhotoFavoriteBody(ids: [item.id], favorite: next),
      );
      // 收藏页取消收藏后该项应从列表消失
      if (widget.favoriteOnly && !next) {
        if (!mounted) return;
        setState(() => _items = _items.where((e) => e.id != item.id).toList());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _favOverride[item.id] = !next);
      NasSnack.show(context, e.toString());
    }
  }

  Future<void> _batchFavorite(bool favorite) async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    setState(() {
      for (final id in ids) {
        _favOverride[id] = favorite;
      }
      _selected.clear();
      _selecting = false;
    });
    try {
      await ApiSession.instance.client.photoFavoriteSet(
        body: PhotoFavoriteBody(ids: ids, favorite: favorite),
      );
      if (widget.favoriteOnly) await _loadTimeline();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    var toTrash = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('photo.delete.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('photo.delete.confirm', {'count': '${ids.length}'})),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('photo.delete.toTrash')),
                subtitle: Text(
                  tr('photo.delete.permanentHint'),
                  style: const TextStyle(fontSize: 11),
                ),
                value: toTrash,
                onChanged: (v) => setLocal(() => toTrash = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('common.delete')),
            ),
          ],
        ),
      ),
    );
if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.photoDelete(
        body: PhotoDeleteBody(ids: ids, toTrash: toTrash),
      );
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      await _loadTimeline();
      NasSnack.showOn(messenger, tr('photo.delete.done', {'count': '${res.count}'}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('photo.delete.failed', {'error': '$e'}));
    }
  }

  Future<void> _addSelectedToCollection() async {
    final res = await ApiSession.instance.client.photoCollectionList();
    if (!mounted) return;
    if (res.items.isEmpty) {
      NasSnack.show(context, tr('photo.timeline.noCollection'));
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('photo.timeline.addToCollection')),
        children: [
          for (final c in res.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: Text('${c.name} · ${c.items}'),
            ),
        ],
      ),
    );
    if (picked == null) return;
    try {
      await ApiSession.instance.client.photoCollectionAdd(
        body: PhotoCollectionMembersBody(
          collectionId: picked,
          itemIds: _selected.toList(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      NasSnack.show(context, tr('photo.collection.added').replaceAll('{n}', '${_selected.length}'));
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
    }
  }

  Widget _selectBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
      child: Row(
        children: [
          const SizedBox(width: NasTokens.spaceMd),
          Text(
            tr('photo.timeline.selected').replaceAll('{n}', '${_selected.length}'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _selected.length == 1 ? _similarFromSelection : null,
            icon: const Icon(Icons.image_search, size: 18),
            label: Text(tr('photo.similar.title')),
          ),
          TextButton.icon(
            onPressed: _selected.isEmpty ? null : () => _batchFavorite(true),
            icon: const Icon(Icons.favorite_border, size: 18),
            label: Text(tr('photo.timeline.batchFavorite')),
          ),
          TextButton.icon(
            onPressed: _selected.isEmpty ? null : _addSelectedToCollection,
            icon: const Icon(Icons.collections_outlined, size: 18),
            label: Text(tr('photo.timeline.addToCollection')),
          ),
          TextButton.icon(
            onPressed: _selected.isEmpty ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(tr('common.delete')),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
        ],
      ),
    );
  }

  Future<void> _openViewer(int index) async {
    if (_items.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(items: _items, initialIndex: index),
      ),
    );
  }

  /// 以图搜图：拿选中的这一张做 CLIP 余弦检索，结果弹窗里点开大图。
  Future<void> _similarFromSelection() async {
    if (_selected.length != 1) return;
    final id = _selected.first;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.photoSimilar(
        id: id,
        limit: 60,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        NasSnack.showOn(messenger, tr('photo.similar.empty'));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('photo.similar.title')),
          content: SizedBox(
            width: 720,
            height: 480,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: NasTokens.spaceXs,
                crossAxisSpacing: NasTokens.spaceXs,
              ),
              itemCount: res.items.length,
              itemBuilder: (c, i) {
                final p = res.items[i];
                return InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    _previewPath(p.path);
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                    child: NasCoverImage(
                      url: _thumbUrl(p.path),
                      headers: _imageHeaders,
                      cacheWidth: 320,
                      icon: Icons.photo_outlined,
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.close')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, '$e');
    }
  }

  /// 弹窗里点开大图：走原图下载（inline），不额外申请播放令牌。
  void _previewPath(String path) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(path.split('/').last)),
          body: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: NasCoverImage(
                url: _media.file(path),
                headers: _imageHeaders,
                cacheWidth: 2000,
                icon: Icons.broken_image_outlined,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 把当前多选状态报给手机端外壳（桌面端没有这个通道，取到 null 就什么也不做）。
  ///
  /// 为什么在 build 之后同步而不是在每个 setState 点手写一次：选中的照片会被
  /// 滚动 / 收藏 / 删除等十来个地方改，逐个补必然漏；这里按「build 后对一次账」，
  /// 用 [NasBulkSpec.signature] 去重，内容没变就不会触发外壳重建。
  void _scheduleBulkSync() {
    if (_bulkSyncScheduled) return;
    _bulkSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bulkSyncScheduled = false;
      if (!mounted) return;
      final ctl = NasBulkScope.maybeOf(context);
      _bulkCtl = ctl;
      if (ctl == null) return;
      if (!_selecting) {
        ctl.hide();
        return;
      }
      final single = _selected.length == 1;
      final any = _selected.isNotEmpty;
      ctl.show(
        NasBulkSpec(
          title: tr(
            'photo.timeline.selected',
          ).replaceAll('{n}', '${_selected.length}'),
          onClose: () => setState(() {
            _selecting = false;
            _selected.clear();
          }),
          actions: [
            NasBulkAction(
              icon: Icons.image_search,
              tooltip: tr('photo.similar.title'),
              enabled: single,
              onPressed: _similarFromSelection,
            ),
            NasBulkAction(
              icon: Icons.favorite_border,
              tooltip: tr('photo.timeline.batchFavorite'),
              enabled: any,
              onPressed: () => _batchFavorite(true),
            ),
            NasBulkAction(
              icon: Icons.collections_outlined,
              tooltip: tr('photo.timeline.addToCollection'),
              enabled: any,
              onPressed: _addSelectedToCollection,
            ),
            NasBulkAction(
              icon: Icons.delete_outline,
              tooltip: tr('common.delete'),
              enabled: any,
              onPressed: _deleteSelected,
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleBulkSync();
    // 相册已独立成二级导航入口：时间轴页不再出现相册列表（宽屏/窄屏都不出现）
    if (widget.view == PhotoPageView.album) return _albumPane();
    return Row(
      children: [
        Expanded(child: _timelinePane()),
        if (_railWidth(context) > 0) _yearRail(),
      ],
    );
  }

  /// 右侧年份刻度：从新到旧，每年下方的小点数按该年照片数缩放
  Widget _yearRail() {
    final stats = _stats;
    if (stats == null || stats.byYear.isEmpty) return const SizedBox.shrink();
    // 过滤明显坏掉的年份（EXIF 损坏会产生 1899 / 2082 之类）
    final maxYear = DateTime.now().year + 1;
    final years = stats.byYear
        .where((e) {
          final y = (e['year'] as num?)?.toInt() ?? 0;
          return y >= 1970 && y <= maxYear;
        })
        .toList();
    if (years.isEmpty) return const SizedBox.shrink();
    final counts = years
        .map((e) => (e['count'] as num?)?.toInt() ?? 0)
        .toList();
    final maxCount = counts.reduce((a, b) => a > b ? a : b);
    return SizedBox(
      width: 64,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
          children: [
            _YearTick(
              label: tr('photo.timeline.all'),
              count: stats.items,
              dots: 0,
              active: _visibleYear == null,
              onTap: () => _filterYear(null),
            ),
            for (var i = 0; i < years.length; i++)
              _YearTick(
                label: '${(years[i]['year'] as num).toInt()}',
                count: counts[i],
                dots: maxCount <= 0
                    ? 1
                    : (counts[i] / maxCount * 6).ceil().clamp(1, 6),
                active: _visibleYear == (years[i]['year'] as num).toInt(),
                onTap: () => _filterYear(
                  (years[i]['year'] as num).toInt(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _filterYear(int? year) async {
    setState(() {
      _yearFilter = year;
      _visibleYear = year;
      // 从年视图 / 月份下钻回来时，闭区间必须清掉，否则"全部"仍带着上次的月份
      _fromSec = null;
      _toSec = null;
      _items = const [];
      _nextCursor = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _loadTimeline();
  }

  /// 年视图下钻：按年（month 为空）或某年某月把时间轴缩放成闭区间
  Future<void> _filterRange(int year, {int? month}) async {
    final from = DateTime(month == null ? year : year, month ?? 1, 1);
    final to = month == null ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
    setState(() {
      _yearFilter = year;
      _visibleYear = year;
      _fromSec = from.millisecondsSinceEpoch ~/ 1000;
      _toSec = to.millisecondsSinceEpoch ~/ 1000 - 1;
      _items = const [];
      _nextCursor = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _loadTimeline();
  }

  Future<void> _openYearView() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoYearViewPage(
          onPick: (year, month) => _filterRange(year, month: month),
        ),
      ),
    );
  }

  /// 另存原图：保存对话框 + 流式下载（.part 落地再改名，中断不留半张图）
  Future<void> _savePhoto(PhotoItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = item.path.split('/').last;
    try {
      final path = await PhotoDownload.save(
        url: _media.file(item.path),
        headers: _imageHeaders,
        suggestedName: name,
      );
      if (!mounted) return;
      if (path != null) {
        NasSnack.showOn(messenger, tr('photo.longPress.saved', {'path': path}));
      }
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('photo.longPress.saveFailed', {'error': '$e'}));
    }
  }

  /// 打开交叉筛选面板（人物 / 场景 / 收藏 / 时间）。
  /// 取消返回 null（不动现状），清除返回空条件（退出筛选）。
  Future<void> _openFilterSheet() async {
    final outcome = await showDialog<_FilterOutcome>(
      context: context,
      builder: (_) => _PhotoFilterSheet(initial: _filter),
    );
    if (outcome == null || !mounted) return;
    setState(() {
      _filter = outcome.conditions;
      _filterSummary = outcome.summary;
      _filterTotal = null;
      _items = const [];
      _nextCursor = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _loadTimeline();
  }

  Future<void> _clearFilter() async {
    setState(() {
      _filter = null;
      _filterSummary = const [];
      _filterTotal = null;
      _items = const [];
      _nextCursor = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _loadTimeline();
  }

  /// 筛选生效时的一条横幅：条件 + 命中总数 + 清除。
  /// 没有它的话，用户只看到"照片变少了"却找不到原因。
  Widget _filterChips() {
    final total = _filterTotal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceXs,
        NasTokens.spaceSm,
        0,
      ),
      child: Row(
        children: [
          Icon(Icons.filter_alt, size: 14, color: context.nasTextSecondary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _filterSummary.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          if (total != null)
            Text(
              tr('photo.filter.count', {'n': '$total'}),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          TextButton(
            onPressed: _clearFilter,
            child: Text(tr('photo.filter.clear')),
          ),
        ],
      ),
    );
  }

  /// 长按单张：菜单而不是直接进多选。直接进多选会让"只想收藏这一张"多两步。
  Future<void> _longPressPhoto(int index) async {
    final item = _items[index];
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_full),
              title: Text(tr('photo.longPress.open')),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: Text(tr('photo.similar.title')),
              onTap: () => Navigator.pop(ctx, 'similar'),
            ),
            // 桌面端能真正"另存为"；Web 端没有稳定保存入口，退成复制原图链接
            if (PhotoDownload.supported)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(tr('photo.longPress.save')),
                onTap: () => Navigator.pop(ctx, 'save'),
              )
            else
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(tr('photo.longPress.copyLink')),
                onTap: () => Navigator.pop(ctx, 'copyLink'),
              ),
            ListTile(
              leading: Icon(_isFavorite(item) ? Icons.favorite : Icons.favorite_border),
              title: Text(
                tr(_isFavorite(item) ? 'photo.longPress.unfavorite' : 'photo.longPress.favorite'),
              ),
              onTap: () => Navigator.pop(ctx, 'fav'),
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: Text(tr('photo.timeline.select')),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('photo.longPress.delete')),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    await _photoAction(action, item, index);
  }

  /// 右键菜单（桌面 / Web）：与长按菜单同一批动作，只是换成鼠标触发。
  List<NasMenuEntry> _photoMenuEntries(PhotoItem item, int index) {
    final fav = _isFavorite(item);
    return [
      NasMenuEntry(
        label: tr('photo.longPress.open'),
        icon: Icons.open_in_full,
        onSelected: () => _photoAction('open', item, index),
      ),
      NasMenuEntry(
        label: tr('photo.similar.title'),
        icon: Icons.travel_explore,
        onSelected: () => _photoAction('similar', item, index),
      ),
      NasMenuEntry(
        label: tr(
          PhotoDownload.supported
              ? 'photo.longPress.save'
              : 'photo.longPress.copyLink',
        ),
        icon: PhotoDownload.supported
            ? Icons.download_outlined
            : Icons.link,
        onSelected: () => _photoAction(
          PhotoDownload.supported ? 'save' : 'copyLink',
          item,
          index,
        ),
      ),
      NasMenuEntry(
        label: tr(
          fav ? 'photo.longPress.unfavorite' : 'photo.longPress.favorite',
        ),
        icon: fav ? Icons.favorite : Icons.favorite_border,
        onSelected: () => _photoAction('fav', item, index),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: tr('photo.timeline.select'),
        icon: Icons.checklist,
        onSelected: () => _photoAction('select', item, index),
      ),
      NasMenuEntry(
        label: tr('photo.longPress.delete'),
        icon: Icons.delete_outline,
        danger: true,
        onSelected: () => _photoAction('delete', item, index),
      ),
    ];
  }

  /// 长按菜单与右键菜单共用的动作分发
  Future<void> _photoAction(String action, PhotoItem item, int index) async {
    switch (action) {
      case 'open':
        _openViewer(index);
      case 'similar':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PhotoSimilarPage(
              photoId: item.id,
              title: item.path.split('/').last,
            ),
          ),
        );
      case 'fav':
        await _toggleFavorite(item);
      case 'save':
        await _savePhoto(item);
      case 'copyLink':
        await Clipboard.setData(ClipboardData(text: _media.file(item.path)));
        if (!mounted) return;
        NasSnack.show(context, tr('photo.longPress.linkCopied'));
      case 'select':
        setState(() {
          _selecting = true;
          _selected.add(item.id);
        });
      case 'delete':
        if (!mounted) return;
        setState(() {
          _selecting = true;
          _selected
            ..clear()
            ..add(item.id);
        });
        await _deleteSelected();
    }
  }

  /// 手机端工具栏只留「筛选 / 多选 / 更多」。
  ///
  /// 原来这一行摆了 8 个 IconButton（排序/缩放×2/年视图/扫描/多选/筛选/刷新），
  /// 390 宽的屏上实测 `RenderFlex overflowed by 4.0 pixels`，所以低频动作收进菜单；
  /// 缩放单独不放进来 —— 手机端固定 3 列（见网格 delegate），缩放已经没有意义。
  Widget _moreMenu() {
    return PopupMenuButton<String>(
      tooltip: tr('common.more'),
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'sort':
            setState(() => _asc = !_asc);
            _loadTimeline();
          case 'year':
            _openYearView();
          case 'scan':
            _scan();
          case 'prune':
            _pruneMissing();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'sort',
          child: Text(
            _asc
                ? tr('photo.timeline.sortAsc')
                : tr('photo.timeline.sortDesc'),
          ),
        ),
        PopupMenuItem(value: 'year', child: Text(tr('photo.yearView.title'))),
        PopupMenuItem(value: 'scan', child: Text(tr('common.scan'))),
        PopupMenuItem(value: 'prune', child: Text(tr('ui.photo.048'))),
      ],
    );
  }

  Widget _timelinePane() {
    final stats = _stats;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: widget.favoriteOnly
                    ? Text(
                        tr('nav.favorites'),
                        style: TextStyle(
                          fontSize: NasTokens.fontSubtitle,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : NasSearchField(
                        controller: _searchCtrl,
                  hintText: tr('ui.photo.057'),
                  onClear: () {
                    setState(() => _query = '');
                    _loadTimeline();
                  },
                  onSubmitted: (v) {
                    _remember(v.trim());
                    setState(() => _query = v.trim());
                    _loadTimeline();
                  },
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              if (!isCompactWidth(context))
                Text(
                  stats == null
                      ? ''
                      : tr('photo.count', {'count': '${stats.items}'}),
                  style: TextStyle(
                    color: context.nasTextSecondary,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              if (!isCompactWidth(context))
                IconButton(
                  tooltip: _asc
                      ? tr('photo.timeline.sortAsc')
                      : tr('photo.timeline.sortDesc'),
                  icon: Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward),
                  onPressed: () {
                    setState(() => _asc = !_asc);
                    _loadTimeline();
                  },
                ),
              if (!isCompactWidth(context)) ...[
                IconButton(
                  tooltip: tr('photo.timeline.zoomOut'),
                  icon: const Icon(Icons.zoom_out),
                  onPressed: () => setState(
                    () => _thumbExtent = (_thumbExtent - 40).clamp(100, 320),
                  ),
                ),
                IconButton(
                  tooltip: tr('photo.timeline.zoomIn'),
                  icon: const Icon(Icons.zoom_in),
                  onPressed: () => setState(
                    () => _thumbExtent = (_thumbExtent + 40).clamp(100, 320),
                  ),
                ),
              ],
              IconButton(
                tooltip: tr('photo.filter.title'),
                icon: Icon(
                  _filter == null ? Icons.filter_alt_outlined : Icons.filter_alt,
                  color: _filter == null ? null : Theme.of(context).colorScheme.primary,
                ),
                onPressed: _openFilterSheet,
              ),
              if (!isCompactWidth(context))
                IconButton(
                  tooltip: tr('photo.yearView.title'),
                  icon: const Icon(Icons.calendar_view_month),
                  onPressed: _openYearView,
                ),
              IconButton(
                tooltip: tr('photo.timeline.select'),
                icon: Icon(
                  _selecting ? Icons.check_circle : Icons.check_circle_outline,
                ),
                onPressed: () => setState(() {
                  _selecting = !_selecting;
                  _selected.clear();
                }),
              ),
              // 扫描 / 清理缺失：两个动作放一个菜单里。
              // 扫描改异步后拿不到「本次发现多少张已不存在」，所以清理缺失不能
              // 再挂成扫描结果上的一个 action，得有自己的入口。
              if (!isCompactWidth(context))
                PopupMenuButton<String>(
                  tooltip: tr('common.scan'),
                  icon: const Icon(Icons.sync),
                  onSelected: (v) {
                    if (v == 'scan') _scan();
                    if (v == 'prune') _pruneMissing();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'scan', child: Text(tr('common.scan'))),
                    PopupMenuItem(
                      value: 'prune',
                      child: Text(tr('ui.photo.048')),
                    ),
                  ],
                ),
              if (isCompactWidth(context)) _moreMenu(),
              NasRefreshButton(onPressed: _bootstrap),
            ],
          ),
        ),
        if (_filter != null) _filterChips(),
        if (_query.isNotEmpty && _hybridTags.isNotEmpty) _hybridInfoBar(),
        if (_query.isNotEmpty && _hybridTags.isEmpty && _hybridUnmatched.isNotEmpty)
          _hybridInfoBar(),
        if (_suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 6, NasTokens.spaceMd, 2),
            child: Text(
              _suggestIsHot
                  ? tr('photo.suggest.recommend')
                  : tr('photo.suggest.suggestions'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
        if (_suggestIsHot && _recentSearches.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 4, NasTokens.spaceMd, 2),
            child: Text(
              tr('photo.suggest.recent'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
              itemCount: _recentSearches.length,
              separatorBuilder: (_, _) => const SizedBox(width: NasTokens.spaceXs),
              itemBuilder: (context, i) => ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(_recentSearches[i]),
                onPressed: () => _applySuggestion(_recentSearches[i]),
              ),
            ),
          ),
        ],
        if (_suggestions.isNotEmpty)
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: NasTokens.spaceMd,
              ),
              itemCount: _suggestions.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: NasTokens.spaceXs),
              itemBuilder: (context, i) {
                final s = _suggestions[i];
                return ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    '${_suggestKindLabel('${s['kind']}')} · ${s['value']}'
                    '${s['count'] == null ? '' : ' (${s['count']})'}',
                  ),
                  onPressed: () => _applySuggestion('${s['value']}'),
                );
              },
            ),
          ),
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
              ? NasErrorState(message: _error!, onRetry: _bootstrap)
              : _items.isEmpty
              ? NasEmptyState(
                  title: _query.isEmpty
                      ? tr('ui.photo.058')
                      : tr('ui.photo.059'),
                  message: _libraries.isEmpty
                      ? tr('ui.photo.h7ed401')
                      : tr('ui.photo.h02e23f'),
                  icon: Icons.photo_library_outlined,
                )
              : LayoutBuilder(
                  builder: (context, c) {
                    // 手机端固定 3 列（2026-11-04 用户要求：一行 3 个、就用这个大小）。
                    // 桌面沿用「160 基准 → 6 列」的缩放换算。
                    final compactGrid =
                        layoutFor(c.maxWidth) == LayoutMode.compact;
                    return GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(NasTokens.spaceSm),
                      // 默认 6 列；缩放档位按 160 / _thumbExtent 换算列数
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: compactGrid
                            ? 3
                            : (6 * 160 / _thumbExtent).round().clamp(2, 12),
                        crossAxisSpacing: 3,
                        mainAxisSpacing: 3,
                      ),
                      itemCount: _items.length + (_loadingMore ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _items.length) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        final item = _items[i];
                        if (_selecting) {
                          final picked = _selected.contains(item.id);
                          return Stack(
                              fit: StackFit.expand,
                              children: [
                                _PhotoTile(
                                  item: item,
                                  url: _thumbUrl(item.path),
                                  headers: _imageHeaders,
                                  favorite: _isFavorite(item),
                                  onToggleFavorite: () => _toggleFavorite(item),
                                  showFavorite: false,
                                  // 键盘 / D-pad 的 Enter 也走选择逻辑
                                  onTap: () => setState(() {
                                    if (picked) {
                                      _selected.remove(item.id);
                                    } else {
                                      _selected.add(item.id);
                                    }
                                  }),
                                ),
                                if (picked)
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black38,
                                      border: Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        width: 2,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.check_circle,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            );
                        }
                        // 桌面 / Web 右键：与长按同一批动作（多选态下不弹）
                        return NasContextMenuRegion(
                          entries: _photoMenuEntries(item, i),
                          child: _PhotoTile(
                            item: item,
                            url: _thumbUrl(item.path),
                            headers: _imageHeaders,
                            favorite: _isFavorite(item),
                            onToggleFavorite: () => _toggleFavorite(item),
                            showFavorite: false,
                            onTap: () => _openViewer(i),
                            onLongPress: () => _longPressPhoto(i),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
        // 手机端多选工具条由外壳顶掉底部 tab 来显示（NasBulkBar），
        // 页面内这条只在桌面端用，否则会出现两条一模一样的工具条
        if (_selecting && !isCompactWidth(context)) _selectBar(),
      ],
    );
  }

  Widget _albumPane() {
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
                  tr('ui.photo.053'),
                  style: TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _createAlbum,
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('ui.photo.050')),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshAlbums,
            child: _albums.isEmpty
                ? ListView(
                    children: [
                      NasEmptyState(
                        title: tr('ui.photo.060'),
                        icon: Icons.photo_album_outlined,
                      ),
                    ],
                  )
                : ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
        itemCount: _albums.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final album = _albums[i];
          return ListTile(
            leading: album.coverPath == null
                ? const Icon(Icons.photo_album_outlined)
                : SizedBox(
                    width: 48,
                    height: 48,
                    child: NasCoverImage(
                      url: _thumbUrl(album.coverPath!, size: 96),
                      headers: _imageHeaders,
                      cacheWidth: 96,
                      icon: Icons.broken_image_outlined,
                    ),
                  ),
            title: Text(album.name),
            subtitle: Text(
              [
                tr('photo.count', {'count': '${album.items}'}),
                if ((album.description ?? '').isNotEmpty) album.description!,
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: tr('photo.album.moveUp'),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: i == 0 ? null : () => _moveAlbum(album, -1),
                ),
                IconButton(
                  tooltip: tr('photo.album.moveDown'),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: i == _albums.length - 1
                      ? null
                      : () => _moveAlbum(album, 1),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'edit') _editAlbum(album);
                    if (v == 'delete') _deleteAlbum(album);
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(tr('photo.album.edit')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(tr('ui.photo.052')),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _AlbumDetailPage(
                    album: album,
                    imageUrl: _thumbUrl,
                    headers: _imageHeaders,
                  ),
                ),
              );
              await _refreshAlbums();
            },
          );
        },
                  ),
          ),
        ),
      ],
    );
  }
}


class _YearTick extends StatelessWidget {
  const _YearTick({
    required this.label,
    required this.count,
    required this.dots,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int count;
  final int dots;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : context.nasTextSecondary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            if (dots > 0)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < dots; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.75),
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 2),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 9,
                color: color.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _monthDay(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.item,
    required this.url,
    required this.headers,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onTap,
    this.onLongPress,
    this.showFavorite = true,
  });

  final PhotoItem item;
  final String url;
  final Map<String, String> headers;
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;

  /// 长按菜单（多选 / 找相似 / 收藏 / 删除）
  final VoidCallback? onLongPress;

  /// 时间轴不显示收藏角标（收藏在左栏独立页 + 多选操作）
  final bool showFavorite;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            NasCoverImage(
              url: url,
              headers: headers,
              cacheWidth: 320,
              borderRadius: NasTokens.radiusSm,
              icon: Icons.broken_image_outlined,
            ),
            if (showFavorite)
              Positioned(
                top: 2,
                right: 2,
                child: Material(
                  color: Colors.black38,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onToggleFavorite,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        favorite ? Icons.favorite : Icons.favorite_border,
                        size: 16,
                        color: favorite ? Colors.redAccent : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            // 日期只留左下角「月-日」，不铺整条暗灰底
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _monthDay(item.takenAt),
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.1,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumDetailPage extends StatefulWidget {
  const _AlbumDetailPage({
    required this.album,
    required this.imageUrl,
    required this.headers,
  });

  final PhotoAlbum album;
  final String Function(String path) imageUrl;
  final Map<String, String> headers;

  @override
  State<_AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<_AlbumDetailPage> {
  bool _loading = true;
  String? _error;
  List<PhotoItem> _items = const [];

  /// 本地收藏态覆盖：切换后不必整页重拉
  final Map<String, bool> _favOverride = <String, bool>{};

  /// 当前封面（服务端返回的可能被单独还原/移出，所以自己留一份）
  String? _coverId;

  @override
  void initState() {
    super.initState();
    _coverId = widget.album.coverItemId;
    _load();
  }

  Future<void> _setCover(PhotoItem item) async {
    try {
      await ApiSession.instance.client.photoAlbumUpdate(
        body: PhotoAlbumUpdateBody(
          albumId: widget.album.id,
          coverItemId: item.id,
        ),
      );
      if (!mounted) return;
      setState(() => _coverId = item.id);
      NasSnack.show(context, tr('photo.album.coverSet'));
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.saveFailed', {'error': '$e'}));
    }
  }

  /// 长按照片：设封面 / 移出 / 收藏。此前长按直接移出且无提示，误触就丢。
  Future<void> _photoMenu(PhotoItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: Text(tr('photo.album.setCover')),
              enabled: _coverId != item.id,
              onTap: () => Navigator.pop(ctx, 'cover'),
            ),
            ListTile(
              leading: Icon(_isFav(item) ? Icons.favorite : Icons.favorite_border),
              title: Text(
                tr(_isFav(item) ? 'photo.longPress.unfavorite' : 'photo.longPress.favorite'),
              ),
              onTap: () => Navigator.pop(ctx, 'fav'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(tr('photo.album.removePhoto')),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'cover':
        await _setCover(item);
      case 'fav':
        await _toggleFav(item);
      case 'remove':
        await _remove(item);
    }
  }

  bool _isFav(PhotoItem item) => _favOverride[item.id] ?? item.favorite;

  Future<void> _toggleFav(PhotoItem item) async {
    final next = !_isFav(item);
    setState(() => _favOverride[item.id] = next);
    try {
      await ApiSession.instance.client.photoFavoriteSet(
        body: PhotoFavoriteBody(ids: [item.id], favorite: next),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _favOverride[item.id] = !next);
      NasSnack.show(context, e.toString());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.photoAlbumItems(
        albumId: widget.album.id,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _remove(PhotoItem item) async {
    try {
      await ApiSession.instance.client.photoAlbumRemove(
        body: PhotoAlbumMembersBody(
          albumId: widget.album.id,
          itemIds: [item.id],
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('photo.removeFailed', {'error': '$e'}));
    }
  }

  /// 相册详情里点图看大图。此前这一格的 onTap 是空的 —— 点一张图没有任何反馈。
  Future<void> _openViewer(int index) async {
    if (_items.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(items: _items, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.album.name),
            if ((widget.album.description ?? '').isNotEmpty)
              Text(
                widget.album.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
          ],
        ),
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('ui.photo.062'),
              message: tr('ui.photo.hc324d6'),
              icon: Icons.photo_album_outlined,
            )
          : LayoutBuilder(
              builder: (context, c) {
                final columns = gridColumns(c.maxWidth);
                return GridView.builder(
                  padding: const EdgeInsets.all(NasTokens.spaceSm),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: NasTokens.spaceXs,
                    mainAxisSpacing: NasTokens.spaceXs,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    return GestureDetector(
                      onLongPress: () => _photoMenu(item),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _PhotoTile(
                            item: item,
                            url: widget.imageUrl(item.path),
                            headers: widget.headers,
                            favorite: _isFav(item),
                            onToggleFavorite: () => _toggleFav(item),
                            onTap: () => _openViewer(i),
                          ),
                          if (_coverId == item.id)
                            Positioned(
                              left: 4,
                              top: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  tr('photo.album.coverBadge'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// 交叉筛选的结果：`conditions == null` 表示"清除筛选"，返回 null 表示"取消"。
class _FilterOutcome {
  const _FilterOutcome(this.conditions, this.summary);

  final PhotoSmartRuleConditions? conditions;
  final List<String> summary;
}

/// 时间轴交叉筛选面板：人物 × 场景 × 收藏 × 时间，多条件是**与**关系。
///
/// 条件判据走服务端 `/photo/filter`（与智能规则同一套 where），
/// 这里只负责收集条件 —— 不在客户端拼 SQL 语义，避免两边结果对不上。
class _PhotoFilterSheet extends StatefulWidget {
  const _PhotoFilterSheet({this.initial});

  final PhotoSmartRuleConditions? initial;

  @override
  State<_PhotoFilterSheet> createState() => _PhotoFilterSheetState();
}

class _PhotoFilterSheetState extends State<_PhotoFilterSheet> {
  bool _loading = true;
  List<PhotoFaceClusterItem> _clusters = const [];
  List<PhotoSceneTagSummaryItem> _scenes = const [];
  String? _person;
  String? _personName;
  String? _scene;
  bool _favorite = false;
  PhotoSmartRulePlace? _place;

  /// 0 = 全部，1 = 近一年，3 = 近三年
  int _timePreset = 0;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _person = init?.faceClusterId;
    _scene = init?.scene;
    _favorite = init?.favorite == true;
    _place = init?.place;
    _load();
  }

  Future<void> _load() async {
    final client = ApiSession.instance.client;
    try {
      // 不传 minCount：跟随「AI 设置 → 人脸显示下限」，避免碎片组铺满筛选面板
      final clusters = await client.photoFaceClusters();
      if (mounted) setState(() => _clusters = clusters.items);
    } catch (_) {
      // 人脸模型没跑过：这一栏空着即可，不影响其它条件
    }
    try {
      final scenes = await client.photoSceneTagSummary();
      if (mounted) setState(() => _scenes = scenes.items);
    } catch (_) {
      // 同上
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      // 已知人物：把名字回填到摘要里（服务端返回的是 id，界面要给人看）
      final matched = _clusters.where((c) => c.id == _person);
      if (matched.isNotEmpty) {
        final c = matched.first;
        _personName =
            (c.name ?? '').trim().isNotEmpty
                ? c.name
                : tr('photo.faceCluster.unnamed', {'id': c.id.substring(0, 6)});
      }
    });
  }

  String _clusterLabel(PhotoFaceClusterItem c) {
    final named = (c.name ?? '').trim();
    return named.isNotEmpty
        ? named
        : tr('photo.faceCluster.unnamed', {'id': c.id.substring(0, 6)});
  }

  void _apply() {
    final now = DateTime.now();
    int? from;
    if (_timePreset == 1) {
      from = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch ~/ 1000;
    } else if (_timePreset == 3) {
      from = DateTime(now.year - 3, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
    }
    final any = _person != null || _scene != null || _favorite || from != null || _place != null;
    if (!any) {
      Navigator.pop(context, const _FilterOutcome(null, []));
      return;
    }
    final summary = <String>[
      ?_personName,
      ?_scene,
      if (_favorite) tr('photo.filter.chipFavorite'),
      if (from != null)
        tr(_timePreset == 1 ? 'photo.filter.lastYear' : 'photo.filter.last3Years'),
      if (_place != null)
        tr('photo.filter.placeChip', {
          'km': '${(_place!.radiusKm ?? 10).round()}',
        }),
    ];
    Navigator.pop(
      context,
      _FilterOutcome(
        PhotoSmartRuleConditions(
          faceClusterId: _person,
          scene: _scene,
          favorite: _favorite ? true : null,
          from: from,
          place: _place,
        ),
        summary,
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: NasTokens.spaceSm, bottom: NasTokens.spaceXs),
    child: Text(
      text,
      style: TextStyle(
        fontSize: NasTokens.fontCaption,
        fontWeight: FontWeight.w600,
        color: context.nasTextSecondary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('photo.filter.title')),
      content: SizedBox(
        width: 520,
        height: 440,
        child: _loading
            ? const NasLoading()
            : ListView(
                children: [
                  _sectionTitle(tr('photo.filter.person')),
                  if (_clusters.isEmpty)
                    Text(
                      tr('photo.filter.nonePerson'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        for (final c in _clusters.take(24))
                          NasChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(_clusterLabel(c)),
                            selected: _person == c.id,
                            onSelected: (v) => setState(() {
                              _person = v ? c.id : null;
                              _personName = v ? _clusterLabel(c) : null;
                            }),
                          ),
                      ],
                    ),
                  _sectionTitle(tr('photo.filter.scene')),
                  if (_scenes.isEmpty)
                    Text(
                      tr('photo.filter.noneScene'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        for (final s in _scenes.take(16))
                          NasChip(
                            visualDensity: VisualDensity.compact,
                            label: Text('${s.label} (${s.count})'),
                            selected: _scene == s.label,
                            onSelected: (v) =>
                                setState(() => _scene = v ? s.label : null),
                          ),
                      ],
                    ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('photo.filter.favorite')),
                    value: _favorite,
                    onChanged: (v) => setState(() => _favorite = v),
                  ),
                  _sectionTitle(tr('photo.filter.time')),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final (value, key) in const [
                        (0, 'photo.filter.all'),
                        (1, 'photo.filter.lastYear'),
                        (3, 'photo.filter.last3Years'),
                      ])
                        NasChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(tr(key)),
                          selected: _timePreset == value,
                          onSelected: (_) => setState(() => _timePreset = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await showPhotoPlacePicker(
                            context,
                            initial: _place,
                          );
                          if (picked == null || !mounted) return;
                          setState(() => _place = picked);
                        },
                        icon: const Icon(Icons.place_outlined, size: 18),
                        label: Text(
                          _place == null
                              ? tr('photo.filter.pickPlace')
                              : tr('photo.filter.placeChip', {
                                  'km': '${(_place!.radiusKm ?? 10).round()}',
                                }),
                        ),
                      ),
                      if (_place != null)
                        IconButton(
                          tooltip: tr('photo.filter.placeClear'),
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _place = null),
                        ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('photo.filter.hint'),
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _FilterOutcome(null, [])),
          child: Text(tr('photo.filter.clear')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(onPressed: _apply, child: Text(tr('photo.filter.apply'))),
      ],
    );
  }
}
