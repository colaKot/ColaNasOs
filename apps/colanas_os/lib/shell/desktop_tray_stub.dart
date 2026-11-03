import 'desktop_tray.dart';

/// 无法判定平台时（既无 dart:io 也无 dart:html）：不支持托盘。
class StubDesktopTray implements DesktopTray {
  const StubDesktopTray();

  @override
  bool get supported => false;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}
}

DesktopTray createPlatformDesktopTray() => const StubDesktopTray();