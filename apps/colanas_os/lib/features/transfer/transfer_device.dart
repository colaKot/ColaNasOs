import 'package:nas_core/nas_core.dart';

import '../../core/endpoint_host.dart';
import 'transfer_device_io.dart'
    if (dart.library.js_interop) 'transfer_device_web.dart'
    as dev;

/// 传输面板上「谁传的」那一列的设备名。
///
/// 服务端只知道 uid 与自报的端标识；能让人一眼认出来源的是设备名。
/// 桌面取主机名（同一账号两台电脑才分得清），移动端取系统名 —— Android 的
/// `localHostname` 常年是 "localhost"，没有区分度，不如直接写平台名。
String get transferDeviceName => dev.detectTransferDeviceName();

/// 传输会话的来源端，与服务端 `transfer_sessions.origin` 对齐。
///
/// 用枚举名而不是自己 switch：`capability_matrix` 里的端清单是契约生成的，
/// 写死一份 switch 会在加端时悄悄漏掉新成员。
String get transferOrigin => switch (EndpointHost.endpoint) {
  CapabilityEndpoint.tvAndroid => 'tv',
  final other => other.name,
};
