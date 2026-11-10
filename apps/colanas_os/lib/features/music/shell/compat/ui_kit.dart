/// 音乐壳视图层的公共零件。
///
/// 列表页的顶栏、排序菜单、卡片、空态、翻页提示以前各写各的：同一个方形按钮
/// 在 8 个文件里重复声明参数，排序菜单项每处都抄一遍「勾选框 + 图标 + 文案」，
/// 空态和「加载更多」也是逐页复制。这里收成一组与业务无关的组件，
/// 底层仍复用项目既有的带边框按钮与空态视图，视觉保持一致。
library;

import 'package:flutter/material.dart';

import 'base_components.dart';
import 'getx.dart';
import 'host.dart' show CustomNoData;

/// 方形圆角图标按钮。参数与底层按钮一致，额外把默认值固定在一处。
class MusicSquareButton extends StatelessWidget {
  const MusicSquareButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 32,
    this.iconSize = 16,
    this.borderRadius = 6,
    this.borderColor,
    this.iconColor,
    this.hoverColor,
    this.backgroundColor,
    this.enabled = true,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double iconSize;
  final double borderRadius;
  final Color? borderColor;
  final Color? iconColor;
  final Color? hoverColor;
  final Color? backgroundColor;
  final bool enabled;
  final bool active;

  @override
  Widget build(BuildContext context) => CustomBorderedIconButton(
    icon: icon,
    onTap: onTap,
    tooltip: tooltip,
    size: size,
    iconSize: iconSize,
    borderRadius: borderRadius,
    borderColor: borderColor,
    iconColor: iconColor,
    hoverColor: hoverColor,
    backgroundColor: backgroundColor,
    enabled: enabled,
    active: active,
  );
}

/// 弹出式排序菜单的一行：左侧勾选位、类型图标、文案。
class MusicSortMenuItem extends StatelessWidget {
  const MusicSortMenuItem({
    super.key,
    required this.icon,
    required this.label,
    this.selected = false,
    this.checkWidth = 24,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final double checkWidth;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      SizedBox(
        width: checkWidth,
        child: selected ? const Icon(Icons.check, size: 18) : null,
      ),
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Text(label),
    ],
  );
}

/// 内联菜单项（MenuItemButton）的选中态封装：选中显示勾，未选中留等宽占位。
class MusicCheckMenuItem extends StatelessWidget {
  const MusicCheckMenuItem({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconSize = 18,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double iconSize;

  @override
  Widget build(BuildContext context) => MenuItemButton(
    onPressed: onTap,
    leadingIcon: selected
        ? Icon(Icons.check, size: iconSize)
        : SizedBox(width: iconSize),
    child: Text(label),
  );
}

/// 卡片顶栏：标题占满剩余宽度，右侧挂操作区（通常是更多菜单）。
class MusicCardHeader extends StatelessWidget {
  const MusicCardHeader({
    super.key,
    required this.title,
    this.trailing,
    this.titleStyle,
    this.onTap,
  });

  final String title;
  final Widget? trailing;
  final TextStyle? titleStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
      ),
      ?trailing,
    ],
  );
}

/// 列表空态。默认文案取多语键，可由调用方覆盖。
class MusicEmptyState extends StatelessWidget {
  const MusicEmptyState({super.key, this.message, this.backgroundColor});

  final String? message;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) => CustomNoData(
    text: message ?? 'no_data'.tr,
    backgroundColor: backgroundColor,
  );
}

/// 列表底部的翻页提示：加载中 → 转圈；还有数据 → 按钮；到底 → 文案。
class MusicLoadMore extends StatelessWidget {
  const MusicLoadMore({
    super.key,
    required this.hasMore,
    required this.onLoad,
    this.busy = false,
    this.loadMoreLabel,
    this.noMoreLabel,
  });

  final bool hasMore;
  final bool busy;
  final VoidCallback onLoad;
  final String? loadMoreLabel;
  final String? noMoreLabel;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!hasMore) return Text(noMoreLabel ?? 'no_more'.tr);
    return OutlinedButton(
      onPressed: onLoad,
      child: Text(loadMoreLabel ?? 'load_more'.tr),
    );
  }
}
