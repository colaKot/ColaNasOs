/// 参考实现 `utils/cola_local_web_asset_server.dart` 的最小等价实现。
///
/// 参考项目在 Web 端把本地音乐文件起一个 localhost 静态服务再喂给播放器，
/// 用来给 iOS AVPlayer 补 MIME / 解容器格式。本项目：
/// - Web 端直接播服务端 `/api/v1/music/stream`（已带 Range 支持）；
/// - 原生端统一 media_kit，自己解容器。
/// 所以这里不启本地服务，`acquire()` 只把服务端地址交回去。
library;

import '../../../../core/session.dart';

class LocalWebAssetServer {
  LocalWebAssetServer._();

  static final LocalWebAssetServer instance = LocalWebAssetServer._();

  int _refs = 0;

  /// 取一个「可以喂给播放器」的基地址；配对调用 [release]。
  Future<String> acquire() async {
    _refs++;
    return ApiSession.instance.baseUrl;
  }

  Future<void> release() async {
    if (_refs > 0) _refs--;
  }

  /// 历史接口：本地文件 → 本地 url。本项目不做映射，返回 null 表示「不接管」。
  static String? urlFor(String path) => null;
}
