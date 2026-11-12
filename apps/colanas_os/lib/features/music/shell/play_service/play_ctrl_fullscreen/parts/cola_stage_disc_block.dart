import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import 'cola_stage_disc_with_needle.dart';

/// 唱片区块：黑胶主体 + 下方一排操作按钮。
class ColaMusicStageDisc extends StatelessWidget {
  const ColaMusicStageDisc({
    super.key,
    required this.onToggleFavorite,
    this.onTapDisc,
    required this.onShowProperties,
    required this.onShowPlaylist,
    required this.onNextDiscStyle,
    required this.isPlaying,
    required this.isFavorite,
    required this.favoriteLoading,
    required this.discAsset,
    required this.coverUrl,
  });

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

  /// 唱片与按钮之间、以及按钮区预留的高度。
  static const double _gap = 10.0;
  static const double _actionsHeight = 48.0;
  static const double _maxDiscSide = 520.0;

  Widget _vinyl() {
    final Widget disc = ColaMusicStageVinyl(
      isPlaying: isPlaying,
      discAsset: discAsset,
      coverUrl: coverUrl,
    );
    final tap = onTapDisc;
    if (tap == null) return disc;
    return GestureDetector(
      onTap: tap,
      behavior: HitTestBehavior.translucent,
      child: disc,
    );
  }

  Widget _favoriteAction(Color tint) {
    if (favoriteLoading) {
      return const SizedBox(
        width: 18.0,
        height: 18.0,
        child: CircularProgressIndicator(strokeWidth: 1.0),
      );
    }
    return Icon(
      isFavorite ? Icons.favorite : Icons.favorite_border,
      color: isFavorite ? Colors.red : tint,
    );
  }

  Widget _actions(Color tint) {
    return Wrap(
      spacing: 10,
      children: <Widget>[
        if (onToggleFavorite != null)
          IconButton(
            tooltip: isFavorite ? 'unfavorite'.tr : 'favorites'.tr,
            onPressed: onToggleFavorite,
            icon: _favoriteAction(tint),
          ),
        IconButton(
          tooltip: 'change_disc_style'.tr,
          onPressed: onNextDiscStyle,
          icon: Icon(Icons.rotate_left, color: tint),
        ),
        IconButton(
          tooltip: 'property'.tr,
          onPressed: onShowProperties,
          icon: Icon(Icons.info_outline, color: tint),
        ),
        IconButton(
          tooltip: 'player_playlist'.tr,
          onPressed: onShowPlaylist,
          icon: Icon(Icons.queue_music, color: tint),
        ),
      ],
    );
  }

  /// 高度不受限时（例如嵌进可滚动容器）按最大宽度与正方形裁切。
  Widget _unboundedLayout(Widget disc, Widget actions) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxDiscSide),
            child: AspectRatio(aspectRatio: 1, child: disc),
          ),
        ),
        const SizedBox(height: _gap),
        Center(child: actions),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.85);
    final disc = _vinyl();
    final actions = _actions(tint);

    return LayoutBuilder(
      builder: (_, box) {
        final heightBounded = box.hasBoundedHeight && box.maxHeight.isFinite;
        if (!heightBounded) return _unboundedLayout(disc, actions);

        // 唱片边长同时受父级宽、父级高（扣掉按钮区）与 520 上限约束。
        final byHeight = (box.maxHeight - _actionsHeight - _gap).clamp(
          0.0,
          double.infinity,
        );
        final side = math.min(math.min(_maxDiscSide, box.maxWidth), byHeight);

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(width: side, height: side, child: disc),
              const SizedBox(height: _gap),
              Center(child: actions),
            ],
          ),
        );
      },
    );
  }
}
