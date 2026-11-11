import '../../core/session.dart';

/// 一部剧的展示信息：`series` 列（英文发布名）→ 中文剧名 + 兜底竖版海报。
class SeriesDisplay {
  const SeriesDisplay(this.name, this.posterUrl);

  final String name;
  final String? posterUrl;
}

/// 剧展示名的进程内缓存。
///
/// 服务端 `/api/v1/video/series/display` 是隐藏路由（不进契约），所以这里直接走
/// transport。只拉一次，之后所有页面同步读 [nameOf] / [posterOf]；
/// 拿不到就保持 `series` 原名，绝不能因为展示名失败把页面卡住。
class SeriesDisplayStore {
  SeriesDisplayStore._();

  static final Map<String, SeriesDisplay> _map = <String, SeriesDisplay>{};
  static bool _loading = false;
  static bool _loaded = false;

  static SeriesDisplay? of(String series) => _map[series];

  static String? nameOf(String series) => _map[series]?.name;

  static String? posterOf(String series) => _map[series]?.posterUrl;

  static Future<void> ensure() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final client = ApiSession.instance.client;
      final token = ApiSession.instance.token;
      final res = await client.transport.send(
        'GET',
        Uri.parse('${client.baseUrl}/api/v1/video/series/display'),
        headers: <String, String>{
          if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
        },
      );
      final data = res.json;
      if (data is Map && data['items'] is List) {
        for (final e in data['items'] as List) {
          if (e is! Map) continue;
          final key = '${e['name'] ?? ''}';
          if (key.isEmpty) continue;
          final shown = '${e['displayName'] ?? key}';
          _map[key] = SeriesDisplay(
            shown.isEmpty ? key : shown,
            e['posterUrl'] as String?,
          );
        }
      }
      _loaded = true;
    } catch (_) {
      // 展示层补充，失败就保持原剧名
    } finally {
      _loading = false;
    }
  }
}
