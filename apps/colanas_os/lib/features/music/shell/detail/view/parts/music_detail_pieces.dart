import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/getx.dart';
import '../../../shared/music_primitives.dart';
import '../../models/music_detail_models.dart';

/// 专辑 / 歌手详情页共用的小部件。
///
/// 拆出来是因为两个页面 80% 的视觉元素相同（封面、元信息行、简介折叠、
/// 错误重试、骨架屏），差别只在「曲目表要不要显示歌手列」和顶部那一块。

/// 大数字紧凑显示：12345 → 1.2万，1.2e8 → 1.2亿。Last.fm 的播放量动辄百万，
/// 原样铺在元信息行里会把整行挤爆。
String formatCompactCount(int value) {
  if (value <= 0) return '0';
  if (value < 10000) return '$value';
  if (value < 100000000) {
    final v = value / 10000;
    return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}万';
  }
  final v = value / 100000000;
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)}亿';
}

/// 秒 → 「1 小时 23 分」
String formatLongDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '$h 小时 ${m.toString().padLeft(2, '0')} 分';
  if (m > 0) return '$m 分钟';
  return '$seconds 秒';
}

String coverUrlOf(String path, {int size = 500}) {
  final p = path.trim();
  if (p.isEmpty) return '';
  return ApiController.instance.getMusicCoverUrl(filePath: p, size: size);
}

/// 封面：点击弹大图。没有封面时回退到默认图，不弹。
class MusicDetailCover extends StatelessWidget {
  const MusicDetailCover({
    super.key,
    required this.path,
    required this.size,
    this.radius = 16,
    this.circle = false,
  });

  final String path;
  final double size;
  final double radius;
  final bool circle;

  void _preview(BuildContext context) {
    final url = coverUrlOf(path, size: 800);
    if (url.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.min(720, MediaQuery.sizeOf(context).width - 48),
              maxHeight: MediaQuery.sizeOf(context).height - 96,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: InteractiveViewer(
                maxScale: 3,
                child: Image.network(url, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = coverUrlOf(path, size: (size * 2).round());
    final child = MusicCoverImage(
      url: url,
      width: size,
      height: size,
      borderRadius: circle ? size / 2 : radius,
    );
    return MouseRegion(
      cursor: url.isEmpty ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: url.isEmpty ? null : () => _preview(context),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(circle ? size / 2 : radius),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.16),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 元信息里的一行：`标签  值`（标签用次要色，值允许换行）
class MusicMetaLine extends StatelessWidget {
  const MusicMetaLine({
    super.key,
    required this.label,
    required this.value,
    this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style:
                  valueStyle ??
                  theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 简介：默认 4 行，超出显示「展开 / 收起」
class MusicIntroSection extends StatelessWidget {
  const MusicIntroSection({
    super.key,
    required this.title,
    required this.text,
    required this.expanded,
    required this.onToggle,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 8),
  });

  final String title;
  final String text;
  final bool expanded;
  final VoidCallback onToggle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final body = text.trim();
    // 没有简介时整个板块隐藏（PRD 明确要求）
    if (body.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: Text(
              body,
              maxLines: expanded ? null : 4,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.7,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onToggle,
              child: Text(expanded ? 'collapse'.tr : 'expand'.tr),
            ),
          ),
        ],
      ),
    );
  }
}

/// 操作按钮：图标 + 文字，PC 竖排大按钮 / 移动端横向小按钮都用它
class MusicActionButton extends StatelessWidget {
  const MusicActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.active = false,
    this.expanded = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool active;

  /// true = 撑满宽度、水平排列（PC 左面板）；false = 紧凑胶囊
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final fg = primary
        ? theme.colorScheme.onPrimary
        : (active ? theme.colorScheme.primary : theme.colorScheme.onSurface);
    final bg = primary
        ? theme.colorScheme.primary
        : (active
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ));

    final content = Row(
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 18, color: enabled ? fg : theme.disabledColor),
        if (label.trim().isNotEmpty) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: enabled ? fg : theme.disabledColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Container(
            height: 40,
            padding: EdgeInsets.symmetric(horizontal: expanded ? 16 : 14),
            alignment: Alignment.center,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 歌手页「收录专辑」横向卡片
class ArtistAlbumRail extends StatelessWidget {
  const ArtistAlbumRail({
    super.key,
    required this.albums,
    required this.onOpen,
  });

  final List<ArtistAlbumItem> albums;
  final void Function(ArtistAlbumItem album) onOpen;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Text(
            'music_detail_owned_albums'.tr,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 186,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final album = albums[index];
              return SizedBox(
                width: 132,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onOpen(album),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      MusicDetailCover(
                        path: album.coverPath,
                        size: 132,
                        radius: 12,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        album.year.isEmpty
                            ? '${album.indexCount} 首'
                            : '${album.year} · ${album.indexCount} 首',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 加载失败 / 专辑或歌手不存在 的兜底页
class MusicDetailErrorView extends StatelessWidget {
  const MusicDetailErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.showRetry = true,
  });

  final String message;
  final VoidCallback onRetry;
  final bool showRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.album_outlined,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (showRetry) ...<Widget>[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: Text('retry'.tr)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 骨架屏：左面板 + 右列表的大致形状，避免白屏闪一下
class MusicDetailSkeleton extends StatelessWidget {
  const MusicDetailSkeleton({super.key, this.wide = true});

  final bool wide;

  Widget _box(BuildContext context, double w, double h, {double r = 8}) {
    final theme = Theme.of(context);
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(r),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < 8; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: <Widget>[
                _box(context, 22, 14),
                const SizedBox(width: 14),
                Expanded(child: _box(context, double.infinity, 14)),
                const SizedBox(width: 20),
                _box(context, 40, 12),
              ],
            ),
          ),
      ],
    );

    if (!wide) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _box(context, 160, 160, r: 16),
            const SizedBox(height: 16),
            _box(context, 180, 18),
            const SizedBox(height: 10),
            _box(context, 120, 12),
            const SizedBox(height: 24),
            rows,
          ],
        ),
      );
    }
    return Row(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _box(context, 200, 200, r: 16),
              const SizedBox(height: 18),
              _box(context, 180, 18),
              const SizedBox(height: 10),
              _box(context, 120, 12),
              const SizedBox(height: 24),
              _box(context, 200, 36, r: 999),
              const SizedBox(height: 12),
              _box(context, 200, 36, r: 999),
            ],
          ),
        ),
        Expanded(child: rows),
      ],
    );
  }
}
