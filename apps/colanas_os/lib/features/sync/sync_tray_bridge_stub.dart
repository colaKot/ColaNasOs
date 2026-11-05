import 'sync_tray_bridge.dart';

/// 非 Web 平台：托盘由 `tray_manager`（`shell/desktop_tray_io.dart`）或宿主
/// 自己管，这里不需要桥 —— 全部空转。
class StubSyncTrayHost implements SyncTrayHost {
  @override
  bool get available => false;

  @override
  Future<void> install(SyncTrayHandlers handlers) async {}

  @override
  Future<void> publish({required bool paused, required int taskCount}) async {}
}

SyncTrayHost createPlatformSyncTrayHost() => StubSyncTrayHost();
