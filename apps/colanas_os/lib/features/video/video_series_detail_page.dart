import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'detail/video_detail_router.dart';
import 'video_card.dart';
import 'cola_video_detail_page.dart';

/// 剧集详情：一部剧 → 按季分组的集列表。
///
/// 从「剧集浏览」「收藏（剧集级）」进来。缺集由服务端 `missing` 一并返回，
/// 这里只标出来（不自动补），因为补集需要用户去下片。
class VideoSeriesDetailPage extends StatefulWidget {
  const VideoSeriesDetailPage({
    super.key,
    required this.name,
    this.coverId,
    this.posterUrl,
    this.headers = const {},
    this.embedded = false,
  });

  final String name;
  final String? coverId;
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
  List<VideoItem> _items = const [];
  List<VideoSeasonGap> _gaps = const [];

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
      final res = await ApiSession.instance.client.videoSeriesItems(name: widget.name);
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _gaps = res.missing;
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

  /// 按季分组，季内按集号升序（季号缺失算第 1 季）
  Map<int, List<VideoItem>> get _bySeason {
    final map = <int, List<VideoItem>>{};
    for (final it in _items) {
      map.putIfAbsent(it.season ?? 1, () => []).add(it);
    }
    for (final list in map.values) {
      list.sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
    }
    return Map.fromEntries(map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const NasLoading()
        : _error != null
            ? NasErrorState(message: _error!, onRetry: _load)
            : _items.isEmpty
                ? ListView(
                    children: [
                      NasEmptyState(title: tr('video.nav.emptyFiles'), icon: Icons.video_library_outlined),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.all(NasTokens.spaceMd),
                    children: [
                      _header(context),
                      const SizedBox(height: NasTokens.spaceMd),
                      for (final entry in _bySeason.entries) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
                          child: Text(
                            tr('video.seasonEpisodes', {
                              'season': '${entry.key}',
                              'episodes': '${entry.value.length}',
                            }),
                            style: const TextStyle(
                              fontSize: NasTokens.fontSubtitle,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        for (final ep in entry.value) _episodeTile(context, ep),
                        _gapLine(context, entry.key),
                        const SizedBox(height: NasTokens.spaceSm),
                      ],
                    ],
                  );

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

  Widget _header(BuildContext context) {
    final cover = widget.coverId;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          child: SizedBox(
            width: 96,
            height: 144,
            child: cover == null
                ? Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(Icons.video_library_outlined, color: context.nasTextSecondary),
                  )
                : NasCoverImage(
                    url: '${ApiSession.instance.baseUrl}/api/v1/video/art?id=${Uri.encodeComponent(cover)}',
                    headers: videoArtHeaders,
                    fallbackText: widget.name,
                  ),
          ),
        ),
        const SizedBox(width: NasTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.name,
                style: const TextStyle(fontSize: NasTokens.fontTitle, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                tr('video.seasonsEpisodes', {
                  'seasons': '${_bySeason.length}',
                  'episodes': '${_items.length}',
                }),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
              if (_gaps.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  tr('video.season.missing', {
                    'list': _gaps
                        .map((g) => 'S${g.season}E${g.episodes.join(',')}')
                        .take(3)
                        .join(' / '),
                  }),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _episodeTile(BuildContext context, VideoItem ep) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ep.watched ? Icons.check_circle : Icons.play_circle_outline,
        size: 20,
        color: ep.watched ? Theme.of(context).colorScheme.primary : context.nasTextSecondary,
      ),
      title: Text(
        'S${ep.season ?? 1}E${ep.episode ?? 0} · ${ep.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: NasTokens.fontCaption),
      ),
      subtitle: Text(
        videoMetaLine(ep),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasTextSecondary),
      ),
      onTap: () async {
        openVideoDetail(context, ep);
        if (mounted) await _load();
      },
    );
  }

  Widget _gapLine(BuildContext context, int season) {
    final gap = _gaps.where((g) => g.season == season).firstOrNull;
    if (gap == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Text(
        tr('video.season.missingOne', {
          'season': '$season',
          'episodes': gap.episodes.join('、'),
        }),
        style: TextStyle(
          fontSize: NasTokens.fontMicro,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

/// 打开剧集详情的统一入口（与 `openVideoDetail` 同口径）。
///
/// 影视壳挂载时进三级页叠层；否则退回整页 push。
Future<void> openVideoSeries(
  BuildContext context, {
  required String name,
  String? coverId,
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
        posterUrl: posterUrl,
        headers: headers,
      ),
    ),
  );
}
