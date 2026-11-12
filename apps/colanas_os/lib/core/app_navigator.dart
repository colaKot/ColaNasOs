import 'package:flutter/widgets.dart';

/// 全局 Navigator key。
///
/// 为什么需要：音乐壳里有一批 GetX controller 要在「没有 context」的情况下弹
/// 对话框（最典型的是「批量加入歌单」——工具条在 `ColaMusicMultiSelect`
/// 里只拿到 controller，拿不到 BuildContext）。项目用的是 `MaterialApp` 而不是
/// `GetMaterialApp`，所以 `Get.context` 恒为 null，那些入口会**静默失败**：
/// 点了没反应、也不报错。
///
/// 挂在 `ColaNasApp` 的 `MaterialApp(navigatorKey:)` 上，任何地方都能通过
/// [appNavigatorContext] 拿到一个可用的 context。
final GlobalKey<NavigatorState> kAppNavigatorKey = GlobalKey<NavigatorState>();

/// 当前可用的根 context（App 还没挂载时是 null）。
///
/// 优先用 `overlay.context`：`navigatorKey.currentContext` 是 **Navigator 自己**
/// 的 context，`showDialog` 内部要 `Navigator.of(context)` 往上找，从它自己开始
/// 找会跳过自身、拿到外层（很多时候就是 null）。overlay 的 context 才是安全锚点。
BuildContext? get appNavigatorContext =>
    kAppNavigatorKey.currentState?.overlay?.context ??
    kAppNavigatorKey.currentContext;
