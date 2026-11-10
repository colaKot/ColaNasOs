/// 参考实现 `core/routes/cola_app_routes.dart` 的最小等价实现。
///
/// 参考页「文件视图」和「回到首页」都走 GetX 命名路由；本项目用 Navigator + 顶层壳，
/// 这里给两个回调，由音乐模块装配处注入实际跳转。
library;

class AppRoutes {
  const AppRoutes._();

  /// 由外层注入：跳到本项目的文件视图，落在 `initialPath`（为空则根目录）
  static void Function(String? initialPath)? toFilesHandler;

  /// 由外层注入：回到桌面首页
  static void Function()? toHomeHandler;

  static void toFiles({String? initialPath}) =>
      toFilesHandler?.call(initialPath);

  static void toHome() => toHomeHandler?.call();
}
