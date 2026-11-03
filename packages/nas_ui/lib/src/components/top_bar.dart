import 'package:flutter/material.dart';

import '../style.dart';
import '../tokens.dart';
import 'panel.dart';

/// 桌面顶栏：左侧标题/副标题，中间搜索（可选），右侧动作按钮。
///
/// 与侧栏、内容区一起构成「三栏」外壳；窄屏时由调用方换成 AppBar。
class NasTopBar extends StatelessWidget {
  const NasTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.search,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? search;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = context.nasStyle;

    return NasPanel(
      radius: spec.radius * 0.75,
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceLg,
        vertical: NasTokens.spaceSm + 2,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: NasTokens.spaceSm)
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NasTokens.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (search != null) ...[
              const SizedBox(width: NasTokens.spaceMd),
              Flexible(
                  flex: 2,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: search!)),
            ],
            const SizedBox(width: NasTokens.spaceMd),
            for (final action in actions) ...[
              action,
              const SizedBox(width: NasTokens.spaceXs)
            ],
          ],
        ),
      ),
    );
  }
}

/// 顶栏搜索框：玻璃/卡片一致的圆角输入框，`onChanged` 为空时只做展示入口。
class NasSearchBox extends StatelessWidget {
  const NasSearchBox(
      {super.key,
      this.hintText,
      this.onChanged,
      this.onSubmitted,
      this.controller,
      this.autofocus = false});

  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextEditingController? controller;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = context.nasStyle;

    return SizedBox(
      height: 38,
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: TextStyle(fontSize: NasTokens.fontBody, color: scheme.onSurface),
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          hintStyle: TextStyle(
              fontSize: NasTokens.fontBody, color: scheme.onSurfaceVariant),
          prefixIcon: Icon(Icons.search,
              size: NasTokens.iconMd, color: scheme.onSurfaceVariant),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 38, minHeight: 38),
          filled: true,
          fillColor: scheme.onSurface.withValues(alpha: 0.05),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: NasTokens.spaceSm),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(spec.radius * 0.6),
            borderSide: BorderSide(color: spec.panelBorderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(spec.radius * 0.6),
            borderSide: BorderSide(color: spec.panelBorderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(spec.radius * 0.6),
            borderSide:
                BorderSide(color: scheme.primary.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }
}

/// 顶栏右侧的圆角图标按钮（悬停有底）。
class NasIconAction extends StatelessWidget {
  const NasIconAction(
      {super.key, required this.icon, required this.onPressed, this.tooltip});

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = context.nasStyle;

    final button = NasHoverBuilder(
      onTap: onPressed,
      builder: (hovered) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: hovered
              ? scheme.onSurface.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(spec.radius * 0.5),
        ),
        child:
            Icon(icon, size: NasTokens.iconMd, color: scheme.onSurfaceVariant),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
