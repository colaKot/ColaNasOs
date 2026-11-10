/// 参数化排序按钮：把「排序项表 → 弹出菜单 → 值编解码 → 回调」收成一处。
///
/// 主列表与专辑/歌手列表原来各自维护 `_buildSortButton` / `_parseSortBy` /
/// `_parseSortOrder` / `_sortByIcon` / `_buildSortItems` 五个函数，逻辑逐行相同，
/// 只是枚举类型与文案不同。这里用泛型 + 声明式 spec 表替代。
library;

import 'package:flutter/material.dart';

import '../compat/getx.dart';
import '../compat/host.dart';
import '../compat/ui_kit.dart';

class MusicSortSpec<B, O> {
  const MusicSortSpec({
    required this.by,
    required this.order,
    required this.labelKey,
    required this.icon,
    this.dividerBefore = false,
  });

  final B by;
  final O order;
  final String labelKey;
  final IconData icon;
  final bool dividerBefore;
}

class MusicSortButton<B, O> extends StatelessWidget {
  const MusicSortButton({
    super.key,
    required this.buttonKey,
    required this.sortBy,
    required this.sortOrder,
    required this.specs,
    required this.onSort,
    required this.isDefault,
    this.onlyIf,
    this.enabled = true,
  });

  final GlobalKey buttonKey;
  final Rx<B> sortBy;
  final Rx<O> sortOrder;
  final List<MusicSortSpec<B, O>> specs;
  final void Function(B by, O order) onSort;
  final bool Function(B by, O order) isDefault;
  final bool Function(MusicSortSpec<B, O> spec)? onlyIf;
  final bool enabled;

  static String _name(Object? value) => value.toString().split('.').last;

  @override
  Widget build(BuildContext context) => Obx(() {
    final currentBy = sortBy.value;
    final currentOrder = sortOrder.value;
    return MusicSquareButton(
      key: buttonKey,
      tooltip: 'sort'.tr,
      icon: Icons.sort_by_alpha,
      active: !isDefault(currentBy, currentOrder),
      enabled: enabled,
      onTap: () => _open(context, currentBy, currentOrder),
    );
  });

  List<MusicSortSpec<B, O>> get _visible => <MusicSortSpec<B, O>>[
    for (final spec in specs)
      if (onlyIf == null || onlyIf!(spec)) spec,
  ];

  Future<void> _open(BuildContext context, B currentBy, O currentOrder) async {
    final items = <PopupMenuEntry<String>>[];
    for (final spec in _visible) {
      if (spec.dividerBefore) items.add(const PopupMenuDivider());
      final selected =
          _name(spec.by) == _name(currentBy) &&
          _name(spec.order) == _name(currentOrder);
      items.add(
        PopupMenuItem<String>(
          value: '${_name(spec.by)}:${_name(spec.order)}',
          child: MusicSortMenuItem(
            icon: spec.icon,
            label: spec.labelKey.tr,
            selected: selected,
          ),
        ),
      );
    }

    final picked = await PopupMenuUtil.showBelowButton<String>(
      context: context,
      buttonKey: buttonKey,
      items: items,
    );
    if (picked == null) return;
    final parts = picked.split(':');
    if (parts.length != 2) return;
    for (final spec in _visible) {
      if (_name(spec.by) == parts[0] && _name(spec.order) == parts[1]) {
        onSort(spec.by, spec.order);
        return;
      }
    }
  }
}
