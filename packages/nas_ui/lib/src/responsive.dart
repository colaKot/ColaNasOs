import 'tokens.dart';

/// 响应式布局判定：一套逻辑，两套布局。
///
/// 业务页面只依赖 [LayoutMode]，由布局层决定具体呈现（列表 / 双栏 / 侧边栏）；
/// 禁止为不同端各写一份页面。
enum LayoutMode {
  /// 手机竖屏、TV 之外的窄屏
  compact,

  /// 平板 / 窗口化桌面
  medium,

  /// 桌面大窗、TV
  expanded,
}

/// Material 3 断点（600 / 1024）。
LayoutMode layoutFor(double width) {
  if (width.isNaN || width <= 0) return LayoutMode.compact;
  if (width < NasTokens.breakpointTablet) return LayoutMode.compact;
  if (width < NasTokens.breakpointDesktop) return LayoutMode.medium;
  return LayoutMode.expanded;
}

/// 双栏布局是否成立（列表 + 详情同屏）。
bool useTwoPane(double width) => layoutFor(width) != LayoutMode.compact;

/// 网格列数：给瀑布流 / 相册用，按宽度自适应。
int gridColumns(double width) {
  switch (layoutFor(width)) {
    case LayoutMode.compact:
      return 2;
    case LayoutMode.medium:
      return 4;
    case LayoutMode.expanded:
      return 6;
  }
}
