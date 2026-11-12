import '../../compat/api_base.dart';
import '../../compat/getx.dart';
import '../models/cola_album_artist_models.dart';

/// 专辑 / 歌手聚合列表的数据源。
///
/// 两种聚合的入参与返回结构一致，只有请求地址不同，因此按 [keyType] 查表选路，
/// 入参组装共用一份实现。
class AlbumArtistListApiService extends BaseApiService {
  static const String _albumPath = '/api/music/album/list';
  static const String _artistPath = '/api/music/artist/list';

  static const Map<String, String> _pathsByType = <String, String>{
    'album': _albumPath,
    'artist': _artistPath,
  };

  static AlbumArtistListApiService get instance {
    if (Get.isRegistered<AlbumArtistListApiService>()) {
      return Get.find<AlbumArtistListApiService>();
    }
    return AlbumArtistListApiService();
  }

  Future<AlbumArtistListPagedResult> listPaged({
    required int page,
    required int pageSize,
    required String keyType,
    String? sortBy,
    String? sortOrder,
    String? search,
    List<String>? sourceList,
    bool showLoading = false,
  }) async {
    final response = await apiPost<Map<String, dynamic>>(
      _pathOf(keyType),
      body: _payload(
        page: page,
        pageSize: pageSize,
        search: search,
        sourceList: sourceList,
        sortBy: sortBy,
        sortOrder: sortOrder,
      ),
      showLoading: showLoading,
    );

    final data = response.success ? response.data : null;
    if (data == null) return const AlbumArtistListPagedResult.empty();
    return AlbumArtistListPagedResult.fromJson(data);
  }

  String _pathOf(String keyType) =>
      _pathsByType[keyType.trim().toLowerCase()] ?? _albumPath;

  /// 可选参数为空时不下发，防止后端把 `null` 当成空串过滤条件。
  Map<String, dynamic> _payload({
    required int page,
    required int pageSize,
    String? search,
    List<String>? sourceList,
    String? sortBy,
    String? sortOrder,
  }) {
    final payload = <String, dynamic>{'page': page, 'page_size': pageSize};
    if (search != null) payload['search'] = search;
    if (sourceList != null) payload['sourceList'] = sourceList;
    if (sortBy != null) payload['sort_by'] = sortBy;
    if (sortOrder != null) payload['sort_order'] = sortOrder;
    return payload;
  }
}
