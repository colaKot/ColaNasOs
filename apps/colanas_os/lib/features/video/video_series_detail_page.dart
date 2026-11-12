import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'cola_video_detail_page.dart';
import 'detail/video_detail_kit.dart';
import 'detail/video_detail_router.dart';
import 'video_card.dart';
import 'video_genre_labels.dart';
import 'video_jp_pages.dart';
import 'video_list_view.dart';
import 'video_series_widgets.dart';
import 'video_series_actions.dart';
import 'short_play_page.dart';
import 'library_types.dart';
import 'series_display.dart';

/// 剧集总览页（一级 · 选季）。
///
/// 只有一季：不再画「选集」中间页，这一层直接渲染该季详情（= 单集详情页，
/// 内部按季收敛选集网格）；多季：列季卡片，选完季落进该季的详情页。
///
/// 版式与电影详情共用 `VideoDetailHeader` / `VideoSection` / `VideoActorRail`，
/// 三页一个设计语言（PRD 的核心诉求就是「拉齐信息层级」）。
///
/// 从「剧集浏览」/ 电视剧库的剧卡片进来。缺集由服务端 `missing` 一并返回，
/// 这里只标出来（不自动补），因为补集需要用户去下片。
class VideoSeriesDetailPage extends StatefulWidget {
  const VideoSeriesDetailPage({
    super.key,
    required this.name,
    this.coverId,
    this.posterId,
    this.libraryId,
    this.posterUrl,
    this.headers = const {},
    this.embedded = false,
  });

  final String name;
  final String? coverId;

  /// 真有竖版海报的那一集（整部剧都没刮到 poster 时为 null，头部改走 TMDB 剧海报）
  final String? posterId;

  final String? libraryId;
  final String? posterUrl;
  final Map<String, String> headers;

  /// true = 作为三级页放进影视壳的内容区：不画自己的 AppBar，
  /// 返回交给外壳（`ShellBack`），底色用外壳同款背景（`nasStyle.background`）。
  final bool embedded;

  @override
  State<VideoSeriesDetailPage> createState() => _VideoSeriesDetailPageState();
}

class _VideoSeriesDetailPageState extends State<VideoSeriesDetailPage> {
  bool _loading = true;
  String? _error;
  SeriesBundle? _bundle;

  /// 演员名 → 头像（与电影详情同一个接口，一次批量问）
  Map<String, Map<String, dynamic>> _actorInfo = const {};

  bool _favBusy = false;

  /// 季层多选：选中季号，动作落到「这些季的每一集」
  bool _seasonSelection = false;
  final Set<int> _seasonSel = {};

  /// 剧库的「海报大小」档位：季卡片跟剧库卡片用同一个尺寸，用户在剧库调大调小
  /// 之后进来看季不会突然变大变小（同一把 key，见 `VideoSeriesGridPage`）。
  double get _posterScale {
    final lib = widget.libraryId;
    if (lib == null) return 1.0;
    final saved =
        SettingsStore.instance.getInt('video.lib.$lib.seriesScale') ?? 100;
    return (saved / 100.0).clamp(0.7, 1.15);
  }

