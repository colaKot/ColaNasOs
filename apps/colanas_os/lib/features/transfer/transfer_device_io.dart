import 'dart:io';

/// 原生端的设备名（桌面取主机名，移动端取平台名）。
///
/// `Platform.localHostname` 在 Android 上通常就是 "localhost"，没有区分度，
/// 所以移动端直接给平台名 —— 用户看「来自 Android」比「来自 localhost」有用。
String detectTransferDeviceName() {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isMacOS) {
    final host = _hostOrEmpty();
    return host.isEmpty ? 'Mac' : host;
  }
  if (Platform.isWindows) {
    final host = _hostOrEmpty();
    return host.isEmpty ? 'Windows' : host;
  }
  if (Platform.isLinux) {
    final host = _hostOrEmpty();
    return host.isEmpty ? 'Linux' : host;
  }
  return '本机';
}

String _hostOrEmpty() {
  try {
    return Platform.localHostname.trim();
  } catch (_) {
    return '';
  }
}
