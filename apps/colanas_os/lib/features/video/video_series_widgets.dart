import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
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

/// 剧集封面地址：`id` 是剧里「有海报的那一集」的 item id。
///
/// `kind` 默认竖版海报；首页推荐的横版剧卡用 `fanart`（服务端会退到 poster / thumb）。
String? seriesArtUrl(String? id, {int size = 0, String kind = 'poster'}) {
  final cover = (id ?? '').trim();
  if (cover.isEmpty) return null;
  final sizeQ = size > 0 ? '&size=$size' : '';
  return '${ApiSession.instance.baseUrl}/api/v1/video/art'
      '?id=${Uri.encodeComponent(cover)}&kind=$kind$sizeQ';
}

/// 某一集的首帧（刮削海报缺失时的兜底图）。
String? episodeStillFallbackUrl(String? id) {
  final v = (id ?? '').trim();
  if (v.isEmpty) return null;
  return '${ApiSession.instance.baseUrl}/api/v1/video/poster'
      '?id=${Uri.encodeComponent(v)}';
}

/// 剧集封面：刮削海报 → TMDB 剧海报 → 服务端抽帧，逐级降级。
///
/// 只在**前一级真的失败**时才往下走：剧照 / 首帧铺进 2:3 的封面位会被裁成一条，
/// 所以它排在最后 —— 但整片空白更糟（短剧、健身视频这种没正式海报的库，
/// 一屏全是灰块，用户会以为「封面全丢了」）。
class SeriesCoverImage extends StatefulWidget {
  const SeriesCoverImage({
    super.key,
    required this.artUrl,
    required this.posterUrl,
    required this.fallbackText,
    this.stillUrl,
    this.icon = Icons.video_library_outlined,
    this.cacheWidth,
  });

  final String? artUrl;
  final String? posterUrl;

  /// 最后兜底：服务端从这一集抽的首帧（可能为 null）
  final String? stillUrl;

  final String fallbackText;
  final IconData icon;
  final int? cacheWidth;

  @override
  State<SeriesCoverImage> createState() => _SeriesCoverImageState();
}

class _SeriesCoverImageState extends State<SeriesCoverImage> {
  /// 已经失败了几级：0 = 还在用首选地址
  int _fails = 0;

