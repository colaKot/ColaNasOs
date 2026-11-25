import 'package:flutter/material.dart';

import '../style.dart';
import '../tokens.dart';

/// 顶部筛选 / 页签胶囊的统一样式。
///
/// 出处：下载管理页顶部「进行中 / 失败 / 已完成」那一套（用户 2026-11-25 指定为
/// 标准样式）。此后所有顶部 tab、筛选条都复用这里，不再各自用
/// `ChoiceChip` / `SegmentedButton` / 纯黑 `surface` 容器另造一套观感。
class NasPillTabs extends StatelessWidget {
  const NasPillTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
    this.counts,
    this.scrollable = true,
    this.padding,
    this.spacing = NasTokens.spaceSm,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 与 [labels] 等长的角标数字；对应位置为 null 时不显示角标。
  final List<int?>? counts;
  final bool scrollable;
  final EdgeInsetsGeometry? padding;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final spec = context.nasStyle;
    final children = <Widget>[
      for (var i = 0; i < labels.length; i++)
        NasPillChip(
          label: labels[i],
          count: counts != null && i < counts!.length ? counts![i] : null,
          selected: i == selectedIndex,
          onTap: () => onSelect(i),
          style: spec,
        ),
    ];
    final row = Row(
      mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          if (scrollable) children[i] else Expanded(child: children[i]),
        ],
      ],
    );
    final content = scrollable
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: row,
          )
        : row;
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: content,
    );
  }
}

/// 单个胶囊：下载管理页样式的最小单元，也供不便整排复用的地方单独使用。
class NasPillChip extends StatelessWidget {
  const NasPillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.style,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final NasStyleSpec? style;

  /// 窄条场景（悬浮胶囊）压缩左右留白，避免多枚胶囊挤在一起
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final spec = style ?? context.nasStyle;
    final scheme = Theme.of(context).colorScheme;
    final ink = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : spec.chipColor,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 14,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: ink,
                  ),
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.18)
                        : spec.panelBorderColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
