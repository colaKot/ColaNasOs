import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'cola_video_detail_page.dart';
import 'player_page.dart';
import 'video_card.dart';

/// 剧 / 季详情页共用的零件。
///
/// 拆出来的理由：剧详情（多季）与季详情（单季）除了「中间放季列表还是集列表」
/// 之外，头部、集卡片、继续播放的语义完全一致；写在两个文件里必然改一处漏一处。

/// 一部剧的全部数据 + 当前用户的观看进度。
class SeriesBundle {
  const SeriesBundle({
    required this.items,
    required this.gaps,
    required this.progress,
  });

  final List<VideoItem> items;
  final List<VideoSeasonGap> gaps;

  /// itemId → 0..100
  final Map<String, int> progress;

  bool get isEmpty => items.isEmpty;

  /// 剧级元信息（刮削是剧级的，任取一集都有同一份 overview / 年份 / 类型）
  VideoItem? get sample {
    if (items.isEmpty) return null;
    for (final it in items) {
      if ((it.overview ?? '').trim().isNotEmpty) return it;
    }
    return items.first;
  }

  /// 按季分组，季内按集号升序（季号缺失算第 1 季）
  Map<int, List<VideoItem>> get bySeason {
    final map = <int, List<VideoItem>>{};
    for (final it in items) {
      map.putIfAbsent(it.season ?? 1, () => []).add(it);
    }
    for (final list in map.values) {
      list.sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
    }
    return Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  List<VideoItem> episodesOf(int season) => bySeason[season] ?? const [];

  /// 继续播放的目标：先看「正在看」的那一集，再退第一个没看过的，最后第一集。
  ///
  /// 已看完（>=95%）的不算「继续」，否则点一下就又跳到片尾。
  VideoItem? resumeOf([Iterable<VideoItem>? scope]) {
    final list = (scope ?? items).toList()
      ..sort((a, b) {
        final sa = a.season ?? 0;
        final sb = b.season ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        return (a.episode ?? 0).compareTo(b.episode ?? 0);
      });
    if (list.isEmpty) return null;
    VideoItem? watching;
    var watchingPercent = -1;
    for (final it in list) {
      final p = progress[it.id] ?? 0;
      if (p > 0 && p < 95 && p > watchingPercent) {
        watchingPercent = p;
        watching = it;
      }
    }
    if (watching != null) return watching;
    for (final it in list) {
      if (!it.watched && (progress[it.id] ?? 0) == 0) return it;
    }
    return list.first;
  }

  VideoSeasonGap? gapOf(int season) {
    for (final g in gaps) {
      if (g.season == season) return g;
    }
    return null;
  }
}

/// 拉一部剧的全部集 + 当前用户在该剧上的进度。
Future<SeriesBundle> loadSeriesBundle(String name, {String? libraryId}) async {
  final client = ApiSession.instance.client;
  final res = await client.videoSeriesItems(name: name, libraryId: libraryId);
  final progress = <String, int>{};
  // 进度只影响「继续播放」按钮，拿不到不该让整页报错
  try {
    final p = await client.videoProgressList(series: name, limit: 500);
    for (final row in p.items) {
      progress[row.itemId] = row.percent;
    }
  } catch (_) {
    // 忽略：进度缺失时退化成「播第一集」
  }
  return SeriesBundle(items: res.items, gaps: res.missing, progress: progress);
}

/// 直接起播一集（口径与详情页「内置播放」一致）。
Future<void> playVideoItemNow(BuildContext context, VideoItem item) async {
  try {
    final res = await ApiSession.instance.client.videoStreamUrl(id: item.id);
    final url = '${ApiSession.instance.baseUrl}${res.url}';
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          url: url,
          title: item.title,
          itemId: item.id,
          compat: res.compat,
          sourceHeight: item.height,
          sourceBytes: item.size,
          durationMs: item.durationMs,
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    NasSnack.show(context, tr('video.playUrlFailed', {'error': '$e'}));
  }
}

/// 剧 / 季详情页的头部：海报 + 标题 + 元信息 + 评分 + 播放按钮 + 简介。
class VideoSeriesHero extends StatefulWidget {
  const VideoSeriesHero({
    super.key,
    required this.title,
    required this.coverId,
    required this.meta,
    required this.score,
    required this.playLabel,
    required this.onPlay,
    this.subtitle,
    this.overview,
    this.notice,
  });

  final String title;

  /// 标题下的一行小字（例如「第 1 季 · 26 集」）
  final String? subtitle;

