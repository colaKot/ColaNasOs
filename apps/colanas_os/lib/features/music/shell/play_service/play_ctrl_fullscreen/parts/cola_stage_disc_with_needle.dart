import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../shared/music_primitives.dart';

class MusicPlayCtrlFullScreenDiscWithNeedle extends StatefulWidget {
  final bool isPlaying;
  final String discAsset;
  final String coverUrl;

  const MusicPlayCtrlFullScreenDiscWithNeedle({
    super.key,
    required this.isPlaying,
    required this.discAsset,
    required this.coverUrl,
  });

  @override
  State<MusicPlayCtrlFullScreenDiscWithNeedle> createState() =>
      _MusicPlayCtrlFullScreenDiscWithNeedleState();
}

class _MusicPlayCtrlFullScreenDiscWithNeedleState
    extends State<MusicPlayCtrlFullScreenDiscWithNeedle>
    with TickerProviderStateMixin {
  late final AnimationController _rotationController;
  late final AnimationController _needleController;
  late final Animation<double> _needleAngle;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    _needleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _needleAngle = Tween<double>(begin: -0.02, end: 0.02).animate(
      CurvedAnimation(parent: _needleController, curve: Curves.easeInOut),
    );
    _sync(widget.isPlaying);
  }

  @override
  void didUpdateWidget(
    covariant MusicPlayCtrlFullScreenDiscWithNeedle oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _sync(widget.isPlaying);
    }
  }

  void _sync(bool playing) {
    if (playing) {
      if (!_rotationController.isAnimating) _rotationController.repeat();
      if (!_needleController.isAnimating) {
        _needleController.repeat(reverse: true);
      }
    } else {
      if (_rotationController.isAnimating) _rotationController.stop();
      if (_needleController.isAnimating) _needleController.stop();
      _needleController.animateTo(
        0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _needleController.dispose();
    super.dispose();
  }

  Widget _buildNeedle(_DiscGeometry g, double angle) {
    const localOriginX = 0.275;
    const localBaseAngle = -0.42;
    const localOriginY = 0.247;
    const localOriginAlignment = Alignment(
      localOriginX * 2 - 1,
      localOriginY * 2 - 1,
    );
    final localAngle = localBaseAngle + (widget.isPlaying ? angle : 0);

    return SizedBox(
      width: g.needleW,
      height: g.needleH,
      child: Transform.rotate(
        alignment: localOriginAlignment,
        angle: localAngle,
        child: Image.asset(
          'assets/music/icons/player_disc_bar.png',
          fit: BoxFit.contain,
          alignment: Alignment.topLeft,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);

    return LayoutBuilder(
      builder: (ctx, c) {
        final g = _DiscGeometry.of(c.maxWidth, c.maxHeight);

        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              width: g.frostedSize,
              top: g.frostedTop,
              left: g.frostedLeft,
              height: g.frostedSize,
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                        width: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              width: g.discSize,
              top: 10.0,
              left: g.discLeft,
              height: g.discSize,
              child: RotationTransition(
                turns: _rotationController,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Image.asset(widget.discAsset, fit: BoxFit.cover),
                    Center(
                      child: SizedBox(
                        width: g.inner,
                        height: g.inner,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.24),
                              width: 3.0,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(3, 3, 3, 3),
                            child: ClipOval(
                              child: Container(
                                color: localTheme.colorScheme.surfaceVariant
                                    .withValues(alpha: 0.35),
                                child: MusicCoverImage(
                                  url: widget.coverUrl,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: -g.size * 0.2,
              left: g.size * 0.18,
              child: AnimatedBuilder(
                animation: _needleAngle,
                builder: (c, _) => _buildNeedle(g, _needleAngle.value),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 唱片 / 唱针 / 磨砂光环的几何量，集中在一处避免散落的 localXxx 计算。
class _DiscGeometry {
  const _DiscGeometry({
    required this.size,
    required this.discSize,
    required this.inner,
    required this.discLeft,
    required this.needleH,
    required this.needleW,
    required this.frostedLeft,
    required this.frostedSize,
    required this.frostedTop,
  });

  factory _DiscGeometry.of(double maxWidth, double maxHeight) {
    final size = min(maxWidth, maxHeight);
    final discSize = size * 0.9;
    final inner = (discSize * 0.42 * 1.3).clamp(0.0, discSize * 0.62);
    final discLeft = (size - discSize) / 2;
    final needleH = size * 0.42;
    final needleW = size * 0.42;
    const frostedExtraRadius = 10.0;
    return _DiscGeometry(
      size: size,
      discSize: discSize,
      inner: inner,
      discLeft: discLeft,
      needleH: needleH,
      needleW: needleW,
      frostedLeft: discLeft - frostedExtraRadius,
      frostedSize: discSize + frostedExtraRadius * 2,
      frostedTop: 10 - frostedExtraRadius,
    );
  }

  final double size;
  final double discSize;
  final double inner;
  final double discLeft;
  final double needleH;
  final double needleW;
  final double frostedLeft;
  final double frostedSize;
  final double frostedTop;
}
