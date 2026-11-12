import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_genre_labels.dart';

/// 影视海报卡的统一实现（首页横滑、列表网格、详情相关页共用）。
///
/// 为什么抽出来：既有实现里这张卡上有 7 层信息（刮削名 / 年份 / 评分 / 类型 /
/// 已看 / 收藏 / 画质徽章 / 进度 / 更多菜单），分散在各页面改一处漏三处。
/// 这里只做「给定 item 就画对」，所有动作由外部回调注入。

/// 日 / 周 / 月榜里最好的名次（null = 不在任何榜上）
int? _bestRank(VideoItem item) {
  final ranks = <int>[
    ?item.rankDaily,
    ?item.rankWeekly,
    ?item.rankMonthly,
  ].where((r) => r > 0).toList();
  if (ranks.isEmpty) return null;
  return ranks.reduce((a, b) => a < b ? a : b);
}

/// tooltip 用的明细：`日榜 3 · 周榜 8 · 月榜 -`
String _rankDetail(VideoItem item) {
  String show(int? v) => v != null && v > 0 ? '$v' : '-';
  return tr('video.card.rankDetail', {
    'daily': show(item.rankDaily),
    'weekly': show(item.rankWeekly),
    'monthly': show(item.rankMonthly),
  });
}

/// 海报地址：有刮削海报走 `/video/art`，否则回退服务端抽的首帧。
///
/// `size` > 0 时服务端会走缩略图（`thumbs` 目录缓存）：列表页把 1~2 MB 的原图
/// 直传过来，SMB 库上十几张卡就能把「打开列表」拖成十几秒（2026-11-03）。
String videoPosterUrl(VideoItem item, {String kind = 'poster', int size = 0}) {
  final base = ApiSession.instance.baseUrl;
  // 图片库 / 混合库：图片条目直接用服务端缩略图，不能走视频海报接口
  if (item.mediaType == 'image') {
    return '$base/api/v1/files/thumb?path=${Uri.encodeComponent(item.path)}&size=720';
  }
  final id = Uri.encodeComponent(item.id);
  final sizeQ = size > 0 ? '&size=$size' : '';
  if (item.hasArt) return '$base/api/v1/video/art?id=$id&kind=$kind$sizeQ';
  // 首帧只能当「海报」用，横版位置没有更好的回退
  return '$base/api/v1/video/poster?id=$id';
}

Map<String, String> get videoArtHeaders {
  final token = ApiSession.instance.token;
  return token == null ? const {} : {'authorization': 'Bearer $token'};
}

/// 副标题：年份 · 分辨率 · 片长 · 评分（能凑几个凑几个，不硬塞占位符）
String videoMetaLine(VideoItem item) {
  final parts = <String>[];
  if (item.mediaType == 'image') {
    final w = item.width ?? 0;
    final h = item.height ?? 0;
    if (w > 0 && h > 0) parts.add('$w×$h');
    if (item.size > 0) parts.add(formatBytes(item.size));
    return parts.join(' · ');
  }
  if ((item.year ?? 0) > 0) parts.add('${item.year}');
  final h = item.height ?? 0;
  if (h >= 2160) {
    parts.add('4K');
  } else if (h >= 1080) {
    parts.add('1080p');
  } else if (h >= 720) {
    parts.add('720p');
  }
  final codec = (item.videoCodec ?? '').toLowerCase();
  if (codec.contains('265') || codec.contains('hevc')) parts.add('H.265');
  final minutes = ((item.durationMs ?? 0) / 60000).round();
  if (minutes > 0) parts.add(tr('video.detail.minutes', {'count': '$minutes'}));
  if (item.genres.isNotEmpty) parts.add(genreLabel(item.genres.first));
  return parts.join(' · ');
}

/// 画质徽章：4K / HDR / DV / Atmos（顺序固定，最多显示 4 个）
List<String> videoFlagsOf(VideoItem item) {
  final flags = <String>[];
  if (item.is4k) flags.add('4K');
  if (item.dolbyVision) {
    flags.add('DV');
  } else if (item.hdr10plus) {
    flags.add('HDR10+');
  } else if (item.hdr10) {
    flags.add('HDR');
  } else if (item.hlg) {
    flags.add('HLG');
  }
  if (item.dolbyAtmos) flags.add('Atmos');
  return flags;
}

/// 封面右上角角标。
///
/// 顺序：中（中字）/ 字（内嵌字幕）/ LTX 或 无码 / 4K。
/// 4K 不再走 `videoFlagsOf` 的通用画质行，避免同一张卡出现两个「4K」。
class VideoCornerBadges extends StatelessWidget {
  const VideoCornerBadges({
    super.key,
    this.chineseSub = false,
    this.uncensored = false,
    this.is4k = false,
    this.hasSubtitle = false,
    this.ltx = false,
    this.scale = 1.0,
  });

