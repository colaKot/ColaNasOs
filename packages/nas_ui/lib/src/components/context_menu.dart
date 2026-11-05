import 'package:flutter/material.dart';

import '../tokens.dart';

/// 右键菜单的一项（或一条分隔线）。
///
/// 为什么自己写而不引 `flutter_context_menu`：我们只需要「一块区域 + 一组项 +
/// Esc/点外部关闭」，Material 3 的 `MenuAnchor` 已经能做，而且三端（Windows /
/// Web / 移动）行为一致、不多一个依赖、样式跟着主题走。
@immutable
class NasMenuEntry {
  const NasMenuEntry({
    required this.label,
    this.icon,
    this.onSelected,
    this.danger = false,
  }) : isDivider = false;

  const NasMenuEntry.divider()
    : label = '',
      icon = null,
      onSelected = null,
      danger = false,
      isDivider = true;

  final String label;
  final IconData? icon;
  final VoidCallback? onSelected;

  /// 破坏性操作（删除 / 移除）—— 用错误色区分
  final bool danger;
  final bool isDivider;

  bool get enabled => onSelected != null;
}

/// 右键菜单区域：把 [child] 包起来，鼠标右键（或触控板双指点按）时在指针位置弹菜单。
///
/// - 只在**有鼠标**的设备上触发（`onSecondaryTapDown`），移动端长按不会误触；
/// - [entries] 为空时完全不包装，调用方可以放心传空列表。
class NasContextMenuRegion extends StatelessWidget {
  const NasContextMenuRegion({
    super.key,
    required this.entries,
    required this.child,
  });

  final List<NasMenuEntry> entries;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return child;
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          ),
        ),
      ),
      menuChildren: [
        for (final e in entries)
          if (e.isDivider)
            const Divider(height: 9, thickness: 1)
          else
            MenuItemButton(
              leadingIcon: e.icon == null
                  ? null
                  : Icon(
                      e.icon,
                      size: NasTokens.iconSm,
                      color: e.danger ? scheme.error : scheme.onSurface,
                    ),
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(180, 36),
                padding: const EdgeInsets.symmetric(
                  horizontal: NasTokens.spaceMd,
                ),
              ),
              onPressed: e.onSelected,
              child: Text(
                e.label,
                style: TextStyle(
                  fontSize: NasTokens.fontBody,
                  color: e.danger ? scheme.error : scheme.onSurface,
                ),
              ),
            ),
      ],
      builder: (context, controller, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            controller.open(position: details.localPosition),
        child: child,
      ),
    );
  }
}

/// 在任意位置弹出一组菜单项（给「空白处右键」这类场景用）。
///
/// 返回选中的下标，点外面关闭返回 null。
Future<int?> showNasContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<NasMenuEntry> entries,
) {
  if (entries.isEmpty) return Future.value(null);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final scheme = Theme.of(context).colorScheme;
  return showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    color: scheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    items: [
      for (var i = 0; i < entries.length; i++)
        if (entries[i].isDivider)
          const PopupMenuDivider()
        else
          PopupMenuItem<int>(
            value: i,
            enabled: entries[i].enabled,
            height: 40,
            child: Row(
              children: [
                if (entries[i].icon != null) ...[
                  Icon(
                    entries[i].icon,
                    size: NasTokens.iconSm,
                    color: entries[i].danger ? scheme.error : null,
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                ],
                Text(
                  entries[i].label,
                  style: TextStyle(
                    fontSize: NasTokens.fontBody,
                    color: entries[i].danger ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ),
    ],
  ).then((index) {
    if (index == null) return null;
    entries[index].onSelected?.call();
    return index;
  });
}
