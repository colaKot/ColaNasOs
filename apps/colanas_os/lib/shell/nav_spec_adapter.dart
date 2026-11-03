import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import 'app_visuals.dart';

/// 契约（`contracts/apps.json#nav`）→ 侧栏分组。
///
/// 这里只做三件"翻译"的活，**组件与契约都不掺**：
///   1. `labelKey` → 当前语言文案（`NasSideNav` 不碰 i18n）
///   2. 图标名 → `IconData`（契约存名字，Flutter 才有图标）
///   3. 动态项按 `idPrefix` 展开成多条、条件项按 `conditions` 过滤
///
/// 加新模块时不用再写这段：契约里写 nav，模块只要给 [dynamic] 与 [conditions] 的数据。
List<NasNavGroup> buildNavGroups({
  required AppNavSpec spec,
  required String Function(String key) translate,
  Map<String, List<NavDynamicEntry>> dynamic = const {},
  Set<String> conditions = const {},
  IconData? fallbackIcon,
}) {
  final groups = <NasNavGroup>[];
  for (final section in spec.sections) {
    final entries = <NasNavEntry>[];
    for (final item in section.items) {
      if (item.when != null && !conditions.contains(item.when)) continue;

      if (item.isDynamic) {
        // 动态项：一条契约变多条菜单项（如影视的每个片源一条）
        final list = dynamic[item.dynamic!] ?? const <NavDynamicEntry>[];
        for (final d in list) {
          entries.add(
            NasNavEntry(
              id: '${item.idPrefix ?? ''}${d.id}',
              label: d.label,
              icon:
                  AppVisuals.iconOrNull(d.icon ?? '') ??
                  fallbackIcon ??
                  Icons.circle_outlined,
            ),
          );
        }
        continue;
      }

      entries.add(
        NasNavEntry(
          id: item.id,
          label: translate(item.labelKey ?? ''),
          icon:
              AppVisuals.iconOrNull(item.icon ?? '') ??
              fallbackIcon ??
              Icons.circle_outlined,
        ),
      );
    }
    if (entries.isEmpty) continue;
    groups.add(
      NasNavGroup(title: translate(section.titleKey), entries: entries),
    );
  }
  return groups;
}

/// 动态菜单项的数据（由模块提供，比如"我的影视库"列表）。
class NavDynamicEntry {
  const NavDynamicEntry({required this.id, required this.label, this.icon});

  final String id;
  final String label;

  /// 图标名（同契约里的写法，如 `movie_outlined`）
  final String? icon;
}

/// 按菜单项 id 反查文案。用于页面标题。
///
/// 动态项（如 `lib:<id>`）由调用方自己解析——契约不知道运行时的库名。
String navItemLabel(
  AppNavSpec spec,
  String itemId,
  String Function(String key) translate, {
  String? fallback,
}) {
  for (final section in spec.sections) {
    for (final item in section.items) {
      if (!item.isDynamic && item.id == itemId && item.labelKey != null) {
        return translate(item.labelKey!);
      }
    }
  }
  return fallback ?? itemId;
}
