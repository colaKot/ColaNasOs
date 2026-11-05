import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import 'discover_detail_page.dart';

/// 影视发现：TMDB 目录 → 详情 → 搜索。
///
/// 数据经服务端代理（客户端不持有 API Key，也不直接打图片域）；
/// 未配置 Key / 外网不通时页面显示明确原因，而不是空列表。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key, this.embedded = false});

  /// 嵌入发现页二级页签时去掉自带 Scaffold/AppBar
  final bool embedded;

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  static const _movieGenres = <(String, String)>[
    ('28', 'action'),
    ('12', 'adventure'),
    ('16', 'animation'),
    ('35', 'comedy'),
    ('80', 'crime'),
    ('99', 'documentary'),
    ('18', 'drama'),
    ('10751', 'family'),
    ('14', 'fantasy'),
    ('27', 'horror'),
    ('9648', 'mystery'),
    ('10749', 'romance'),
    ('878', 'scifi'),
    ('53', 'thriller'),
    ('10752', 'war'),
    ('37', 'western'),
  ];

  static const _tvGenres = <(String, String)>[
    ('10759', 'action'),
    ('16', 'animation'),
    ('35', 'comedy'),
    ('80', 'crime'),
    ('99', 'documentary'),
    ('18', 'drama'),
    ('10751', 'family'),
    ('9648', 'mystery'),
    ('10764', 'reality'),
    ('10765', 'scifi'),
  ];

  List<(String, String)> get _genres => _media == 'tv' ? _tvGenres : _movieGenres;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _yearFromCtrl = TextEditingController();
  final _yearToCtrl = TextEditingController();
  Timer? _filterTimer;

  String _media = 'movie';
  String _kind = 'trending_day';
  final Set<String> _genresSel = <String>{};
  int? _yearFrom;
  int? _yearTo;
  final Set<String> _languagesSel = <String>{};
  String _sort = 'popularity.desc';
  String _country = '';
  double _minVote = 0;

  /// 浏览态：显示筛选行；榜单态只显示榜单胶囊与信息条（参考实现的三态之一）
  bool _browse = false;

  bool get _hasFilters =>
      _genresSel.isNotEmpty ||
      _yearFrom != null ||
      _yearTo != null ||
      _languagesSel.isNotEmpty ||
      _country.isNotEmpty ||
      _minVote > 0;

  /// 榜单集合按媒体类型过滤：TV 没有 upcoming，改为 on_air
  List<(String, String)> get _kinds => _media == 'tv'
      ? const [
          ('trending_day', 'discover.kind.today'),
          ('trending_week', 'discover.kind.week'),
          ('popular', 'discover.kind.popular'),
          ('top_rated', 'discover.kind.topRated'),
          ('on_air', 'discover.kind.onAir'),
        ]
      : const [
          ('trending_day', 'discover.kind.today'),
          ('trending_week', 'discover.kind.week'),
          ('popular', 'discover.kind.popular'),
          ('top_rated', 'discover.kind.topRated'),
          ('upcoming', 'discover.kind.upcoming'),
        ];

  String get _kindLabel {
    for (final k in _kinds) {
      if (k.$1 == _kind) return tr(k.$2);
    }
    return tr('discover.kind.week');
  }

  static const _countries = <String>['CN', 'HK', 'TW', 'US', 'JP', 'KR', 'GB', 'FR', 'DE', 'IN', 'TH', 'ES'];
  int _page = 1;
  int _totalPages = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _degraded = false;
  String _reason = '';

  /// 上游失败、本次用的是落库快照（内容可能是几小时前的）
  bool _stale = false;
  int _snapshotAt = 0;
  String _query = '';
  List<DiscoverMediaCard> _items = const [];
  DiscoverSettings? _settings;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    _yearFromCtrl.dispose();
    _yearToCtrl.dispose();
    _filterTimer?.cancel();
    super.dispose();
  }

  String _imageUrl(String path) =>
      '${ApiSession.instance.baseUrl}/api/v1/discover/image?path=${Uri.encodeComponent(path)}&size=w342';

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _page >= _totalPages) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      _load(more: true);
    }
  }

  Future<void> _bootstrap() async {
    try {
      final settings = await ApiSession.instance.client.discoverSettingsGet();
      if (!mounted) return;
      setState(() => _settings = settings);
    } catch (_) {
      // 设置读取失败仍可尝试目录（服务端会给出原因）
    }
    await _load();
  }

  void _scheduleFilterLoad() {
    _filterTimer?.cancel();
    _filterTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load();
    });
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _page = 1;
      }
    });
    try {
      final c = ApiSession.instance.client;
      final res = _query.isEmpty
          ? await c.discoverCatalog(
              kind: _kind,
              media: _media,
              page: more ? _page + 1 : 1,
              genre: _genresSel.isEmpty ? null : _genresSel.join('|'),
              yearFrom: _yearFrom,
              yearTo: _yearTo,
              language: _languagesSel.isEmpty ? null : _languagesSel.join(','),
              sort: _hasFilters ? _sort : null,
              country: _country.isEmpty ? null : _country,
              minVote: _minVote > 0 ? _minVote : null,
            )
          : await c.discoverSearch(
              q: _query,
              media: _media,
              page: more ? _page + 1 : 1,
            );
      if (!mounted) return;
      setState(() {
        _items = more ? [..._items, ...res.items] : res.items;
        _page = res.page;
        _totalPages = res.totalPages;
        _degraded = res.degraded;
        _reason = res.reason;
        _stale = res.stale ?? false;
        _snapshotAt = res.snapshotAt ?? 0;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _degraded = true;
        _reason = e.toString();
      });
    }
  }

  /// 快照距今几小时（0 表示不知道，文案里会显示成"不到 1 小时前"）
  int _staleHours() {
    if (_snapshotAt <= 0) return 0;
    final at = DateTime.fromMillisecondsSinceEpoch(_snapshotAt * 1000);
    final hours = DateTime.now().difference(at).inHours;
    return hours < 0 ? 0 : hours;
  }

  void _resetFilters() {
    setState(() {
      _genresSel.clear();
      _yearFrom = null;
      _yearTo = null;
      _languagesSel.clear();
      _country = '';
      _minVote = 0;
      _sort = 'popularity.desc';
      _browse = false;
    });
    _load();
  }

  /// 评分分色（参考实现：<6 灰 / 6 蓝 / 7 绿 / 8+ 橙）
  static Color _ratingColor(double? rating) {
    if (rating == null || rating < 6) return const Color(0xFF6B7280);
    if (rating < 7) return const Color(0xFF3B82F6);
    if (rating < 8) return const Color(0xFF22C55E);
    return const Color(0xFFF97316);
  }

  Widget _cornerBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// 发现页设置：TMDB（Key / 语言）+ 豆瓣 Cookie，各带一个「测试」按钮。
  ///
  /// Key / Cookie 都是**明文回传**并直接填进输入框：用户要能看见自己配的是哪一个，
  /// 不再是「已配置 / 未配置」两句话说事。
  Future<void> _openSettings() async {
    final keyCtrl = TextEditingController(text: _settings?.apiKey ?? '');
    final langCtrl = TextEditingController(
      text: _settings?.language ?? 'zh-CN',
    );
    final doubanCtrl = TextEditingController();
    try {
      final d = await ApiSession.instance.client.discoverDoubanSettingsGet();
      doubanCtrl.text = '${d['cookie'] ?? ''}';
    } catch (_) {
      // 读不到豆瓣配置不该挡住 TMDB 设置
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.discover.001')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _settings?.apiKeyConfigured == true
                    ? tr('ui.discover.h839ce1')
                    : tr('ui.discover.h8b26af'),
                style: TextStyle(
                  color: ctx.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(labelText: 'TMDB API Key'),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              TextField(
                controller: langCtrl,
                decoration: InputDecoration(
                  labelText: tr('ui.discover.002'),
                  hintText: 'zh-CN',
                ),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              TextField(
                controller: doubanCtrl,
                decoration: InputDecoration(
                  labelText: tr('discover.douban.cookie'),
                  helperText: tr('discover.douban.hint'),
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
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx, false);
              _testTmdbKey(keyCtrl.text.trim());
            },
            child: Text(tr('video.tmdb.test')),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx, false);
              _testDoubanCookie(doubanCtrl.text.trim());
            },
            child: Text('${tr('discover.douban.cookie')} · ${tr('common.test')}'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ApiSession.instance.client.discoverSettingsSet(
        body: DiscoverSettingsBody(
          apiKey: keyCtrl.text.trim(),
          language: langCtrl.text.trim(),
        ),
      );
      if (doubanCtrl.text.trim().isNotEmpty) {
        await ApiSession.instance.client.discoverDoubanSettings(
          body: {'cookie': doubanCtrl.text.trim()},
        );
      }
      if (!mounted) return;
      setState(() => _settings = res);
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.saveFailed', {'error': '$e'}));
    }
  }

  /// TMDB 连通性自检：用输入框里的 Key，没保存也能测
  Future<void> _testTmdbKey(String apiKey) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ApiSession.instance.client.videoTmdbTest(
        body: {'apiKey': apiKey},
      );
      NasSnack.showOn(messenger, '${r['message'] ?? ''} (${r['latencyMs'] ?? 0} ms)');
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  /// 豆瓣连通性自检
  Future<void> _testDoubanCookie(String cookie) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ApiSession.instance.client.discoverDoubanTest(
        body: {'cookie': cookie},
      );
      NasSnack.showOn(messenger, '${r['message'] ?? ''} (${r['latencyMs'] ?? 0} ms)');
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  Future<void> _openDetail(DiscoverMediaCard card) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverDetailPage(
          id: card.id,
          mediaType: card.mediaType,
        ),
      ),
    );
  }

  /// 卡片心形：每用户收藏（服务端 discover_favorites），成功后本地即时更新
  Future<void> _toggleFavorite(DiscoverMediaCard card) async {
    final next = !(card.favorited ?? false);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.discoverFavoriteSet(
        body: DiscoverFavoriteBody(
          id: card.id,
          mediaType: card.mediaType,
          favorite: next,
        ),
      );
      if (!mounted) return;
      setState(() {
        _items = [
          for (final it in _items)
            if (it.id == card.id && it.mediaType == card.mediaType)
              DiscoverMediaCard.fromJson(<String, dynamic>{
                ...it.toJson(),
                'favorited': next,
              })
            else
              it,
        ];
      });
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
        title: Text(tr('ui.discover.006')),
        actions: [
          IconButton(
            tooltip: tr('ui.discover.007'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          NasRefreshButton(onPressed: () => _load()),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceSm,
              NasTokens.spaceMd,
              0,
            ),
            child: Row(
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'movie',
                      label: Text(tr('ui.discover.008')),
                    ),
                    ButtonSegment(
                      value: 'tv',
                      label: Text(tr('ui.discover.009')),
                    ),
                  ],
                  selected: {_media},
                  onSelectionChanged: (v) {
                    setState(() {
                      _media = v.first;
                      _kind = 'trending_day';
                      _browse = false;
                    });
                    _load();
                  },
                ),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: NasSearchField(
                    controller: _searchCtrl,
                    hintText: tr('ui.discover.010'),
                    onClear: () {
                      setState(() => _query = '');
                      _load();
                    },
                    onSubmitted: (v) {
                      setState(() => _query = v.trim());
                      _load();
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_query.isEmpty && !_browse)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NasTokens.spaceMd,
                vertical: NasTokens.spaceXs,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final k in _kinds)
                      Padding(
                        padding: const EdgeInsets.only(
                          right: NasTokens.spaceXs,
                        ),
                        child: NasChip(
                          label: Text(tr(k.$2)),
                          selected: _kind == k.$1,
                          onSelected: (_) {
                            setState(() {
                              _kind = k.$1;
                              _browse = false;
                            });
                            _load();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (_query.isEmpty && !_browse)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                0,
                NasTokens.spaceMd,
                NasTokens.spaceXs,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.leaderboard_outlined,
                    size: 14,
                    color: context.nasTextSecondary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      tr('discover.board.info', {'name': _kindLabel}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _browse = true),
                    icon: const Icon(Icons.tune, size: 16),
                    label: Text(tr('discover.filter.browse')),
                  ),
                ],
              ),
            ),
          if (_query.isEmpty && _browse)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                0,
                NasTokens.spaceMd,
                NasTokens.spaceXs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('discover.filter.genre'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                  const SizedBox(height: NasTokens.spaceXs),
                  Wrap(
                    spacing: NasTokens.spaceXs,
                    runSpacing: NasTokens.spaceXs,
                    children: [
                      for (final g in _genres)
                        NasChip(
                          label: Text(tr('discover.genre.${g.$2}')),
                          selected: _genresSel.contains(g.$1),
                          onSelected: (on) {
                            setState(() {
                              if (on) {
                                _genresSel.add(g.$1);
                              } else {
                                _genresSel.remove(g.$1);
                              }
                            });
                            _load();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('discover.filter.language'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                  const SizedBox(height: NasTokens.spaceXs),
                  Wrap(
                    spacing: NasTokens.spaceXs,
                    runSpacing: NasTokens.spaceXs,
                    children: [
                      for (final lang in const ['zh', 'ja', 'ko', 'en', 'fr', 'de', 'es'])
                        NasChip(
                          label: Text(tr('discover.language.$lang')),
                          selected: _languagesSel.contains(lang),
                          onSelected: (on) {
                            setState(() {
                              if (on) {
                                _languagesSel.add(lang);
                              } else {
                                _languagesSel.remove(lang);
                              }
                            });
                            _load();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Wrap(
                    spacing: NasTokens.spaceSm,
                    runSpacing: NasTokens.spaceXs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _yearFromCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: tr('discover.filter.yearFrom'),
                            isDense: true,
                          ),
                          onChanged: (v) {
                            setState(() => _yearFrom = int.tryParse(v.trim()));
                            _scheduleFilterLoad();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _yearToCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: tr('discover.filter.yearTo'),
                            isDense: true,
                          ),
                          onChanged: (v) {
                            setState(() => _yearTo = int.tryParse(v.trim()));
                            _scheduleFilterLoad();
                          },
                        ),
                      ),
                      SizedBox(

                        width: 132,
                        child: NasDropdown<String>(
                          initialValue: _sort,
                          isDense: true,
                          decoration: InputDecoration(
                            labelText: tr('discover.filter.sort'),
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'popularity.desc',
                              child: Text(tr('discover.sort.popular')),
                            ),
                            DropdownMenuItem(
                              value: 'vote_average.desc',
                              child: Text(tr('discover.sort.rating')),
                            ),
                            DropdownMenuItem(
                              value: 'primary_release_date.desc',
                              child: Text(tr('discover.sort.new')),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _sort = v ?? _sort);
                            _load();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_query.isEmpty && _browse)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                0,
                NasTokens.spaceMd,
                NasTokens.spaceXs,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 130,
                    child: NasDropdown<String>(
                      initialValue: _country.isEmpty ? '__any__' : _country,
                      isDense: true,
                      decoration: InputDecoration(
                        labelText: tr('discover.filter.country'),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '__any__',
                          child: Text(tr('discover.filter.anyCountry')),
                        ),
                        for (final c in _countries)
                          DropdownMenuItem(
                            value: c,
                            child: Text(tr('discover.country.$c')),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() => _country = (v == null || v == '__any__') ? '' : v);
                        _load();
                      },
                    ),
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('discover.filter.minScoreValue', {
                            'score': _minVote.toStringAsFixed(1),
                          }),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                        SizedBox(
                          height: 36,
                          child: Slider(
                            value: _minVote,
                            min: 0,
                            max: 10,
                            divisions: 20,
                            label: _minVote.toStringAsFixed(1),
                            onChanged: (v) => setState(() => _minVote = v),
                            onChangeEnd: (_) => _load(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _hasFilters ? _resetFilters : null,
                    child: Text(tr('discover.filter.reset')),
                  ),
                ],
              ),
            ),
          if (_query.isEmpty && _browse)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                0,
                NasTokens.spaceMd,
                NasTokens.spaceXs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _page >= _totalPages
                          ? tr('discover.filter.total', {
                              'count': '${_items.length}',
                            })
                          : tr('discover.filter.totalMore', {
                              'count': '${_items.length}',
                            }),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() => _browse = false);
                      _load();
                    },
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: Text(tr('discover.filter.back')),
                  ),
                ],
              ),
            ),
          // 快照兜底提示：不阻断浏览，只说明"这份榜单是几小时前的"
          if (_stale && !_degraded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                NasTokens.spaceXs,
                NasTokens.spaceMd,
                0,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.history_toggle_off,
                    size: 14,
                    color: context.nasTextSecondary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      tr('discover.staleHint', {
                        'hours': '${_staleHours()}',
                      }),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_degraded)
            Padding(
              padding: const EdgeInsets.all(NasTokens.spaceMd),
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(NasTokens.spaceSm),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_off_outlined),
                      const SizedBox(width: NasTokens.spaceSm),
                      Expanded(
                        child: Text(
                          _reason.isEmpty ? tr('ui.discover.011') : _reason,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const NasLoading()
                : _items.isEmpty
                ? NasEmptyState(
                    title: _degraded
                        ? tr('ui.discover.012')
                        : tr('ui.discover.013'),
                    message: _degraded
                        ? tr('ui.discover.h1bfb3a')
                        : tr('ui.discover.h56f7c6'),
                    icon: Icons.travel_explore,
                  )
                : LayoutBuilder(
                    builder: (context, c) {
                      final columns = gridColumns(c.maxWidth);
                      // 用 LayoutBuilder 反算格子高度：海报按 2:3 完整显示，
                      // 下面留 40px 给标题两行。写死 0.62 会把竖版海报裁掉一截。
                      return LayoutBuilder(builder: (context, c) {
                        final spacing = NasTokens.spaceSm;
                        final itemWidth =
                            (c.maxWidth - spacing * (columns + 1)) / columns;
                        final itemHeight = itemWidth * 1.5 + 58;
                        return GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(NasTokens.spaceSm),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: spacing,
                          mainAxisSpacing: spacing,
                          childAspectRatio: itemWidth / itemHeight,
                        ),
                        itemCount: _items.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _items.length) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final card = _items[i];
                          return InkWell(
                            onTap: () => _openDetail(card),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      NasTokens.radiusMd,
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (card.posterPath == null)
                                          Container(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            child: const Center(
                                              child: Icon(Icons.movie_outlined),
                                            ),
                                          )
                                        else
                                          Image.network(
                                            _imageUrl(card.posterPath!),
                                            headers: ApiSession.instance.authHeaders,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                const Center(
                                                  child: Icon(
                                                    Icons.broken_image_outlined,
                                                  ),
                                                ),
                                          ),
                                        if (card.owned == true)
                                          Positioned(
                                            left: 6,
                                            bottom: 6,
                                            child: _cornerBadge(
                                              tr('discover.owned'),
                                              Theme.of(context).colorScheme.primary,
                                            ),
                                          ),
                                        Positioned(
                                          left: 6,
                                          top: 6,
                                          child: _cornerBadge(
                                            tr(
                                              card.mediaType == 'tv'
                                                  ? 'discover.media.tv'
                                                  : 'discover.media.movie',
                                            ),
                                            Colors.black54,
                                          ),
                                        ),
                                        if (card.rating != null)
                                          Positioned(
                                            right: 6,
                                            top: 6,
                                            child: _cornerBadge(
                                              '★ ${card.rating!.toStringAsFixed(1)}',
                                              _ratingColor(card.rating),
                                            ),
                                          ),
                                        Positioned(
                                          right: 6,
                                          bottom: 6,
                                          child: GestureDetector(
                                            onTap: () => _toggleFavorite(card),
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(alpha: 0.55),
                                                shape: BoxShape.circle,
                                              ),
                                              child: Icon(
                                                (card.favorited ?? false)
                                                    ? Icons.favorite
                                                    : Icons.favorite_border,
                                                size: 14,
                                                color: (card.favorited ?? false)
                                                    ? const Color(0xFFF43F5E)
                                                    : Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: NasTokens.spaceXs),
                                Text(
                                  card.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: NasTokens.fontBody,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                  ),
                                ),
                                Text(
                                  card.year == null ? '' : '${card.year}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.nasTextSecondary,
                                    fontSize: NasTokens.fontCaption,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                        );
                      });
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