  @override
  void initState() {
    super.initState();
    // 剧中文名 / TMDB 竖版海报是展示层补充，拉到后重画一次即可
    SeriesDisplayStore.ensure().then((_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  /// 拉数据。[silent] = 不闪骨架屏（刷新 / 收藏 / 标记已看这类就地更新用）。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final b = await loadSeriesBundle(
        widget.name,
        libraryId: widget.libraryId,
      );
      if (!mounted) return;
      setState(() {
        _bundle = b;
        _loading = false;
        _error = null;
      });
      _loadActorInfo(b);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 演职头像：拿不到就只显示名字，不影响整页
  Future<void> _loadActorInfo(SeriesBundle b) async {
    final sample = b.sample;
    if (sample == null) return;
    final names = <String>[
      for (final n in [...sample.directors, ...sample.actors])
        if (videoPersonName(n).isNotEmpty) videoPersonName(n),
    ];
    if (names.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.videoActorAvatars(
        body: {'names': names.take(48).toList()},
      );
      if (!mounted) return;
      final list = (res['items'] as List?) ?? const [];
      final map = <String, Map<String, dynamic>>{};
      for (final e in list) {
        if (e is Map) map['${e['name'] ?? ''}'] = Map<String, dynamic>.from(e);
      }
      setState(() => _actorInfo = map);
    } catch (_) {
      // 头像缺失只影响观感
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    // 只有一季 → 直接落到该季详情（= 单集详情页），不显示「选集」中间页。
    // 这一层仍是三级栈里的一层，返回由外壳统一处理。
    if (!_loading &&
        _error == null &&
        bundle != null &&
        !bundle.isEmpty &&
        bundle.bySeason.length <= 1) {
      final ep = bundle.resumeOf() ?? bundle.items.first;
      return VideoDetailPage(
        item: ep,
        posterUrl: videoPosterUrl(ep),
        headers: videoArtHeaders,
        embedded: widget.embedded,
      );
    }

    final body = LayoutBuilder(
      builder: (context, c) {
        final mode = layoutFor(c.maxWidth);
        if (_loading) {
          return Padding(
            padding: const EdgeInsets.all(NasTokens.spaceMd),
            child: VideoDetailSkeleton(mode: mode),
          );
        }
        if (_error != null) {
          return NasErrorState(message: _error!, onRetry: _load);
        }
        if (bundle == null || bundle.isEmpty) {
          return ListView(
            children: [
              NasEmptyState(
                title: tr('video.nav.emptyFiles'),
                icon: Icons.video_library_outlined,
              ),
            ],
          );
        }
        return _content(context, bundle, mode);
      },
    );

    if (!widget.embedded) {
      // 壳没挂载 / 调用方已是整页路由时才走这里：自带顶栏。
      // 标题优先用中文剧名，与头部主标题保持同一个名字（`series` 列是英文发布名）。
      final sample = bundle?.sample;
      return Scaffold(
        // 背景与相册时间轴同一套极光主题（Scaffold 自身透明，必须显式铺一层）
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            _displayName(sample?.series ?? widget.name, sample?.path),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            context.nasStyle.background,
            Positioned.fill(child: body),
          ],
        ),
      );
    }

    // 三级页：顶栏与返回交给外壳，自己必须铺一层**不透明**底色 ——
    // 本项目的 `scaffoldBackgroundColor` 是透明的（背景由 NasStyle 铺在 MaterialApp 底层），
    // 不铺就会跟下面的列表文字叠在一起。
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(child: context.nasStyle.background),
          Positioned.fill(child: body),
        ],
      ),
    );
  }

  /// 剧名：series 列是英文发布名，目录 / 文件名里带中文时优先用中文。
  String _displayName(String series, String? path) {
    final cached = SeriesDisplayStore.nameOf(series);
    if (cached != null && cached.isNotEmpty) return cached;
    final re = RegExp(r'[\u3400-\u9fff][\u3400-\u9fff0-9A-Za-z·：:，,、\s]{1,30}');
    for (final s in [series, path ?? '']) {
      final m = re.firstMatch(s);
      if (m == null) continue;
      final t = (m.group(0) ?? '').trim().replaceAll(
        RegExp(r'[\s.,·:：，、]+$'),
        '',
      );
      if (t.length >= 2) return t;
    }
    return series;
  }

  /// 继续播放按钮下方：从第几集几分钟开始（进度按片长 × 百分比估算）。
  String? _resumeHint(SeriesBundle b) {
    final ep = b.resumeOf();
    if (ep == null) return null;
    final percent = b.progress[ep.id] ?? 0;
    if (percent <= 0 || percent >= 95) return null;
    final duration = ep.durationMs ?? 0;
    if (duration <= 0) return null;
    final minutes = (duration * percent / 100 / 60000).floor();
    final n = ep.episode ?? 0;
    if (n > 0) {
      return tr('video.detail.resumeEpisodeMinute', {
        'episode': '$n',
        'minute': '$minutes',
      });
    }
    return tr('video.detail.resumeMinute', {'minute': '$minutes'});
  }

  Widget _content(
    BuildContext context,
    SeriesBundle b,
    LayoutMode mode,
  ) {
    // 单季已在 build 里直接落到单集详情，这里只可能是多季的选季页。
    final seasons = b.bySeason;
    final sample = b.sample;
    final resume = b.resumeOf();
    final resumeHint = _resumeHint(b);
    final playing = (b.progress[resume?.id] ?? 0) > 0;

    // 内容铺满三级页：与影片详情同口径，不再按 1080 限宽居中。
    const double hPad = 16.0;

    final meta = <String>[
      if ((sample?.year ?? 0) > 0) '${sample!.year}',
      if (sample != null) ...genreLabels(sample.genres.take(3)),
      if ((sample?.regions ?? const <String>[]).isNotEmpty)
        sample!.regions.first,
      tr('video.seasonsEpisodes', {
        'seasons': '${seasons.length}',
        'episodes': '${b.items.length}',
      }),
    ];

    final gapNote = b.gaps.isEmpty
        ? null
        : tr('video.season.missing', {
            'list': b.gaps
                .map((g) => 'S${g.season}E${g.episodes.join(',')}')
                .take(3)
                .join(' / '),
          });

    final overview = (sample?.overview ?? '').trim();
    final people = sample == null
        ? const <VideoPerson>[]
        : videoPeopleOf(sample, avatarInfo: _actorInfo);

    return ListView(
      padding: EdgeInsets.fromLTRB(hPad, NasTokens.spaceMd, hPad, 0),
      children: <Widget>[
        VideoDetailHeader(
          title: _displayName(sample?.series ?? widget.name, sample?.path),
          mode: mode,
          originalTitle: sample?.originalName,
          posterUrl: seriesArtUrl(
            widget.posterId ?? widget.coverId ?? sample?.id,
            size: mode == LayoutMode.compact ? 320 : 480,
          ),
          posterText: _displayName(sample?.series ?? widget.name, sample?.path),
          meta: meta,
          score: sample?.score ?? 0,
          badges: sample == null ? const <String>[] : videoFlagsOf(sample),
        ),
        if (overview.isNotEmpty) ...<Widget>[
          const SizedBox(height: 24),
          VideoSection(
            title: tr('video.series.overview'),
            child: VideoExpandableText(overview),
          ),
        ],
        // 继续播放放在简介**之后**（用户 2026-11-11 明确要求：先读介绍再播）。
        // 这是它不进头部操作行的原因，别顺手挪回去。
        const SizedBox(height: 14),
        _actionRow(context, b, playing, resume),
        if (resumeHint != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            resumeHint,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
        if (gapNote != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            gapNote,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 24),
        VideoSection(
          title: tr('video.series.seasonList'),
          trailing: '${seasons.length}',
          // 季卡是竖版海报网格，套一层深色卡反而把海报压暗
          card: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_seasonSelection) ...<Widget>[
                _seasonSelectionBar(context, b, seasons),
                const SizedBox(height: NasTokens.spaceSm),
              ],
              VideoSeasonGrid(
                seasons: seasons,
                progress: b.progress,
                scale: _posterScale,
                coverId: widget.coverId ?? sample?.id,
                selectionMode: _seasonSelection,
                selected: _seasonSel,
                onSelectToggle: (s) => setState(() {
                  if (!_seasonSel.remove(s)) _seasonSel.add(s);
                }),
                onTap: (s) => _openSeason(context, b, s),
                // 季卡右键：本季标记已看 / 删除本季
                menuEntries: (season, eps) => seasonMenuEntries(
                  context,
                  episodes: eps,
                  onChanged: () => _load(silent: true),
                ),
              ),
            ],
          ),
        ),
        if (people.isNotEmpty) ...<Widget>[
          const SizedBox(height: 24),
          VideoSection(
            title: tr('video.series.mainCast'),
            cardPadding: EdgeInsets.zero,
            child: VideoActorRail(
              people: people,
              onTap: (p) => _openPerson(context, p),
            ),
          ),
        ],
        const SizedBox(height: NasTokens.spaceXl),
      ],
    );
  }

  /// 头部操作：继续播放 / 收藏（整部剧）/ 更多。
  Widget _actionRow(
    BuildContext context,
    SeriesBundle b,
    bool playing,
    VideoItem? resume,
  ) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilledButton.icon(
          onPressed: resume == null ? null : () => _play(resume),
          icon: const Icon(Icons.play_arrow, size: 20),
          label: Text(
            playing ? tr('video.series.resume') : tr('video.series.play'),
          ),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: const StadiumBorder(),
          ),
        ),
        _circleAction(
          context,
          icon: _allFavorited(b) ? Icons.favorite : Icons.favorite_border,
          tooltip: _allFavorited(b)
              ? tr('video.action.unfavorite')
              : tr('video.action.favorite'),
          active: _allFavorited(b),
          onTap: _favBusy ? null : () => _toggleFavorite(b),
        ),
        _circleAction(
          context,
          icon: Icons.more_horiz,
          tooltip: tr('video.card.more'),
          onTap: () => _showMore(b),
        ),
      ],
    );
  }

  bool _allFavorited(SeriesBundle b) =>
      b.items.isNotEmpty && b.items.every((e) => e.favorite);

  /// 季层多选条：标记已看 / 未看（**没有**「加入合集」——合集只在整部剧那层给）
  Widget _seasonSelectionBar(
    BuildContext context,
    SeriesBundle b,
    Map<int, List<VideoItem>> seasons,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final ids = <String>[
      for (final s in _seasonSel)
        for (final e in seasons[s] ?? const <VideoItem>[]) e.id,
    ];
    final empty = ids.isEmpty;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Text(
            tr('video.list.selected', {'count': '${_seasonSel.length}'}),
            style: const TextStyle(fontSize: NasTokens.fontCaption),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              _seasonSel
                ..clear()
                ..addAll(seasons.keys);
            }),
            child: Text(tr('video.list.filter.all')),
          ),
          TextButton(
            onPressed: empty
                ? null
                : () => markVideos(
                      context,
                      ids,
                      watched: true,
                      count: ids.length,
                      onChanged: () => _load(silent: true),
                    ),
            child: Text(tr('video.action.markWatched')),
          ),
          TextButton(
            onPressed: empty
                ? null
                : () => markVideos(
                      context,
                      ids,
                      watched: false,
                      count: ids.length,
                      onChanged: () => _load(silent: true),
                    ),
            child: Text(tr('video.action.markUnwatched')),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: tr('common.cancel'),
            onPressed: () => setState(() {
              _seasonSelection = false;
              _seasonSel.clear();
            }),
          ),
        ],
      ),
    );
  }

  /// 收藏口径：一部剧 = 它的每一集。剧没有自己的收藏列，
  /// 按集收藏才能让「收藏」筛选里看到这部剧。
  Future<void> _toggleFavorite(SeriesBundle b) async {
    final target = !_allFavorited(b);
    setState(() => _favBusy = true);
    try {
      await ApiSession.instance.client.videoFavoriteSet(
        body: VideoFavoriteBody(
          ids: b.items.map((e) => e.id).toList(),
          favorite: target,
        ),
      );
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    } finally {
      if (mounted) setState(() => _favBusy = false);
    }
  }

  Widget _circleAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? scheme.primary.withValues(alpha: 0.16)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 20,
              color: active ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMore(SeriesBundle b) async {
    final allWatched = b.items.isNotEmpty && b.items.every((e) => e.watched);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: Icon(allWatched ? Icons.remove_done : Icons.done_all),
              title: Text(
                tr(
                  allWatched
                      ? 'video.action.markUnwatched'
                      : 'video.action.markTvWatched',
                ),
              ),
              onTap: () => Navigator.pop(ctx, 'watch'),
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: Text(tr('video.list.multiSelect')),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(tr('common.refresh')),
              onTap: () => Navigator.pop(ctx, 'refresh'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'watch':
        await markVideos(
          context,
          b.items.map((e) => e.id).toList(),
          watched: !allWatched,
          count: b.items.length,
          onChanged: () => _load(silent: true),
        );
      case 'select':
        setState(() {
          _seasonSelection = true;
          _seasonSel.clear();
        });
      case 'refresh':
        await _load(silent: true);
    }
  }

  /// 选完季直接进该季的详情页（内部只列本季的集）：优先续播集，否则第一集。
  void _openSeason(BuildContext context, SeriesBundle b, int season) {
    final eps = b.episodesOf(season);
    if (eps.isEmpty) return;
    openVideoDetail(context, b.resumeOf(eps) ?? eps.first);
  }

  /// 演职人员点击：日本库进日本演员页，普通库进「某人的作品」。
  void _openPerson(BuildContext context, VideoPerson person) {
    if (VideoDetailRouter.instance.isJpLibrary(widget.libraryId)) {
      openVideoJpActor(context, name: person.name, libraryId: widget.libraryId);
      return;
    }
    openVideoListByPerson(
      context,
      kind: person.isDirector ? 'director' : 'actor',
      name: person.name,
    );
  }

  Future<void> _play(VideoItem ep) async {
    final bundle = _bundle;
    if (VideoLibraryTypes.isShortTv(ep.libraryId) &&
        bundle != null &&
        bundle.items.length > 1) {
      final idx = bundle.items.indexWhere((e) => e.id == ep.id);
      await openShortPlay(context, bundle.items, idx < 0 ? 0 : idx);
      if (mounted) await _load(silent: true);
      return;
    }
    await playVideoItemNow(context, ep);
    if (mounted) await _load(silent: true);
  }
}

/// 打开剧详情的统一入口（与 `openVideoDetail` 同口径）。
///
/// 影视壳挂载时进三级页叠层；否则退回整页 push。
Future<void> openVideoSeries(
  BuildContext context, {
  required String name,
  String? coverId,
  String? posterId,
  String? libraryId,
  String? posterUrl,
  Map<String, String> headers = const {},
}) {
  final router = VideoDetailRouter.instance;
  if (router.embeddableFrom(context)) {
    router.open(
      VideoDetailEntry(
        tag: 'series:$name',
        build: (_) => VideoSeriesDetailPage(
          name: name,
          coverId: coverId,
          posterId: posterId,
          libraryId: libraryId,
          posterUrl: posterUrl,
          headers: headers,
          embedded: true,
        ),
      ),
    );
    return Future<void>.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideoSeriesDetailPage(
        name: name,
        coverId: coverId,
        posterId: posterId,
        libraryId: libraryId,
        posterUrl: posterUrl,
        headers: headers,
      ),
    ),
  );
}
