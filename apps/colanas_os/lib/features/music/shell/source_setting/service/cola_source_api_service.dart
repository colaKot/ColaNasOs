import '../../compat/api_base.dart';
import '../../compat/getx.dart';
import '../models/cola_music_source.dart';

/// 音乐来源（扫描目录）的增删改查。
///
/// 六个接口的返回体都是同一个 `{ok, ...}` 形状，差别只在路径与请求体，
/// 所以路径抽成常量、调用收口到 `_post`，避免五处重复的泛型样板。
class ColaMusicSourceApiService extends BaseApiService {
  static const String _listPath = '/api/music/source/list';
  static const String _addPath = '/api/music/source/add';
  static const String _deletePath = '/api/music/source/delete';
  static const String _scanPath = '/api/music/source/scan';
  static const String _updatePrefix = '/api/music/source/update/';
  static const String _relocatePrefix = '/api/music/source/relocate/';

  static ColaMusicSourceApiService get instance =>
      Get.isRegistered<ColaMusicSourceApiService>()
      ? Get.find<ColaMusicSourceApiService>()
      : ColaMusicSourceApiService();

  Future<List<ColaMusicSource>> listSources({bool showLoading = false}) async {
    final res = await apiPost<List<dynamic>>(
      _listPath,
      body: const <String, dynamic>{},
      showLoading: showLoading,
    );
    final raw = res.success ? res.data : null;
    if (raw == null) return const <ColaMusicSource>[];
    return <ColaMusicSource>[
      for (final entry in raw)
        if (entry is Map) ColaMusicSource.fromJson(entry.cast<String, dynamic>()),
    ];
  }

  Future<ApiResponse<Map<String, dynamic>>> addSource(
    String path, {
    bool showLoading = true,
  }) => _post(_addPath, <String, dynamic>{'path': path}, showLoading);

  /// 按 id 更新：真正要改哪些字段由 [payload] 决定
  /// （`scan_when_*` / `scan_interval*` 都是逐字段可选的）
  Future<ApiResponse<Map<String, dynamic>>> updateSource(
    int id,
    Map<String, dynamic> payload, {
    bool showLoading = false,
  }) => _post('$_updatePrefix$id', payload, showLoading);

  Future<ApiResponse<Map<String, dynamic>>> deleteSource(
    int id, {
    bool showLoading = false,
  }) => _post(_deletePath, <String, dynamic>{'id': id}, showLoading);

  Future<ApiResponse<Map<String, dynamic>>> relocateSource(
    int id,
    String newPath, {
    bool showLoading = false,
  }) => _post('$_relocatePrefix$id', <String, dynamic>{
    'new_path': newPath,
  }, showLoading);

  /// 触发扫描。传具体目录只扫该来源；传 `all` 扫全部来源。
  /// 服务端默认**入队后立刻返回**，结果由 `scan.done` 事件推送。
  Future<ApiResponse<Map<String, dynamic>>> scanSource(
    String path, {
    bool showLoading = false,
  }) => _post(_scanPath, <String, dynamic>{'path': path}, showLoading);

  Future<ApiResponse<Map<String, dynamic>>> _post(
    String path,
    Map<String, dynamic> body,
    bool showLoading,
  ) =>
      apiPost<Map<String, dynamic>>(path, body: body, showLoading: showLoading);
}
