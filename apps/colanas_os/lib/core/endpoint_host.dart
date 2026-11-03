import 'package:nas_core/nas_core.dart';

import 'app_settings.dart';
import 'endpoint_host_io.dart'
    if (dart.library.js_interop) 'endpoint_host_web.dart' as host;

/// 当前端形态（端能力矩阵 `docs/04 §64` 的 6 端之一）。
///
/// UI 用 [endpoint] 决定「受限 / 不提供」提示，不再各处自行判断平台。
/// 测试用 [overrideForTest] 固定端形态（不依赖真实运行环境）。
class EndpointHost {
  EndpointHost._();

  static CapabilityEndpoint? _override;

  /// 当前端：`web` / `desktop` / `mobile` / `tvAndroid` / `harmony`。
  /// AppleTV 是原生壳（不跑 Flutter），Flutter 端不会返回 `tvApple`。
  static CapabilityEndpoint get endpoint =>
      _override ??
      host.detectEndpoint(tvMode: AppSettings.instance.tvMode.value);

  static void overrideForTest(CapabilityEndpoint? value) => _override = value;
}