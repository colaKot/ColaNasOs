import 'sync_autostart.dart';

/// 无法判定平台时（既无 dart:io 也无 dart:html）：一律不支持。
class StubSyncAutoStart implements SyncAutoStart {
  const StubSyncAutoStart();

  @override
  bool get supported => false;

  @override
  String get unsupportedReasonKey => 'sync.autostart.unsupported';

  @override
  bool get enabled => false;

  @override
  String get targetPath => '';

  @override
  Future<bool> setEnabled(bool value) async => false;
}

SyncAutoStart createPlatformSyncAutoStart() => const StubSyncAutoStart();
