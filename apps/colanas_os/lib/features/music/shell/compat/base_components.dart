/// 音乐模块用到的几个通用视觉组件（网络图片、玻璃卡片、按钮等）。
///
/// 统一使用 Material 3 主题与项目色板，构造参数保持简洁，页面按需组合。
library;

import 'package:flutter/material.dart';

import '../../../../core/session.dart';
import 'cola_custom_colors.dart';

/// 网络图片：带鉴权头 + 加载占位 + 圆角（替代 extended_image 版）
class CustomExtendedImage extends StatelessWidget {
  const CustomExtendedImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.errorBuilder,
    this.width,
    this.height,
    this.borderRadius = 4.0,
    this.showLoading = true,
  });

  final String imageUrl;
  final BoxFit fit;
  final Alignment alignment;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;
  final double? width;
  final double? height;
  final double borderRadius;
  final bool showLoading;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (imageUrl.isEmpty) {
      child =
          errorBuilder?.call(context, 'empty', null) ??
          const ColoredBox(
            color: Colors.black12,
            child: Center(child: Icon(Icons.music_note, size: 20)),
          );
    } else {
      child = Image.network(
        imageUrl,
        fit: fit,
        alignment: alignment,
        width: width,
        height: height,
        headers: ApiSession.instance.authHeaders,
        errorBuilder: (c, e, s) =>
            errorBuilder?.call(c, e, s) ??
            const ColoredBox(
              color: Colors.black12,
              child: Center(child: Icon(Icons.broken_image_outlined, size: 20)),
            ),
        loadingBuilder: (c, w, progress) {
          if (progress == null) return w;
          // 列表调用点都传 showLoading:false；以前直接 return w（空白），
          // 网络封面还没回来时整屏就是一片灰方块。给个中性占位。
          if (!showLoading) {
            return ColoredBox(
              color: Colors.black12,
              child: Center(
                child: Icon(
                  Icons.music_note,
                  size: 20,
                  color: Theme.of(c).colorScheme.onSurface
                      .withValues(alpha: 0.38),
                ),
              ),
            );
          }
          return const ColoredBox(
            color: Colors.black12,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        },
      );
    }
    if (borderRadius <= 0) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }
}

/// 扁平卡片：纯色 + 0.5px 细边框，无阴影（Windows 风格）
class CustomGlassCard extends StatelessWidget {
  const CustomGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin,
    this.border,
    this.borderRadius = 4.0,
    this.blur = 0.0,
    this.opacity = 1.0,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BoxBorder? border;
  final double borderRadius;

  /// 兼容旧调用点，扁平卡片不做模糊
  final double blur;

  /// 兼容旧调用点，始终不透明
  final double opacity;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final custom = theme.extension<CustomColors>();
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(borderRadius),
        border:
            border ??
            Border.all(
              color: custom?.hairlineBorderColor ?? const Color(0x1F000000),
              width: 0.5,
            ),
      ),
      // 卡片里会直接放 ListTile / SwitchListTile：水波纹画在**最近的 Material** 上，
      // 这层背景会把它盖住（debug 下抛「ListTile background color or ink splashes
      // may be invisible」）。补一层透明 Material，让涟漪落在卡片内部、背景之上。
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (onTap == null) return box;
    return InkWell(
      borderRadius: BorderRadius.circular(borderRadius),
      onTap: onTap,
      child: box,
    );
  }
}

/// 带边框的图标按钮（hover 变底色，disabled 置灰）
class CustomBorderedIconButton extends StatefulWidget {
  const CustomBorderedIconButton({
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
  State<CustomBorderedIconButton> createState() =>
      _CustomBorderedIconButtonState();
}

class _CustomBorderedIconButtonState extends State<CustomBorderedIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = widget.enabled && widget.onTap != null;
    final fg = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : widget.active
        ? scheme.primary
        : (widget.iconColor ?? scheme.onSurfaceVariant);
    final bg = widget.active
        ? scheme.primary.withValues(alpha: 0.12)
        : _hovered && enabled
        ? (widget.hoverColor ?? scheme.onSurface.withValues(alpha: 0.06))
        : (widget.backgroundColor ?? Colors.transparent);

    final button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          onTap: enabled ? widget.onTap : null,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color:
                    widget.borderColor ??
                    scheme.outlineVariant.withValues(alpha: 0.6),
                width: 0.5,
              ),
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
    if (widget.tooltip == null || widget.tooltip!.isEmpty) return button;
    return Tooltip(message: widget.tooltip!, child: button);
  }
}

/// 图标按钮（可带底色 / 边框）
class CustomIconButton extends StatelessWidget {
  const CustomIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.iconColor,
    this.backgroundColor,
    this.iconSize = 20,
    this.buttonSize = 40,
    this.borderRadius = 8,
    this.tooltip,
    this.borderSide,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? iconColor;
  final Color? backgroundColor;
  final double iconSize;
  final double buttonSize;
  final double borderRadius;
  final String? tooltip;
  final BorderSide? borderSide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = Material(
      color: backgroundColor ?? Colors.transparent,
      borderRadius: BorderRadius.circular(borderRadius),
      shape: borderSide == null
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(borderRadius),
              side: borderSide!,
            ),
      child: InkWell(
        borderRadius: BorderRadius.circular(borderRadius),
        onTap: onPressed,
        child: SizedBox(
          width: buttonSize,
          height: buttonSize,
          child: Icon(
            icon,
            size: iconSize,
            color: onPressed == null
                ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
                : (iconColor ?? theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 主/次按钮
class CustomButton extends StatelessWidget {
  const CustomButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.style,
    this.isPrimary = true,
    this.isDisabled = false,
    this.width,
    this.height,
    this.icon,
  });

  final String text;
  final VoidCallback? onPressed;
  final ButtonStyle? style;
  final bool isPrimary;
  final bool isDisabled;
  final double? width;
  final double? height;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final cb = isDisabled ? null : onPressed;
    final child = icon == null
        ? Text(text)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [icon!, const SizedBox(width: 6), Text(text)],
          );
    final button = isPrimary
        ? FilledButton(onPressed: cb, style: style, child: child)
        : OutlinedButton(onPressed: cb, style: style, child: child);
    if (width == null && height == null) return button;
    return SizedBox(width: width, height: height, child: button);
  }
}

/// 描边按钮（compact 小号）
class CustomOutlinedButton extends StatelessWidget {
  const CustomOutlinedButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.icon,
    this.foregroundColor,
    this.borderColor,
    this.compact = true,
  });

  final String text;
  final VoidCallback? onPressed;
  final Widget? icon;
  final Color? foregroundColor;
  final Color? borderColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fc = foregroundColor ?? theme.colorScheme.primary;
    final bc = borderColor ?? theme.colorScheme.primary;
    final style = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      foregroundColor: fc,
      side: BorderSide(color: bc),
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    );
    return icon != null
        ? OutlinedButton.icon(
            icon: icon!,
            label: Text(text),
            onPressed: onPressed,
            style: style,
          )
        : OutlinedButton(onPressed: onPressed, style: style, child: Text(text));
  }
}
