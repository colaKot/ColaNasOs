import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

/// 全站右键/长按菜单的统一入口。
///
/// 只封装 flutter_context_menu 本身的构造，不接管浏览器原生菜单：Web 壳里
/// 输入框、文本选择仍需系统自带的复制粘贴菜单。
class ContextMenuUtil {
  const ContextMenuUtil._();

  static const EdgeInsets _defaultPadding = EdgeInsets.all(8.0);

  /// Web 端无需额外初始化，保留空实现给启动流程调用。
  static void init() {}

  /// 构造菜单；`position` 为空时由 [ContextMenuRegion] 自行计算弹出点。
  static ContextMenu _menu({
    required List<ContextMenuEntry> entries,
    Offset? position,
    EdgeInsets padding = _defaultPadding,
    BoxDecoration? boxDecoration,
  }) {
    return ContextMenu(
      entries: entries,
      position: position,
      padding: padding,
      boxDecoration: boxDecoration,
    );
  }

  /// 在屏幕坐标处弹出并返回选中值；未选择时返回 null。
  static Future<dynamic> showAtPosition(
    BuildContext context, {
    required List<ContextMenuEntry> entries,
    required Offset position,
    ValueChanged<dynamic>? onItemSelected,
  }) async {
    final selection = await _menu(
      entries: entries,
      position: position,
    ).show(context);
    if (selection == null) return null;
    onItemSelected?.call(selection);
    return selection;
  }

  /// 把 child 包成可右键/长按的热区。
  static Widget region({
    required Widget child,
    required List<ContextMenuEntry> entries,
    ValueChanged<dynamic>? onItemSelected,
  }) {
    return ContextMenuRegion(
      contextMenu: _menu(entries: entries),
      onItemSelected: onItemSelected,
      child: child,
    );
  }
}
