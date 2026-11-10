import 'package:flutter/material.dart';

import '../../../compat/getx.dart';

import 'cola_stage_disc_with_needle.dart';

class MusicPlayCtrlFullScreenDiscBlock extends StatelessWidget {
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onTapDisc;
  final VoidCallback onShowProperties;
  final VoidCallback onShowPlaylist;
  final VoidCallback onNextDiscStyle;
  final bool isPlaying;
  final bool isFavorite;
  final bool favoriteLoading;
  final String discAsset;
  final String coverUrl;

  const MusicPlayCtrlFullScreenDiscBlock({
    required this.onToggleFavorite,
    this.onTapDisc,
    required this.onShowProperties,
    required this.onShowPlaylist,
    required this.onNextDiscStyle,
    super.key,
    required this.isPlaying,
    required this.isFavorite,
    required this.favoriteLoading,
    required this.discAsset,
    required this.coverUrl,
  });

  Widget _buildDisc() {
    final disc = MusicPlayCtrlFullScreenDiscWithNeedle(
      isPlaying: isPlaying,
      discAsset: discAsset,
      coverUrl: coverUrl,
    );
    if (onTapDisc == null) return disc;
    return GestureDetector(
      onTap: onTapDisc,
      behavior: HitTestBehavior.translucent,
      child: disc,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.colorScheme.onSurface.withValues(alpha: 0.85);

    Widget icon(IconData data, {Color? color}) {
      return Icon(data, color: color ?? iconColor);
    }

    final disc = _buildDisc();

    final actions = Wrap(
      spacing: 10,
      children: <Widget>[
        if (onToggleFavorite != null)
          IconButton(
            tooltip: isFavorite ? 'unfavorite'.tr : 'favorites'.tr,
            onPressed: onToggleFavorite,
            icon: favoriteLoading
                ? const SizedBox(
                    width: 18.0,
                    height: 18.0,
                    child: CircularProgressIndicator(strokeWidth: 1.0),
                  )
                : icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite ? Colors.red : iconColor,
                  ),
          ),
        IconButton(
          tooltip: 'change_disc_style'.tr,
          onPressed: onNextDiscStyle,
          icon: icon(Icons.rotate_left),
        ),
        IconButton(
          tooltip: 'property'.tr,
          onPressed: onShowProperties,
          icon: icon(Icons.info_outline),
        ),
        IconButton(
          tooltip: 'player_playlist'.tr,
          onPressed: onShowPlaylist,
          icon: icon(Icons.queue_music),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (ctx, c) {
        final boundedHeight = c.hasBoundedHeight && c.maxHeight.isFinite;
        if (!boundedHeight) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: AspectRatio(aspectRatio: 1, child: disc),
                ),
              ),
              const SizedBox(height: 10.0),
              Center(child: actions),
            ],
          );
        }

        final g = _DiscBlockGeometry.of(c.maxWidth, c.maxHeight);

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(width: g.discSize, height: g.discSize, child: disc),
              const SizedBox(height: _DiscBlockGeometry.gap),
              Center(child: actions),
            ],
          ),
        );
      },
    );
  }
}

/// 有界高度分支下的碟面边长与留白，集中在一处。
class _DiscBlockGeometry {
  const _DiscBlockGeometry({required this.discSize});

  static const double gap = 10.0;
  static const double actionsHeight = 48.0;

  factory _DiscBlockGeometry.of(double maxWidth, double maxHeight) {
    final maxDiscByHeight = (maxHeight - actionsHeight - gap).clamp(
      0.0,
      double.infinity,
    );
    final discSize = [
      520.0,
      maxWidth,
      maxDiscByHeight,
    ].reduce((a, b) => a < b ? a : b);
    return _DiscBlockGeometry(discSize: discSize);
  }

  final double discSize;
}
