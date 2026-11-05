import 'package:flutter/foundation.dart';

/// 桌面顶栏「返回上一层」的注册表。
///
/// 三级 / 四级页面有两种形态：`Navigator.push` 出来的整页自带 AppBar（顶栏被遮住），
/// 而「在模块内下钻」的页面（如相册·人脸点进某个簇）仍留在三栏外壳里，没有自己的返回入口。
/// 这些页面把「回上一层」的闭包注册到这里，顶栏据此显示返回按钮；按当前 App 取，
/// 切到别的模块时不会误弹上一个模块的层级。
class ShellBack {
  ShellBack._();

  static final Map<String, VoidCallback> _handlers = <String, VoidCallback>{};

  /// 顶栏监听它重建：注册 / 注销后返回按钮的显隐立即生效。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void register(String appId, VoidCallback onBack) {
    _handlers[appId] = onBack;
    revision.value += 1;
  }

  static void unregister(String appId, VoidCallback onBack) {
    if (_handlers[appId] != onBack) return;
    _handlers.remove(appId);
    revision.value += 1;
  }

  static VoidCallback? handlerFor(String appId) => _handlers[appId];
}
