import '../../compat/api_base.dart';
import '../../compat/getx.dart';
import '../models/music_detail_models.dart';

/// 专辑 / 歌手详情与 Last.fm 配置的接口封装。
///
/// 路径使用兼容接口形状（`/api/music/...`），由 `compat/api_ns.dart` 统一
/// 翻译成 `/api/v1/music/compat/...` —— 与音乐模块其它 service 保持一致。
class MusicDetailApiService extends BaseApiService {
  static const String _albumDetail = '/api/music/album/detail';
  static const String _artistDetail = '/api/music/artist/detail';
  static const String _lastfmConfig = '/api/music/lastfm/config';
  static const String _lastfmTest = '/api/music/lastfm/test';
  static const String _lastfmClear = '/api/music/lastfm/cache/clear';
  static const String _lastfmLinkStart = '/api/music/lastfm/link/start';
  static const String _lastfmLinkComplete = '/api/music/lastfm/link/complete';
  static const String _lastfmUnlink = '/api/music/lastfm/link/unlink';
  static const String _lastfmScrobble = '/api/music/lastfm/scrobble';

  static MusicDetailApiService get instance =>
      Get.isRegistered<MusicDetailApiService>()
      ? Get.find<MusicDetailApiService>()
      : MusicDetailApiService();

  Future<AlbumDetailInfo> albumDetail({
    required String name,
    String? artist,
  }) async {
    final res = await apiPost<Map<String, dynamic>>(
      _albumDetail,
      body: <String, dynamic>{
        'name': name,
        if ((artist ?? '').trim().isNotEmpty) 'artist': artist!.trim(),
      },
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    if (data == null) return const AlbumDetailInfo.empty();
    return AlbumDetailInfo.fromJson(data);
  }

  Future<ArtistDetailInfo> artistDetail({required String name}) async {
    final res = await apiPost<Map<String, dynamic>>(
      _artistDetail,
      body: <String, dynamic>{'name': name},
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    if (data == null) return const ArtistDetailInfo.empty();
    return ArtistDetailInfo.fromJson(data);
  }

  Future<LastfmConfig> lastfmConfig() async {
    final res = await apiGet<Map<String, dynamic>>(
      _lastfmConfig,
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    if (data == null) {
      return const LastfmConfig(configured: false, apiKeyMasked: '');
    }
    return LastfmConfig.fromJson(data);
  }

  /// 保存 Key / Secret（两者都传则一起改；只传一个时另一个保持原样）
  Future<LastfmConfig> saveLastfmCreds({
    String? apiKey,
    String? apiSecret,
  }) async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmConfig,
      body: <String, dynamic>{
        if (apiKey != null) 'api_key': apiKey.trim(),
        if (apiSecret != null) 'api_secret': apiSecret.trim(),
      },
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    if (data == null) {
      return const LastfmConfig(configured: false, apiKeyMasked: '');
    }
    return LastfmConfig.fromJson(data);
  }

  /// 发起绑定：拿到 Last.fm 授权页地址 + 本次的临时 token
  ///
  /// token 要留着：Last.fm 的授权页在没配 Callback URL 时**不会跳回**
  /// （只显示「可以关闭浏览器了」），这时得靠客户端拿 token 调 [lastfmComplete]。
  Future<({String url, String token})> lastfmLinkStart() async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmLinkStart,
      body: const <String, dynamic>{},
      showLoading: true,
    );
    final data = res.success ? res.data : null;
    if (data == null || data['ok'] == false) {
      return (url: '', token: '');
    }
    return (
      url: (data['url'] as String?)?.trim() ?? '',
      token: (data['token'] as String?)?.trim() ?? '',
    );
  }

  /// 恢复绑定：服务端 pending token 还在就直接换 session。
  ///
  /// 页面刷新 / 换网络 / 换域名之后，客户端内存里的 token 就没了，
  /// 但「用户在 Last.fm 点过授权」这件事服务端是知道的 —— 由它补完成。
  Future<bool> lastfmResume() async {
    final res = await apiPost<Map<String, dynamic>>(
      '/api/music/lastfm/link/resume',
      body: const <String, dynamic>{},
      showLoading: false,
    );
    return res.success && (res.data?['linked'] == true);
  }

  /// 授权完成后由客户端主动换 session（不依赖浏览器回调）
  Future<LastfmLinkResult> lastfmComplete(String token) async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmLinkComplete,
      body: <String, dynamic>{'token': token},
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    if (data == null) {
      return const LastfmLinkResult(ok: false, message: 'network');
    }
    return LastfmLinkResult.fromJson(data);
  }

  Future<bool> lastfmUnlink() async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmUnlink,
      body: const <String, dynamic>{},
      showLoading: false,
    );
    return res.success;
  }

  /// 播放上报（阈值判断在客户端：满 30s 且超过总时长一半）
  Future<bool> scrobble({
    required String artist,
    required String track,
    String? album,
    required int timestamp,
    int? durationSec,
  }) async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmScrobble,
      body: <String, dynamic>{
        'artist': artist,
        'track': track,
        if ((album ?? '').trim().isNotEmpty) 'album': album!.trim(),
        'timestamp': timestamp,
        if ((durationSec ?? 0) > 0) 'duration': durationSec,
      },
      showLoading: false,
    );
    return res.success && (res.data?['ok'] == true);
  }

  Future<LastfmTestResult> testLastfm() async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmTest,
      body: const <String, dynamic>{},
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    if (data == null) {
      return const LastfmTestResult(
        ok: false,
        message: '',
        samples: <String>[],
      );
    }
    return LastfmTestResult.fromJson(data);
  }

  Future<int> clearCache() async {
    final res = await apiPost<Map<String, dynamic>>(
      _lastfmClear,
      body: const <String, dynamic>{},
      showLoading: false,
    );
    final data = res.success ? res.data : null;
    return data?['removed'] is num ? (data!['removed'] as num).toInt() : 0;
  }
}
