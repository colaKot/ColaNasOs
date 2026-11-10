import 'package:flutter/material.dart';

import 'getx.dart';

/// 一条排序选项的声明式描述。
class SortMenuChoice<B, O> {
  const SortMenuChoice(
    this.by,
    this.order,
    this.labelKey, {
    this.dividerBefore = false,
    this.enabled = true,
  });

  final B by;
  final O order;
  final String labelKey;
  final bool dividerBefore;
  final bool enabled;
}

typedef SortPicker<B, O> = void Function(B by, O order);

/// 把排序选项表渲染成带勾选态的菜单项。
///
/// 主列表、子列表、专辑列表共用这套渲染，各自只需要给出选项数据。
List<Widget> buildSortMenuItems<B extends Object, O extends Object>({
  required B currentBy,
  required O currentOrder,
  required List<SortMenuChoice<B, O>> choices,
  required SortPicker<B, O> onPick,
}) {
  final items = <Widget>[];
  for (final choice in choices) {
    if (!choice.enabled) continue;
    if (choice.dividerBefore) items.add(const Divider(height: 1));

    final selected = currentBy == choice.by && currentOrder == choice.order;
    items.add(
      MenuItemButton(
        leadingIcon: selected
            ? const Icon(Icons.check, size: 18)
            : const SizedBox(width: 18),
        onPressed: () => onPick(choice.by, choice.order),
        child: Text(choice.labelKey.tr),
      ),
    );
  }
  return items;
}