  @override
  void didUpdateWidget(covariant SeriesCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artUrl != widget.artUrl ||
        oldWidget.posterUrl != widget.posterUrl ||
        oldWidget.stillUrl != widget.stillUrl) {
      _fails = 0;
    }
  }

  List<String> get _candidates => <String>[
        if ((widget.artUrl ?? '').isNotEmpty) widget.artUrl!,
        if ((widget.posterUrl ?? '').isNotEmpty) widget.posterUrl!,
        if ((widget.stillUrl ?? '').isNotEmpty) widget.stillUrl!,
      ];

  @override
  Widget build(BuildContext context) {
    final urls = _candidates;
    if (urls.isEmpty || _fails >= urls.length) return _placeholder(context);
    return _network(urls[_fails], context);
  }

  Widget _network(String url, BuildContext context) {
    return Image.network(
      url,
      key: ValueKey<String>(url),
      fit: BoxFit.cover,
      headers: videoArtHeaders,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (ctx, _, _) {
        // 不能在 build 里同步 setState，挪到下一帧
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _fails += 1);
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

/// 剧 / 季 / 集的观看三态。
///
/// 用户 2026-11-12 定的口径：一集没看 = 未看；看了一部分 = 未看完；
/// 全看完 = 已看完。季和整部剧都按「本季 / 本剧的已看集数 ÷ 总集数」折算，
/// 所以三处的标签永远是同一套算法、同一套颜色。
enum SeriesWatchState { none, partial, done }

SeriesWatchState seriesWatchStateOf(int watched, int total) {
  if (total <= 0 || watched <= 0) return SeriesWatchState.none;
  if (watched >= total) return SeriesWatchState.done;
  return SeriesWatchState.partial;
}

/// 角标文案：未看 / 已看 3/8 / 已看完
String seriesWatchLabel(int watched, int total) {
  switch (seriesWatchStateOf(watched, total)) {
    case SeriesWatchState.none:
      return tr('video.series.watch.none');
    case SeriesWatchState.partial:
      return tr('video.series.watch.progress', {
        'done': '${watched.clamp(0, total)}',
        'total': '$total',
      });
    case SeriesWatchState.done:
      return tr('video.series.watch.done');
  }
}

/// 封面左上角的观看状态角标（与影片卡的 `VideoWatchedBadge` 同一套视觉：
/// 未看是黑色半透明小标签、已看完是绿色圆底白勾，未看完用琥珀色比例）。
class SeriesWatchBadge extends StatelessWidget {
  const SeriesWatchBadge({
    super.key,
    required this.watched,
    required this.total,
    this.compact = false,
  });

  final int watched;
  final int total;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = seriesWatchStateOf(watched, total);
    if (state == SeriesWatchState.done) {
      final size = compact ? 18.0 : 22.0;
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xFF22C55E),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.check_rounded,
          size: compact ? 12 : 15,
          color: Colors.white,
        ),
      );
    }
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 6,
        vertical: compact ? 1.5 : 2,
      ),
      decoration: BoxDecoration(
        color: state == SeriesWatchState.partial
            ? const Color(0xFFE0A030).withValues(alpha: 0.92)
            : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        seriesWatchLabel(watched, total),
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 9.5 : 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
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
    final itemWidth = ((maxWidth - spacing * (columns - 1) - spacing) / columns)
        .floorToDouble();
    return PosterGridMetrics(
      spacing: spacing,
      columns: columns,
      itemWidth: itemWidth,
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
    this.menuEntries,
    this.selectionMode = false,
    this.selected = const <int>{},
    this.onSelectToggle,
  });

  /// 季号 → 该季全部集（升序）
  final Map<int, List<VideoItem>> seasons;
  final Map<String, int> progress;

  /// 剧库的「海报大小」档位，跟着剧库的滑块走
  final double scale;

  /// 剧级封面（该季连一张剧照都没有时兜底）
  final String? coverId;

  final void Function(int season)? onTap;

  /// 季卡的右键菜单（标记本季已看 / 删除本季），由调用方按季生成
  final List<NasMenuEntry> Function(int season, List<VideoItem> episodes)?
  menuEntries;

  /// 多选态：季卡左上角换成勾选框，点击改为选中（用户 2026-11-12：
  /// 电视剧每一层都要能多选，但「加入合集」只在最外层的整部剧上给）
  final bool selectionMode;
  final Set<int> selected;
  final void Function(int season)? onSelectToggle;

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
            final menu =
                menuEntries?.call(e.key, e.value) ?? const <NasMenuEntry>[];
            final card = SeasonPosterCard(
              season: e.key,
              episodes: e.value,
              width: m.itemWidth,
              progress: progress,
              coverId: coverId,
              selectionMode: selectionMode,
              selected: selected.contains(e.key),
              onSelectToggle: onSelectToggle == null
                  ? null
                  : () => onSelectToggle!(e.key),
              onTap: onTap == null ? null : () => onTap!(e.key),
            );
            if (menu.isEmpty || selectionMode) return card;
            return NasContextMenuRegion(entries: menu, child: card);
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
    this.selectionMode = false,
    this.selected = false,
    this.onSelectToggle,
  });

  final int season;
  final List<VideoItem> episodes;
  final double width;
  final Map<String, int> progress;
  final String? coverId;
  final VoidCallback? onTap;

  /// 多选态（点到季卡 = 选中本季，不打开）
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectToggle;

  @override
  Widget build(BuildContext context) {
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
              // 季封面统一用剧海报；横版剧照 / 首帧都不拿来顶竖版封面
              artUrl: seriesArtUrl(coverId, size: wantSize),
              posterUrl: null,
              stillUrl: episodeStillFallbackUrl(coverId),
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
          // 左上角：多选勾选框 / 本季观看三态（未看 · 已看 n/m · 已看完）
          Positioned(
            top: 6,
            left: 6,
            child: selectionMode
                ? NasSelectChip(selected: selected)
                : SeriesWatchBadge(
                    watched: watched,
                    total: episodes.length,
                  ),
          ),
          // 右上角：本季集数（与剧库卡片的角标同一款式）
          if (episodes.isNotEmpty)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                constraints: const BoxConstraints(minWidth: 26),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
        onTap: selectionMode ? onSelectToggle : onTap,
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
