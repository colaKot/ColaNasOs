import '../../compat/api_base.dart';
import '../../compat/json_read.dart';
import '../models/cola_collection_model.dart';

/// 音乐合集的增删改查。
///
/// 五个接口的返回形状一致（成功给数据、失败给 message + code + 原始响应），
/// 以前每个方法都抄一遍「判 success → 造 failure → 造 success」。
/// 这里收口到 [_run]：只描述「请求」和「怎么把 data 变成模型」，
/// 错误透传、空对象兜底统一处理，加接口不用再复制样板。
class MusicCollectionApiService extends BaseApiService {
  static const String _listPath = '/api/music/collection/list';
  static const String _getPath = '/api/music/collection/get';
  static const String _createPath = '/api/music/collection/create';
  static const String _updatePath = '/api/music/collection/update';
  static const String _deletePath = '/api/music/collection/delete';

  Future<ApiResponse<MusicCollectionListResult>> listCollections({
    int page = 1,
    int pageSize = 20,
    String? keyword,
    String sortField = 'create_time',
    String sortOrder = 'desc',
  }) {
    final trimmed = keyword?.trim() ?? '';
    return _run(
      apiPost<Map<String, dynamic>>(
        _listPath,
        body: <String, dynamic>{
          'page': page,
          'pageSize': pageSize,
          if (trimmed.isNotEmpty) 'keyword': trimmed,
          'sortField': sortField,
          'sortOrder': sortOrder,
        },
        showLoading: false,
      ),
      MusicCollectionListResult.fromJson,
    );
  }

  Future<ApiResponse<MusicCollectionItem>> getCollection(int id) => _run(
    apiPost<Map<String, dynamic>>(
      _getPath,
      body: <String, dynamic>{'id': id},
      showLoading: false,
    ),
    MusicCollectionItem.fromJson,
  );

  /// 新建成功返回新合集的 id（失败或解析不到时是 0）
  Future<ApiResponse<int>> createCollection({
    required String name,
    required List<String> pathList,
  }) => _run(
    apiPost<Map<String, dynamic>>(
      _createPath,
      body: <String, dynamic>{'name': name, 'path_list': pathList},
      showLoading: true,
    ),
    (data) => data.readInt(const ['id']),
  );

  /// 改名 / 换目录：成功即 true，不再回传实体
  Future<ApiResponse<bool>> updateCollection({
    required int id,
    required String name,
    required List<String> pathList,
  }) => _run(
    apiPost<Map<String, dynamic>>(
      _updatePath,
      body: <String, dynamic>{'id': id, 'name': name, 'path_list': pathList},
      showLoading: true,
    ),
    (_) => true,
  );

  /// 删除成功返回受影响的行数
  Future<ApiResponse<int>> deleteCollection(int id) => _run(
    apiPost<Map<String, dynamic>>(
      _deletePath,
      body: <String, dynamic>{'id': id},
      showLoading: true,
    ),
    (data) => data.readInt(const ['affected']),
  );

  /// 统一处理「失败透传 + 成功转换」
  Future<ApiResponse<T>> _run<T>(
    Future<ApiResponse<Map<String, dynamic>>> request,
    T Function(Map<String, dynamic> data) map,
  ) async {
    final res = await request;
    if (!res.success) {
      return ApiResponse<T>.failure(
        res.message ?? 'network_failure',
        code: res.code,
        rawResponse: res.rawResponse,
      );
    }
    return ApiResponse<T>.success(
      map(res.data ?? const <String, dynamic>{}),
      message: res.message,
      code: res.code,
      rawResponse: res.rawResponse,
    );
  }
}
