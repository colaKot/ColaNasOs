import 'dart:math';

import 'package:flutter/material.dart';

import '../../../compat/host.dart';
import '../../../compat/base_components.dart';
import '../../../compat/cola_api_controller.dart';
import '../../models/cola_album_artist_models.dart';

/// 专辑 / 歌手卡：封面在上，名称与曲目数在下。
///
/// 整张卡都能点开详情，所以外层套了不透明命中区域的 [GestureDetector]；
/// 内层 `CustomAlbum` 的点击只覆盖封面方块。
class AlbumArtistItemCard extends StatelessWidget {
  final double width;
  final VoidCallback onTap;
  final AlbumArtistGroupItem item;
  final double coverSize;
  final String badgeLabel;

  const AlbumArtistItemCard({
    required this.width,
    required this.onTap,
    super.key,
    required this.item,
    required this.coverSize,
    required this.badgeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: <Widget>[
          _CoverSquare(
            item: item,
            size: coverSize,
            badgeLabel: badgeLabel,
            onTap: onTap,
          ),
          const SizedBox(height: 6),
          _Caption(
            title: item.name,
            subtitle: '${max(0, item.indexCount)}首',
            width: width,
            titleStyle: theme.textTheme.titleSmall,
            subtitleStyle: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 方形封面：封面图 + 右上角的维度角标。
class _CoverSquare extends StatelessWidget {
  const _CoverSquare({
    required this.item,
    required this.size,
    required this.badgeLabel,
    required this.onTap,
  });

  final AlbumArtistGroupItem item;
  final double size;
  final String badgeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final showBadge = badgeLabel.trim().isNotEmpty;
    return SizedBox(
      width: size,
      height: size,
      child: CustomAlbum(
        onTap: onTap,
        preview: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _CoverPicture(
              filePath: item.firstFilePath,
              fallbackSeed: item.name,
            ),
            if (showBadge)
              Positioned(
                top: 6,
                right: 6,
                child: _CornerBadge(label: badgeLabel),
              ),
          ],
        ),
      ),
    );
  }
}

/// 网络封面：地址为空或加载失败都退回本地兜底图。
class _CoverPicture extends StatelessWidget {
  const _CoverPicture({required this.filePath, required this.fallbackSeed});

  final String filePath;
  final String fallbackSeed;

  @override
  Widget build(BuildContext context) {
    final url = _resolveUrl();
    if (url == null) return _FallbackCover(seed: fallbackSeed);
    return CustomExtendedImage(
      showLoading: false,
      imageUrl: url,
      fit: BoxFit.cover,
      borderRadius: 0,
      errorBuilder: (_, _, _) => _FallbackCover(seed: fallbackSeed),
    );
  }

  String? _resolveUrl() {
    final path = filePath.trim();
    if (path.isEmpty) return null;
    final url = ApiController.instance.getMusicCoverUrl(
      filePath: path,
      size: 200,
    );
    return url.isEmpty ? null : url;
  }
}

/// 本地兜底封面：用组名做种子固定挑一张，避免每次重建都换图。
class _FallbackCover extends StatelessWidget {
  const _FallbackCover({required this.seed});

  final String seed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = Random(seed.hashCode).nextInt(20) + 1;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Image.asset(
        'assets/music/musicCover/other$index.jpg',
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }
}

/// 封面右上角的维度角标（专辑 / 歌手）。
class _CornerBadge extends StatelessWidget {
  const _CornerBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 标题与曲目数：固定行高，避免长短名字把网格撑高。
class _Caption extends StatelessWidget {
  const _Caption({
    required this.title,
    required this.subtitle,
    required this.width,
    required this.titleStyle,
    required this.subtitleStyle,
  });

  final String title;
  final String subtitle;
  final double width;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 46,
    child: Column(
      children: <Widget>[
        Tooltip(
          waitDuration: const Duration(milliseconds: 300),
          message: title,
          child: _SingleLineText(text: title, width: width, style: titleStyle),
        ),
        if (subtitle.isNotEmpty)
          _SingleLineText(text: subtitle, width: width, style: subtitleStyle),
      ],
    ),
  );
}

/// 单行居中省略文本，标题与副标题共用同一套排版约束。
class _SingleLineText extends StatelessWidget {
  const _SingleLineText({
    required this.text,
    required this.width,
    required this.style,
  });

  final String text;
  final double width;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: style,
    ),
  );
}
