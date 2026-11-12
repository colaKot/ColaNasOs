import 'package:flutter/material.dart';
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
            child: Row(
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'movie',
                      label: Text(tr('video.jp.movie')),
                    ),
                    ButtonSegment(
                      value: 'actor',
                      label: Text(tr('video.jp.actor')),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (v) {
                    setState(() => _kind = v.first);
                    _reload();
                  },
                ),
                const SizedBox(width: NasTokens.spaceSm),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'daily',
                      label: Text(tr('video.jp.daily')),
                    ),
                    ButtonSegment(
                      value: 'weekly',
                      label: Text(tr('video.jp.weekly')),
                    ),
                    ButtonSegment(
                      value: 'monthly',
                      label: Text(tr('video.jp.monthly')),
                    ),
                  ],
                  selected: {_period},
                  onSelectionChanged: (v) {
                    setState(() => _period = v.first);
                    _reload();
                  },
                ),
                const Spacer(),
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
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NasTokens.spaceMd,
                    ),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _row(context, _items[i]),
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
  String _query = '';
  String _sortBy = 'smart';
  bool _onlyFavorite = false;
  bool _onlyUnwatched = false;
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
  String? _worksError;
  List<VideoItem> _works = const [];

  /// 演员页筛选：口径与影片列表完全一致（同一个 VideoJpFilter / 同一个 facets 接口）。
  /// 语义是「名下至少有一部符合条件的影片，这个人才显示」—— 由服务端在
  /// 「演员 × 作品」关系行上过滤，不在客户端拍脑袋。
  VideoJpFilter _filter = const VideoJpFilter();

  String _k(String name) => 'video.jp.${widget.libraryId ?? 'all'}.$name';

  /// true = 「只看这一个演员」模式（从影片详情点演员进来）
  bool get _pinned => (widget.initialActorName ?? '').trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _showFanart = SettingsStore.instance.getBool(_k('fanart')) ?? false;
    _sortBy = SettingsStore.instance.getString(_k('sortBy')) ?? 'smart';
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
    setState(() {
      _selected = actor;
      _worksLoading = true;
      _worksError = null;
      _works = const [];
    });
    try {
      // 作品必须和演员列表用同一份筛选：列表写着 1 部，进来就只有这 1 部。
      // libraryId 也要带 —— 不然同一个演员在别的库里的片会被算进来。
      final res = await ApiSession.instance.client.videoJpActorWorks(
        key: _str(actor['key']).isEmpty ? null : _str(actor['key']),
        name: _str(actor['name']),
        libraryId: widget.libraryId,
        limit: '2000',
        resolution: _filter.resolution.isEmpty ? null : _filter.resolution,
        jpTag: _filter.jpTag.isEmpty ? null : _filter.jpTag,
        genre: _filter.genre.isEmpty ? null : _filter.genre,
        sourceId: _filter.sourceId.isEmpty ? null : _filter.sourceId,
      );
      if (!mounted || _selected != actor) return;
      setState(() {
        _works = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => VideoItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _worksLoading = false;
      });
    } catch (e) {
      if (!mounted || _selected != actor) return;
      setState(() {
        _worksError = '$e';
        _worksLoading = false;
      });
    }
  }

  void _closeActor() {
    setState(() {
      _selected = null;
      _works = const [];
      _worksError = null;
    });
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

  /// 删除「当前筛选下这位演员的全部作品」——不是删除这个演员。
  ///
  /// 批量删除的三条底线：范围说清楚、可恢复、不牵连范围外的数据。
  ///   · 名单就是作品接口按同一份筛选返回的 ids（触到上限就拒绝，避免「全部」名不副实）；
  ///   · 走回收站（permanent: false）；
  ///   · 服务端只删这些条目及其关联行，绝不 delete jp_actors。
  Future<void> _deleteFilteredWorks(Map<String, dynamic> actor) async {
    if (_filter.isEmpty) {
      NasSnack.show(context, tr('video.jp.deleteNeedFilter'));
      return;
    }
    final ids = _works.map((e) => e.id).toList();
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
          tr('video.jp.deleteWorksBody', {'count': '${ids.length}'}),
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
          await _openActor(actor);
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
      await _openActor(actor);
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    } finally {
      if (mounted) setState(() => _worksLoading = false);
    }
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
                onOnlyFavoriteChanged: (v) => setState(() => _onlyFavorite = v),
                onOnlyUnwatchedChanged: (v) =>
                    setState(() => _onlyUnwatched = v),
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
        // 必须用 GridView.builder 懒加载：Wrap + SingleChildScrollView 会把
        // 全部演员（本库 500 个）一次性建出来，每人再发一张封面请求 ——
        // 500 张图同时下、同时解码，滚动/点击全卡死（2026-11-04 反馈）。
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(spacing, 8, spacing, 32),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing + 4,
            crossAxisSpacing: spacing,
            mainAxisExtent: imgH + 64,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) =>
              RepaintBoundary(child: _actorCard(list[i], cellW)),
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
      onTap: () => _openActor(actor),
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
          Text(
            _str(actor['name']),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: NasTokens.fontBody,
              fontWeight: FontWeight.w600,
            ),
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
  /// 顶栏额外给一个「返回演员」按钮 —— 既有实现是在列表页顶栏放同样的切换钮。
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
                onPressed: _worksLoading ? null : () => _deleteFilteredWorks(actor),
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
        _ActorHeader(actor: actor),
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
          padding: const EdgeInsets.fromLTRB(spacing, 8, spacing, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: imgH + 44,
          ),
          itemCount: _works.length,
          itemBuilder: (context, i) {
            final item = _works[i];
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
                    final action = await showVideoItemActionSheet(context, item);
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
