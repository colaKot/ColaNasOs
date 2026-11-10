/// 参考实现 `core/api/cola_api_controller.dart` 的最小等价实现。
///
/// 参考项目是「一个 ApiController 管所有 URL / token / P2P」，音乐模块只用到其中
/// 很小一部分：封面地址、原始文件地址、转码地址、token 刷新、几个能力探测开关。
/// 这里全部映射到本项目的 `ApiSession` + `/api/v1/music/*`。
library;

import '../../../../core/session.dart';

/// 能力探测开关（参考项目有 P2P / shell 支持等差异，本项目一律「支持」）
class ApiRuntimeState {
  const ApiRuntimeState();

  bool get shellSupported => true;
}

class ApiController {
  ApiController._();

  static final ApiController instance = ApiController._();

  final ApiRuntimeState state = const ApiRuntimeState();

  String get baseUrl => ApiSession.instance.baseUrl;

  String? get accessToken => ApiSession.instance.token;

  /// 本项目没有 P2P 通道
  bool get isP2pMode => false;

  /// 没有 P2P 时给一个永不匹配真实地址的前缀：
  /// 调用方用它判断 `url.startsWith(p2pBaseUrl)`，恒 false 即为「非 P2P 地址」。
  static String get p2pBaseUrl => 'p2p://colanas';

  /// 自用 NAS：客户端与服务端就是同一套账号体系，直连即可
  bool get isSameMachine => true;

  bool isServerVersionAtLeast(int _) => true;

  /// token 过期后重新登录一次。本项目 token 由 ApiSession 统一维护，
  /// 这里只需把当前 token 交回去；真过期时 ApiSession 自己有密码兜底。
  Future<bool> refreshAuthToken() async => (accessToken ?? '').isNotEmpty;

  /// 音乐封面：搬运过来的页面全程按「文件路径」取图，
  /// 走内核的兼容口 `/music/compat/cover`（内部按 rel_path 找曲目再取内嵌封面）。
  String getMusicCoverUrl({required String filePath, int size = 0}) {
    if (filePath.trim().isEmpty) return '';
    final q = <String>['path=${Uri.encodeQueryComponent(filePath)}'];
    if (size > 0) q.add('size=$size');
    return '$baseUrl/api/v1/music/compat/cover?${q.join('&')}';
  }

  /// 转码播放地址（AAC 缓存命中后直出）
  String getMusicTranscodeUrl(
    String path, {
    bool withAccessToken = false,
    String? p2pChannel,
  }) {
    final q = <String>[
      'path=${Uri.encodeQueryComponent(path)}',
      'format=transcoded',
      if (withAccessToken && (accessToken ?? '').isNotEmpty)
        'token=${Uri.encodeQueryComponent(accessToken!)}',
    ];
    return '$baseUrl/api/v1/music/compat/stream?${q.join('&')}';
  }

  /// 原始文件地址（Web 端缓存/P2P 兜底用）
  String getRawFileUrl(
    String path, {
    bool withAccessToken = false,
    bool isRawFile = false,
    String? p2pChannel,
  }) {
    final q = <String>[
      'path=${Uri.encodeQueryComponent(path)}',
      if (withAccessToken && (accessToken ?? '').isNotEmpty)
        'token=${Uri.encodeQueryComponent(accessToken!)}',
    ];
    return '$baseUrl/api/v1/music/compat/stream?${q.join('&')}';
  }

  /// 本项目没有 P2P：调用即报错，调用方只在 `isP2pMode` 为真时才走这里
  Future<Never> sendP2pRequest(Object _) =>
      Future<Never>.error(UnsupportedError('P2P not supported'));
}
