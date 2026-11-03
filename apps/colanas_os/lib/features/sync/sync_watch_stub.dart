import 'sync_engine.dart';
import 'sync_watch.dart';

/// Web / 其它平台：没有本地目录监听能力，按需同步退化为定时同步。
class StubSyncWatcher implements SyncWatcher {
  const StubSyncWatcher();

  @override
  void sync(List<SyncTask> tasks) {}

  @override
  void stop() {}
}

SyncWatcher createPlatformSyncWatcher() => const StubSyncWatcher();