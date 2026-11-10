import '../../compat/api_base.dart';
import '../../compat/getx.dart';
import '../../compat/json_read.dart';
import '../../list/models/cola_list_models.dart';

/// 歌单相关接口。
///
/// 六个方法除了路径和请求体，返回处理完全一样（失败透传 + 成功转换），
/// 统一收口到 [_run]；「加歌 / 移歌」共用的 id 清洗也抽成 [_cleanIds]。
class PlayListApiService extends BaseApiService {
  static const String _listPath = '/api/music/playlist/list';
  static const String _createPath = '/api/music/playlist/create';
  static const String _updatePath = '/api/music/playlist/update';
  static const String _deletePath = '/api/music/playlist/delete';
  static const String _addItemsPath = '/api/music/playlist/index/add';
  static const String _removeItemsPath = '/api/music/playlist/index/remove';

  static PlayListApiService get instance =>
      Get.isRegistered<PlayListApiService>()
      ? Get.find<PlayListApiService>()
      : PlayListApiService();

  Future<ApiResponse<PlayListPagedResult>> listLists({
    int page = 1,
    int pageSize = 30,
    String? search,
    String sortBy = 'create_time',
    String sortOrder = 'desc',
  }) {
    final keyword = search?.trim() ?? '';
    return _run(
      apiPost<Map<String, dynamic>>(
        _listPath,
        body: <String, dynamic>{
          'page': page,
          'page_size': pageSize,
          if (keyword.isNotEmpty) 'search': keyword,
          'sort_by': sortBy,
          'sort_order': sortOrder,
        },
        showLoading: false,
      ),
      PlayListPagedResult.fromJson,
    );
  }

  Future<ApiResponse<PlayListItem>> createList({required String name}) => _run(
    apiPost<Map<String, dynamic>>(
      _createPath,
      body: <String, dynamic>{'name': name.trim()},
      showLoading: true,
    ),
    PlayListItem.fromJson,
  );

  Future<ApiResponse<PlayListItem>> updateList({
    required int id,
    required String name,
  }) => _run(
    apiPost<Map<String, dynamic>>(
      _updatePath,
      body: <String, dynamic>{'id': id, 'name': name.trim()},
      showLoading: true,
    ),
    PlayListItem.fromJson,
  );

  Future<ApiResponse<bool>> deleteList(int id) => _run(
    apiPost<Map<String, dynamic>>(
      _deletePath,
      body: <String, dynamic>{'id': id},
      showLoading: true,
    ),
    (_) => true,
  );

  Future<ApiResponse<bool>> addIndexes({
    required int listId,
    required List<int> indexIds,
  }) {
    final ids = _cleanIds(indexIds);
    if (ids.isEmpty) return _reject();
    return _run(
      apiPost<Map<String, dynamic>>(
        _addItemsPath,
        body: <String, dynamic>{'list_id': listId, 'index_ids': ids},
        showLoading: true,
      ),
      (_) => true,
    );
  }

  Future<ApiResponse<bool>> removeIndexes({
    required int listId,
    required List<int> indexIds,
  }) {
    final ids = _cleanIds(indexIds);
    if (ids.isEmpty) return _reject();
    return _run(
      apiPost<Map<String, dynamic>>(
        _removeItemsPath,
        body: <String, dynamic>{'list_id': listId, 'index_ids': ids},
        showLoading: true,
      ),
      (_) => true,
    );
  }

  /// 丢掉非法 id（<= 0 是本地临时条目）、去重、排序 —— 排序让同一次操作
  /// 产生可复现的请求体，排查问题时日志能直接比对。
  List<int> _cleanIds(List<int> raw) =>
      raw.where((id) => id > 0).toSet().toList()..sort();

  Future<ApiResponse<bool>> _reject() => Future<ApiResponse<bool>>.value(
    ApiResponse<bool>.failure('network_failure'),
  );

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

/// 歌单条目（卡片展示用，`previews` 是前几首的缩略信息）
class PlayListItem {
  final int id;
  final int uid;
  final String name;
  final String createTime;
  final List<MusicListItem> previews;

  const PlayListItem({
    required this.id,
    required this.uid,
    required this.name,
    required this.createTime,
    required this.previews,
  });

  factory PlayListItem.fromJson(Map<String, dynamic> json) => PlayListItem(
    id: json.readInt(const ['id']),
    uid: json.readInt(const ['uid', 'owner_id', 'ownerId']),
    name: json.readString(const ['name']).trim(),
    createTime: json.readString(const ['create_time', 'createTime']).trim(),
    previews: json.readList(const ['previews'], MusicListItem.fromJson),
  );
}

/// 歌单列表的一次返回
class PlayListPagedResult {
  final List<PlayListItem> items;
  final PlayListPagination pagination;

  const PlayListPagedResult({required this.items, required this.pagination});

  const PlayListPagedResult.empty()
    : items = const <PlayListItem>[],
      pagination = const PlayListPagination.empty();

  factory PlayListPagedResult.fromJson(Map<String, dynamic> json) {
    final pagination = json.readMap(const ['pagination']);
    return PlayListPagedResult(
      items: json.readList(const ['items'], PlayListItem.fromJson),
      pagination: pagination == null
          ? const PlayListPagination.empty()
          : PlayListPagination.fromJson(pagination),
    );
  }
}

/// 歌单分页信息
class PlayListPagination {
  final int total;
  final int page;
  final int pageSize;

  const PlayListPagination({
    required this.total,
    required this.page,
    required this.pageSize,
  });

  const PlayListPagination.empty() : total = 0, page = 1, pageSize = 30;

  factory PlayListPagination.fromJson(Map<String, dynamic> json) =>
      PlayListPagination(
        total: json.readInt(const ['total']),
        page: json.readInt(const ['page']),
        pageSize: json.readInt(const ['pageSize', 'page_size']),
      );

  bool get hasNextPage {
    // pageSize 兜底 30 与 `empty()` 保持一致；total 为 0 时只有一页
    final size = pageSize <= 0 ? 30 : pageSize;
    final maxPage = total <= 0 ? 1 : ((total + size - 1) / size).floor();
    return page < maxPage;
  }
}
