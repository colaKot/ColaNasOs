import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

/// 右键菜单的统一入口：桌面右键 / 长按都走这里。
///
/// 保留四个静态 API 给各页面直接调用；实现只依赖 flutter_context_menu 本身，
/// 不做 Web 端「禁用浏览器默认菜单」那套 —— 本项目 Web 壳不需要，禁了反而
/// 会挡掉输入框里的原生复制粘贴菜单。
class ContextMenuUtil {
  const ContextMenuUtil._();

  static void init() {}

  /// position 为空时交给 [ContextMenuRegion] 自己算触发点。
  static ContextMenu buildMenu({
    required List<ContextMenuEntry> entries,
    Offset? position,
    EdgeInsets padding = const EdgeInsets.all(8.0),
    BoxDecoration? boxDecoration,
  }) {
    return ContextMenu(
      entries: entries,
      position: position,
      padding: padding,
      boxDecoration: boxDecoration,
    );
  }

  /// 在指定屏幕坐标弹出，返回选中的 value；没选返回 null。
  static Future<dynamic> showAtPosition(
    BuildContext context, {
    required List<ContextMenuEntry> entries,
    required Offset position,
    ValueChanged<dynamic>? onItemSelected,
  }) async {
    final selected = await buildMenu(
      entries: entries,
      position: position,
    ).show(context);
    if (selected != null) onItemSelected?.call(selected);
    return selected;
  }

  /// 包一层右键 / 长按热区，选中值交给 [onItemSelected]。
  static Widget region({
    required Widget child,
    required List<ContextMenuEntry> entries,
    ValueChanged<dynamic>? onItemSelected,
  }) {
    return ContextMenuRegion(
      contextMenu: buildMenu(entries: entries),
      onItemSelected: onItemSelected,
      child: child,
    );
  }
}
