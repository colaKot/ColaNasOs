import 'dart:io';

import 'package:nas_core/nas_core.dart';

/// 原生端（桌面 / 移动 / 鸿蒙 / TV）判定：按操作系统 + TV 开关。
///
/// 鸿蒙走 `flutter_ohos`，Dart 的 `Platform.operatingSystem` 为 `ohos`（见 CL4-01）。
CapabilityEndpoint detectEndpoint({required bool tvMode}) {
  final os = Platform.operatingSystem;
  if (os == 'ohos') return CapabilityEndpoint.harmony;
  if (Platform.isAndroid) {
    return tvMode ? CapabilityEndpoint.tvAndroid : CapabilityEndpoint.mobile;
  }
  if (Platform.isIOS) return CapabilityEndpoint.mobile;
  return CapabilityEndpoint.desktop;
}