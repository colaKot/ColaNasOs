/// 波浪加载动画：一排小竖条按正弦相位高低起伏。
///
/// 自绘实现，避免为单个 loading 引入额外依赖；对外参数与 `SpinKitWave` 对齐。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class SpinKitWave extends StatefulWidget {
  const SpinKitWave({
    super.key,
    this.color,
    this.size = 50.0,
    this.itemCount = 5,
    this.duration = const Duration(milliseconds: 1200),
    this.controller,
  });

  final Color? color;
  final double size;
  final int itemCount;
  final Duration duration;
  final AnimationController? controller;

  @override
  State<SpinKitWave> createState() => _SpinKitWaveState();
}

class _SpinKitWaveState extends State<SpinKitWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _own = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  AnimationController get _ctrl => widget.controller ?? _own;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _own.repeat();
  }

  @override
  void dispose() {
    if (widget.controller == null) _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = math.max(1, widget.itemCount);
    final gap = widget.size * 0.12;
    final barWidth = (widget.size - gap * (count - 1)) / count;
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List<Widget>.generate(count, (i) {
              final phase = _ctrl.value * 2 * math.pi - i * 0.7;
              // 0.25~1.0 之间起伏，避免完全消失
              final scale = 0.25 + (math.sin(phase) + 1) / 2 * 0.75;
              return Container(
                width: barWidth,
                height: widget.size * scale,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(barWidth / 2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
