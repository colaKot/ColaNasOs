import 'package:flutter/material.dart';

import '../style.dart';
import '../tokens.dart';

/// 全系统统一的下拉选择框。
///
/// 为什么不用 Material 的 `DropdownButton` / `DropdownButtonFormField`：
/// 那两个在不同页面里被写出了十几种形态（有描边、有下划线、有裸的、有填色的），
/// 字号、圆角、内边距各不相同 —— 同一个 App 里看着像两套产品。
/// 现在**只有一个**下拉：改这里 = 改全系统。
///
/// 参数刻意兼容 Material 两版的用法，迁移时基本只改类名：
///   - `initialValue`（FormField 版）/ `value`（Button 版）都收
///   - `decoration` 直接透传给 `InputDecoration`
class NasDropdown<T> extends StatelessWidget {
  const NasDropdown({
    super.key,
    this.value,
    this.initialValue,
    required this.items,
    required this.onChanged,
    this.decoration,
    this.label,
    this.helper,
    this.hint,
    this.dense = true,
    this.isDense,
    this.expanded = false,
    this.isExpanded,
    this.underline,
    this.padding,
    this.textStyle,
    this.dropdownColor,
    this.focusColor,
    this.itemHeight,
  });

  final T? value;
  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final String? label;
  final String? helper;
  final Widget? hint;
  final bool dense;

  /// Material 版的参数名（等价于 [dense]）；两个都收，迁移时不用改参数名
  final bool? isDense;

  /// 撑满可用宽度。默认 **false**（与 Material 的两版一致）——
  /// 之前默认 true 时，放进 Row 的下拉会拿到无限宽度约束，测试直接报 'hasSize'。
  /// 需要撑满的地方显式写 `expanded: true`。
  final bool expanded;
  final bool? isExpanded;
  final Widget? underline;
  final EdgeInsetsGeometry? padding;
  final TextStyle? textStyle;

  /// ↓ Material 的其余可选参数：收下但由本组件统一外观，多数被忽略
  final Color? dropdownColor;
  final Color? focusColor;
  final double? itemHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = value ?? initialValue;

    final field = DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: current,
        items: items,
        onChanged: onChanged,
        isDense: isDense ?? dense,
        isExpanded: isExpanded ?? expanded,
        borderRadius: BorderRadius.circular(8),
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        style: textStyle ??
            theme.textTheme.bodyMedium?.copyWith(fontSize: NasTokens.fontBody),
        // 弹出菜单用面板材质合成的不透明色：跟整站卡片同色系，又不透出下层内容。
        dropdownColor: Color.alphaBlend(
          context.nasStyle.panelColor,
          context.nasStyle.baseColor,
        ),
        hint: hint,
        icon: Icon(Icons.arrow_drop_down, size: 18, color: scheme.onSurfaceVariant),
      ),
    );

    if (decoration != null) {
      return DropdownButtonFormField<T>(
        initialValue: current,
        items: items,
        onChanged: onChanged,
        isDense: isDense ?? dense,
        isExpanded: isExpanded ?? expanded,
        borderRadius: BorderRadius.circular(8),
        decoration: decoration,
        style: textStyle,
        dropdownColor: Color.alphaBlend(
          context.nasStyle.panelColor,
          context.nasStyle.baseColor,
        ),
      );
    }

    // 没有 decoration 的场景（工具条里的裸下拉）：给一个统一的描边容器，
    // 免得跟表单里的下拉长得完全不一样。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: field,
    );
  }
}

/// 全系统统一的胶囊选项（替代 Material 的 `FilterChip` / `ChoiceChip`）。
///
/// Material 的 Chip 在深色主题下是「实心高饱和 + 粗描边」，和本项目的低饱和配色
/// 打架（用户吐槽过「太丑」）。这里的规则很简单：
///   - 选中：主色淡底 + 主色描边 + 主色文字
///   - 未选中：**半透明**底 + 极淡描边 + 次要文字
class NasChip extends StatelessWidget {
  const NasChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
    this.avatar,
    this.tooltip,
    this.dense = true,
    this.padding,
    // ↓ Material Chip 的可选参数：留着是为了让「机械替换」能编译，
    //   外观一律按本组件的规则走，这些值多数被忽略。
    this.showCheckmark,
    this.side,
    this.backgroundColor,
    this.selectedColor,
    this.labelStyle,
    this.visualDensity,
    this.shape,
    this.checkmarkColor,
    this.materialTapTargetSize,
  });

  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? icon;
  final Widget? avatar;
  final String? tooltip;
  final bool dense;
  final EdgeInsetsGeometry? padding;
  final bool? showCheckmark;
  final BorderSide? side;
  final Color? backgroundColor;
  final Color? selectedColor;
  final TextStyle? labelStyle;
  final VisualDensity? visualDensity;
  final ShapeBorder? shape;
  final Color? checkmarkColor;
  final MaterialTapTargetSize? materialTapTargetSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 未选中不再用 Material 默认的近黑胶囊，统一走风格面板材质。
    final style = context.nasStyle;
    final bg = selected
        ? scheme.primary.withValues(alpha: 0.14)
        : style.panelColor;
    final border = selected
        ? scheme.primary.withValues(alpha: 0.55)
        : style.panelBorderColor;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;

    Widget content = Container(
      padding: padding ??
          EdgeInsets.symmetric(
            horizontal: dense ? 12 : 16,
            vertical: dense ? 6 : 10,
          ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (avatar != null) ...[avatar!, const SizedBox(width: 6)],
          if (icon != null) ...[
            IconTheme.merge(
              data: IconThemeData(size: 16, color: fg),
              child: icon!,
            ),
            const SizedBox(width: 6),
          ],
          DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: dense ? NasTokens.fontCaption : NasTokens.fontBody,
              color: fg,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
            child: label,
          ),
        ],
      ),
    );

    if (tooltip != null) {
      content = Tooltip(message: tooltip!, child: content);
    }

    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        borderRadius: BorderRadius.circular(999),
        child: content,
      ),
    );
  }
}
