import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../shared/music_primitives.dart';

/// 黑胶唱机：旋转盘面 + 磨砂光环 + 播放时轻微摆动的唱针。
class ColaMusicStageVinyl extends StatefulWidget {
  const ColaMusicStageVinyl({
    super.key,
    required this.isPlaying,
    required this.discAsset,
    required this.coverUrl,
  });

  final bool isPlaying;
  final String discAsset;
  final String coverUrl;

  @override
  State<ColaMusicStageVinyl> createState() => _ColaMusicStageVinylState();
}

class _ColaMusicStageVinylState extends State<ColaMusicStageVinyl>
    with TickerProviderStateMixin {
  static const String _needleAsset = 'assets/music/icons/player_disc_bar.png';

  late final AnimationController _spin;
  late final AnimationController _swing;
  late final Animation<double> _swingAngle;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    _swing = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _swingAngle = Tween<double>(
      begin: -0.02,
      end: 0.02,
    ).animate(CurvedAnimation(parent: _swing, curve: Curves.easeInOut));
    _applyPlayState(widget.isPlaying);
  }

  @override
  void didUpdateWidget(covariant ColaMusicStageVinyl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _applyPlayState(widget.isPlaying);
    }
  }

  void _applyPlayState(bool playing) {
    if (playing) {
      if (!_spin.isAnimating) _spin.repeat();
      if (!_swing.isAnimating) _swing.repeat(reverse: true);
      return;
    }
    _spin.stop();
    _swing.stop();
    // 暂停时唱针落回中位，避免停在某个摆动极值上。
    _swing.animateTo(
      0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _spin.dispose();
    _swing.dispose();
    super.dispose();
  }

  Widget _needle(_VinylMetrics m, double angle) {
    const originX = 0.275;
    const originY = 0.247;
    const restAngle = -0.42;
    final pivot = Alignment(originX * 2 - 1, originY * 2 - 1);

    return SizedBox(
      width: m.needleWidth,
      height: m.needleHeight,
      child: Transform.rotate(
        alignment: pivot,
        angle: restAngle + (widget.isPlaying ? angle : 0),
        child: Image.asset(
          _needleAsset,
          fit: BoxFit.contain,
          alignment: Alignment.topLeft,
        ),
      ),
    );
  }

  Widget _frostedHalo(_VinylMetrics m) {
    return Positioned(
      width: m.haloSize,
      height: m.haloSize,
      top: m.haloTop,
      left: m.haloLeft,
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
    );
  }

  Widget _spinningDisc(_VinylMetrics m, ThemeData theme) {
    return Positioned(
      width: m.discSize,
      height: m.discSize,
      top: 10.0,
      left: m.discLeft,
      child: RotationTransition(
        turns: _spin,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image.asset(widget.discAsset, fit: BoxFit.cover),
            Center(child: _label(m, theme)),
          ],
        ),
      ),
    );
  }

  /// 盘面中心贴的封面圆：外圈留 3px 白描边。
  Widget _label(_VinylMetrics m, ThemeData theme) {
    return SizedBox(
      width: m.labelSize,
      height: m.labelSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.24),
            width: 3.0,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              child: MusicCoverImage(url: widget.coverUrl, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (_, box) {
        final m = _VinylMetrics.of(box.maxWidth, box.maxHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            _frostedHalo(m),
            _spinningDisc(m, theme),
            Positioned(
              top: -m.side * 0.2,
              left: m.side * 0.18,
              child: AnimatedBuilder(
                animation: _swingAngle,
                builder: (_, _) => _needle(m, _swingAngle.value),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 盘面、唱针、光环的尺寸都由同一条边长推导，集中算一次。
class _VinylMetrics {
  const _VinylMetrics({
    required this.side,
    required this.discSize,
    required this.labelSize,
    required this.discLeft,
    required this.needleWidth,
    required this.needleHeight,
    required this.haloLeft,
    required this.haloTop,
    required this.haloSize,
  });

  factory _VinylMetrics.of(double maxWidth, double maxHeight) {
    final side = math.min(maxWidth, maxHeight);
    final disc = side * 0.9;
    final left = (side - disc) / 2;
    return _VinylMetrics(
      side: side,
      discSize: disc,
      labelSize: (disc * 0.546).clamp(0.0, disc * 0.62),
      discLeft: left,
      needleWidth: side * 0.42,
      needleHeight: side * 0.42,
      haloLeft: left - _haloBleed,
      haloTop: 10.0 - _haloBleed,
      haloSize: disc + _haloBleed * 2,
    );
  }

  static const double _haloBleed = 10.0;

  final double side;
  final double discSize;
  final double labelSize;
  final double discLeft;
  final double needleWidth;
  final double needleHeight;
  final double haloLeft;
  final double haloTop;
  final double haloSize;
}
