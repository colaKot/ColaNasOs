import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../shell/app_widgets.dart';
import '../../shell/shell_back.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../../core/task_poll.dart';
import 'detail/video_detail_router.dart';
import 'video_card.dart';
import 'video_item_actions.dart';
import 'video_jp_filters.dart';
import 'video_page.dart';

/// 日本片榜单（JavDB 日 / 周 / 月 × 影片 / 演员）。
class VideoJpRankPage extends StatefulWidget {
  const VideoJpRankPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<VideoJpRankPage> createState() => _VideoJpRankPageState();
}

class _VideoJpRankPageState extends State<VideoJpRankPage> {
  bool _loading = true;
  String? _error;
  String _period = 'daily';
  String _kind = 'movie';
  List<Map<String, dynamic>> _items = const [];

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
      final res = await ApiSession.instance.client.videoJpRankMovie(
        body: {'period': _period},
      );
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  Future<void> _loadActors() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoJpRankActor(
        body: {'period': _period},
      );
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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

  Future<void> _reload() async {
    if (_kind == 'actor') {
      await _loadActors();
    } else {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(title: Text(tr('video.jp.rankTitle'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            child: Wrap(
              spacing: NasTokens.spaceMd,
              runSpacing: NasTokens.spaceSm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                NasPillTabs(
                  labels: [
                    tr('video.jp.movie'),
                    tr('video.jp.actor'),
                  ],
                  selectedIndex: _kind == 'actor' ? 1 : 0,
                  onSelect: (i) {
                    final v = i == 1 ? 'actor' : 'movie';
                    if (v == _kind) return;
                    setState(() => _kind = v);
                    _reload();
                  },
                ),
                NasPillTabs(
                  labels: [
                    tr('video.jp.daily'),
                    tr('video.jp.weekly'),
                    tr('video.jp.monthly'),
                  ],
                  selectedIndex:
                      const ['daily', 'weekly', 'monthly'].indexOf(_period),
                  onSelect: (i) {
                    const periods = ['daily', 'weekly', 'monthly'];
                    if (periods[i] == _period) return;
                    setState(() => _period = periods[i]);
                    _reload();
                  },
                ),
                NasRefreshButton(onPressed: _reload),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const NasLoading()
                : _error != null
                ? NasErrorState(message: _error!, onRetry: _reload)
                : _items.isEmpty
                ? NasEmptyState(
                    title: tr('video.jp.empty'),
                    icon: Icons.leaderboard_outlined,
                  )
                // 榜单只读：整列表包一个选区，片名 / 番号可以跨行拖选复制
                : SelectionArea(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NasTokens.spaceMd,
                      ),
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _row(context, _items[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> item) {
    final rank = (item['rank'] as num?)?.toInt() ?? 0;
    final title = '${item['title'] ?? item['name'] ?? ''}';
    final code = item['code'] == null ? '' : '${item['code']}';
    final inLibrary = item['inLibrary'] == true;
    final cover = item['coverUrl'] == null ? null : '${item['coverUrl']}';
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 56,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: NasTokens.fontMono,
                  color: rank <= 3
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  fontWeight: rank <= 3 ? FontWeight.w700 : null,
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 28,
              height: 40,
              child: NasCoverImage(
                url: cover,
                icon: Icons.person_outline,
                cacheWidth: 120,
              ),
            ),
          ],
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: code.isEmpty ? null : Text(code),
      trailing: inLibrary
          ? Chip(
              label: Text(tr('video.jp.inLibrary')),
              visualDensity: VisualDensity.compact,
            )
          : null,
    );
  }
}

/// 日本演员库：进入日本电影库默认显示演员网格，点演员进入她的作品。
///
/// 排序与封面口径：
///   * 演员默认「综合序」= 已收藏 → 有未看 → 未看数多 → 最新入库 → 热度 → 名字；
///   * 演员封面 = 她「最热的未看片」，全看过时退化为全部里最热的一部；
///   * 点进演员后作品按服务端综合序（未看 → 热度 → 评分 → 年份 → 入库 → 收藏）。
class VideoJpActorPage extends StatefulWidget {
  const VideoJpActorPage({
    super.key,
    this.embedded = true,
    this.libraryId,
    this.initialActorName,
  });

  final bool embedded;

  /// 只看某个日本库；null = 所有库
  final String? libraryId;

  /// 直接打开这位演员（从影片详情的「演职人员」点进来）。
  ///
  /// 非空时**只显示演员详情**，不加载演员网格、不再注册自己的返回层 ——
  /// 它是叠在影片详情之上的三级页，返回由外壳统一处理。
  final String? initialActorName;

  @override
  State<VideoJpActorPage> createState() => _VideoJpActorPageState();
}

class _VideoJpActorPageState extends State<VideoJpActorPage> {
  final _searchCtrl = TextEditingController();
  final _actorScroll = ScrollController();
  String _query = '';
  String _sortBy = 'smart';
  String _worksSortBy = 'smart';
  bool _onlyFavorite = false;
  bool _onlyUnwatched = false;

  /// 是否连「已屏蔽」的演员一起显示。
  ///
  /// 屏蔽只影响默认视图：平时列表里不再出现，勾上这个才回来（用来取消屏蔽）。
  bool _showBlocked = false;
  bool _showFanart = false;
  bool _showMovies = false;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _actors = const [];

  /// `_visibleActors` 的 memo：条件不变就不重排（搜索每敲一个字符都会 build）
  List<Map<String, dynamic>>? _visibleCache;
  String _visibleKey = '';

  /// 收藏等就地修改 `_actors` 内容时自增，让上面的 memo 失效
  int _actorsRevision = 0;

  Map<String, dynamic>? _selected;
  bool _worksLoading = false;
  int _worksRequestGeneration = 0;
  String? _worksError;
  List<VideoItem> _works = const [];

  /// 演员页筛选：口径与影片列表完全一致（同一个 VideoJpFilter / 同一个 facets 接口）。
  /// 语义是「名下至少有一部符合条件的影片，这个人才显示」—— 由服务端在
  /// 「演员 × 作品」关系行上过滤，不在客户端拍脑袋。
  VideoJpFilter _filter = const VideoJpFilter();
  int _actorColumns = 1;
  double _actorRowExtent = 0;
  String? _returnActorKey;
  int _returnActorIndex = 0;
  double _returnRowViewportOffset = 0;

  String _k(String name) => 'video.jp.${widget.libraryId ?? 'all'}.$name';

  String get _worksStorageKey =>
      'video.jp.actorWorks.${widget.libraryId ?? 'all'}.${_actorKey(_selected!)}';

  /// true = 「只看这一个演员」模式（从影片详情点演员进来）
  bool get _pinned => (widget.initialActorName ?? '').trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _showFanart = SettingsStore.instance.getBool(_k('fanart')) ?? false;
    _sortBy = SettingsStore.instance.getString(_k('sortBy')) ?? 'smart';
    _worksSortBy =
        SettingsStore.instance.getString(_k('worksSortBy')) ?? 'smart';
    if (_pinned) {
      // 不拉那 500 个演员的网格，直接按名字要档案 + 作品
      _loading = false;
      _openActorByName(widget.initialActorName!.trim());
    } else {
      _load();
    }
  }

  /// 按名字打开演员：先要档案（身高 / 三围 / 生日），再拉作品；
  /// 档案拿不到就只显示名字，至少作品列表是对的。
  Future<void> _openActorByName(String name) async {
    var actor = <String, dynamic>{'name': name};
    try {
      final p = await ApiSession.instance.client.videoJpActorProfile(
        body: {'name': name},
      );
      if (!mounted) return;
      if (p.isNotEmpty) actor = <String, dynamic>{...actor, ...p};
    } catch (_) {
      // 档案接口失败不影响看作品
    }
    if (!mounted) return;
    await _openActor(actor);
    if (!mounted) return;
    final selected = _selected;
    if (selected == null) return;
    // 档案接口只给「身高/三围/生日」，没有列表侧的聚合（共几部、几部未看），
    // 这两个用刚拉到的作品补上，别让页头显示 0 部。
    final patch = <String, dynamic>{};
    if (_int(selected['count']) == 0 && _works.isNotEmpty) {
      patch['count'] = _works.length;
    }
    if (_int(selected['unwatchedCount']) == 0) {
      final unwatched = _works.where((w) => !w.watched).length;
      if (unwatched > 0) patch['unwatchedCount'] = unwatched;
    }
    if (patch.isNotEmpty) {
      setState(() {
        _selected = <String, dynamic>{...selected, ...patch};
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _actorScroll.dispose();
    super.dispose();
  }

  void _toggleFanart() {
    setState(() => _showFanart = !_showFanart);
    SettingsStore.instance.setBool(_k('fanart'), _showFanart);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoJpActorList(
        libraryId: widget.libraryId,
        limit: '500',
        resolution: _filter.resolution.isEmpty ? null : _filter.resolution,
        jpTag: _filter.jpTag.isEmpty ? null : _filter.jpTag,
        genre: _filter.genre.isEmpty ? null : _filter.genre,
        sourceId: _filter.sourceId.isEmpty ? null : _filter.sourceId,
        includeBlocked: _showBlocked ? '1' : null,
      );
      if (!mounted) return;
      setState(() {
        _actors = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _actorsRevision++;
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

  Future<void> _openActor(Map<String, dynamic> actor) async {
    final generation = ++_worksRequestGeneration;
    final filter = _filter;
    setState(() {
      _selected = actor;
      _worksLoading = true;
      _worksError = null;
      _works = const [];
    });
    try {
      // 作品必须和演员列表用同一份筛选：列表写着 1 部，进来就只有这 1 部。
      // libraryId 也要带 —— 不然同一个演员在别的库里的片会被算进来。
      final works = await _fetchActorWorks(actor, filter);
      if (!mounted ||
          generation != _worksRequestGeneration ||
          _selected != actor) {
        return;
      }
      setState(() {
        _works = works;
        _worksLoading = false;
      });
    } catch (e) {
      if (!mounted ||
          generation != _worksRequestGeneration ||
          _selected != actor) {
        return;
      }
      setState(() {
        _worksError = '$e';
        _worksLoading = false;
      });
    }
  }

  Future<List<VideoItem>> _fetchActorWorks(
    Map<String, dynamic> actor,
    VideoJpFilter filter,
  ) async {
    final res = await ApiSession.instance.client.videoJpActorWorks(
      key: _str(actor['key']).isEmpty ? null : _str(actor['key']),
      name: _str(actor['name']),
      libraryId: widget.libraryId,
      limit: '2000',
      resolution: filter.resolution.isEmpty ? null : filter.resolution,
      jpTag: filter.jpTag.isEmpty ? null : filter.jpTag,
      genre: filter.genre.isEmpty ? null : filter.genre,
      sourceId: filter.sourceId.isEmpty ? null : filter.sourceId,
    );
    return ((res['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => VideoItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  bool _sameJpFilter(VideoJpFilter a, VideoJpFilter b) =>
      a.resolution == b.resolution &&
      a.jpTag == b.jpTag &&
      a.sourceId == b.sourceId &&
      a.genre == b.genre;

  Future<List<VideoItem>?> _fetchGridActorWorks(
    Map<String, dynamic> actor,
  ) async {
    final filter = _filter;
    final onlyUnwatched = _onlyUnwatched;
    final loadedWorks = await _fetchActorWorks(actor, filter);
    if (!mounted) return null;
    if (!_sameJpFilter(filter, _filter) || onlyUnwatched != _onlyUnwatched) {
      NasSnack.show(context, tr('video.jp.actorScopeChanged'));
      return null;
    }
    final works = onlyUnwatched
        ? loadedWorks.where((work) => !work.watched).toList()
        : loadedWorks;
    if (works.length >= 2000) {
      NasSnack.show(context, tr('video.jp.actorWorksTooMany'));
      return null;
    }
    final expected = onlyUnwatched
        ? _int(actor['unwatchedCount'])
        : _int(actor['count'] ?? actor['items']);
    if (works.length != expected) {
      NasSnack.show(context, tr('video.jp.actorScopeChanged'));
      return null;
    }
    return works;
  }

  void _closeActor() {
    _worksRequestGeneration++;
    setState(() {
      _selected = null;
      _works = const [];
      _worksError = null;
    });
    _restoreActorPosition();
  }

  String _actorKey(Map<String, dynamic> actor) {
    final key = _str(actor['key']);
    return key.isNotEmpty ? key : _str(actor['name']);
  }

  void _openActorFromGrid(Map<String, dynamic> actor) {
    final list = _visibleActors;
    final key = _actorKey(actor);
    final index = list.indexWhere((candidate) => _actorKey(candidate) == key);
    final columns = _actorColumns < 1 ? 1 : _actorColumns;
    final rowExtent = _actorRowExtent > 0 ? _actorRowExtent : 1;
    final row = (index < 0 ? 0 : index) ~/ columns;
    _returnActorKey = key;
    _returnActorIndex = index < 0 ? 0 : index;
    _returnRowViewportOffset = _actorScroll.hasClients
        ? _actorScroll.offset - row * rowExtent
        : 0;
    unawaited(_openActor(actor));
  }

  void _restoreActorPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selected != null || !_actorScroll.hasClients) return;
      final list = _visibleActors;
      if (list.isEmpty) return;
      var index = list.indexWhere(
        (actor) => _actorKey(actor) == _returnActorKey,
      );
      if (index < 0) {
        index = _returnActorIndex.clamp(0, list.length - 1).toInt();
      }
      final columns = _actorColumns < 1 ? 1 : _actorColumns;
      final rowExtent = _actorRowExtent;
      if (rowExtent <= 0) return;
      final target = (index ~/ columns) * rowExtent + _returnRowViewportOffset;
      final position = _actorScroll.position;
      _actorScroll.jumpTo(target.clamp(0, position.maxScrollExtent).toDouble());
    });
  }

  void _updateWorksFilter(VideoJpFilter filter) {
    setState(() => _filter = filter);
    final actor = _selected;
    if (actor != null) unawaited(_openActor(actor));
    unawaited(_load());
  }

  List<VideoItem> get _sortedWorks {
    final works = List<VideoItem>.of(_works);
    int titleOrder(VideoItem a, VideoItem b) {
      final order = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return order != 0 ? order : a.id.compareTo(b.id);
    }

    switch (_worksSortBy) {
      case 'title':
        works.sort(titleOrder);
        break;
      case 'year':
        works.sort((a, b) {
          final order = (b.year ?? 0).compareTo(a.year ?? 0);
          return order != 0 ? order : titleOrder(a, b);
        });
        break;
      case 'rating':
        works.sort((a, b) {
          final order = (b.score ?? -1).compareTo(a.score ?? -1);
          return order != 0 ? order : titleOrder(a, b);
        });
        break;
      case 'unwatched':
        works.sort((a, b) {
          final order = (a.watched ? 1 : 0).compareTo(b.watched ? 1 : 0);
          return order != 0 ? order : titleOrder(a, b);
        });
        break;
    }
    return works;
  }

  Future<void> _toggleFavorite(Map<String, dynamic> actor) async {
    final target = actor['favorite'] != true;
    try {
      await ApiSession.instance.client.videoJpActorFavorite(
        body: {'name': _str(actor['name']), 'favorite': target},
      );
      if (!mounted) return;
      setState(() {
        actor['favorite'] = target;
        _actorsRevision++;
        if (_selected == actor) _selected = Map<String, dynamic>.from(actor);
      });
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  /// 删除「当前范围下这位演员的全部作品」——不是删除这个演员。
  ///
  /// 三条底线：范围说清楚、可恢复、不牵连范围外的数据。
  ///   · 名单就是作品接口按同一份筛选返回的 ids（没有筛选时 = 她全部作品，
  ///     这时候确认框会换成「全部 N 部」的口径，不能让人以为是筛出来的那几部）；
  ///   · 走回收站（permanent: false）；
  ///   · 服务端只删这些条目及其关联行，绝不 delete jp_actors。
  Future<void> _deleteFilteredWorks(
    Map<String, dynamic> actor, {
    List<VideoItem>? scopedWorks,
  }) async {
    final noFilter = _filter.isEmpty && !_onlyUnwatched;
    final candidates = scopedWorks ?? _works;
    final filtered = _onlyUnwatched
        ? candidates.where((work) => !work.watched)
        : candidates;
    final ids = filtered.map((e) => e.id).toSet().toList();
    if (ids.isEmpty) return;
    if (ids.length >= 2000) {
      NasSnack.show(
        context,
        tr('video.jp.deleteTooMany', {'count': '${ids.length}'}),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(
          noFilter
              ? tr('video.jp.deleteWorksBodyAll', {
                  'name': _str(actor['name']),
                  'count': '${ids.length}',
                })
              : tr('video.jp.deleteWorksBody', {'count': '${ids.length}'}),
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
    );
    if (ok != true || !mounted) return;
    // 提前拿 messenger：后面要 await 删除任务，别把 BuildContext 带过异步间隙
    final messenger = ScaffoldMessenger.of(context);
    final actorWasOpen = _selected == actor;
    setState(() => _worksLoading = true);
    try {
      final res = await ApiSession.instance.client.videoItemsDeleteTask(
        body: VideoDeleteItemsBody(ids: ids, permanent: false),
      );
      final taskId = _str(res['taskId']);
      if (taskId.isNotEmpty) {
        final task = await waitTask(taskId);
        if (task != null && task['state'] != 'done') {
          NasSnack.showOn(messenger, '${task['error'] ?? task['state']}');
          if (actorWasOpen) await _openActor(actor);
          await _load();
          return;
        }
      }
      NasSnack.showOn(
        messenger,
        tr('video.jp.deleteWorksDone', {'count': '${ids.length}'}),
      );
      // 删完这批，这个人在当前筛选下可能就不再出现 —— 但她的档案和不符合
      // 筛选的影片都还在，取消筛选立刻能再看到她。
      if (actorWasOpen) await _openActor(actor);
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _worksLoading = false);
    }
  }

  Future<void> _deleteFilteredWorksFromGrid(Map<String, dynamic> actor) async {
    try {
      final works = await _fetchGridActorWorks(actor);
      if (works == null) return;
      await _deleteFilteredWorks(actor, scopedWorks: works);
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    }
  }

  Future<void> _markFilteredWorksWatched(Map<String, dynamic> actor) async {
    try {
      final works = await _fetchGridActorWorks(actor);
      if (works == null) return;
      final ids = works
          .where((work) => !work.watched)
          .map((work) => work.id)
          .toList();
      if (ids.isEmpty) return;
      await ApiSession.instance.client.videoWatchMark(
        body: VideoWatchBody(ids: ids, watched: true),
      );
      if (!mounted) return;
      NasSnack.show(
        context,
        tr('video.jp.markFilteredWatchedDone', {'count': '${ids.length}'}),
      );
      await _load();
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    }
  }

  List<NasMenuEntry> _actorMenuEntries(Map<String, dynamic> actor) {
    final count = _int(actor['count'] ?? actor['items']);
    final unwatched = _int(actor['unwatchedCount']);
    final blocked = actor['blocked'] == true;
    final deleteCount = _onlyUnwatched ? unwatched : count;
    // 没有任何筛选时，「删除当前筛选下的作品」这个名字会误导：那等于她全部作品。
    final noFilter = _filter.isEmpty && !_onlyUnwatched;
    return [
      NasMenuEntry(
        label: tr('video.jp.markFilteredWatched', {'count': '$unwatched'}),
        icon: Icons.done_all,
        onSelected: unwatched == 0
            ? null
            : () => unawaited(_markFilteredWorksWatched(actor)),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: tr('video.jp.copyActorName'),
        icon: Icons.content_copy,
        onSelected: () => unawaited(_copyActorName(actor)),
      ),
      NasMenuEntry(
        label: blocked ? tr('video.jp.unblockActor') : tr('video.jp.blockActor'),
        icon: blocked ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        onSelected: () => unawaited(_toggleActorBlocked(actor)),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: noFilter
            ? tr('video.jp.deleteAllWorksCount', {'count': '$deleteCount'})
            : tr('video.jp.deleteWorksCount', {'count': '$deleteCount'}),
        icon: Icons.delete_outline,
        danger: true,
        onSelected: () => unawaited(_deleteFilteredWorksFromGrid(actor)),
      ),
    ];
  }

  /// 复制演员名：卡片上右键要留给菜单，所以这里给一条显式入口，
  /// 详情页那边是可以直接拖选的。
  Future<void> _copyActorName(Map<String, dynamic> actor) async {
    final name = _str(actor['name']);
    if (name.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: name));
    if (mounted) NasSnack.show(context, tr('common.copied'));
  }

  /// 屏蔽 / 取消屏蔽：只改「这个用户的演员列表视图」，不动演员档案与影片。
  Future<void> _toggleActorBlocked(Map<String, dynamic> actor) async {
    final name = _str(actor['name']);
    if (name.isEmpty) return;
    final target = actor['blocked'] != true;
    try {
      await ApiSession.instance.client.videoJpActorBlock(
        body: <String, dynamic>{'name': name, 'blocked': target},
      );
      if (!mounted) return;
      setState(() {
        actor['blocked'] = target;
        _actorsRevision++;
        if (_selected == actor) {
          _selected = Map<String, dynamic>.from(actor);
        }
        // 默认视图不显示已屏蔽的：刚屏蔽的人立刻从当前列表里拿掉，
        // 不然要手动刷新才「消失」，会让人误以为没生效。
        if (target && !_showBlocked) {
          _actors = _actors
              .where((candidate) => !identical(candidate, actor))
              .toList();
        }
      });
      NasSnack.show(
        context,
        tr(
          target ? 'video.jp.blockedDone' : 'video.jp.unblockedDone',
          {'name': name},
        ),
      );
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    }
  }

  Future<void> _showActorActionSheet(Map<String, dynamic> actor) async {
    final entries = _actorMenuEntries(actor);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final entry in entries)
                if (entry.isDivider)
                  const Divider()
                else
                  ListTile(
                    dense: true,
                    leading: entry.icon == null
                        ? null
                        : Icon(
                            entry.icon,
                            size: 20,
                            color: entry.danger ? scheme.error : null,
                          ),
                    title: Text(
                      entry.label,
                      style: TextStyle(
                        color: entry.danger ? scheme.error : null,
                      ),
                    ),
                    onTap: entry.enabled
                        ? () {
                            Navigator.pop(ctx);
                            entry.onSelected?.call();
                          }
                        : null,
                  ),
            ],
          ),
        );
      },
    );
  }

  List<Map<String, dynamic>> get _visibleActors {
    // 500 个演员每次 build 都过滤 + 排序，搜索每敲一个字就重排一遍（2026-11-04：
    // 打字也卡）。条件没变就复用上一次的结果。
    final key =
        '$_query\u0001$_sortBy\u0001$_onlyFavorite\u0001$_onlyUnwatched'
        '\u0001${_actors.length}\u0001$_actorsRevision';
    if (_visibleCache != null && _visibleKey == key) return _visibleCache!;
    final q = _query.trim().toLowerCase();
    final list = _actors.where((a) {
      if (_onlyFavorite && a['favorite'] != true) return false;
      if (_onlyUnwatched && _int(a['unwatchedCount']) <= 0) return false;
      if (q.isNotEmpty && !_str(a['name']).toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();

    switch (_sortBy) {
      case 'name':
        list.sort((a, b) => _str(a['name']).compareTo(_str(b['name'])));
        break;
      case 'hot':
        list.sort((a, b) => _int(b['hot']) - _int(a['hot']));
        break;
      case 'unwatched':
        list.sort(
          (a, b) => _int(b['unwatchedCount']) - _int(a['unwatchedCount']),
        );
        break;
      case 'count':
        list.sort(
          (a, b) =>
              _int(b['count'] ?? b['items']) - _int(a['count'] ?? a['items']),
        );
        break;
      default:
        // 综合序（服务端已按同口径返回，这里再排一次
        // 是为了收藏切换后立即生效，不用重新请求）
        list.sort((a, b) {
          var c =
              (b['favorite'] == true ? 1 : 0) - (a['favorite'] == true ? 1 : 0);
          if (c != 0) return c;
          c =
              (_int(b['unwatchedCount']) > 0 ? 1 : 0) -
              (_int(a['unwatchedCount']) > 0 ? 1 : 0);
          if (c != 0) return c;
          c = _int(b['unwatchedCount']) - _int(a['unwatchedCount']);
          if (c != 0) return c;
          c = _int(b['latestCreateTime']) - _int(a['latestCreateTime']);
          if (c != 0) return c;
          c = _int(b['hot']) - _int(a['hot']);
          if (c != 0) return c;
          return _str(a['name']).compareTo(_str(b['name']));
        });
        break;
    }
    _visibleCache = list;
    _visibleKey = key;
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return SubPageScope(
      // pinned：三层页里的返回由外壳那层 SubPageScope 负责，
      // 这里再注册一个只会把「演员详情」退成空网格。
      active: !_pinned && (_showMovies || _selected != null),
      onBack: () {
        if (_showMovies) {
          setState(() => _showMovies = false);
        } else if (_selected != null) {
          _closeActor();
        }
      },
      child: _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    final body = _showMovies
        ? _buildMoviesView()
        : (_selected == null ? _buildActorView() : _buildActorDetail());
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _pinned && _selected != null
              ? _str(_selected!['name'])
              : tr('video.jp.actorTitle'),
        ),
      ),
      body: body,
    );
  }

  Widget _buildActorView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceMd,
            NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('video.jp.searchHint'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: tr('common.close'),
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              // 筛选：和普通影视列表同一个按钮样式（有筛选时高亮），
              // 点开才是演员页自己的各种条件，不再常驻占两行。
              VideoJpFilterButton(
                value: _filter,
                libraryId: widget.libraryId,
                onlyFavorite: _onlyFavorite,
                onlyUnwatched: _onlyUnwatched,
                showBlocked: _showBlocked,
                onOnlyFavoriteChanged: (v) => setState(() => _onlyFavorite = v),
                onOnlyUnwatchedChanged: (v) =>
                    setState(() => _onlyUnwatched = v),
                onShowBlockedChanged: (v) {
                  setState(() => _showBlocked = v);
                  _load();
                },
                onChanged: (v) {
                  setState(() => _filter = v);
                  _load();
                },
              ),
              PopupMenuButton<String>(
                initialValue: _sortBy,
                tooltip: tr('video.jp.sort'),
                onSelected: (v) {
                  setState(() => _sortBy = v);
                  SettingsStore.instance.setString(_k('sortBy'), v);
                },
                itemBuilder: (_) => [
                  for (final (value, key) in const [
                    ('smart', 'video.jp.sortSmart'),
                    ('unwatched', 'video.jp.sortUnwatched'),
                    ('hot', 'video.jp.sortHot'),
                    ('count', 'video.jp.sortCount'),
                    ('name', 'video.jp.sortName'),
                  ])
                    PopupMenuItem(value: value, child: Text(tr(key))),
                ],
                child: Icon(
                  Icons.sort_by_alpha,
                  color: _sortBy == 'smart'
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              IconButton(
                tooltip: _showFanart
                    ? tr('video.jp.poster')
                    : tr('video.jp.fanart'),
                onPressed: _toggleFanart,
                icon: Icon(
                  _showFanart ? Icons.crop_16_9 : Icons.crop_portrait,
                  color: _showFanart
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              // 「影片」视图的入口。纯图标在满屏海报里几乎看不见，补上文字。
              TextButton.icon(
                onPressed: () => setState(() => _showMovies = true),
                icon: const Icon(Icons.movie_outlined, size: 18),
                label: Text(tr('video.jp.movie')),
              ),
              NasRefreshButton(onPressed: _loading ? null : _load),
            ],
          ),
        ),
        // 筛选入口已收进顶栏按钮，这里直接留整块高度给演员网格。
        Expanded(
          child: _loading
              ? const NasLoading()
              : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : _buildActorGrid(),
        ),
      ],
    );
  }

  Widget _buildActorGrid() {
    final list = _visibleActors;
    if (list.isEmpty) {
      return NasEmptyState(
        title: tr('video.jp.emptyActors'),
        icon: Icons.people_outline,
      );
    }
    return LayoutBuilder(
      builder: (context, cons) {
        const spacing = 12.0;
        final compact = cons.maxWidth < 600;
        final base = compact ? 112.0 : 168.0;
        final target = _showFanart ? base * 2.25 : base;
        final cols = ((cons.maxWidth - spacing * 2) / (target + spacing))
            .floor()
            .clamp(1, 12);
        final cellW = (cons.maxWidth - spacing * (cols + 1)) / cols;
        // 卡片高度 = 图 + 文本块（见 _actorCard 的 Column：6 + 名 + 数量 + 身高）
        final imgH = _showFanart ? cellW / 1.5 : cellW * 1.5;
        _actorColumns = cols;
        _actorRowExtent = imgH + 64 + spacing + 4;
        // 必须用 GridView.builder 懒加载：Wrap + SingleChildScrollView 会把
        // 全部演员（本库 500 个）一次性建出来，每人再发一张封面请求 ——
        // 500 张图同时下、同时解码，滚动/点击全卡死（2026-11-04 反馈）。
        return GridView.builder(
          key: PageStorageKey<String>(
            'video.jp.actors.${widget.libraryId ?? 'all'}',
          ),
          controller: _actorScroll,
          padding: const EdgeInsets.fromLTRB(spacing, 8, spacing, 32),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing + 4,
            crossAxisSpacing: spacing,
            mainAxisExtent: imgH + 64,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final actor = list[i];
            return RepaintBoundary(
              child: NasContextMenuRegion(
                entries: _actorMenuEntries(actor),
                child: _actorCard(actor, cellW),
              ),
            );
          },
        );
      },
    );
  }

  Widget _actorCard(Map<String, dynamic> actor, double width) {
    final fav = actor['favorite'] == true;
    final cover = _coverItemOf(actor);
    final avatar = _str(actor['avatarUrl']);
    // 一定要带 size：不带就走原图直出（单张 200KB~2MB），
    // 网格里几十张同时拉，SMB 上就是几十 MB 的网络盘读盘。
    // 带 size 后走 /files/thumb 的本地缓存，命中后只有 20KB 左右。
    final url = cover != null
        ? videoPosterUrl(
            cover,
            kind: _showFanart ? 'fanart' : 'poster',
            size: (width * 2).round(),
          )
        : (avatar.isEmpty ? null : avatar);
    final unwatched = _int(actor['unwatchedCount']);
    final count = _int(actor['count'] ?? actor['items']);
    final height = _int(actor['heightCm']);

    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: () => _openActorFromGrid(actor),
      onLongPress: () => unawaited(_showActorActionSheet(actor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: _showFanart ? 3 / 2 : 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NasCoverImage(
                    url: url,
                    fit: _showFanart ? BoxFit.contain : BoxFit.cover,
                    // 头像走远程 CDN（jdbstatic 等），带 Authorization 会触发 CORS 预检
                    // 直接被浏览器挡掉；只有本服务的海报接口才需要认证头。
                    headers: cover != null ? videoArtHeaders : const {},
                    icon: Icons.person_outline,
                    cacheWidth: (width * 2).round(),
                  ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.42),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _toggleFavorite(actor),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(
                            fav ? Icons.star : Icons.star_border,
                            size: 17,
                            color: fav ? const Color(0xFFF5B301) : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (unwatched > 0)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '$unwatched',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (actor['blocked'] == true) ...[
                Container(
                  margin: const EdgeInsets.only(right: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tr('video.jp.blockedBadge'),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              Expanded(
                child: Text(
                  _str(actor['name']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Text(
            '$count ${tr('video.jp.items')}',
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          if (height > 0)
            Text(
              '$height cm',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  /// 「影片」视图：直接复用普通列表页（分页 / 搜索 / 排序 / 筛选都在），
  /// 顶栏额外给一个「返回演员」按钮 —— 列表页顶栏放同样的切换钮。
  Widget _buildMoviesView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceXs,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: tr('video.jp.actor'),
                onPressed: () => setState(() => _showMovies = false),
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  tr('video.jp.movie'),
                  style: const TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: VideoPage(
            embedded: true,
            libraryId: widget.libraryId,
            jp: true,
            jpFilter: _filter,
          ),
        ),
      ],
    );
  }

  Widget _buildActorDetail() {
    final actor = _selected!;
    final name = _str(actor['name']);
    final fav = actor['favorite'] == true;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceXs,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              if (!_pinned)
                IconButton(
                  tooltip: tr('video.jp.back'),
                  onPressed: _closeActor,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // 删的是「当前筛选下这批作品」，不是这个演员：
              // 演员档案、收藏关系、以及不符合筛选的影片一律不动。
              IconButton(
                tooltip: tr('video.jp.deleteWorks'),
                onPressed: _worksLoading
                    ? null
                    : () => _deleteFilteredWorks(actor),
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: fav
                    ? tr('video.jp.unfavorite')
                    : tr('video.jp.favorite'),
                onPressed: () => _toggleFavorite(actor),
                icon: Icon(
                  fav ? Icons.star : Icons.star_border,
                  color: fav ? const Color(0xFFF5B301) : null,
                ),
              ),
              IconButton(
                tooltip: _showFanart
                    ? tr('video.jp.poster')
                    : tr('video.jp.fanart'),
                onPressed: _toggleFanart,
                icon: Icon(
                  _showFanart ? Icons.crop_16_9 : Icons.crop_portrait,
                  color: _showFanart
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceMd,
            vertical: NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              VideoJpFilterButton(
                value: _filter,
                libraryId: widget.libraryId,
                onlyFavorite: _onlyFavorite,
                onlyUnwatched: _onlyUnwatched,
                onOnlyFavoriteChanged: (value) {
                  setState(() => _onlyFavorite = value);
                  unawaited(_load());
                },
                onOnlyUnwatchedChanged: (value) {
                  setState(() => _onlyUnwatched = value);
                  unawaited(_load());
                },
                onChanged: _updateWorksFilter,
              ),
              PopupMenuButton<String>(
                initialValue: _worksSortBy,
                tooltip: tr('video.jp.worksSort'),
                onSelected: (value) {
                  setState(() => _worksSortBy = value);
                  SettingsStore.instance.setString(_k('worksSortBy'), value);
                },
                itemBuilder: (_) => [
                  for (final (value, key) in const [
                    ('smart', 'video.jp.worksSortSmart'),
                    ('unwatched', 'video.jp.worksSortUnwatched'),
                    ('rating', 'video.jp.worksSortRating'),
                    ('year', 'video.jp.worksSortYear'),
                    ('title', 'video.jp.worksSortTitle'),
                  ])
                    PopupMenuItem(value: value, child: Text(tr(key))),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sort),
                    const SizedBox(width: NasTokens.spaceXs),
                    Text(tr('video.jp.worksSort')),
                  ],
                ),
              ),
              const Spacer(),
              if (_filter.isNotEmpty)
                Text(
                  tr('video.jp.filterActiveCount', {
                    'count': '${_filter.activeCount}',
                  }),
                  style: TextStyle(color: context.nasTextSecondary),
                ),
            ],
          ),
        ),
        // 演员名 / 影片数 / 三围 / 生日都能拖选复制，鼠标停上去是 I 型光标
        SelectionArea(child: _ActorHeader(actor: actor)),
        Expanded(
          child: _worksLoading
              ? const NasLoading()
              : _worksError != null
              ? NasErrorState(
                  message: _worksError!,
                  onRetry: () => _openActor(actor),
                )
              : _works.isEmpty
              ? NasEmptyState(
                  title: tr('video.jp.noWorks'),
                  icon: Icons.movie_outlined,
                )
              : _buildWorksGrid(),
        ),
      ],
    );
  }

  Widget _buildWorksGrid() {
    final works = _sortedWorks;
    return LayoutBuilder(
      builder: (context, cons) {
        const spacing = 12.0;
        final compact = cons.maxWidth < 600;
        final base = compact ? 120.0 : 176.0;
        final target = _showFanart ? base * 1.5 : base;
        final cols = ((cons.maxWidth - spacing * 2) / (target + spacing))
            .floor()
            .clamp(1, 12);
        final cellW = (cons.maxWidth - spacing * (cols + 1)) / cols;
        // VideoPosterCard 内部按「图 + 42px 文本块」排，网格高度必须一致
        final imgH = _showFanart ? cellW / (3 / 2) : cellW * 1.5;
        // 同演员网格：作品最多 200 条，Wrap 会全量构建，改成懒加载
        return GridView.builder(
          key: PageStorageKey<String>(_worksStorageKey),
          padding: const EdgeInsets.fromLTRB(spacing, 8, spacing, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: imgH + 44,
          ),
          itemCount: works.length,
          itemBuilder: (context, i) {
            final item = works[i];
            Future<void> run(String action) async {
              final changed = await runVideoItemAction(context, action, item);
              if (!mounted || _selected == null) return;
              // 删片会改变演员在当前筛选下的影片数，演员列表也要跟着重算
              if (action == VideoItemAction.delete) await _load();
              if (changed) await _openActor(_selected!);
            }

            return RepaintBoundary(
              child: NasContextMenuRegion(
                entries: videoItemMenuEntries(
                  item,
                  onAction: run,
                  context: context,
                ),
                child: GestureDetector(
                  onLongPress: () async {
                    final action = await showVideoItemActionSheet(
                      context,
                      item,
                    );
                    if (action != null) await run(action);
                  },
                  child: VideoPosterCard(
                    item: item,
                    width: cellW,
                    showFanart: _showFanart,
                    onTap: () async {
                      await openVideoDetail(context, item);
                      // 详情页里标记已看 / 收藏 / 删片后，回来不能还是旧状态
                      if (!mounted || _selected == null) return;
                      await _openActor(_selected!);
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 演员详情顶部信息卡：头像 + 名字 + 影片数 / 未看 / 评分 / 热度 / 档案。
class _ActorHeader extends StatelessWidget {
  const _ActorHeader({required this.actor});

  final Map<String, dynamic> actor;

  @override
  Widget build(BuildContext context) {
    final avatar = _str(actor['avatarUrl']);
    final count = _int(actor['count'] ?? actor['items']);
    final unwatched = _int(actor['unwatchedCount']);
    final scoreAvg = (actor['scoreAvg'] as num?)?.toDouble() ?? 0;
    final hotTotal = _int(actor['hotTotal']);
    final height = _int(actor['heightCm']);
    final weight = _int(actor['weightKg']);
    final bust = _int(actor['bust']);
    final waist = _int(actor['waist']);
    final hip = _int(actor['hip'] ?? actor['hips']);
    final cup = _str(actor['cup']);
    final birthday = _str(actor['birthday']);
    final birthplace = _str(actor['birthplace']);

    final measurements = <String>[
      if (bust > 0) '$bust',
      if (waist > 0) '$waist',
      if (hip > 0) '$hip',
    ].join(' / ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        0,
        NasTokens.spaceMd,
        NasTokens.spaceXs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 64,
              height: 64,
              child: NasCoverImage(
                url: avatar.isEmpty ? null : avatar,
                icon: Icons.person,
                cacheWidth: 160,
              ),
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _str(actor['name']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 10,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '$count ${tr('video.jp.items')}',
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                    if (unwatched > 0)
                      Text(
                        '$unwatched ${tr('video.jp.items')}${tr('video.card.unwatched')}',
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (scoreAvg > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Colors.amber.shade600,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            scoreAvg.toStringAsFixed(2),
                            style: const TextStyle(
                              fontSize: NasTokens.fontCaption,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    if (hotTotal > 0)
                      Text(
                        '$hotTotal',
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                  ],
                ),
                if (height > 0 ||
                    weight > 0 ||
                    measurements.isNotEmpty ||
                    cup.isNotEmpty ||
                    birthday.isNotEmpty ||
                    birthplace.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      if (height > 0)
                        Text(
                          '$height cm',
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (weight > 0)
                        Text(
                          '$weight kg',
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      if (measurements.isNotEmpty)
                        Text(
                          measurements,
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      if (cup.isNotEmpty)
                        Text(
                          cup,
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      if (birthday.isNotEmpty)
                        Text(
                          birthday,
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      if (birthplace.isNotEmpty)
                        Text(
                          birthplace,
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

VideoItem? _coverItemOf(Map<String, dynamic> actor) {
  final raw = actor['coverItem'];
  if (raw is! Map) return null;
  try {
    return VideoItem.fromJson(Map<String, dynamic>.from(raw));
  } catch (_) {
    return null;
  }
}

int _int(Object? v) {
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}'.trim()) ?? 0;
}

String _str(Object? v) => v == null ? '' : '$v';

/// 打开「某位日本演员」的详情（与 `openVideoDetail` 同口径）。
///
/// 影片详情里点演员时用它：日本库的演员页有身高 / 三围 / 生日 / 收藏，
/// 和普通库的「某人的作品」不是同一页，别拿后者顶。
Future<void> openVideoJpActor(
  BuildContext context, {
  required String name,
  String? libraryId,
}) {
  final router = VideoDetailRouter.instance;
  if (router.embeddableFrom(context)) {
    router.open(
      VideoDetailEntry(
        tag: 'jpactor:${libraryId ?? 'all'}:$name',
        build: (_) => VideoJpActorPage(
          embedded: true,
          libraryId: libraryId,
          initialActorName: name,
        ),
      ),
    );
    return Future<void>.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideoJpActorPage(
        embedded: false,
        libraryId: libraryId,
        initialActorName: name,
      ),
    ),
  );
}
