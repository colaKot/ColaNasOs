import 'desktop_tray_stub.dart'
    if (dart.library.io) 'desktop_tray_io.dart';

/// 桌面端系统托盘（Windows / macOS / Linux）。
///
/// 只在 Flutter 桌面端生效：点关闭按钮缩到托盘常驻，点托盘图标或菜单恢复窗口。
/// Web 端与 Electron 外壳由各自宿主提供托盘（`electron/main.ts` 已有），这里不重复。
abstract class DesktopTray {
  /// 当前平台是否支持托盘（Web 一律 false）
  bool get supported;

  /// 初始化托盘；失败时降级为普通关闭，不阻塞启动
  Future<void> init();

  Future<void> dispose();
}

/// 全局单例：插件监听器必须保持强引用，否则会被 GC 掉
final DesktopTray desktopTray = createPlatformDesktopTray();