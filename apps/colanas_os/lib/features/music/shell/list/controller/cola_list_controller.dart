import 'dart:async';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../compat/list_batch_ops.dart';
import '../../compat/mutation_feedback.dart';
import '../../compat/paged_list.dart';
import '../models/cola_list_models.dart';
import '../service/cola_list_api_service.dart';
import 'cola_multi_select_controller.dart';

enum MusicListSortBy {
  title,
  artist,
  album,
  year,
  duration,
  ctime,
  mtime,
  favoriteTime,
}

enum MusicListSortOrder { asc, desc }

/// 主曲目列表。
///
/// 状态分三层：分页与筛选（本类）、多选与批量动作（[MusicSelection] +
/// `list_batch_ops.dart`）、排序与目录偏好的本地持久化。三处翻页请求共用
/// [_requestPage]，避免「刷新 / 追加 / 跳页」各抄一遍参数表。
class MusicListController extends GetxController
    implements ColaMusicMultiSelect {
  MusicListController({
    this.listType = '',
    this.listId,
    this.seriesIndexId,
    this.collectionId,
    this.isFavorite = false,
    this.initialSortBy = MusicListSortBy.mtime,
    this.initialSortOrder = MusicListSortOrder.desc,
  });

  final String listType;
  final int? listId;
  final int? seriesIndexId;
  final int? collectionId;
  final bool isFavorite;
  final MusicListSortBy initialSortBy;
  final MusicListSortOrder initialSortOrder;

  bool get isFavoriteList => isFavorite;

  static const Map<MusicListSortBy, String> _sortByParams =
      <MusicListSortBy, String>{
        MusicListSortBy.title: 'title',
        MusicListSortBy.artist: 'artist',
        MusicListSortBy.album: 'album',
        MusicListSortBy.year: 'year',
        MusicListSortBy.duration: 'duration',
        MusicListSortBy.ctime: 'ctime',
        MusicListSortBy.mtime: 'mtime',
        MusicListSortBy.favoriteTime: 'favorite_time',
      };

  static final Map<String, MusicListSortBy> _sortByValues =
      <String, MusicListSortBy>{
        for (final entry in _sortByParams.entries) entry.value: entry.key,
      };

  final RxList<MusicListItem> items = <MusicListItem>[].obs;
  final RxBool loading = false.obs;
  final RxBool loadingMore = false.obs;
  final RxBool hasMore = true.obs;
  final RxBool autoLoadFailed = false.obs;

  /// 底部翻页控件用的页码，与请求游标 [_cursor] 分开记
  final RxInt page = 1.obs;
  final RxInt totalPages = 0.obs;
  final RxInt total = 0.obs;

  final RxString searchText = ''.obs;
  final RxBool isMultiSelectMode = false.obs;

  @override
  final RxSet<int> selectedItems = <int>{}.obs;

  final selectionRect = Rxn<Rect>();
  final selectionRectContent = Rxn<Rect>();
  Offset? _dragOrigin;
  double _dragOriginScroll = 0;
  Set<int>? _dragBaseline;

  final RxList<String> artists = <String>[].obs;
  final RxList<String> albums = <String>[].obs;
  final RxList<String> genres = <String>[].obs;

  final RxList<String> availableArtists = <String>[].obs;
  final RxList<String> availableAlbums = <String>[].obs;
  final RxList<String> availableGenres = <String>[].obs;

  final RxList<MusicListPathItem> availablePaths = <MusicListPathItem>[].obs;
  final RxList<String> selectedPaths = <String>[].obs;
  List<MusicListPathItem> _fullPathCatalog = <MusicListPathItem>[];

  final Rx<MusicListSortBy> sortBy = MusicListSortBy.mtime.obs;
  final Rx<MusicListSortOrder> sortOrder = MusicListSortOrder.desc.obs;

  int get activeFilterCount => artists.length + albums.length + genres.length;

  int _cursor = 1;
  static const int _pageSize = 300;
  final RxBool isScrolling = false.obs;
  Timer? _scrollEndDebounce;
  final SearchDebouncer _search = SearchDebouncer(
    const Duration(milliseconds: 320),
  );

  Worker? _selectedPathsWorker;
  bool _restoringPaths = false;
  void Function()? _scanDoneOff;

  late final MusicSelection _selection = MusicSelection(
    selected: selectedItems,
    multiMode: isMultiSelectMode,
    items: items,
  );

  String get _sortByParam => _sortByParams[sortBy.value] ?? 'mtime';
  String get _sortOrderParam =>
      sortOrder.value == MusicListSortOrder.asc ? 'asc' : 'desc';
  List<String>? get _sourceFilter =>
      selectedPaths.isEmpty ? null : selectedPaths.toList();

  /// 同一套排序偏好按「当前所在库」隔离：歌单 / 收藏 / 合集各自记一份。
  String get _sortScope {
    if ((seriesIndexId ?? 0) > 0) {
      return 'series_${listType.isNotEmpty ? listType : 'all'}';
    }
    if (isFavoriteList) return 'favorite';
    if ((listId ?? 0) > 0) return 'list_$listId';
    if ((collectionId ?? 0) > 0) return 'collection_$collectionId';
    return listType.isNotEmpty ? 'lib_$listType' : 'lib_all';
  }

  String get _sortByKey => '${CacheKeys.musicListSortByPrefix}$_sortScope';
  String get _sortOrderKey =>
      '${CacheKeys.musicListSortOrderPrefix}$_sortScope';
  String get _pathsKey => CacheKeys.musicListSelectedPaths;

  bool get _pathsCacheApplicable =>
      (listId ?? 0) <= 0 &&
      (collectionId ?? 0) <= 0 &&
      (seriesIndexId ?? 0) <= 0;

  MusicListSortBy? _parseSortBy(String? raw) =>
      raw == null ? null : _sortByValues[raw];

  MusicListSortOrder? _parseSortOrder(String? raw) => switch (raw) {
    'asc' => MusicListSortOrder.asc,
    'desc' => MusicListSortOrder.desc,
    _ => null,
  };

  void _restoreSort() {
    final by = _parseSortBy(CacheManager().getString(_sortByKey));
    final order = _parseSortOrder(CacheManager().getString(_sortOrderKey));
    sortBy.value = by ?? initialSortBy;
    sortOrder.value = order ?? initialSortOrder;
  }

  void _persistSort() {
    CacheManager().setString(_sortByKey, _sortByParam);
    CacheManager().setString(_sortOrderKey, _sortOrderParam);
  }

  void _restorePaths() {
    if (!_pathsCacheApplicable) return;
    _restoringPaths = true;
    try {
      final cached = CacheManager().getStringList(_pathsKey);
      if (cached == null || cached.isEmpty) return;
      final kept = _cleanStrings(cached);
      if (kept.isNotEmpty) selectedPaths.assignAll(kept);
    } finally {
      _restoringPaths = false;
    }
  }

  void _persistPaths() {
    if (!_pathsCacheApplicable) return;
    final kept = _cleanStrings(selectedPaths);
    if (kept.isEmpty) {
      CacheManager().remove(_pathsKey);
      return;
    }
    CacheManager().setStringList(_pathsKey, kept);
  }

  static List<String> _cleanStrings(Iterable<String> source) {
    final kept =
        source
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return kept;
  }

  /// 本地记住的目录可能已经不在库里了，拿服务端返回的有效目录求一次交集。
  bool _dropStalePaths() {
    if (!_pathsCacheApplicable || selectedPaths.isEmpty) return false;
    final valid = availablePaths
        .map((entry) => entry.path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    if (valid.isEmpty) return false;
    final current = _cleanStrings(selectedPaths).toSet();
    final kept = current.where(valid.contains).toList();
    if (kept.length == current.length) return false;
    if (kept.isEmpty) {
      selectedPaths.clear();
    } else {
      selectedPaths.assignAll(kept);
    }
    return true;
  }

  @override
  void onInit() {
    super.onInit();
    // `GetBuilder(init:)` 在 initState 里创建控制器，此时 framework 还处于 build 锁内。
    // 直接写 Rx（恢复排序、置 loading、拉首屏）会让已挂载的 Obx 报
    // 「markNeedsBuild called when widget tree was locked」，统一挪到首帧之后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      _restoreSort();
      _restorePaths();
      if (_pathsCacheApplicable) {
        _selectedPathsWorker = ever<List<String>>(selectedPaths, (_) {
          if (_restoringPaths) return;
          _persistPaths();
        });
      }
      // 扫描是后台任务，不订阅事件就会一直停留在旧列表
      _scanDoneOff = listenMusicScanDone(
        () => unawaited(refreshList(showLoading: false)),
      );
      unawaited(refreshList(showLoading: true));
    });
  }

  @override
  void onClose() {
    _scanDoneOff?.call();
    _scanDoneOff = null;
    _search.cancel();
    _scrollEndDebounce?.cancel();
    _selectedPathsWorker?.dispose();
    super.onClose();
  }

  void markScrolling() {
    isScrolling.value = true;
    _scrollEndDebounce?.cancel();
    _scrollEndDebounce = Timer(const Duration(milliseconds: 120), () {
      isScrolling.value = false;
    });
  }

  void toggleSelection(int id) => _selection.toggle(id);

  void startDragSelection(Offset start, {double scrollOffset = 0}) {
    _dragOrigin = start;
    _dragOriginScroll = scrollOffset;
    _dragBaseline = selectedItems.toSet();
    selectionRect.value = Rect.fromLTWH(start.dx, start.dy, 0, 0);
    selectionRectContent.value = Rect.fromLTWH(
      start.dx,
      start.dy + scrollOffset,
      0,
      0,
    );
  }

  ({double left, double top, double width, double height}) _span(
    Offset a,
    Offset b,
  ) => (
    left: a.dx < b.dx ? a.dx : b.dx,
    top: a.dy < b.dy ? a.dy : b.dy,
    width: (a.dx - b.dx).abs(),
    height: (a.dy - b.dy).abs(),
  );

  void updateDragSelection(Offset current, {double scrollOffset = 0}) {
    final origin = _dragOrigin;
    if (origin == null) return;
    final viewport = _span(origin, current);
    selectionRect.value = Rect.fromLTWH(
      viewport.left,
      viewport.top,
      viewport.width,
      viewport.height,
    );

    final content = _span(
      Offset(origin.dx, origin.dy + _dragOriginScroll),
      Offset(current.dx, current.dy + scrollOffset),
    );
    selectionRectContent.value = Rect.fromLTWH(
      content.left,
      content.top,
      content.width,
      content.height,
    );
  }

  Set<int> _mergeDragHits(Set<int> hitIds, bool additive) {
    final base = _dragBaseline ?? selectedItems.toSet();
    return additive ? (base.toSet()..addAll(hitIds)) : hitIds;
  }

  void _writeDragSelection(Set<int> next) {
    selectedItems
      ..clear()
      ..addAll(next);
    selectedItems.refresh();
  }

  void updateDragPreview(Set<int> hitIds, {required bool additive}) =>
      _writeDragSelection(_mergeDragHits(hitIds, additive));

  void applyDragSelection(
    Set<int> hitIds, {
    required bool multiModeAtStart,
    required bool additive,
  }) {
    final next = _mergeDragHits(hitIds, additive);
    _writeDragSelection(next);
    if (next.isNotEmpty && !isMultiSelectMode.value) {
      isMultiSelectMode.value = true;
    }
    if (next.isEmpty && !multiModeAtStart) {
      isMultiSelectMode.value = false;
    }
  }

  void finishDragSelection() {
    selectionRect.value = null;
    selectionRectContent.value = null;
    _dragOrigin = null;
    _dragOriginScroll = 0;
    _dragBaseline = null;
  }

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

  @override
  Future<void> switchSelectionFavorite() async {
    final ok = await applyBatchFavorite(
      ids: sortedIndexIds(selectedItems),
      makeFavorite: !allSelectedFavorited,
      onState: updateFavoriteState,
    );
    if (ok) leaveMultiSelect();
  }

  Future<void> _setFavoriteForSelection(bool next) async {
    if (next == isFavoriteList) return;
    final ok = await applyBatchFavorite(
      ids: sortedIndexIds(selectedItems),
      makeFavorite: next,
      onState: updateFavoriteState,
    );
    if (ok) leaveMultiSelect();
  }

  Future<void> favoriteSelected() => _setFavoriteForSelection(true);

  Future<void> unfavoriteSelected() => _setFavoriteForSelection(false);

  @override
  bool get insidePlaylist => (listId ?? 0) > 0;

  Future<void> _removeFromList(
    List<int> ids, {
    bool exitSelection = false,
  }) async {
    final current = listId ?? 0;
    if (current <= 0 || ids.isEmpty) return;
    try {
      await removeIndexesFromPlayList(
        listId: current,
        ids: ids,
        items: items,
        total: total,
        onRemoved: exitSelection ? leaveMultiSelect : null,
      );
    } catch (_) {
      notifyFailure(null);
    }
  }

  @override
  Future<void> removeSelectionFromPlaylist() =>
      _removeFromList(sortedIndexIds(selectedItems), exitSelection: true);

  Future<void> removeFromPlayListItem(MusicListItem item) =>
      _removeFromList(<int>[item.id]);

  @override
  Future<void> addSelectionToPlaylist() async {
    final ids = sortedIndexIds(selectedItems);
    if (ids.isEmpty) return;
    try {
      final picked = await pickMusicPlayList();
      if (picked == null) return;
      final ok = await addIndexesToPlayList(listId: picked.id, ids: ids);
      if (ok) leaveMultiSelect();
    } catch (_) {
      notifyFailure(null);
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

  @override
  Future<void> downloadSelection() =>
      _download(_selection.chosen, exitSelection: true);

  Future<void> downloadItem(MusicListItem item) =>
      _download(<MusicListItem>[item], exitSelection: false);

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
    );
    if (ok && exitSelection) leaveMultiSelect();
  }

  @override
  Future<void> deleteSelection() =>
      _delete(_selection.chosen, exitSelection: true);

  Future<void> deleteItem(MusicListItem item) =>
      _delete(<MusicListItem>[item], exitSelection: false);

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
    isFavorite: isFavoriteList,
    search: searchText.value,
    sourceList: _sourceFilter,
    sortBy: _sortByParam,
    sortOrder: _sortOrderParam,
    showLoading: showLoading,
  );

  void _applyPaging(MusicListPagedResult result) {
    final paging = result.pagination;
    total.value = paging.total;
    page.value = paging.page;
    totalPages.value = paging.totalPages;
    hasMore.value = paging.hasNextPage;
  }

  void _syncPathCatalog(MusicListPagedResult result) {
    if (selectedPaths.isEmpty) {
      _fullPathCatalog = result.validPaths;
      availablePaths.assignAll(result.validPaths);
      return;
    }
    availablePaths.assignAll(
      _fullPathCatalog.isNotEmpty ? _fullPathCatalog : result.validPaths,
    );
  }

  Future<void> refreshList({bool showLoading = false}) async {
    if (loading.value) return;
    loading.value = true;
    autoLoadFailed.value = false;
    try {
      var withLoading = showLoading;
      var reconciled = false;
      // 记住的目录若已失效，去掉后重取一次；只重取一轮，避免来回震荡
      for (var pass = 0; pass < 2; pass++) {
        _cursor = 1;
        final result = await _requestPage(_cursor, showLoading: withLoading);
        items.assignAll(result.items);
        _applyPaging(result);
        _syncPathCatalog(result);
        if (!_dropStalePaths() || reconciled) break;
        reconciled = true;
        withLoading = false;
      }
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

  /// 真翻页：整表替换，与 loadMore 的累加不同。
  Future<void> goToPage(int target) async {
    final wanted = target < 1 ? 1 : target;
    if (loading.value || loadingMore.value) return;
    if (wanted == page.value && items.isNotEmpty) return;
    loading.value = true;
    try {
      _cursor = wanted;
      final result = await _requestPage(_cursor, showLoading: false);
      items.assignAll(result.items);
      _applyPaging(result);
      autoLoadFailed.value = false;
    } finally {
      loading.value = false;
    }
  }

  Future<void> nextPage() => goToPage(page.value + 1);

  Future<void> prevPage() => goToPage(page.value - 1);

  MusicListPagingQuery buildPagingQuery() => MusicListPagingQuery(
    page: _cursor,
    pageSize: _pageSize,
    hasMore: hasMore.value,
    listType: listType,
    listId: listId,
    seriesIndexId: seriesIndexId,
    collectionId: collectionId,
    isFavorite: isFavoriteList,
    search: searchText.value,
    artists: artists.isEmpty ? null : artists.toList(),
    albums: albums.isEmpty ? null : albums.toList(),
    genres: genres.isEmpty ? null : genres.toList(),
    sourceList: selectedPaths.isEmpty
        ? null
        : selectedPaths.toList(growable: false),
    sortBy: _sortByParam,
    sortOrder: _sortOrderParam,
  );

  void setSort(MusicListSortBy by, MusicListSortOrder order) {
    if (sortBy.value == by && sortOrder.value == order) return;
    sortBy.value = by;
    sortOrder.value = order;
    _persistSort();
    unawaited(refreshList(showLoading: true));
  }

  void _toggleFilter(RxList<String> bucket, String value) {
    if (!bucket.remove(value)) bucket.add(value);
    unawaited(refreshList(showLoading: true));
  }

  void toggleArtist(String value) => _toggleFilter(artists, value);

  void toggleAlbum(String value) => _toggleFilter(albums, value);

  void toggleGenre(String value) => _toggleFilter(genres, value);

  void resetFilter() {
    artists.clear();
    albums.clear();
    genres.clear();
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

  void updateFavoriteState(int indexId, bool nextIsFavorite) {
    if (indexId <= 0) return;
    if (isFavoriteList && !nextIsFavorite) {
      items.removeWhere((entry) => entry.id == indexId);
      total.value = (total.value - 1).clamp(0, 1 << 30);
      return;
    }
    final at = items.indexWhere((entry) => entry.id == indexId);
    if (at < 0) return;
    items[at] = items[at].copyWith(isFavorite: nextIsFavorite);
  }
}
