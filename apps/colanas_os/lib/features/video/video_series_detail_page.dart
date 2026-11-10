import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import 'detail/video_detail_router.dart';
import 'video_genre_labels.dart';
import 'video_season_detail_page.dart';
import 'video_series_widgets.dart';

/// 剧详情：一部剧 → 季列表（多季）或直接是该季的集列表（只有一季）。
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

  Widget _content(BuildContext context, SeriesBundle b) {
    final seasons = b.bySeason;
    final multi = seasons.length > 1;
    final sample = b.sample;
    final resume = b.resumeOf();

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
          title: sample?.series ?? widget.name,
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
        const SizedBox(height: NasTokens.spaceLg),
        if (multi) ...[
          _sectionTitle(context, tr('video.series.seasonList')),
          const SizedBox(height: 4),
          for (final entry in seasons.entries)
            SeasonTile(
              season: entry.key,
              episodes: entry.value,
              progress: b.progress,
              onTap: () => openVideoSeason(
                context,
                name: widget.name,
                season: entry.key,
                libraryId: widget.libraryId,
                coverId: widget.coverId,
              ),
            ),
        ] else ...[
          _sectionTitle(
            context,
            tr('video.series.episodeList'),
            trailing: '${b.items.length}',
          ),
          const SizedBox(height: 10),
          VideoEpisodeGrid(
            episodes: b.items,
            progress: b.progress,
            onTap: (ep) => openEpisodeDetail(context, ep),
          ),
        ],
        const SizedBox(height: NasTokens.spaceXl),
      ],
    );
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
