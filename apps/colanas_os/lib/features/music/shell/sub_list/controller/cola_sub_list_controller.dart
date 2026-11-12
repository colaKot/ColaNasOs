import 'dart:async';

import '../../compat/cola_api_controller.dart';
import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../compat/list_batch_ops.dart';
import '../../compat/mutation_feedback.dart';
import '../../compat/paged_list.dart';
import '../../favorite/service/cola_favorite_api_service.dart';
import '../../list/controller/cola_multi_select_controller.dart';
import '../../list/models/cola_list_models.dart';
import '../../list/service/cola_list_api_service.dart';
import '../../play_service/controller/cola_player_controller.dart';

enum MusicSubListSortBy {
  filename,
  title,
  artist,
  album,
  year,
  duration,
  ctime,
  mtime,
  favoriteTime,

  /// 专辑原生顺序（专辑名 → 音轨号 → 曲名）。专辑详情页的默认排序。
  albumOrder,

  /// 热度：Last.fm 排名优先、本地播放量兜底（服务端融合，见 compat/list）
  hot,
}

enum MusicSubListSortOrder { asc, desc }

/// 打开子列表时携带的上下文：按专辑还是歌手聚合、名字、以及可选的剧集 id。
class MusicSubListPayload {
  const MusicSubListPayload({
    required this.keyType,
    required this.name,
    this.seriesIndexId,
  });

  final String keyType;
  final String name;
  final int? seriesIndexId;

  bool get isAlbum => keyType.trim().toLowerCase() == 'album';
}

class MusicSubListOverlayController extends GetxController {
  final Rxn<MusicSubListPayload> active = Rxn<MusicSubListPayload>();