  /// 封面用的 item id（剧里「有海报的那一集」）
  final String? coverId;

  final List<String> meta;
  final double score;
  final String playLabel;
  final VoidCallback? onPlay;
  final String? overview;

  /// 缺集等提示（红色小字）
  final String? notice;

  @override
  State<VideoSeriesHero> createState() => _VideoSeriesHeroState();
}

class _VideoSeriesHeroState extends State<VideoSeriesHero> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.of(context).size.width >= 820;
    final posterW = wide ? 176.0 : 108.0;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: wide ? 26 : 20,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            widget.subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
        if (widget.meta.isNotEmpty || widget.score > 0) ...[
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 评分放在信息行最前面：标题行右侧会被嵌入模式的浮层胶囊压住，
              // 也容易在长标题下被挤掉（2026-11-11 实测漏画）。
              if (widget.score > 0) ...[
                Text(
                  '★ ${widget.score.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
                Text(
                  ' · ',
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
              for (var i = 0; i < widget.meta.length; i++) ...[
                if (i > 0)
                  Text(
                    ' · ',
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                Text(
                  widget.meta[i],
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ],
          ),
        ],
        if (widget.notice != null) ...[
          const SizedBox(height: 6),
          Text(
            widget.notice!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NasTokens.fontMicro, color: scheme.error),
          ),
        ],
      ],
    );

    final overview = (widget.overview ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusMd),
              child: SizedBox(
                width: posterW,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: SeriesCoverImage(
                    artUrl: seriesArtUrl(
                      widget.coverId,
                      size: (posterW * 2).round(),
                    ),
                    posterUrl: episodeStillFallbackUrl(widget.coverId),
                    fallbackText: widget.title,
                  ),
                ),
              ),
            ),
            SizedBox(width: wide ? 22 : 14),
            Expanded(child: info),
          ],
        ),
        if (overview.isNotEmpty) ...[
          const SizedBox(height: NasTokens.spaceMd),
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              overview,
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: const TextStyle(height: 1.6),
            ),
          ),
        ],
        // 继续播放放在简介下方（用户 2026-11-11 指定：介绍之后才是播放按钮）
        if (widget.onPlay != null) ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: widget.onPlay,
            icon: const Icon(Icons.play_arrow, size: 20),
            label: Text(widget.playLabel),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 18),
            ),
          ),
        ],
      ],
    );
  }
}

/// 剧集封面地址：`id` 是剧里「有海报的那一集」的 item id。
String? seriesArtUrl(String? id, {int size = 0}) {
  final cover = (id ?? '').trim();
  if (cover.isEmpty) return null;
  final sizeQ = size > 0 ? '&size=$size' : '';
  return '${ApiSession.instance.baseUrl}/api/v1/video/art'
      '?id=${Uri.encodeComponent(cover)}&kind=poster$sizeQ';
}

/// 某一集的首帧（刮削海报缺失时的兜底图）。
String? episodeStillFallbackUrl(String? id) {
  final v = (id ?? '').trim();
  if (v.isEmpty) return null;
  return '${ApiSession.instance.baseUrl}/api/v1/video/poster'
      '?id=${Uri.encodeComponent(v)}';
}

/// 剧集封面：先请求刮削海报，404 再退到首帧。
///
/// `NasCoverImage` 出错只画占位，不会换地址；剧库里总有些集既没刮到海报、
/// 名字也不符合 `-poster/-post` 约定，直接铺一片灰块很难看。
class SeriesCoverImage extends StatefulWidget {
  const SeriesCoverImage({
    super.key,
    required this.artUrl,
    required this.posterUrl,
    required this.fallbackText,
    this.icon = Icons.video_library_outlined,
    this.cacheWidth,
  });

  final String? artUrl;
  final String? posterUrl;
  final String fallbackText;
  final IconData icon;
  final int? cacheWidth;

  @override
  State<SeriesCoverImage> createState() => _SeriesCoverImageState();
}

class _SeriesCoverImageState extends State<SeriesCoverImage> {
  bool _artFailed = false;

