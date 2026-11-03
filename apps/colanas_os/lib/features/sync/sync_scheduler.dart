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

  Future<void> setEnabled(bool value) async {
    await SettingsStore.instance.setBool(_autoKey, value);
    // 关掉定时同步不销毁按需监听：realtime 是每任务的独立开关
    if (value) start();
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

  Future<void> _tick() async {
    if (_busy || !ApiSession.instance.authed) return;
    if (!SyncEngine.instance.fs.canSync) return;
    _busy = true;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final res = await ApiSession.instance.client.syncTaskList();
      final raw = (res['items'] as List?) ?? const [];
      final tasks = raw
          .whereType<Map>()
          .map((e) => SyncTask.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      // 按需同步始终生效（每任务的 realtime 开关），与本机自动同步总开关无关
      _watch.sync(tasks);
      if (!enabled) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final task in tasks) {
        // 只跑本机创建的任务：别的设备的目录/基线不该被这台机器动
        if (task.deviceId.isNotEmpty && task.deviceId != _deviceId) continue;
        if (SyncEngine.instance.isRunning(task.id)) continue;
        // 每任务间隔：0 = 仅手动（参考实现语义）
        final minutes = task.syncConfig.intervalMinutes;
        if (minutes <= 0) continue;
        final gap = minutes * 60 * 1000;
        if (task.lastRunAt != null && now - task.lastRunAt! < gap) continue;
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
