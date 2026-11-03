import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'video_card.dart';
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
                IconButton(
                  tooltip: tr('common.refresh'),
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
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
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) =>
                                _row(context, _items[i]),
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
  const VideoJpActorPage({super.key, this.embedded = true, this.libraryId});

  final bool embedded;

  /// 只看某个日本库；null = 所有库
  final String? libraryId;

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

  Map<String, dynamic>? _selected;
  bool _worksLoading = false;
  String? _worksError;
  List<VideoItem> _works = const [];

  String _k(String name) => 'video.jp.${widget.libraryId ?? 'all'}.$name';

  @override
  void initState() {
    super.initState();
    _showFanart = SettingsStore.instance.getBool(_k('fanart')) ?? false;
    _sortBy = SettingsStore.instance.getString(_k('sortBy')) ?? 'smart';
    _load();
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
      );
      if (!mounted) return;
      setState(() {
        _actors = ((res['items'] as List?) ?? const [])
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

  Future<void> _openActor(Map<String, dynamic> actor) async {
    setState(() {
      _selected = actor;
      _worksLoading = true;
      _worksError = null;
      _works = const [];
    });
    try {
      final res = await ApiSession.instance.client.videoJpActorWorks(
        key: _str(actor['key']).isEmpty ? null : _str(actor['key']),
        name: _str(actor['name']),
        limit: '200',
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
        if (_selected == actor) _selected = Map<String, dynamic>.from(actor);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  List<Map<String, dynamic>> get _visibleActors {
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
        list.sort((a, b) => _int(b['unwatchedCount']) - _int(a['unwatchedCount']));
        break;
      case 'count':
        list.sort((a, b) => _int(b['count'] ?? b['items']) - _int(a['count'] ?? a['items']));
        break;
      default:
        // 综合序（服务端已按同口径返回，这里再排一次
        // 是为了收藏切换后立即生效，不用重新请求）
        list.sort((a, b) {
          var c = (b['favorite'] == true ? 1 : 0) - (a['favorite'] == true ? 1 : 0);
          if (c != 0) return c;
          c = (_int(b['unwatchedCount']) > 0 ? 1 : 0) -
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
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final body = _showMovies
        ? _buildMoviesView()
        : (_selected == null ? _buildActorView() : _buildActorDetail());
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('video.jp.actorTitle'))),
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
              IconButton(
                tooltip: tr('video.jp.movie'),
                onPressed: () => setState(() => _showMovies = true),
                icon: const Icon(Icons.movie_outlined),
              ),
              IconButton(
                tooltip: tr('common.refresh'),
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
          child: Row(
            children: [
              FilterChip(
                label: Text(tr('video.jp.favorites')),
                selected: _onlyFavorite,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => _onlyFavorite = v),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              FilterChip(
                label: Text(tr('video.jp.onlyUnwatched')),
                selected: _onlyUnwatched,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => _onlyUnwatched = v),
              ),
            ],
          ),
        ),
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
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(spacing, 8, spacing, 32),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing + 4,
            children: [
              for (final actor in list)
                SizedBox(width: cellW, child: _actorCard(actor, cellW)),
            ],
          ),
        );
      },
    );
  }

  Widget _actorCard(Map<String, dynamic> actor, double width) {
    final fav = actor['favorite'] == true;
    final cover = _coverItemOf(actor);
    final avatar = _str(actor['avatarUrl']);
    final url = cover != null
        ? videoPosterUrl(cover, kind: _showFanart ? 'fanart' : 'poster')
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
                    headers: videoArtHeaders,
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
                          color: Theme.of(context)
                              .colorScheme
                              .primary
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
  /// 顶栏额外给一个「返回演员」按钮 —— 参考实现是在列表页顶栏放同样的切换钮。
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
          child: VideoPage(embedded: true, libraryId: widget.libraryId),
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
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(spacing, 8, spacing, 96),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final item in _works)
                SizedBox(
                  width: cellW,
                  child: VideoPosterCard(
                    item: item,
                    width: cellW,
                    showFanart: _showFanart,
                    onTap: () => openVideoDetail(context, item),
                  ),
                ),
            ],
          ),
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
                    birthday.isNotEmpty) ...[
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
