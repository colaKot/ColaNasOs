import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/settings_store.dart';
import 'cola_video_detail_page.dart';
import 'detail/video_detail_router.dart';
import 'video_card.dart';
import 'video_genre_labels.dart';
import 'video_series_widgets.dart';
import 'video_series_actions.dart';
import 'short_play_page.dart';
import 'library_types.dart';
import 'series_display.dart';

/// 剧详情 / 选季入口。
///
/// 只有一季：不再画「选集」中间页，这一层直接渲染单集详情（播放页）。
/// 多季：只列季卡片，选完季直接落进该季的单集详情。
/// 两条路径都不再经过「季详情 + 选集列表」那一层（用户 2026-11-11 要求）。
///
/// 从「剧集浏览」/ 电视剧库的剧卡片进来。缺集由服务端 `missing` 一并返回，
/// 这里只标出来（不自动补），因为补集需要用户去下片。
class VideoSeriesDetailPage extends StatefulWidget {
  const VideoSeriesDetailPage({
    super.key,
    required this.name,
    this.coverId,
    this.libraryId,
    this.posterUrl,
    this.headers = const {},
    this.embedded = false,
  });

  final String name;
  final String? coverId;
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final b = await loadSeriesBundle(widget.name, libraryId: widget.libraryId);
      if (!mounted) return;
      setState(() {
        _bundle = b;
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

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    // 只有一季 → 直接落到单集详情/播放页，不显示「选集」中间页。
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

    final body = _loading
        ? const NasLoading()
        : _error != null
        ? NasErrorState(message: _error!, onRetry: _load)
        : (_bundle == null || _bundle!.isEmpty)
        ? ListView(
            children: [
              NasEmptyState(
                title: tr('video.nav.emptyFiles'),
                icon: Icons.video_library_outlined,
              ),
            ],
          )
        : _content(context, _bundle!);

    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
        body: body,
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

  Widget _content(BuildContext context, SeriesBundle b) {
    // 单季已在 build 里直接落到单集详情，这里只可能是多季的选季页。
    final seasons = b.bySeason;
    final sample = b.sample;
    final resume = b.resumeOf();
    final resumeHint = _resumeHint(b);

    final meta = <String>[
      if ((sample?.year ?? 0) > 0) '${sample!.year}',
      if (sample != null) ...genreLabels(sample.genres.take(3)),
      if ((sample?.regions ?? const []).isNotEmpty) sample!.regions.first,
    ];

    final gapNote = b.gaps.isEmpty
        ? null
        : tr('video.season.missing', {
            'list': b.gaps
                .map((g) => 'S${g.season}E${g.episodes.join(',')}')
                .take(3)
                .join(' / '),
          });

    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      children: [
        VideoSeriesHero(
          title: _displayName(sample?.series ?? widget.name, sample?.path),
          subtitle: tr('video.seasonsEpisodes', {
            'seasons': '${seasons.length}',
            'episodes': '${b.items.length}',
          }),
          coverId: widget.coverId ?? sample?.id,
          meta: meta,
          score: sample?.score ?? 0,
          overview: sample?.overview,
          playLabel: (b.progress[resume?.id] ?? 0) > 0
              ? tr('video.series.resume')
              : tr('video.series.play'),
          onPlay: resume == null ? null : () => _play(resume),
          notice: gapNote,
        ),
        if (resumeHint != null) ...[
          const SizedBox(height: 8),
          Text(
            resumeHint,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
        const SizedBox(height: NasTokens.spaceLg),
        _sectionTitle(context, tr('video.series.seasonList')),
        const SizedBox(height: 10),
        VideoSeasonGrid(
          seasons: seasons,
          progress: b.progress,
          scale: _posterScale,
          coverId: widget.coverId ?? sample?.id,
          onTap: (s) => _openSeason(context, b, s),
          // 季卡右键：本季标记已看 / 删除本季
          menuEntries: (season, eps) => seasonMenuEntries(
            context,
            episodes: eps,
            onChanged: () => _load(),
          ),
        ),
        const SizedBox(height: NasTokens.spaceXl),
      ],
    );
  }

  /// 选完季直接进该季的单集详情/播放页：优先续播集，否则第一集。
  void _openSeason(BuildContext context, SeriesBundle b, int season) {
    final eps = b.episodesOf(season);
    if (eps.isEmpty) return;
    openVideoDetail(context, b.resumeOf(eps) ?? eps.first);
  }

  Widget _sectionTitle(BuildContext context, String text, {String? trailing}) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: NasTokens.fontSubtitle,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(
            trailing,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _play(VideoItem ep) async {
    final bundle = _bundle;
    if (VideoLibraryTypes.isShortTv(ep.libraryId) &&
        bundle != null &&
        bundle.items.length > 1) {
      final idx = bundle.items.indexWhere((e) => e.id == ep.id);
      await openShortPlay(context, bundle.items, idx < 0 ? 0 : idx);
      if (mounted) await _load();
      return;
    }
    await playVideoItemNow(context, ep);
    if (mounted) await _load();
  }
}

/// 打开剧详情的统一入口（与 `openVideoDetail` 同口径）。
///
/// 影视壳挂载时进三级页叠层；否则退回整页 push。
Future<void> openVideoSeries(
  BuildContext context, {
  required String name,
  String? coverId,
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
        libraryId: libraryId,
        posterUrl: posterUrl,
        headers: headers,
      ),
    ),
  );
}
