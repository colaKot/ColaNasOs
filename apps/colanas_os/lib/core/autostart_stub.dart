/// 非 dart:io 环境（Web / 测试）的降级实现：没有系统启动项这回事。
bool get autostartSupported => false;

Future<bool> setAutostartEnabled(bool enabled) async => false;

Future<void> syncAutostartEntry(bool enabled) async {}
