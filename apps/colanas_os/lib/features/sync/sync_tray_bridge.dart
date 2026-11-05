import 'dart:async';

import 'sync_scheduler.dart';
import 'sync_tray_bridge_stub.dart'
    if (dart.library.js_interop) 'sync_tray_bridge_web.dart';

/// 托盘动作的处理函数，由 `AppShell` 注入。
class SyncTrayHandlers {
  const SyncTrayHandlers({
    required this.onSyncNow,
    required this.onToggleAutoSync,
    required this.onOpenTasks,
  });

  final Future<void> Function() onSyncNow;
  final Future<void> Function() onToggleAutoSync;
  final Future<void> Function() onOpenTasks;
}

/// 系统托盘（Electron 主进程）↔ 客户端同步状态的桥。
///
/// 为什么需要：PC 客户端的托盘在 **Electron 主进程**（`electron/main.ts`），
/// 而「自动同步开关 / 任务列表 / 跑同步」这些都在 Flutter 侧。主进程没有登录态，
/// 也不该重复实现一遍调度，所以两边这样分工：
///
/// - 主进程：画菜单、处理「显示窗口 / 开机自启 / 退出」，把同步三项的点击
///   通过 `executeJavaScript` 调 `window.colanasTray(action)` 转给页面；
/// - 客户端（本文件）：接住 action 真正干活，并把「是否暂停 / 本机任务数」
///   通过 `colanasSync.invoke({op:'trayState'})` 报回去，主进程据此重画菜单。
///
/// 纯浏览器里 `colanasSync` 不存在，[available] 为 false，一切空转。
abstract class SyncTrayHost {
  bool get available;

  Future<void> install(SyncTrayHandlers handlers);

  Future<void> publish({required bool paused, required int taskCount});
}

/// 全局单例：主进程的点击只会打到这一个桥上
final SyncTrayBridge syncTrayBridge = SyncTrayBridge();

class SyncTrayBridge {
  SyncTrayBridge({SyncTrayHost? host}) : _host = host ?? createSyncTrayHost();

  final SyncTrayHost _host;

  bool get available => _host.available;

  Future<void> install(SyncTrayHandlers handlers) => _host.install(handlers);

  /// 把当前状态同步给主进程（菜单文案 / 置灰要跟着变）。
  ///
  /// 任务数要查一次接口，所以只在状态真的可能变的时候调：启动、开关切换、
  /// 同步页刷新 —— 不要在每帧或每次菜单弹出时调。
  Future<void> refresh() async {
    if (!available) return;
    int count;
    try {
      count = await SyncScheduler.instance.localTaskCount();
    } catch (_) {
      count = 0;
    }
    await _host.publish(
      paused: !SyncScheduler.instance.enabled,
      taskCount: count,
    );
  }

  /// 自动同步开关变化后自动刷新（`SyncScheduler.setEnabled` 触发）
  void bindScheduler() {
    if (!available) return;
    SyncScheduler.addStateListener(() => unawaited(refresh()));
  }
}

/// 平台实现：Web/Electron 用 js_interop，其余平台空实现
SyncTrayHost createSyncTrayHost() => createPlatformSyncTrayHost();
