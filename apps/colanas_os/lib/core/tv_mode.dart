import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// TV 构建开关：`flutter build ... --dart-define=COLANAS_TV=1` 默认开启 TV 模式。
const bool kTvBuild = bool.fromEnvironment('COLANAS_TV');

/// TV 遥控器 / 手柄的确认键映射。
///
/// Flutter 默认只把 Enter / Space 映射到 `ActivateIntent`；Android TV 的
/// DPAD_CENTER、部分手柄的 A 键走的是 `select` / `gameButtonA`，这里补齐。
const Map<ShortcutActivator, Intent> kTvShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
};
