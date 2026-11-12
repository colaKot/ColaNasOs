/// Web 端音乐资源地址解析。
///
/// Web 直接播服务端 `/api/v1/music/stream`（已支持 Range）；原生端统一走
/// media_kit。因此这里不需要本地静态服务，`acquire()` 只返回服务端地址。
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