  final bool chineseSub;
  final bool uncensored;
  final bool is4k;
  final bool hasSubtitle;
  final bool ltx;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (chineseSub) _chip(tr('video.badge.chinese'), const Color(0xFF2E7D32)),
      if (hasSubtitle && !chineseSub)
        _chip(tr('video.badge.subtitle'), const Color(0xFF1565C0)),
      if (ltx)
        _chip('LTX', const Color(0xFF6A1B9A))
      else if (uncensored)
        _chip(tr('video.badge.uncensored'), const Color(0xFFC62828)),
      if (is4k) _chip('4K', const Color(0xFFB8860B)),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chips.length; i += 1) ...[
          if (i > 0) SizedBox(width: 4 * scale),
          chips[i],
        ],
      ],
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 5 * scale,
        vertical: 1.5 * scale,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(4 * scale),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 10 * scale,
          height: 1.15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 封面左上角的「已观看 / 未观看」角标。
///
/// 未观看是黑色半透明小标签，已观看是绿色圆底 + 白勾。
class VideoWatchedBadge extends StatelessWidget {
  const VideoWatchedBadge({
    super.key,
    required this.watched,
    this.compact = false,
  });

  final bool watched;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 18.0 : 22.0;
    if (watched) {
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
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        tr('video.card.unwatched'),
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

class VideoPosterCard extends StatelessWidget {
  const VideoPosterCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
    this.showFanart = false,
    this.progress,
    this.onMore,
    this.selected = false,
    this.selectionMode = false,
  });

