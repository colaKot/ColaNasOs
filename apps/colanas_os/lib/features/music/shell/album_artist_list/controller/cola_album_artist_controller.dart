import 'dart:async';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../compat/paged_list.dart';
import '../../list/models/cola_list_models.dart';
import '../../list/service/cola_list_api_service.dart';
import '../../playlist/service/cola_playlist_api_service.dart';
import '../../playlist/view/cola_playlist_view.dart';
import '../models/cola_album_artist_models.dart';
import '../service/cola_album_artist_api_service.dart';

enum AlbumArtistListSortBy { count, name }

enum AlbumArtistListSortOrder { asc, desc }

/// 专辑 / 歌手聚合列表。
///
/// 同一个控制器按 [keyType] 切换两种聚合，排序用枚举而不是裸字符串；
/// 翻页请求的参数组装收敛到 [_requestPage]，刷新与追加只负责各自的游标
/// 和失败标志。扫描完成后通过 `listenMusicScanDone` 静默重取一次。
class AlbumArtistListController extends GetxController {
  AlbumArtistListController({
    required this.keyType,
    this.initialSortBy = AlbumArtistListSortBy.count,
    this.initialSortOrder = AlbumArtistListSortOrder.desc,
  });

  final String keyType;
  final AlbumArtistListSortBy initialSortBy;
  final AlbumArtistListSortOrder initialSortOrder;

  final RxList<AlbumArtistGroupItem> items = <AlbumArtistGroupItem>[].obs;
  final RxBool loading = false.obs;
  final RxBool loadingMore = false.obs;
  final RxBool hasMore = true.obs;
  final RxBool autoLoadFailed = false.obs;

  final RxInt total = 0.obs;
  final RxString searchText = ''.obs;

  final RxList<MusicListPathItem> availablePaths = <MusicListPathItem>[].obs;
  final RxList<String> selectedPaths = <String>[].obs;

  final Rx<AlbumArtistListSortBy> sortBy = AlbumArtistListSortBy.count.obs;
  final Rx<AlbumArtistListSortOrder> sortOrder =
      AlbumArtistListSortOrder.desc.obs;

  static const int _pageSize = 30;
  static const int _maxIndexPages = 200;

  int _page = 1;
  final SearchDebouncer _search = SearchDebouncer(
    const Duration(milliseconds: 400),
  );
  void Function()? _scanDoneOff;

  List<String>? get _sourceFilter =>
      selectedPaths.isEmpty ? null : selectedPaths.toList();

  String get _sortByParam => switch (sortBy.value) {
    AlbumArtistListSortBy.count => 'count',
    AlbumArtistListSortBy.name => 'name',
  };

  String get _sortOrderParam => switch (sortOrder.value) {
    AlbumArtistListSortOrder.asc => 'asc',
    AlbumArtistListSortOrder.desc => 'desc',
  };

  @override
  void onInit() {
    super.onInit();
    sortBy.value = initialSortBy;
    sortOrder.value = initialSortOrder;
    _scanDoneOff = listenMusicScanDone(
      () => unawaited(refreshList(showLoading: false)),
    );
    unawaited(refreshList(showLoading: true));
  }

  @override
  void onClose() {
    _scanDoneOff?.call();
    _scanDoneOff = null;
    _search.cancel();
    super.onClose();
  }

  String get badgeLabel => keyType.trim().toLowerCase() == 'artist'
      ? 'music_menu_library_artists'.tr
      : 'music_menu_library_albums'.tr;

  void setSort(AlbumArtistListSortBy by, AlbumArtistListSortOrder order) {
    if (sortBy.value == by && sortOrder.value == order) return;
    sortBy.value = by;
    sortOrder.value = order;
    unawaited(refreshList(showLoading: false));
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
    if (searchText.value.isEmpty) return;
    searchText.value = '';
    unawaited(refreshList(showLoading: false));
  }

  Future<AlbumArtistListPagedResult> _requestPage(
    int pageNumber, {
    required bool showLoading,
  }) => AlbumArtistListApiService.instance.listPaged(
    keyType: keyType,
    page: pageNumber,
    pageSize: _pageSize,
    search: searchText.value,
    sourceList: _sourceFilter,
    sortBy: _sortByParam,
    sortOrder: _sortOrderParam,
    showLoading: showLoading,
  );

  void _applyPage(AlbumArtistListPagedResult result) {
    total.value = result.pagination.total;
    hasMore.value = result.pagination.hasNextPage;
    availablePaths.assignAll(result.validPaths);
  }

  /// 回到第一页。失败标志只在这里清，自动续页的失败单独记在 [autoLoadFailed]。
  Future<void> refreshList({bool showLoading = false}) async {
    loading.value = true;
    autoLoadFailed.value = false;
    try {
      _page = 1;
      final result = await _requestPage(_page, showLoading: showLoading);
      items.assignAll(result.items);
      _applyPage(result);
    } finally {
      loading.value = false;
    }
  }

  /// 追加一页。自动触底失败时留一个标志，让视图给出可重试的提示。
  Future<void> loadMore({required bool fromAuto}) async {
    if (loadingMore.value || loading.value || !hasMore.value) return;
    loadingMore.value = true;
    try {
      final next = _page + 1;
      final result = await _requestPage(next, showLoading: false);
      _page = next;
      items.addAll(result.items);
      _applyPage(result);
      autoLoadFailed.value = false;
    } catch (_) {
      if (fromAuto) autoLoadFailed.value = true;
      rethrow;
    } finally {
      loadingMore.value = false;
    }
  }

  /// 把一个聚合分组里的曲目批量加入歌单：先选歌单，再按分页把 indexId 收齐。
  /// context 由调用方传入：项目用 MaterialApp 而非 GetMaterialApp，
  /// `Get.context` 恒为 null，右键「加入歌单」会静默失败（2026-11-09）。
  Future<void> addToPlayList(
    AlbumArtistGroupItem group,
    BuildContext context,
  ) async {
    if (group.name.trim().isEmpty) return;
    try {
      final target = await _pickPlayList(context);
      if (target == null) return;
      final ids = await _collectIndexIds(group);
      if (ids.isEmpty) return;
      final res = await PlayListApiService.instance.addIndexes(
        listId: target.id,
        indexIds: ids,
      );
      ToastUtil.show(
        res.success
            ? 'operation_success'.tr
            : (res.message ?? 'operation_failed'.tr),
      );
    } catch (_) {
      ToastUtil.show('operation_failed'.tr);
    }
  }

  Future<PlayListItem?> _pickPlayList(BuildContext context) =>
      showDialog<PlayListItem>(
        context: context,
        barrierDismissible: true,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
            child: const PlayListListView(selectionMode: true),
          ),
        ),
      );

  Future<List<int>> _collectIndexIds(AlbumArtistGroupItem group) async {
    final name = group.name.trim();
    if (name.isEmpty) return const <int>[];
    const batchSize = 200;
    final collected = <int>{};

    for (var pageNo = 1; pageNo <= _maxIndexPages; pageNo++) {
      final result = await MusicListApiService.instance.listPaged(
        page: pageNo,
        pageSize: batchSize,
        artists: group.isArtist ? <String>[name] : null,
        albums: group.isAlbum ? <String>[name] : null,
        sourceList: _sourceFilter,
        showLoading: pageNo == 1,
      );
      for (final item in result.items) {
        if (item.id > 0) collected.add(item.id);
      }
      final reachedCount =
          group.indexCount > 0 && collected.length >= group.indexCount;
      if (!result.pagination.hasNextPage || reachedCount) break;
    }

    return collected.toList()..sort();
  }
}
