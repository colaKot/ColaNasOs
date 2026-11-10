import 'package:flutter/material.dart';

import '../tokens.dart';

/// 二级左侧导航（与相册 / 影视 / 音乐模块一致的视觉规格）。
///
/// 统一入口：页内顶部/底部 Tab 一律上移到左侧栏；宽度 128（图标 + 4 字），
/// 收起态 56（只留图标，且**不渲染文字**，避免固定占位溢出）。
class NasNavEntry {
  const NasNavEntry(
      {required this.id, required this.label, required this.icon});

  final String id;
  final String label;
  final IconData icon;
}

class NasNavGroup {
  const NasNavGroup({this.title = '', required this.entries});

  final String title;
  final List<NasNavEntry> entries;
}

class NasSideNav extends StatelessWidget {
  const NasSideNav({
    super.key,
    required this.groups,
    required this.selectedId,
    required this.onSelect,
    this.width = 128,
    this.iconOnly = false,
    this.header,
    this.footer,
    this.title,
    this.onToggleCollapsed,
    this.expandTooltip,
    this.collapseTooltip,
    this.debugLabel,
  });

  final List<NasNavGroup> groups;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final double width;
  final bool iconOnly;
  final Widget? header;
  final Widget? footer;

  /// 内置头部标题。与 [onToggleCollapsed] 一起用时，组件自己渲染
  /// 「标题 + 折叠按钮」这一行 —— **各模块不要再各画一遍**（那正是溢出 bug 的来源）。
  final String? title;

  /// 折叠/展开回调。为 null 时不渲染折叠按钮（一级导航就是这样）。
  final VoidCallback? onToggleCollapsed;
  final String? expandTooltip;
  final String? collapseTooltip;

  /// 条目 key 的前缀（测试用）。一级栏和二级栏都有 `home` 这种同名 id，
  /// 给每栏一个 label 就能用 `find.byKey(ValueKey('nav:photo/home'))` 精确定位。
  final String? debugLabel;

  /// 某个菜单项的稳定 key。测试遍历「全部 app × 菜单项」时靠它点到条目。
  static Key keyOf(String scope, String id) =>
      ValueKey<String>('nav:$scope/$id');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceXs,
            vertical: NasTokens.spaceSm,
          ),
          children: [
            if (_usesBuiltInHeader(context)) _builtInHeader(context),
            if (header != null) header!,
            for (final group in groups) ...[
              if (!iconOnly && group.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NasTokens.spaceSm,
                    NasTokens.spaceMd,
                    NasTokens.spaceSm,
                    NasTokens.spaceXs,
                  ),
                  child: Text(
                    group.title.toUpperCase(),
                    // 一级栏收窄到「图标 + 2 字」后，较长的分组名要截断而不是换行
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                const SizedBox(height: NasTokens.spaceSm),
              for (final entry in group.entries)
                _Tile(
                  key: keyOf(debugLabel ?? '-', entry.id),
                  entry: entry,
                  selected: entry.id == selectedId,
                  iconOnly: iconOnly,
                  onTap: () => onSelect(entry.id),
                ),
            ],
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}

extension _SideNavHeader on NasSideNav {
  bool _usesBuiltInHeader(BuildContext context) =>
      onToggleCollapsed != null && (title != null || iconOnly);

  /// 内置头部：标题 + 折叠按钮。
  ///
  /// 折叠态可用宽度只有 ~36px（56 侧栏 - 内边距），而 `IconButton` 默认最小点击区 48，
  /// 直接放会 `RenderFlex overflowed by 4.0 pixels`。这里是**唯一**一处定义这个按钮，
  /// 收紧到 32×32 并让折叠态居中，避免各模块再各写一份又漏改。
  Widget _builtInHeader(BuildContext context) {
    final collapsed = iconOnly;
    final label = title;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
      ),
      child: Row(
        mainAxisAlignment:
            collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          if (!collapsed && label != null && label.isNotEmpty)
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          IconButton(
            tooltip:
                collapsed ? (expandTooltip ?? '') : (collapseTooltip ?? ''),
            // M3 的 IconButton 只看 style 里的 minimumSize / tapTargetSize：
            // 只给 `constraints` 时仍会按 40 的最小点击区绘制，折叠态（可用宽度 36）
            // 就溢出了 4px。这里显式压到 32×32，别退回只写 constraints 的写法。
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              maximumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: Icon(
              collapsed
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
            ),
            onPressed: onToggleCollapsed,
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.entry,
    required this.selected,
    required this.iconOnly,
    required this.onTap,
  });

  final NasNavEntry entry;
  final bool selected;
  final bool iconOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg =
        selected ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.78);
    final tile = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: EdgeInsets.symmetric(
          horizontal: iconOnly ? 0 : NasTokens.spaceSm,
          vertical: NasTokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          border: selected
              ? const Border(
                  left: BorderSide(width: 2.5, color: Colors.transparent))
              : null,
        ),
        foregroundDecoration: selected
            ? BoxDecoration(
                border:
                    Border(left: BorderSide(width: 2.5, color: scheme.primary)),
              )
            : null,
        child: iconOnly
            ? Center(
                child: Icon(
                  entry.icon,
                  size: NasTokens.iconMd,
                  color: selected ? scheme.primary : fg,
                ),
              )
            : Row(
                children: [
                  Icon(
                    entry.icon,
                    size: NasTokens.iconMd,
                    color: selected ? scheme.primary : fg,
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontBody,
                        color: fg,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    return iconOnly ? Tooltip(message: entry.label, child: tile) : tile;
  }
}
