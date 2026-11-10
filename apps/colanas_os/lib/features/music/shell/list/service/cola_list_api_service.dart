import '../../compat/api_base.dart';
import '../../compat/getx.dart';
import '../../compat/json_read.dart';
import '../models/cola_list_models.dart';

/// 曲目列表相关的接口。
///
/// 列表接口的入参组合特别多（歌单 / 合集 / 收藏 / 历史 / 搜索 / 多维筛选），
/// 以前全塞在一个字面量里、每加一个维度就多一行 `if`。这里拆成
/// [_listQueryBody]，缺省值判断和「哪些字段该发」集中在一处。
class MusicListApiService extends BaseApiService {
  static const String _listPath = '/api/music/list';
  static const String _countPath = '/api/music/list/count';
  static const String _deletePath = '/api/music/delete';
  static const String _detailPath = '/api/music/detail/get';
  static const String _historyRefreshPath = '/api/music/history/refresh';

  static MusicListApiService get instance =>
      Get.isRegistered<MusicListApiService>()
      ? Get.find<MusicListApiService>()
      : MusicListApiService();

  /// 各类曲库的条目数（首页统计条用）
  Future<ApiResponse<MusicLibraryCountResult>> getLibraryCounts({
    List<String>? sourceList,
  }) async {
    final res = await apiPost<Map<String, dynamic>>(
      _countPath,
      body: <String, dynamic>{'sourceList': ?sourceList},
      showLoading: false,
    );
    if (!res.success) {
      // 计数失败要把原始错误透传上去，页面据此区分「没权限」和「网络不通」
      return ApiResponse<MusicLibraryCountResult>.failure(
        res.message ?? 'network_failure',
        code: res.code,
        rawResponse: res.rawResponse,
      );
    }
    return ApiResponse<MusicLibraryCountResult>.success(
      MusicLibraryCountResult.fromJson(res.data ?? const <String, dynamic>{}),
      message: res.message,
      code: res.code,
      rawResponse: res.rawResponse,
    );
  }

  /// 批量删除曲目文件。路径先 trim + 去空 + 排序，保证同一批请求可复现。
  Future<ApiResponse<Map<String, dynamic>>> deleteEntries(
    List<String> paths, {
    bool recycle = false,
    bool showLoading = true,
  }) {
    final targets =
        paths
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty)
            .toList()
          ..sort();
    if (targets.isEmpty) {
      return Future<ApiResponse<Map<String, dynamic>>>.value(
        ApiResponse<Map<String, dynamic>>.failure('network_failure'),
      );
    }
    return apiPost<Map<String, dynamic>>(
      _deletePath,
      body: <String, dynamic>{'paths': targets, 'recycle': recycle},
      showLoading: showLoading,
    );
  }

  Future<MusicListPagedResult> listPaged({
    required int page,
    required int pageSize,
    String? listType,
    int? listId,
    int? seriesIndexId,
    int? collectionId,
    bool isFavorite = false,
    bool isHistory = false,
    String? search,
    List<String>? artists,
    List<String>? albums,
    List<String>? genres,
    List<String>? sourceList,
    String? sortBy,
    String? sortOrder,
    bool showLoading = false,
    bool dedupe = false,
  }) async {
    final res = await apiPost<Map<String, dynamic>>(
      _listPath,
      body: _listQueryBody(
        page: page,
        pageSize: pageSize,
        listType: listType,
        listId: listId,
        seriesIndexId: seriesIndexId,
        collectionId: collectionId,
        isFavorite: isFavorite,
        isHistory: isHistory,
        search: search,
        artists: artists,
        albums: albums,
        genres: genres,
        sourceList: sourceList,
        sortBy: sortBy,
        sortOrder: sortOrder,
        dedupe: dedupe,
      ),
      showLoading: showLoading,
    );
    final data = res.success ? res.data : null;
    if (data == null) return const MusicListPagedResult.empty();
    return MusicListPagedResult.fromJson(data);
  }

  /// 列表请求体。
  ///
  /// 规则：**只发有意义的字段**。空串的 `listType`、0 的 id 号、没开的开关
  /// 一律不发 —— 后端拿到 `listId: 0` 会当成「查 id 为 0 的歌单」直接空结果。
  Map<String, dynamic> _listQueryBody({
    required int page,
    required int pageSize,
    String? listType,
    int? listId,
    int? seriesIndexId,
    int? collectionId,
    required bool isFavorite,
    required bool isHistory,
    String? search,
    List<String>? artists,
    List<String>? albums,
    List<String>? genres,
    List<String>? sourceList,
    String? sortBy,
    String? sortOrder,
    bool dedupe = false,
  }) {
    final type = listType?.trim() ?? '';
    return <String, dynamic>{
      'page': page,
      'page_size': pageSize,
      if (type.isNotEmpty) 'listType': type,
      if ((listId ?? 0) > 0) 'list_id': listId,
      if ((seriesIndexId ?? 0) > 0) 'series_index_id': seriesIndexId,
      if ((collectionId ?? 0) > 0) 'collection_id': collectionId,
      if (isFavorite) 'is_favorite': 1,
      if (isHistory) 'isHistory': 1,
      'search': ?search,
      'artists': ?artists,
      'albums': ?albums,
      'genres': ?genres,
      'sourceList': ?sourceList,
      'sort_by': ?sortBy,
      'sort_order': ?sortOrder,
      if (dedupe) 'dedupe': 1,
    };
  }

  /// 按文件路径取详情（同时带回旁挂 / 内嵌歌词）
  Future<ApiResponse<Map<String, dynamic>>> getDetailByPath(
    String filePath, {
    bool showLoading = false,
  }) {
    final path = filePath.trim();
    if (path.isEmpty) {
      return Future<ApiResponse<Map<String, dynamic>>>.value(
        ApiResponse<Map<String, dynamic>>.failure('network_failure'),
      );
    }
    return apiPost<Map<String, dynamic>>(
      _detailPath,
      body: <String, dynamic>{'file_path': path},
      showLoading: showLoading,
    );
  }

  /// 上报一次播放（写历史）。id 与路径至少给一个，两个都给时后端按 id 优先。
  Future<ApiResponse<Map<String, dynamic>>> refreshHistory({
    int? indexId,
    String? filePath,
    bool showLoading = false,
  }) {
    final id = indexId ?? 0;
    final path = filePath?.trim() ?? '';
    if (id <= 0 && path.isEmpty) {
      return Future<ApiResponse<Map<String, dynamic>>>.value(
        ApiResponse<Map<String, dynamic>>.failure('network_failure'),
      );
    }
    return apiPost<Map<String, dynamic>>(
      _historyRefreshPath,
      body: <String, dynamic>{
        if (id > 0) 'index_id': id,
        if (path.isNotEmpty) 'file_path': path,
      },
      showLoading: showLoading,
    );
  }
}

/// 首页统计条上的曲库总量
class MusicLibraryCountResult {
  final int songs;

  const MusicLibraryCountResult({required this.songs});

  factory MusicLibraryCountResult.fromJson(Map<String, dynamic> json) =>
      MusicLibraryCountResult(songs: json.readInt(const ['songs']));
}
