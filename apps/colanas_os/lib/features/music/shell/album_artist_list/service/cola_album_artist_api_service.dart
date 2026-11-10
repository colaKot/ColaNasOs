import '../../compat/api_base.dart';
import '../../compat/getx.dart';
import '../models/cola_album_artist_models.dart';

/// 专辑 / 歌手聚合列表的接口封装。
///
/// 两个列表除请求路径不同外，入参与返回结构完全一致，所以用 `keyType` 分流，
/// 不写两套几乎相同的调用。
class AlbumArtistListApiService extends BaseApiService {
  static const String _artistEndpoint = '/api/music/artist/list';
  static const String _albumEndpoint = '/api/music/album/list';

  static AlbumArtistListApiService get instance =>
      Get.isRegistered<AlbumArtistListApiService>()
      ? Get.find<AlbumArtistListApiService>()
      : AlbumArtistListApiService();

  Future<AlbumArtistListPagedResult> listPaged({
    required String keyType,
    required int page,
    required int pageSize,
    String? search,
    List<String>? sourceList,
    String? sortBy,
    String? sortOrder,
    bool showLoading = false,
  }) async {
    final isArtist = keyType.trim().toLowerCase() == 'artist';
    final res = await apiPost<Map<String, dynamic>>(
      isArtist ? _artistEndpoint : _albumEndpoint,
      body: _requestBody(
        page: page,
        pageSize: pageSize,
        search: search,
        sourceList: sourceList,
        sortBy: sortBy,
        sortOrder: sortOrder,
      ),
      showLoading: showLoading,
    );

    // 失败返回空结果而不是 null：调用方只需要渲染列表，空结构更省事
    final data = res.success ? res.data : null;
    if (data == null) return const AlbumArtistListPagedResult.empty();
    return AlbumArtistListPagedResult.fromJson(data);
  }

  /// 只把非空参数放进去，避免后端把 `search: null` 当成「搜空串」
  Map<String, dynamic> _requestBody({
    required int page,
    required int pageSize,
    String? search,
    List<String>? sourceList,
    String? sortBy,
    String? sortOrder,
  }) {
    return <String, dynamic>{
      'page': page,
      'page_size': pageSize,
      if (search != null) 'search': search,
      if (sourceList != null) 'sourceList': sourceList,
      if (sortBy != null) 'sort_by': sortBy,
      if (sortOrder != null) 'sort_order': sortOrder,
    };
  }
}