  @override
  Widget build(BuildContext context) {
    final art = widget.artUrl;
    if (art == null || art.isEmpty) return _placeholder(context);
    if (_artFailed) {
      final poster = widget.posterUrl;
      if (poster == null || poster.isEmpty) return _placeholder(context);
      return Image.network(
        poster,
        fit: BoxFit.cover,
        headers: videoArtHeaders,
        errorBuilder: (ctx, _, _) => _placeholder(ctx),
      );
    }
    return Image.network(
      art,
      fit: BoxFit.cover,
      headers: videoArtHeaders,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (ctx, _, _) {
        // 不能在 build 里同步 setState，挪到下一帧
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _artFailed = true);
        });
        return _placeholder(ctx);
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: 22, color: context.nasTextSecondary),
          const SizedBox(height: 4),
          Text(
            widget.fallbackText,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一集的缩略图（剧照优先，没有就退首帧）。
String episodeStillUrl(VideoItem ep, {int size = 0}) {
  return videoPosterUrl(ep, kind: 'fanart', size: size);
}

/// 集卡片网格：**一行两列**（用户 2026-11-11 指定，不要一列一行）。
class VideoEpisodeGrid extends StatelessWidget {
  const VideoEpisodeGrid({
    super.key,
    required this.episodes,
    required this.progress,
    this.onTap,
  });

  final List<VideoItem> episodes;
  final Map<String, int> progress;
  final void Function(VideoItem ep)? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const spacing = 12.0;
        const columns = 2;
        final w = ((c.maxWidth - spacing * (columns - 1)) / columns)
            .floorToDouble();
        final h = w * 9 / 16 + 56;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: w / h,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, i) {
            final ep = episodes[i];
            return EpisodeCard(
              ep: ep,
              width: w,
              percent: progress[ep.id] ?? 0,
              onTap: onTap == null ? null : () => onTap!(ep),
            );
          },
        );
      },
    );
  }
}

/// 单集卡片：16:9 剧照 + 集号 / 时长 / 进度 + 标题。
class EpisodeCard extends StatelessWidget {
  const EpisodeCard({
    super.key,
    required this.ep,
    required this.width,
    this.percent = 0,
    this.onTap,
  });

  final VideoItem ep;
  final double width;
  final int percent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final epNo = ep.episode ?? 0;
    final minutes = ((ep.durationMs ?? 0) / 60000).round();
    final p = (percent.clamp(0, 100)) / 100.0;

    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  child: NasCoverImage(
                    url: episodeStillUrl(ep, size: (width * 1.5).round()),
                    headers: videoArtHeaders,
                    fallbackText: ep.title,
                    icon: Icons.movie_outlined,
                    cacheWidth: (width * 1.5).round(),
                  ),
                ),
                // 左上：集号
                if (epNo > 0)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        tr('video.series.episode', {'n': '$epNo'}),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                // 右上：已看勾
                if (ep.watched)
                  Positioned(
                    top: 5,
                    right: 6,
                    child: Icon(
                      Icons.check_circle,
                      size: 16,
                      color: scheme.primary,
                    ),
                  ),
                // 右下：时长
                if (minutes > 0)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tr('video.detail.minutes', {'count': '$minutes'}),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                // 底部进度
                if (p > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(NasTokens.radiusSm),
                      ),
                      child: LinearProgressIndicator(
                        value: p,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          scheme.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            (ep.title).trim().isEmpty
                ? tr('video.series.episode', {'n': '$epNo'})
                : ep.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: NasTokens.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            videoMetaLine(ep),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 季列表的一条：小横图 + 「第 N 季 · M 集」+ 箭头。
///
/// 用竖排条目而不是大卡片：季通常有 2~10 个，铺成两列大图会把「看季」这件事
/// 变成滚三屏（用户 2026-11-11 的截图里季就是一行一条）。
class SeasonTile extends StatelessWidget {
  const SeasonTile({
    super.key,
    required this.season,
    required this.episodes,
    required this.progress,
    this.onTap,
  });

  final int season;
  final List<VideoItem> episodes;
  final Map<String, int> progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = episodes.isEmpty ? null : episodes.first;
    final watched = episodes.where((e) => e.watched).length;

    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              child: SizedBox(
                width: 112,
                height: 63,
                child: NasCoverImage(
                  url: cover == null ? null : episodeStillUrl(cover, size: 360),
                  headers: videoArtHeaders,
                  fallbackText: 'S$season',
                  icon: Icons.video_library_outlined,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('video.series.season', {'n': '$season'}),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: NasTokens.fontSubtitle,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    watched > 0
                        ? '${tr('video.series.episodeCount', {'n': '${episodes.length}'})} · $watched/${episodes.length}'
                        : tr('video.series.episodeCount', {
                            'n': '${episodes.length}',
                          }),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 集列表的一列点击入口（统一走影片详情，和列表页一致）。
void openEpisodeDetail(BuildContext context, VideoItem ep) {
  openVideoDetail(context, ep);
}
