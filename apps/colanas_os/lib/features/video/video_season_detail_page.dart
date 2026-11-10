import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import 'detail/video_detail_router.dart';
import 'video_genre_labels.dart';
import 'video_series_widgets.dart';

/// 季详情：某部剧的某一季 → 这一季的海报 / 介绍 / 继续播放 + 全部集（一行两列）。
///
/// 从剧详情（多季）的季卡片进来。只有一季的剧不会走到这里：剧详情直接把集列出来。
class VideoSeasonDetailPage extends StatefulWidget {
  const VideoSeasonDetailPage({
    super.key,
    required this.name,
    required this.season,
    this.libraryId,
    this.coverId,
    this.embedded = false,
  });

  final String name;
  final int season;
  final String? libraryId;

  /// 剧级封面（该剧「有海报的那一集」的 id）
  final String? coverId;

  final bool embedded;

  @override
  State<VideoSeasonDetailPage> createState() => _VideoSeasonDetailPageState();
}

class _VideoSeasonDetailPageState extends State<VideoSeasonDetailPage> {
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
        : _content(context, _bundle!);

    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            '${widget.name} · ${tr('video.series.season', {'n': '${widget.season}'})}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: body,
      );
    }

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
    final episodes = b.episodesOf(widget.season);
    if (episodes.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.nav.emptyFiles'),
            icon: Icons.video_library_outlined,
          ),
        ],
      );
    }
    // 季级元信息取该季一集的（刮削是剧级的，季内各集一致）
    final sample = episodes.firstWhere(
      (e) => (e.overview ?? '').trim().isNotEmpty,
      orElse: () => episodes.first,
    );
    final resume = b.resumeOf(episodes);
    final gap = b.gapOf(widget.season);

    final meta = <String>[
      if ((sample.year ?? 0) > 0) '${sample.year}',
      ...genreLabels(sample.genres.take(3)),
      if (sample.regions.isNotEmpty) sample.regions.first,
    ];

    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      children: [
        VideoSeriesHero(
          title: b.sample?.series ?? widget.name,
          subtitle: tr('video.seasonEpisodes', {
            'season': '${widget.season}',
            'episodes': '${episodes.length}',
          }),
          coverId: widget.coverId ?? sample.id,
          meta: meta,
          score: sample.score ?? 0,
          overview: sample.overview,
          playLabel: (b.progress[resume?.id] ?? 0) > 0
              ? tr('video.series.resume')
              : tr('video.series.play'),
          onPlay: resume == null ? null : () => _play(resume),
          notice: gap == null
              ? null
              : tr('video.season.missingOne', {
                  'season': '${widget.season}',
                  'episodes': gap.episodes.join('、'),
                }),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        Row(
          children: [
            Text(
              tr('video.series.episodeList'),
              style: const TextStyle(
                fontSize: NasTokens.fontSubtitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${episodes.length}',
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        VideoEpisodeGrid(
          episodes: episodes,
          progress: b.progress,
          onTap: (ep) => openEpisodeDetail(context, ep),
        ),
        const SizedBox(height: NasTokens.spaceXl),
      ],
    );
  }

  Future<void> _play(VideoItem ep) async {
    await playVideoItemNow(context, ep);
    if (mounted) await _load();
  }
}

/// 打开季详情的入口（与 `openVideoSeries` 同口径）。
Future<void> openVideoSeason(
  BuildContext context, {
  required String name,
  required int season,
  String? libraryId,
  String? coverId,
}) {
  final router = VideoDetailRouter.instance;
  if (router.embeddableFrom(context)) {
    router.open(
      VideoDetailEntry(
        tag: 'season:$name:$season',
        build: (_) => VideoSeasonDetailPage(
          name: name,
          season: season,
          libraryId: libraryId,
          coverId: coverId,
          embedded: true,
        ),
      ),
    );
    return Future<void>.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideoSeasonDetailPage(
        name: name,
        season: season,
        libraryId: libraryId,
        coverId: coverId,
      ),
    ),
  );
}
