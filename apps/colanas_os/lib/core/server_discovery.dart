/// 服务端地址自动匹配：换端口 / 找局域网设备。
///
/// Web 端没有 dart:io，走 `server_discovery_web.dart` 的空实现；
/// 原生端（桌面 / Android）走 `server_discovery_io.dart`，真探测 `/health`。
library;

export 'server_discovery_web.dart'
    if (dart.library.io) 'server_discovery_io.dart';
