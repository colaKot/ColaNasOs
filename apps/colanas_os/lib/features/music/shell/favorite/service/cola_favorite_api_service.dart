import '../../compat/api_base.dart';
import '../../compat/getx.dart';

/// 「收藏」接口。单曲与批量走同一个后端端点，所以只保留一个真实实现，
/// 单曲操作只是包一层，避免两条路径出现行为差异。
class MusicFavoriteApiService extends BaseApiService {
  static const String _batchEndpoint = '/api/music/favorite/batch';

  static MusicFavoriteApiService get instance =>
      Get.isRegistered<MusicFavoriteApiService>()
      ? Get.find<MusicFavoriteApiService>()
      : MusicFavoriteApiService();

  Future<bool> addFavorite(int indexId) => batchFavorite([indexId], true);

  Future<bool> removeFavorite(int indexId) => batchFavorite([indexId], false);

  /// 批量设置收藏状态。
  ///
  /// 入参先做三件事：丢掉非法 id（<= 0 是本地临时条目）、去重、排序 ——
  /// 排序是为了让同样的集合产生同样的请求体，方便日志和幂等排查。
  Future<bool> batchFavorite(List<int> indexIds, bool isFavorite) async {
    final ids = indexIds.where((id) => id > 0).toSet().toList()..sort();
    if (ids.isEmpty) return false;
    final res = await apiPost<void>(
      _batchEndpoint,
      body: <String, dynamic>{'index_ids': ids, 'is_favorite': isFavorite},
      showLoading: false,
    );
    return res.success;
  }
}
