import 'sync_fs.dart';

/// Web 端：浏览器没有本地目录递归扫描能力（File System Access API 覆盖不全，
/// 且同步需要长时间后台读写）。入口隐藏，引擎在运行前给出明确原因。
class WebSyncFs implements SyncFs {
  const WebSyncFs();

  @override
  bool get canSync => false;

  @override
  Future<String> resolveDeviceId() async => 'web-browser';

  @override
  Future<String> resolveDeviceName() async => 'browser';

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

SyncFs createPlatformSyncFs() => const WebSyncFs();
