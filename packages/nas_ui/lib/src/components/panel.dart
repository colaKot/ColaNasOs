import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../style.dart';
import '../tokens.dart';

/// 通用「面板」：按当前 [NasUiStyle] 取材质（半透明 + 模糊 / 纯色卡片 / 云母）。
///
/// 页面里**不要**再自己写 `Container(color: ...)` + `BackdropFilter`：
/// 材质（模糊半径、边框、阴影、圆角）全部由风格决定，换风格时整站一致。
class NasPanel extends StatelessWidget {
  const NasPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(NasTokens.spaceMd),
    this.radius,
    this.blur,
    this.color,
    this.border,
    this.shadow,
    this.margin,
    this.width,
    this.height,
    this.alignment,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 覆盖风格圆角；null = 用风格值
  final double? radius;
  final double? blur;
  final Color? color;
  final BoxBorder? border;
  final List<BoxShadow>? shadow;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final spec = context.nasStyle;
    final r = radius ?? spec.radius;
    final borderRadius = BorderRadius.circular(r);
    final sigma = blur ?? spec.panelBlur;

    final surface = Container(
      width: width,
      height: height,
      alignment: alignment,
      decoration: BoxDecoration(
        color: color ?? spec.panelColor,
        borderRadius: borderRadius,
        border: border ?? Border.all(color: spec.panelBorderColor),
      ),
      child: Padding(padding: padding, child: child),
    );

    return Container(
      margin: margin,
      width: width,
      height: height,
      decoration: BoxDecoration(
          borderRadius: borderRadius, boxShadow: shadow ?? spec.panelShadow),
      child: sigma <= 0
          ? surface
          : ClipRRect(
              borderRadius: borderRadius,
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: surface,
              ),
            ),
    );
  }
}

/// 卡片：比面板更「浮」的一层，用于工作台里的应用卡 / 统计卡。
class NasCard extends StatelessWidget {
  const NasCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(NasTokens.spaceMd),
    this.radius,
    this.color,
    this.width,
    this.height,
    this.constraints,
    this.highlight = false,
    this.focusRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double? radius;
  final Color? color;
  final double? width;
  final double? height;

  /// 尺寸约束（与 [width] / [height] 二选一）：传 `minHeight` 可让卡片随内容增高，
  /// 避免中文字体行高比 Roboto 大时撑破固定高度（debug 下表现为底部黄黑溢出条）。
  final BoxConstraints? constraints;

  /// 高亮描边（选中/重点）
  final bool highlight;

  /// 键盘 / D-pad 焦点框圆角；null = 卡片圆角
  final double? focusRadius;

  @override
  Widget build(BuildContext context) {
    final spec = context.nasStyle;
    final scheme = Theme.of(context).colorScheme;
    final r = radius ?? spec.cardRadius;
    final borderRadius = BorderRadius.circular(r);

    return _Hoverable(
      onTap: onTap,
      focusRadius: focusRadius ?? r,
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: NasTokens.durationFast),
        curve: Curves.easeOut,
        width: width,
        height: height,
        constraints: constraints,
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? spec.panelColor,
          borderRadius: borderRadius,
          border: Border.all(
            color: highlight
                ? scheme.primary.withValues(alpha: 0.55)
                : hovered
                    ? scheme.primary.withValues(alpha: 0.30)
                    : spec.panelBorderColor,
          ),
          boxShadow: hovered ? spec.cardShadow : null,
        ),
        // 卡片里经常直接放 ListTile / SwitchListTile：它们的水波纹画在**最近的
        // Material** 上，而这层 AnimatedContainer 的背景会盖住它 —— debug 下直接抛
        // 「ListTile background color or ink splashes may be invisible」。
        // 透明 Material 让涟漪落在这层（卡片内部、背景之上），视觉不变。
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

/// 悬停 / 焦点 + 点击的统一包装。
///
/// 鼠标端维持原悬停语义；键盘与 D-pad（TV 遥控器）端：
/// - `FocusableActionDetector` 让元素进入焦点链；
/// - `ActivateIntent`（Enter / Space / TV OK）直接触发 `onTap`；
/// - 焦点态画一圈主题色描边，远距离也能看清落点。
class _Hoverable extends StatefulWidget {
  const _Hoverable({
    required this.builder,
    this.onTap,
    this.focusRadius = NasTokens.radiusMd,
  });

  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;
  final double focusRadius;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final scheme = Theme.of(context).colorScheme;
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (value) {
        if (_hovered != value) setState(() => _hovered = value);
      },
      onShowFocusHighlight: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      actions: enabled
          ? <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap?.call();
                  return null;
                },
              ),
            }
          : const <Type, Action<Intent>>{},
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.builder(_hovered),
            if (_focused)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.focusRadius),
                      border: Border.all(color: scheme.primary, width: 2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 让外部也能复用同一套悬停 / 焦点语义（侧栏项、文件瓦片）。
class NasHoverBuilder extends StatelessWidget {
  const NasHoverBuilder({
    super.key,
    required this.builder,
    this.onTap,
    this.focusRadius = NasTokens.radiusMd,
  });

  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;
  final double focusRadius;

  @override
  Widget build(BuildContext context) => _Hoverable(
        builder: builder,
        onTap: onTap,
        focusRadius: focusRadius,
      );
}
