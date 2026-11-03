import 'package:flutter/widgets.dart';

/// TV / 大屏模式作用域。
///
/// 只影响「怎么呈现」，不做平台判断：桌面窗口、浏览器、电视盒子都可以打开，
/// 由宿主（`AppSettings.tvMode` 或 `--dart-define=COLANAS_TV=1`）决定。
class TvScope extends InheritedWidget {
  const TvScope({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvScope>()?.enabled ?? false;

  @override
  bool updateShouldNotify(TvScope oldWidget) => enabled != oldWidget.enabled;
}

/// 10-foot UI 的字号放大倍数：文字整体放大，图标 / 间距由各组件单独加宽。
const double kTvTextScale = 1.18;

/// TV 侧栏宽度（常显展开态）
const double kTvNavWidth = 168;
