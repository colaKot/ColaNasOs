import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

/// 顶栏 / 工具条上的「刷新」按钮。
///
/// 全站曾有 37 处手写 `IconButton(icon: Icon(Icons.refresh), tooltip: tr('common.refresh'))`，
/// 图标尺寸三种（18 / 20 / 默认 24）、有的干脆没 tooltip。统一到这里：
/// 尺寸、文案、点击区一份实现，改一次全站生效。
class NasRefreshButton extends StatelessWidget {
  const NasRefreshButton({
    super.key,
    required this.onPressed,
    this.size,
    this.tooltip,
  });

  /// 为 null 时按钮置灰（部分页面在加载中禁用刷新）
  final VoidCallback? onPressed;

  /// 图标尺寸；不传沿用 `Icon` 的默认值（24），与原裸 `IconButton` 视觉一致
  final double? size;

  /// 默认取 `common.refresh`；只有语义确实不同（如「刷新评论」）才另传
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip ?? tr('common.refresh'),
      icon: Icon(Icons.refresh, size: size),
      onPressed: onPressed,
    );
  }
}
