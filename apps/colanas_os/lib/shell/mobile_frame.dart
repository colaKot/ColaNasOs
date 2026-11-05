import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'app_nav_shell.dart';

/// 单页模块（没有二级菜单的那些）的统一顶栏。
///
/// - **手机（< 600）**：56 顶栏，左上角房子（回工作台），标题 + 动作；
/// - **桌面**：原来的 `AppBar`，标题与动作一模一样 —— 桌面样式零变化。
///
/// 为什么要这个函数：`files / share / monitor / transfer / notes / mount / book /
/// accounts / settings` 这些页面各自写了 `AppBar`，手机上它们没有房子，
/// 进了 App 就只能靠系统返回。一页页手写会漂移，收敛成一个函数只改一行。
PreferredSizeWidget nasPageAppBar(
  BuildContext context, {
  required String title,
  List<Widget> actions = const <Widget>[],
  PreferredSizeWidget? bottom,
}) {
  if (layoutFor(MediaQuery.sizeOf(context).width) == LayoutMode.compact) {
    return NasMobileAppBar(
      title: title,
      onHome: AppNavShell.onExitToHome,
      homeTooltip: tr('nav.home'),
      actions: actions,
      bottom: bottom,
    );
  }
  return AppBar(title: Text(title), actions: actions, bottom: bottom);
}

/// 当前是否手机宽度。页面里要分支渲染时用它，避免各处重复算。
bool isCompactWidth(BuildContext context) =>
    layoutFor(MediaQuery.sizeOf(context).width) == LayoutMode.compact;
