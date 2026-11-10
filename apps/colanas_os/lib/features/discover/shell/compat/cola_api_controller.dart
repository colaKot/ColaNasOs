import '../../../../core/session.dart';

/// 参考源码里 `_proxiedImage()` 用 `ApiController.instance.baseUrl` 拼图片代理地址。
/// 这里桥接到本项目全局会话，避免引入 参考实现 那套独立的 ApiController。
class ApiController {
  ApiController._();

  static final ApiController instance = ApiController._();

  String get baseUrl => ApiSession.instance.baseUrl;
}

/// 本项目图片代理需要 Bearer token（参考实现的图片接口是白名单、不需要）。
/// `discover_view.dart` 里的 `Image.network` 统一加这个 headers。
Map<String, String> get compatAuthHeaders => ApiSession.instance.authHeaders;
