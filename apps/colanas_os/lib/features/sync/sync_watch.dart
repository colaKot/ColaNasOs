import 'sync_watch_stub.dart'
    if (dart.library.io) 'sync_watch_io.dart'
    if (dart.library.html) 'sync_watch_stub.dart';

import 'sync_engine.dart';

/// 按需同步（每任务 `realtime`）的目录监听器。
///
/// Web / 非桌面端没有本地目录监听能力，实现为 no-op；
/// 桌面端在调度器每次 tick 时同步监听集合（见 `sync_watch_io.dart`）。
abstract class SyncWatcher {
  /// 用最新的任务列表刷新监听集合（只监听 `syncConfig.realtime` 为真的任务）
  void sync(List<SyncTask> tasks);

  void stop();
}

SyncWatcher createSyncWatcher() => createPlatformSyncWatcher();