import 'package:flutter/material.dart';

import '../tokens.dart';

/// 骨架屏块：列表/网格加载前的占位（docs/04 §39.2「展示 · 骨架屏」）。
///
/// 刻意不做 shimmer 动画：静态块已能满足首屏提示，且不引入额外依赖。
class NasSkeleton extends StatelessWidget {
  const NasSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = NasTokens.radiusSm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(NasTokens.colorSurfaceAlt),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 网格骨架：按列数铺满占位块（相册 / 海报 / 书架首屏用）。
class NasSkeletonGrid extends StatelessWidget {
  const NasSkeletonGrid({
    super.key,
    required this.columns,
    this.aspectRatio = 1,
    this.count = 12,
    this.padding = const EdgeInsets.all(NasTokens.spaceSm),
    this.spacing = NasTokens.spaceXs,
  });

  final int columns;
  final double aspectRatio;
  final int count;
  final EdgeInsets padding;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
        childAspectRatio: aspectRatio,
      ),
      itemCount: count,
      itemBuilder: (context, index) => const NasSkeleton(
          height: double.infinity, radius: NasTokens.radiusMd),
    );
  }
}
