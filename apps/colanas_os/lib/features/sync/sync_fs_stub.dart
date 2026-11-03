import 'sync_fs.dart';

/// 其它平台兜底：与 Web 一致（不可用）。
class StubSyncFs implements SyncFs {
  const StubSyncFs();

  @override
  bool get canSync => false;

  @override
  Future<String> resolveDeviceId() async => 'unsupported';

  @override
  Future<String> resolveDeviceName() async => 'unsupported';

  @override
  Future<String?> pickDirectory() async => null;

  @override
  Future<List<SyncLocalEntry>> scan(
    String root, {
    List<String> include = const [],
    List<String> exclude = const [],
    SyncFilterConfig filter = const SyncFilterConfig(),
  }) async =>
      const [];

  @override
  Future<List<int>> readChunk(String path, int start, int end) async =>
      throw UnsupportedError('sync_requires_desktop');

  @override
  Future<void> download({
    required Uri uri,
    required Map<String, String> headers,
    required String localPath,
    required int mtimeMs,
    required void Function(int received) onProgress,
    required bool Function() cancelled,
  }) async =>
      throw UnsupportedError('sync_requires_desktop');

  @override
  Future<void> deleteLocal(String path) async =>
      throw UnsupportedError('sync_requires_desktop');

  @override
  Future<bool> exists(String path) async => false;
}

SyncFs createPlatformSyncFs() => const StubSyncFs();
