import 'package:nas_core/nas_core.dart';

import 'endpoint_host.dart';

/// 「这个 App 在当前客户端能不能看见」。
///
/// `contracts/apps.json` 里每个 App 都声明了 `endpoints`（desktop / tablet / mobile /
/// tv / web / appleTv），但生成出来的 `AppRegistry` 之前没人用它过滤 —— 等于所有端
/// 都看到全部入口。这里补上判定，导航（侧栏 / 底部栏）与工作台都走它。
///
/// 端形态的两套枚举要在这里对齐：
///   * 契约侧 `ClientEndpoint`（6 端，含 tablet）；
///   * 运行时 `CapabilityEndpoint`（按 OS 探测，没有 tablet 细分，鸿蒙是单独一端）。

/// 当前客户端在契约维度上算哪一端。
ClientEndpoint get currentClientEndpoint {
  // Electron 外壳加载的是 Flutter Web 产物，`endpoint` 会报 web；
  // 但产品语义上它是 PC 客户端（同步这类依赖本机能力的入口只在它上面出现）。
  if (EndpointHost.isPcClient) return ClientEndpoint.desktop;
  switch (EndpointHost.endpoint) {
    case CapabilityEndpoint.desktop:
      return ClientEndpoint.desktop;
    case CapabilityEndpoint.web:
      return ClientEndpoint.web;
    case CapabilityEndpoint.tvAndroid:
    case CapabilityEndpoint.tvApple:
      return ClientEndpoint.tv;
    case CapabilityEndpoint.mobile:
    case CapabilityEndpoint.harmony:
      // 运行时判不出平板，手机端顺带认 tablet 声明，避免 tablet-only 的 App 在平板上消失
      return ClientEndpoint.mobile;
  }
}

/// 契约里的 `endpoints` 是否包含当前端。
bool appVisibleOnThisClient(AppDescriptor app) {
  final here = currentClientEndpoint;
  if (app.supports(here)) return true;
  // 手机 / 平板在运行时是同一端，声明 tablet 的 App 也给手机看
  return here == ClientEndpoint.mobile && app.supports(ClientEndpoint.tablet);
}

/// 过滤一批入口。
List<AppDescriptor> visibleAppsOnThisClient(Iterable<AppDescriptor> apps) =>
    apps.where(appVisibleOnThisClient).toList(growable: false);

/// 是否是「手机 App」（原生 Android / iOS 构建）。
///
/// 注意与「手机浏览器」的区别：web 端 `EndpointHost.endpoint` 是 `web`，
/// 哪怕是在手机上打开。相册备份这类依赖本机相册权限的功能只该出现在 App 里。
bool isMobileApp() => EndpointHost.endpoint == CapabilityEndpoint.mobile;