  void open({
    required String keyType,
    required String name,
    int? seriesIndexId,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    active.value = MusicSubListPayload(
      keyType: keyType.trim(),
      name: trimmed,
      seriesIndexId: seriesIndexId,
    );
  }

  void openFromGroupItem(String keyType, String name) =>
      open(keyType: keyType, name: name);

  void close() {
    if (active.value != null) active.value = null;
  }
}

/// 专辑 / 歌手 / 收藏 / 历史等「从主列表下钻」的曲目列表。
///
/// 与主列表共用多选、批量收藏、下载、删除、歌单操作；这里额外负责
/// 聚合维度的筛选参数、封面地址，以及把分页查询交给播放服务做续播。
class MusicSubListController extends GetxController
    implements ColaMusicMultiSelect {
  MusicSubListController({
    required this.keyType,
    required this.name,
    this.isFavorite = false,
    this.isHistory = false,
    this.listId,
    this.seriesIndexId,
    this.collectionId,
    this.listType,
    this.initialSortBy = MusicSubListSortBy.filename,
    this.initialSortOrder = MusicSubListSortOrder.asc,
    this.dedupe = false,
    this.ignoreStoredSort = false,
  });

  final String keyType;
  final String name;
  final bool isFavorite;
  final bool isHistory;
  final int? listId;
  final int? seriesIndexId;
  final int? collectionId;
  final String? listType;
  final MusicSubListSortBy initialSortBy;
  final MusicSubListSortOrder initialSortOrder;

  /// 同名同歌手只留最新一条（服务端去重）。歌手详情页开，曲库/歌单页不开
  /// —— 那些页必须让人看到磁盘上的每一个文件。
  final bool dedupe;

  /// 排序不读 / 不写全局缓存。
  /// 专辑 / 歌手详情页有自己的固定排序语义，跟着曲库页的「文件名排序」跑会莫名其妙。
  final bool ignoreStoredSort;

  static const Map<MusicSubListSortBy, String> _sortByParams =
      <MusicSubListSortBy, String>{
        MusicSubListSortBy.filename: 'filename',
        MusicSubListSortBy.title: 'title',
        MusicSubListSortBy.artist: 'artist',
        MusicSubListSortBy.album: 'album',
        MusicSubListSortBy.year: 'year',
        MusicSubListSortBy.duration: 'duration',
        MusicSubListSortBy.ctime: 'ctime',
        MusicSubListSortBy.mtime: 'mtime',
        MusicSubListSortBy.favoriteTime: 'favorite_time',
        MusicSubListSortBy.albumOrder: 'album_order',
        MusicSubListSortBy.hot: 'hot',
      };

  static final Map<String, MusicSubListSortBy> _sortByValues =
      <String, MusicSubListSortBy>{
        for (final entry in _sortByParams.entries) entry.value: entry.key,
      };

  final RxList<MusicListItem> items = <MusicListItem>[].obs;
  final RxBool loading = false.obs;
  final RxBool loadingMore = false.obs;
  final RxBool hasMore = true.obs;
  final RxBool autoLoadFailed = false.obs;
  final RxInt total = 0.obs;
  final RxBool isMultiSelectMode = false.obs;

  @override
  final RxSet<int> selectedItems = <int>{}.obs;

  final Rx<MusicSubListSortBy> sortBy = MusicSubListSortBy.filename.obs;
  final Rx<MusicSubListSortOrder> sortOrder = MusicSubListSortOrder.asc.obs;
  final RxString searchText = ''.obs;

  static const int _pageSize = 300;
  int _cursor = 1;
  final RxBool isScrolling = false.obs;
  Timer? _scrollEndDebounce;
  void Function()? _scanDoneOff;

  final SearchDebouncer _search = SearchDebouncer(
    const Duration(milliseconds: 320),
  );

  late final MusicSelection _selection = MusicSelection(
    selected: selectedItems,
    multiMode: isMultiSelectMode,
    items: items,
  );

  String get _sortByParam => _sortByParams[sortBy.value] ?? 'filename';
  String get _sortOrderParam =>
      sortOrder.value == MusicSubListSortOrder.asc ? 'asc' : 'desc';

  bool get _isArtist => keyType.trim().toLowerCase() == 'artist';

  List<String>? get _artistsFilter =>
      !isHistory && _isArtist ? <String>[name] : null;

  List<String>? get _albumsFilter =>
      !isHistory && keyType.trim().toLowerCase() == 'album'
      ? <String>[name]
      : null;

  MusicSubListSortBy? _parseSortBy(String? raw) =>
      raw == null ? null : _sortByValues[raw];

  MusicSubListSortOrder? _parseSortOrder(String? raw) => switch (raw) {
    'asc' => MusicSubListSortOrder.asc,
    'desc' => MusicSubListSortOrder.desc,
    _ => null,
  };

  void _restoreSort() {
    if (ignoreStoredSort) {
      sortBy.value = initialSortBy;
      sortOrder.value = initialSortOrder;
      return;
    }
    final by = _parseSortBy(
      CacheManager().getString(CacheKeys.musicSubListSortBy),
    );
    final order = _parseSortOrder(
      CacheManager().getString(CacheKeys.musicSubListSortOrder),
    );
    sortBy.value = by ?? initialSortBy;
    sortOrder.value = order ?? initialSortOrder;
  }

  void _persistSort() {
    if (ignoreStoredSort) return;
    CacheManager().setString(CacheKeys.musicSubListSortBy, _sortByParam);
    CacheManager().setString(CacheKeys.musicSubListSortOrder, _sortOrderParam);
  }

  @override
  void onInit() {
    super.onInit();
    _restoreSort();
    // 后台扫描完成后重取，历史 / 收藏等聚合数也会跟着变
    _scanDoneOff = listenMusicScanDone(
      () => unawaited(refreshList(showLoading: false)),
    );
    unawaited(refreshList(showLoading: true));
  }

  @override
  void onClose() {
    _scanDoneOff?.call();
    _scanDoneOff = null;
    _scrollEndDebounce?.cancel();
    _search.cancel();
    super.onClose();
  }

  void markScrolling() {
    isScrolling.value = true;
    _scrollEndDebounce?.cancel();
    _scrollEndDebounce = Timer(const Duration(milliseconds: 120), () {
      isScrolling.value = false;
    });
  }

  String get headerCoverPath =>
      items.isEmpty ? '' : musicFilePathOf(items.first);

  String get headerCoverUrl {
    if (items.isEmpty || items.first.hasInnerCover != 1) return '';
    final path = headerCoverPath;
    if (path.isEmpty) return '';
    return ApiController.instance.getMusicCoverUrl(filePath: path, size: 500);
  }

  /// 交给播放服务的分页描述：播到列表末尾时据此继续取下一页。
  MusicListPagingQuery _pagingQuery() => MusicListPagingQuery(
    page: _cursor,
    pageSize: _pageSize,
    hasMore: hasMore.value,
    listType: listType,
    listId: listId,
    seriesIndexId: seriesIndexId,
    collectionId: collectionId,
    isFavorite: isFavorite,
    isHistory: isHistory,
    search: searchText.value,
    artists: _artistsFilter,
    albums: _albumsFilter,
    sortBy: _sortByParam,
    sortOrder: _sortOrderParam,
  );

  void playAll({int initialIndex = 0}) {
    if (items.isEmpty) return;
    final start = items[initialIndex.clamp(0, items.length - 1)];
    MusicPlayServiceController.instance.playFromList(
      items: items.toList(growable: false),
      startItem: start,
      paging: MusicPlaylistPaging.fromQuery(_pagingQuery()),
    );
  }

  void playAt(int index) => playAll(initialIndex: index);

  void toggleMultiSelectMode() {
    final next = !isMultiSelectMode.value;
    isMultiSelectMode.value = next;
    if (!next) selectedItems.clear();
  }

  void toggleSelection(int id) => _selection.toggle(id);

  @override
  bool get hasSelection => _selection.hasSelection;

  @override
  int get selectedCount => _selection.selectedCount;

  @override
  bool get allCurrentSelected => _selection.allSelected;

  @override
  void toggleSelectAll() => _selection.toggleAll();

  @override
  void leaveMultiSelect() => _selection.clear();

  @override
  bool get allSelectedFavorited => _selection.allFavorited;

  void setSort(MusicSubListSortBy by, MusicSubListSortOrder order) {
    if (sortBy.value == by && sortOrder.value == order) return;
    sortBy.value = by;
    sortOrder.value = order;
    _persistSort();
    unawaited(refreshList(showLoading: true));
  }

  void onSearchChanged(String value) {
    searchText.value = value;
    _search.submit(value, (_) => unawaited(refreshList(showLoading: false)));
  }

  void setSearchImmediate(String value) {
    searchText.value = value;
    _search.cancel();
    unawaited(refreshList(showLoading: false));
  }

  void clearSearch() {
    searchText.value = '';
    unawaited(refreshList(showLoading: false));
  }

  Future<MusicListPagedResult> _requestPage(
    int pageNo, {
    required bool showLoading,
  }) => MusicListApiService.instance.listPaged(
    page: pageNo,
    pageSize: _pageSize,
    listType: listType,
    listId: listId,
    seriesIndexId: seriesIndexId,
    collectionId: collectionId,
    isFavorite: isFavorite,
    isHistory: isHistory,
    search: searchText.value,
    artists: _artistsFilter,
    albums: _albumsFilter,
    sortBy: _sortByParam,
    sortOrder: _sortOrderParam,
    showLoading: showLoading,
    dedupe: dedupe,
  );

  void _applyPaging(MusicListPagedResult result) {
    total.value = result.pagination.total;
    hasMore.value = result.pagination.hasNextPage;
  }

  Future<void> refreshList({bool showLoading = false}) async {
    loading.value = true;
    autoLoadFailed.value = false;
    try {
      _cursor = 1;
      final result = await _requestPage(_cursor, showLoading: showLoading);
      items.assignAll(result.items);
      _applyPaging(result);
    } finally {
      loading.value = false;
    }
  }

  Future<void> loadMore({bool fromAuto = false}) async {
    if (loadingMore.value || loading.value || !hasMore.value) return;
    if (fromAuto && autoLoadFailed.value) return;

    loadingMore.value = true;
    try {
      final next = _cursor + 1;
      final result = await _requestPage(next, showLoading: false);
      _cursor = next;
      items.addAll(result.items);
      _applyPaging(result);
      autoLoadFailed.value = false;
    } catch (_) {
      autoLoadFailed.value = true;
      rethrow;
    } finally {
      loadingMore.value = false;
    }
  }

  Future<void> _download(
    List<MusicListItem> entries, {
    required bool exitSelection,
  }) async {
    final paths = musicPathsOf(entries);
    if (paths.isEmpty) return;
    await submitMusicDownload(paths);
    if (exitSelection) leaveMultiSelect();
  }

  Future<void> downloadAll() => _download(items, exitSelection: false);

  Future<void> downloadItem(MusicListItem item) =>
      _download(<MusicListItem>[item], exitSelection: false);

  @override
  Future<void> downloadSelection() =>
      _download(_selection.chosen, exitSelection: true);

  Future<void> toggleFavorite(MusicListItem item) async {
    if (item.id <= 0) return;
    final makeFavorite = !item.isFavorite;
    final ok = makeFavorite
        ? await MusicFavoriteApiService.instance.addFavorite(item.id)
        : await MusicFavoriteApiService.instance.removeFavorite(item.id);
    if (ok) updateFavoriteState(item.id, makeFavorite);
  }

  @override
  Future<void> switchSelectionFavorite() async {
    final ok = await applyBatchFavorite(
      ids: sortedIndexIds(selectedItems),
      makeFavorite: !allSelectedFavorited,
      onState: updateFavoriteState,
    );
    if (ok) leaveMultiSelect();
  }

  void updateFavoriteState(int indexId, bool nextIsFavorite) {
    if (indexId <= 0) return;
    if (isFavorite && !nextIsFavorite) {
      items.removeWhere((entry) => entry.id == indexId);
      total.value = (total.value - 1).clamp(0, 1 << 30);
      return;
    }
    final at = items.indexWhere((entry) => entry.id == indexId);
    if (at < 0) return;
    items[at] = items[at].copyWith(isFavorite: nextIsFavorite);
    items.refresh();
  }

  @override
  bool get insidePlaylist => (listId ?? 0) > 0;

  /// 删掉几首后列表可能不满一页，静默补一次，异常不外抛打断界面。
  void _autoLoadMoreIfNeeded() {
    if (!_canAutoLoad) return;
    Future.microtask(() {
      if (!_canAutoLoad) return;
      unawaited(loadMore(fromAuto: false).catchError((_) {}));
    });
  }

  bool get _canAutoLoad =>
      hasMore.value &&
      !loading.value &&
      !loadingMore.value &&
      items.length < _pageSize;

  Future<void> _removeFromList(
    List<int> ids, {
    bool exitSelection = false,
    required bool refill,
  }) async {
    final current = listId ?? 0;
    if (current <= 0 || ids.isEmpty) return;
    try {
      await removeIndexesFromPlayList(
        listId: current,
        ids: ids,
        items: items,
        total: total,
        onRemoved: () {
          if (exitSelection) leaveMultiSelect();
          if (refill) _autoLoadMoreIfNeeded();
        },
      );
    } catch (_) {
      notifyFailure(null);
    }
  }

  Future<void> removeFromPlayListItem(MusicListItem item) =>
      _removeFromList(<int>[item.id], refill: true);

  @override
  Future<void> removeSelectionFromPlaylist() => _removeFromList(
    sortedIndexIds(selectedItems),
    exitSelection: true,
    refill: true,
  );

  Future<void> _addToPlayList(
    List<int> ids, {
    required bool exitSelection,
  }) async {
    if (ids.isEmpty) return;
    try {
      final picked = await pickMusicPlayList();
      if (picked == null) return;
      final ok = await addIndexesToPlayList(listId: picked.id, ids: ids);
      if (ok && exitSelection) leaveMultiSelect();
    } catch (_) {
      notifyFailure(null);
    }
  }

  @override
  Future<void> addSelectionToPlaylist() =>
      _addToPlayList(sortedIndexIds(selectedItems), exitSelection: true);

  Future<void> addToPlayListItem(MusicListItem item) =>
      _addToPlayList(<int>[item.id], exitSelection: false);

  Future<void> _delete(
    List<MusicListItem> entries, {
    required bool exitSelection,
  }) async {
    final targets = musicDeleteTargetsOf(entries);
    if (targets.isEmpty) return;
    final recycle = await confirmMusicDeletion(targets.paths);
    if (recycle == null) return;
    final ok = await performMusicDeletion(
      paths: targets.paths,
      removeIds: targets.ids,
      recycle: recycle,
      items: items,
      total: total,
      onRemoved: _autoLoadMoreIfNeeded,
    );
    if (ok && exitSelection) leaveMultiSelect();
  }

  @override
  Future<void> deleteSelection() =>
      _delete(_selection.chosen, exitSelection: true);

  Future<void> deleteItem(MusicListItem item) =>
      _delete(<MusicListItem>[item], exitSelection: false);
}
