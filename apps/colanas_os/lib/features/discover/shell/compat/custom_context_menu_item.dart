import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

/// 发现 / 音乐等模块共用的右键菜单项构造器。
///
/// 菜单行高由图标撑起，纯文字标签会显得偏上；这里把文字下移 3px 与图标中线
/// 对齐。间距只在这一处定义，改一处所有菜单一起生效。
class CustomContextMenuItem {
  const CustomContextMenuItem._();

  /// [value] 原样作为选中回调的返回值；[onSelected] 为空时菜单项仍可点击。
  static MenuItem create({
    required Widget label,
    required String value,
    required void Function(dynamic)? onSelected,
    Widget? icon,
    Color? color,
  }) {
    final alignedLabel = Padding(
      padding: const EdgeInsets.only(top: 3),
      child: label,
    );
    return MenuItem(
      label: alignedLabel,
      icon: icon,
      textColor: color,
      value: value,
      onSelected: onSelected,
    );
  }
}
