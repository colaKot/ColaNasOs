import 'package:flutter/material.dart';

import '../../compat/base_components.dart';

/// 旋转唱片封面。
///
/// 状态层只负责按播放状态驱动动画；唱片叠层与封面图片是无状态部件，
/// 这样改封面加载策略时不需要碰动画生命周期。
class MusicPlayDiscCover extends StatefulWidget {
  const MusicPlayDiscCover({
    super.key,
    required this.coverUrl,
    required this.isPlaying,
    required this.discAsset,
    this.onTap,
    this.outerSize = 58,
    this.innerSize = 40,
    this.rotationDuration = const Duration(seconds: 18),
  });

  final Duration rotationDuration;
  final double outerSize;
  final VoidCallback? onTap;
  final bool isPlaying;
  final double innerSize;
  final String discAsset;
  final String coverUrl;

  @override
  State<MusicPlayDiscCover> createState() => _MusicPlayDiscCoverState();
}

class _MusicPlayDiscCoverState extends State<MusicPlayDiscCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: widget.rotationDuration,
  );

  @override
  void initState() {
    super.initState();
    _syncWith(widget);
  }

  @override
  void didUpdateWidget(covariant MusicPlayDiscCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncWith(widget);
  }

  void _syncWith(MusicPlayDiscCover config) {
    if (_spin.duration != config.rotationDuration) {
      _spin.duration = config.rotationDuration;
    }
    if (config.isPlaying && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!config.isPlaying && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _DiscSurface(spin: _spin, config: widget);
}

class _DiscSurface extends StatelessWidget {
  const _DiscSurface({required this.spin, required this.config});

  final Animation<double> spin;
  final MusicPlayDiscCover config;

  @override
  Widget build(BuildContext context) {
    final backdrop = Theme.of(context).colorScheme.surfaceContainerHighest
        .withValues(alpha: 0.4);

    return SizedBox(
      width: config.outerSize,
      height: config.outerSize,
      child: GestureDetector(
        onTap: config.onTap,
        behavior: HitTestBehavior.opaque,
        child: RotationTransition(
          turns: spin,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image.asset(config.discAsset, fit: BoxFit.cover),
              Center(
                child: ClipOval(
                  child: Container(
                    width: config.innerSize,
                    height: config.innerSize,
                    color: backdrop,
                    child: _CoverImage(
                      url: config.coverUrl,
                      side: config.innerSize,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverImage extends StatelessWidget {
  const _CoverImage({required this.url, required this.side});

  final String url;
  final double side;

  static const String _fallback = 'assets/music/icons/default_cover.jpg';

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) return _asset();
    return CustomExtendedImage(
      width: side,
      showLoading: false,
      imageUrl: url,
      height: side,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _asset(),
      borderRadius: 0,
    );
  }

  Widget _asset() =>
      Image.asset(_fallback, width: side, height: side, fit: BoxFit.cover);
}
