/// Web 端的离线缓存占位：浏览器没有稳定可写的本地目录，
/// 这里一律返回「不支持」，界面据此隐藏入口（而不是给一个点了没反应的按钮）。
class MusicCache {
  MusicCache._();

  static final MusicCache instance = MusicCache._();

  bool get supported => false;

  Future<void> ensureIndexed() async {}

  bool has(String trackId) => false;

  String? pathOf(String trackId) => null;

  Future<int> totalBytes() async => 0;

  Future<void> clear() async {}

  Future<String> download({
    required String trackId,
    required String url,
    required Map<String, String> headers,
    String ext = 'bin',
  }) async {
    throw UnsupportedError('web 端不支持离线缓存');
  }

  Future<void> remove(String trackId) async {}
}
