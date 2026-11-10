import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'sync_engine.dart';
import 'sync_watch.dart';

/// 后台自动同步（主客户端内置）。
///
/// 应用运行期间每分钟检查一次：到点的任务（距上次运行 ≥ 间隔）自动跑一轮。
/// 关掉应用就停——这是「内置调度」，不是独立同步端/系统服务；
/// 独立同步端（独立 exe）与开机自启仍属未做项。
class SyncScheduler {
  SyncScheduler._();

  static final SyncScheduler instance = SyncScheduler._();

  static const _autoKey = 'sync.auto';
  static const _intervalKey = 'sync.intervalMin';

  Timer? _timer;
  bool _busy = false;
  String? _deviceId;
  final _watch = createSyncWatcher();

  /// 调度是否由用户开启（默认关，避免悄悄读写磁盘）
  bool get enabled => SettingsStore.instance.getBool(_autoKey) ?? false;

  /// 间隔（分钟），默认 30
  int get intervalMin => SettingsStore.instance.getInt(_intervalKey) ?? 30;

  /// 自动同步开关变化时通知外部（托盘菜单的 label 要跟着变）
  static final List<void Function()> _stateListeners = <void Function()>[];

  static void addStateListener(void Function() fn) => _stateListeners.add(fn);

  Future<void> setEnabled(bool value) async {
    await SettingsStore.instance.setBool(_autoKey, value);
    // 关掉定时同步不销毁按需监听：realtime 是每任务的独立开关
    if (value) start();
    for (final fn in _stateListeners) {
      fn();
    }
  }

  Future<void> setIntervalMinutes(int minutes) async {
    await SettingsStore.instance.setInt(_intervalKey, minutes);
  }

  void start() {
    if (!SyncEngine.instance.fs.canSync) return;
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  /// 手动触发一次检查（UI 的「立即检查」可用）
  Future<void> tickNow() => _tick();

  /// 立即同步：忽略每任务间隔，把本机所有任务跑一轮。
  ///
  /// 托盘的「立即同步」用它 —— `_tick` 只跑到点的任务，用户主动点的时候
  /// 预期是「现在就同步」，不该被间隔挡住。跑的还是同一套 [SyncEngine.run]，
  /// 所以进度、冲突、记录都跟界面里点「同步」一致。
  Future<void> runAllNow() async {
    if (_busy || !ApiSession.instance.authed) return;
    if (!SyncEngine.instance.fs.canSync) return;
    _busy = true;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final tasks = await _loadTasks();
      for (final task in tasks) {
        // 只跑本机创建的任务：别的设备的目录/基线不该被这台机器动
        if (task.deviceId.isNotEmpty && task.deviceId != _deviceId) continue;
        if (SyncEngine.instance.isRunning(task.id)) continue;
        await SyncEngine.instance.run(task);
      }
    } catch (e) {
      debugPrint('[sync] runAllNow failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// 拉一次任务列表（托盘要用它算「本机任务数」，界面也要用）
  Future<List<SyncTask>> _loadTasks() async {
    final res = await ApiSession.instance.client.syncTaskList();
    final raw = (res['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => SyncTask.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 本机任务数：托盘的「立即同步」据此置灰（0 个任务时点了也没事可做）
  Future<int> localTaskCount() async {
    if (!ApiSession.instance.authed) return 0;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final tasks = await _loadTasks();
      return tasks
          .where((t) => t.deviceId.isEmpty || t.deviceId == _deviceId)
          .length;
    } catch (e) {
      debugPrint('[sync] localTaskCount failed: $e');
      return 0;
    }
  }

  Future<void> _tick() async {
    if (_busy || !ApiSession.instance.authed) return;
    if (!SyncEngine.instance.fs.canSync) return;
    _busy = true;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final tasks = await _loadTasks();
      // 按需同步始终生效（每任务的 realtime 开关），与本机自动同步总开关无关
      _watch.sync(tasks);
      if (!enabled) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final task in tasks) {
        // 只跑本机创建的任务：别的设备的目录/基线不该被这台机器动
        if (task.deviceId.isNotEmpty && task.deviceId != _deviceId) continue;
        if (SyncEngine.instance.isRunning(task.id)) continue;
        // 每任务间隔：0 = 仅手动（既有实现语义）
        final minutes = task.syncConfig.intervalMinutes;
        if (minutes <= 0) continue;
        final gap = minutes * 60 * 1000;
        // lastRunAt 是 Unix **秒**，跟毫秒的 now 直接相减会得出 1.7e12 的巨值 →
        // 间隔判断永远成立，等于「每分钟都同步一次」。这里统一到毫秒再比。
        final lastMs = task.lastRunAt == null ? null : task.lastRunAt! * 1000;
        if (lastMs != null && now - lastMs < gap) continue;
        await SyncEngine.instance.run(task);
      }
    } catch (e) {
      debugPrint('[sync] auto scheduler tick failed: $e');
    } finally {
      _busy = false;
    }
  }
}

/// 间隔选项（分钟）
const syncIntervalOptions = <int>[15, 30, 60, 180, 720];
