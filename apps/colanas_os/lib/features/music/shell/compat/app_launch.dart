/// 既有实现 `core/bootstrap/app_launch.dart` 的最小等价实现。
///
/// 兼容基线能「以音乐模式单独启动」（`AppLaunchMode.music`），用来隐藏
/// 侧边栏只留播放器。本项目是统一桌面壳，永远走 full 模式。
library;

enum AppLaunchMode { full, music, files }

class AppLaunch {
  const AppLaunch._();

  /// 永远 full：本项目没有单模块启动模式
  static AppLaunchMode get mode => AppLaunchMode.full;
}
