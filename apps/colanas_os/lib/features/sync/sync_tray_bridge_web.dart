import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'sync_tray_bridge.dart';

/// `window.colanasSync` —— Electron 主进程注入的桥（见 `electron/preload.ts`）。
/// 纯浏览器没有这个对象。
@JS('colanasSync')
external JSObject? get _bridge;

extension type _TrayWindow(JSObject _) implements JSObject {
  external set colanasTray(JSFunction? value);
}

@JS('window')
external _TrayWindow get _window;

/// Web / Electron 端托盘桥。
///
/// 两个方向：
/// - 主进程 → 页面：托盘点击调 `window.colanasTray(action)`；
/// - 页面 → 主进程：`colanasSync.invoke({op:'trayState'})` 上报状态。
class WebSyncTrayHost implements SyncTrayHost {
  SyncTrayHandlers? _handlers;
  bool _installed = false;

  @override
  bool get available => _bridge != null;

  @override
  Future<void> install(SyncTrayHandlers handlers) async {
    _handlers = handlers;
    if (!available || _installed) return;
    _window.colanasTray = ((JSString action) {
      // 托盘点击不该阻塞主进程的 executeJavaScript
      unawaited(_dispatch(action.toDart));
    }).toJS;
    _installed = true;
  }

  Future<void> _dispatch(String action) async {
    final h = _handlers;
    if (h == null) return;
    try {
      switch (action) {
        case 'syncNow':
          await h.onSyncNow();
        case 'toggleAutoSync':
          await h.onToggleAutoSync();
        case 'openTasks':
          await h.onOpenTasks();
      }
    } catch (e) {
      // 托盘侧没有 UI 可以报错，吞掉但留在控制台（Electron 会写进 ui.log）
      // ignore: avoid_print
      print('[tray] action $action failed: $e');
    }
  }

  @override
  Future<void> publish({required bool paused, required int taskCount}) async {
    final bridge = _bridge;
    if (bridge == null) return;
    final payload = jsonEncode(<String, dynamic>{
      'op': 'trayState',
      'paused': paused,
      'taskCount': taskCount,
    });
    final promise =
        bridge.callMethod<JSPromise<JSAny?>>('invoke'.toJS, payload.toJS);
    await promise.toDart;
  }
}

SyncTrayHost createPlatformSyncTrayHost() => WebSyncTrayHost();
