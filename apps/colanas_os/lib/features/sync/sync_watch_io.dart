import 'dart:async';
import 'dart:io';

import 'sync_engine.dart';
import 'sync_watch.dart';

/// 桌面端：`Directory.watch(recursive: true)` + 2 s 去抖。
///
/// 只对 `syncConfig.realtime` 为真的任务生效；文件变化后触发一轮三向同步，
/// 同一任务运行中不重复触发（引擎自身有 `_running` 保护）。
class IoSyncWatcher implements SyncWatcher {
  final Map<String, StreamSubscription<FileSystemEvent>> _subs = {};
  final Map<String, Timer> _debounce = {};
  final Map<String, SyncTask> _tasks = {};

  @override
  void sync(List<SyncTask> tasks) {
    final wanted = <String, SyncTask>{
      for (final t in tasks)
        if (t.syncConfig.realtime && t.localDir.isNotEmpty) t.id: t,
    };
    for (final id in _subs.keys.toList()) {
      if (!wanted.containsKey(id)) _unwatch(id);
    }
    for (final task in wanted.values) {
      _tasks[task.id] = task;
      if (_subs.containsKey(task.id)) continue;
      _watch(task);
    }
  }

  void _watch(SyncTask task) {
    try {
      final dir = Directory(task.localDir);
      if (!dir.existsSync()) return;
      _subs[task.id] = dir.watch(recursive: true).listen(
        (_) => _schedule(task.id),
        onError: (_) => _unwatch(task.id),
        cancelOnError: true,
      );
    } catch (_) {
      // 目录不可读 / 平台不支持：退化为定时同步
    }
  }

  void _schedule(String id) {
    _debounce[id]?.cancel();
    _debounce[id] = Timer(const Duration(seconds: 2), () {
      final task = _tasks[id];
      if (task == null) return;
      if (SyncEngine.instance.isRunning(task.id)) return;
      SyncEngine.instance.run(task);
    });
  }

  void _unwatch(String id) {
    _subs.remove(id)?.cancel();
    _debounce.remove(id)?.cancel();
    _tasks.remove(id);
  }

  @override
  void stop() {
    for (final id in _subs.keys.toList()) {
      _unwatch(id);
    }
  }
}

SyncWatcher createPlatformSyncWatcher() => IoSyncWatcher();