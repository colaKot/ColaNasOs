/// 启动模式声明。
///
/// 本项目是统一桌面壳，始终以 full 模式启动；音乐模块仅复用该枚举做类型约束。
library;

enum AppLaunchMode { full, music, files }

class AppLaunch {
  const AppLaunch._();

  /// 永远 full：本项目没有单模块启动模式
  static AppLaunchMode get mode => AppLaunchMode.full;
}
