import 'sync_autostart.dart';

/// Web 端没有「开机自启」概念：一律不支持，UI 只展示原因。
class WebSyncAutoStart implements SyncAutoStart {
  const WebSyncAutoStart();

  @override
  bool get supported => false;

  @override
  String get unsupportedReasonKey => 'sync.autostart.web';

  @override
  bool get enabled => false;

  @override
  String get targetPath => '';

  @override
  Future<bool> setEnabled(bool value) async => false;
}

SyncAutoStart createPlatformSyncAutoStart() => const WebSyncAutoStart();