  final VideoItem item;
  final double width;
  final VoidCallback onTap;
  final bool showFanart;
  final double? progress;
  final VoidCallback? onMore;
  final bool selected;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 按显示宽度 ×2 要缩略图：列表一屏几十张，原图直传在 SMB 库上会卡住整个页面
    final wantSize = (width * 2).round();
    final url = showFanart
        ? videoPosterUrl(item, kind: 'fanart', size: wantSize)
        : videoPosterUrl(item, size: wantSize);
    final radius = NasTokens.radiusSm;
    final flags = videoFlagsOf(item);
    final isImage = item.mediaType == 'image';
    final ratio = isImage ? 4 / 3 : (showFanart ? 3 / 2 : 2 / 3);
    final p = progress?.clamp(0.0, 1.0);

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, box) {
            // 网格里格子高度是有限值，用 Flexible 让出几像素给文字；
            // 演员页的 Wrap 在纵向滚动里拿到的是无限高度，此时不能再放 flex 子节点。
            final bounded = box.maxHeight.isFinite;
            final poster = AspectRatio(
              aspectRatio: ratio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: NasCoverImage(
                      url: url,
                      fit: showFanart ? BoxFit.contain : BoxFit.cover,
                      headers: videoArtHeaders,
                      fallbackText: item.title,
                      // 海报是原图直出（服务端不缩放）：1000×1500 按原尺寸解码约 6 MB，
                      // 一屏 27 张就超过 imageCache 默认的 100 MB。按显示宽度 × 2 解码
                      // （与 music 封面同一口径）。
                      cacheWidth: (width * 2).round(),
                    ),
                  ),
                  // 底部渐变：让评分 / 类型角标在任何封面上都读得清
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(radius),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.72),
                              Colors.transparent,
                              Colors.transparent,
                            ],
                            stops: const [0, 0.45, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 左上：已观看 / 未观看角标（图片没有观看状态，不显示）
                  if (!isImage)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: VideoWatchedBadge(
                        watched: item.watched,
                        compact: true,
                      ),
                    ),
                  // 右上：日本片角标（中 / 字 / 无码 / 4K）+ 其它画质徽章（图片不挂）
                  if (!isImage &&
                      (item.chineseSub ||
                          item.uncensored ||
                          item.is4k ||
                          item.hasSubtitle ||
                          flags.isNotEmpty))
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VideoCornerBadges(
                            chineseSub: item.chineseSub,
                            uncensored: item.uncensored,
                            is4k: item.is4k,
                            hasSubtitle: item.hasSubtitle,
                            scale: 0.95,
                          ),
                          for (final f in flags.where((f) => f != '4K').take(2))
                            Padding(
                              padding: const EdgeInsets.only(left: 3),
                              child: _badge(
                                context,
                                f,
                                Colors.black.withValues(alpha: 0.62),
                              ),
                            ),
                        ],
                      ),
                    ),
                  // 右上：更多菜单（画质徽章下面，避免叠一起）
                  if (onMore != null && !selectionMode)
                    Positioned(
                      top: flags.isEmpty ? 6 : 30,
                      right: 6,
                      child: _circleButton(context, Icons.more_horiz, onMore!),
                    ),
                  // 左上：收藏（已看下面）
                  if (item.favorite)
                    Positioned(
                      top: item.watched ? 30 : 6,
                      left: 6,
                      child: _circleButton(
                        context,
                        Icons.favorite,
                        null,
                        color: scheme.error,
                        compact: true,
                      ),
                    ),
                  // 底部：评分（左）/ 类型·番号（右）
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Row(
                      children: [
                        if ((item.score ?? 0) > 0)
                          _pill(
                            context,
                            (item.score ?? 0).toStringAsFixed(1),
                            const Color(0xFFE5B527),
                          ),
                        if (item.code != null && item.code!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: _pill(context, item.code!, Colors.white),
                          ),
                        // 榜单名次：日/周/月取最好的一次显示；明细放 tooltip
                        // （三个角标塞不进海报角，只显示最好的那个）
                        Builder(
                          builder: (context) {
                            final best = _bestRank(item);
                            if (best == null) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Tooltip(
                                message: _rankDetail(item),
                                child: _pill(
                                  context,
                                  tr('video.card.rankBadge', {'rank': '$best'}),
                                  const Color(0xFFFF8A3D),
                                ),
                              ),
                            );
                          },
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                  // 顶部进度条（继续观看）
                  if (p != null && p > 0)
                    Positioned(
                      left: 6,
                      right: 6,
                      top: 0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: p,
                          minHeight: 4,
                          backgroundColor: Colors.black.withValues(alpha: 0.35),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  // 多选遮罩
                  if (selectionMode)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius),
                            color: selected
                                ? scheme.primary.withValues(alpha: 0.22)
                                : Colors.black26,
                            border: Border.all(
                              color: selected
                                  ? scheme.primary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: selected
                              ? Center(
                                  child: Icon(
                                    Icons.check_circle,
                                    size: 32,
                                    color: scheme.primary,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            );
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
                  item.title,
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
                  videoMetaLine(item),
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

  Widget _badge(BuildContext context, String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          height: 1.2,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _circleButton(
    BuildContext context,
    IconData icon,
    VoidCallback? onTap, {
    Color? color,
    bool compact = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final child = Container(
      padding: EdgeInsets.all(compact ? 4 : 5),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.12)),
      ),
      child: Icon(
        icon,
        size: compact ? 13 : 16,
        color: color ?? scheme.onSurface,
      ),
    );
    if (onTap == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: child,
      ),
    );
  }
}

/// 首页的「大卡」（16:9 剧照 + 简介），用于推荐位。
class VideoHeroCard extends StatelessWidget {
  const VideoHeroCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
    this.onMore,
    this.title,
    this.meta,
    this.artUrl,
    this.badge,
  });

  final VideoItem item;
  final double width;
  final VoidCallback onTap;
  final VoidCallback? onMore;

  /// 展示用标题；缺省用 `item.title`（首页剧卡传剧名）
  final String? title;

  /// 副标题；缺省用 `videoMetaLine(item)`（首页剧卡传「N 季 · M 集」）
  final String? meta;

  /// 封面地址；缺省按 `item` 取横版剧照（首页剧卡传剧封面）
  final String? artUrl;

  /// 左上角角标（首页剧卡传「未看 / 已看 n/m / 已看完」，与剧库卡片同一套）
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusMd),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NasCoverImage(
                url: artUrl ??
                    videoPosterUrl(
                      item,
                      kind: 'fanart',
                      size: (width * 2).round(),
                    ),
                fit: BoxFit.cover,
                headers: videoArtHeaders,
                fallbackText: title ?? item.title,
                // 16:9 剧照 1920×1080 原尺寸解码约 8 MB，同 VideoPosterCard 按显示宽度解码。
                cacheWidth: (width * 2).round(),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black.withValues(alpha: 0.15),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                ),
              ),
              if (badge != null)
                Positioned(top: 6, left: 6, child: badge!),
              if (onMore != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(99),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(99),
                      onTap: onMore,
                      child: const Padding(
                        padding: EdgeInsets.all(5),
                        child: Icon(
                          Icons.more_horiz,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title ?? item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta ?? videoMetaLine(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: NasTokens.fontMicro,
                      ),
                    ),
                    if ((item.overview ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.overview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: NasTokens.fontMicro,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 统一入口 `openVideoDetail` / `openVideoDetailOn` 已挪到 `cola_video_detail_page.dart`：
// 那里才知道影视壳是否挂载（走三级页叠层 / 退回整页 push），
// 留两份实现会同时被 import 造成 ambiguous_import。

/// 画质徽章行（4K / HDR / DV / Atmos）。详情页与列表卡片共用同一套判断口径。
class MediaFlagsRow extends StatelessWidget {
  const MediaFlagsRow({super.key, required this.item, this.compact = false});

  final VideoItem item;

  /// 紧凑：小一号字、更小间距（列表卡片里用）
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final flags = videoFlagsOf(item);
    if (flags.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: compact ? 4 : 6,
      runSpacing: compact ? 4 : 6,
      children: [
        for (final f in flags)
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 7,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              f,
              style: TextStyle(
                fontSize: compact ? 9 : NasTokens.fontMicro,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
      ],
    );
  }
}
