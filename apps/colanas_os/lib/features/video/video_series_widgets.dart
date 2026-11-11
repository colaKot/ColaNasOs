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

/// 竖版海报网格的尺寸口径 —— 剧库列表、剧详情里的季网格共用同一套算法。
///
/// 用户 2026-11-11 明确要求「季卡片和电视剧列表里的卡片一样大」，
/// 所以两边必须用同一份公式；改这里就是同时改两处，别在页面里另抄一份。
class PosterGridMetrics {
  const PosterGridMetrics({
    required this.spacing,
    required this.columns,
    required this.itemWidth,
  });

  /// 卡片下方的两行文字（标题 + 副标题）占的高度
  static const textBlock = 42.0;

  final double spacing;
  final int columns;
  final double itemWidth;

  double get tileHeight => itemWidth * 1.5 + textBlock;

  factory PosterGridMetrics.of(double maxWidth, {double scale = 1.0}) {
    final spacing = maxWidth < 480 ? 8.0 : 12.0;
    final baseWidth = (maxWidth < 480 ? 108.0 : 132.0) * scale;
    final columns = (maxWidth / baseWidth).floor().clamp(2, 9);
    final itemWidth =
        ((maxWidth - spacing * (columns - 1) - spacing) / columns)
            .floorToDouble();
    return PosterGridMetrics(
      spacing: spacing,
      columns: columns,
      itemWidth: itemWidth,
    );
  }
}

/// 集卡片网格：**正方形缩略图，一行 6 个**（用户 2026-11-11 指定）。
///
/// 列数按目标宽度算并夹在 3~6：桌面一行 6 个，窄屏（手机）退到 3 个，
/// 不然 6 个方图在手机上只有 50 多点宽，什么都看不清。
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

  /// 卡片下方两行文字（集号 + 名字）
  static const _textBlock = 44.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxWidth = c.maxWidth;
        final spacing = maxWidth < 480 ? 8.0 : 12.0;
        final baseWidth = maxWidth < 480 ? 110.0 : 168.0;
        final columns = (maxWidth / baseWidth).floor().clamp(3, 6);
        final w = ((maxWidth - spacing * (columns - 1)) / columns)
            .floorToDouble();
        final h = w + _textBlock;
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

/// 单集卡片：**正方形**剧照 + 集号（一行）+ 名字（换行）。
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
    // 集的 title 常常就是剧名（同一部剧每一集都一样），第二行写它等于重复四遍。
    // 只有和剧名不同、或本来就没有剧名时才算「这是这一集自己的名字」。
    // 比较前去掉空格 / 点 / 下划线：库里同一个东西会写成 `SEAL.Team` 和 `SEAL Team`。
    final title = ep.title.trim();
    final seriesName = (ep.series ?? '').trim();
    final ownName =
        title.isNotEmpty &&
        (seriesName.isEmpty || _nameKey(title) != _nameKey(seriesName));

    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  child: NasCoverImage(
                    url: episodeStillUrl(ep, size: (width * 1.5).round()),
                    headers: videoArtHeaders,
                    fallbackText: epNo > 0
                        ? tr('video.series.episode', {'n': '$epNo'})
                        : title,
                    icon: Icons.movie_outlined,
                    cacheWidth: (width * 1.5).round(),
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
          const SizedBox(height: 4),
          // 集号单独一行，名字换行放下面（用户 2026-11-11 指定）
          Text(
            epNo > 0
                ? tr('video.series.episode', {'n': '$epNo'})
                : tr('video.series.episodeList'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: NasTokens.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            ownName ? title : videoMetaLine(ep),
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

/// 季网格：竖版海报卡，一片排开（桌面一行 6~8 个），尺寸口径与电视剧库一致。
///
/// 之前是一行一条的小横图（112×63），用户 2026-11-11 反馈「太小了」，
/// 要求改成和剧库卡片同比例的竖版海报，一行铺满、超出换行。
class VideoSeasonGrid extends StatelessWidget {
  const VideoSeasonGrid({
    super.key,
    required this.seasons,
    required this.progress,
    this.scale = 1.0,
    this.coverId,
    this.onTap,
  });

  /// 季号 → 该季全部集（升序）
  final Map<int, List<VideoItem>> seasons;
  final Map<String, int> progress;

  /// 剧库的「海报大小」档位，跟着剧库的滑块走
  final double scale;

  /// 剧级封面（该季连一张剧照都没有时兜底）
  final String? coverId;

  final void Function(int season)? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final m = PosterGridMetrics.of(c.maxWidth, scale: scale);
        final entries = seasons.entries.toList();
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: m.columns,
            mainAxisSpacing: m.spacing,
            crossAxisSpacing: m.spacing,
            childAspectRatio: m.itemWidth / m.tileHeight,
          ),
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            return SeasonPosterCard(
              season: e.key,
              episodes: e.value,
              width: m.itemWidth,
              progress: progress,
              coverId: coverId,
              onTap: onTap == null ? null : () => onTap!(e.key),
            );
          },
        );
      },
    );
  }
}

/// 季卡片：竖版封面 + 右上角「本季集数」角标 + 「第 N 季」+ 集数（/ 已看）。
///
/// 版式刻意和剧库的 `SeriesPosterCard` 一模一样（2:3 + 两行字），
/// 这样从剧库点进来看季，卡片不会突然变小一号。
class SeasonPosterCard extends StatelessWidget {
  const SeasonPosterCard({
    super.key,
    required this.season,
    required this.episodes,
    required this.width,
    required this.progress,
    this.coverId,
    this.onTap,
  });

  final int season;
  final List<VideoItem> episodes;
  final double width;
  final Map<String, int> progress;
  final String? coverId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cover = episodes.isEmpty ? null : episodes.first;
    final watched = episodes.where((e) => e.watched).length;
    final wantSize = (width * 2).round();
    final countLabel = tr('video.series.episodeCount', {
      'n': '${episodes.length}',
    });

    final poster = AspectRatio(
      aspectRatio: 2 / 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            child: SeriesCoverImage(
              // 季封面用本季第一集的剧照（每季各不相同），没有才退到剧海报
              artUrl: cover == null
                  ? null
                  : episodeStillUrl(cover, size: wantSize),
              posterUrl: seriesArtUrl(coverId, size: wantSize),
              fallbackText: tr('video.series.season', {'n': '$season'}),
              cacheWidth: wantSize,
            ),
          ),
          // 底部渐变：让角标在任何封面上都读得清
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.4],
                  ),
                ),
              ),
            ),
          ),
          // 右上角：本季集数（与剧库卡片的角标同一款式）
          if (episodes.isNotEmpty)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                constraints: const BoxConstraints(minWidth: 26),
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF2AA7B8).withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                ),
                child: Text(
                  '${episodes.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, box) {
            final bounded = box.maxHeight.isFinite;
            return Column(
              mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bounded)
                  Flexible(fit: FlexFit.loose, child: poster)
                else
                  poster,
                const SizedBox(height: 4),
                Text(
                  tr('video.series.season', {'n': '$season'}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  watched > 0
                      ? '$countLabel · $watched/${episodes.length}'
                      : countLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 集列表的一列点击入口（统一走影片详情，和列表页一致）。
void openEpisodeDetail(BuildContext context, VideoItem ep) {
  openVideoDetail(context, ep);
}

/// 判断「这行文字是不是同一部剧的名字」用的归一化：忽略大小写与空格 / 点 / 下划线。
String _nameKey(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[\s._\-·]+'), '');
