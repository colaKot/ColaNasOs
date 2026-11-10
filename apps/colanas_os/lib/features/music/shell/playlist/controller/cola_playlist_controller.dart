import 'dart:async';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/paged_list.dart';
import '../service/cola_playlist_api_service.dart';

/// 打开歌单浮层时携带的最小信息：只存 id 与展示名，不持有列表内容。
class PlayListOverlayPayload {
  const PlayListOverlayPayload({required this.listId, required this.name});

  final int listId;
  final String name;

  bool get isValid => listId > 0 && name.trim().isNotEmpty;
}

/// 浮层开关状态。列表页与曲目页共用同一个实例，靠 GetX 注册状态协调。
class PlayListOverlayController extends GetxController {
  final Rxn<PlayListOverlayPayload> active = Rxn<PlayListOverlayPayload>();

  void open({required int listId, required String name}) {
    final payload = PlayListOverlayPayload(listId: listId, name: name);
    if (!payload.isValid) return;
    active.value = payload;
  }

  void openFromItem(PlayListItem item) =>
      open(listId: item.id, name: item.name);

  void close() => active.value = null;
}

/// 歌单列表状态。
///
/// 与合集列表共用 [PagedListLoader] / [SearchDebouncer] / [SortPreference]，
/// 差异只在接口参数名（`sortBy`）和「服务端直接给 hasNextPage」这两点。
class PlayListController extends GetxController {
  static const String keySortField = 'music_playlist_sort_field';
  static const String keySortOrder = 'music_playlist_sort_order';

  static const SortPreference _sortStore = SortPreference(
    fieldKey: keySortField,
    orderKey: keySortOrder,
  );

  final RxBool isLoading = false.obs;
  final RxBool hasMore = true.obs;
  final RxList<PlayListItem> items = <PlayListItem>[].obs;
  final RxInt page = 1.obs;
  final RxInt pageSize = 30.obs;
  final RxInt total = 0.obs;

  final RxString keyword = ''.obs;
  final RxString sortBy = 'create_time'.obs;
  final RxString sortOrder = 'desc'.obs;

  final TextEditingController searchController = TextEditingController();
  final PlayListApiService _api = PlayListApiService.instance;
  final SearchDebouncer _search = SearchDebouncer(
    const Duration(milliseconds: 450),
  );

  PagedListLoader<PlayListItem> get _loader => PagedListLoader<PlayListItem>(
    fetchPage: _requestPage,
    isBusy: () => isLoading.value,
    setBusy: (value) => isLoading.value = value,
    items: items,
    onApplied: _applyPage,
    identity: (item) => item.id,
  );

  @override
  void onInit() {
    super.onInit();
    _restoreSort();
    unawaited(refreshLists());
  }

  @override
  void onClose() {
    _search.cancel();
    searchController.dispose();
    super.onClose();
  }

  void onSearchChanged(String value) => _search.submit(value, (text) {
    keyword.value = text;
    unawaited(refreshLists());
  });

  void clearSearch() {
    keyword.value = '';
    searchController.clear();
    unawaited(refreshLists());
  }

  void setSort({required String field, required String order}) {
    final next = SortValues(
      field: field == 'name' ? 'name' : 'create_time',
      order: order == 'asc' ? 'asc' : 'desc',
    );
    final current = SortValues(field: sortBy.value, order: sortOrder.value);
    if (next.sameAs(current)) return;
    sortBy.value = next.field;
    sortOrder.value = next.order;
    _sortStore.write(next);
    unawaited(refreshLists());
  }

  void _restoreSort() {
    final saved = _sortStore.read(
      const SortValues(field: 'create_time', order: 'desc'),
    );
    sortBy.value = saved.field;
    sortOrder.value = saved.order;
  }

  Future<void> refreshLists() async {
    hasMore.value = true;
    await loadLists(pageNumber: 1, append: false);
  }

  Future<void> loadLists({required int pageNumber, required bool append}) =>
      _loader.load(pageNumber: pageNumber, append: append);

  Future<ListPage<PlayListItem>?> _requestPage(int pageNumber) async {
    final res = await _api.listLists(
      page: pageNumber,
      pageSize: pageSize.value,
      search: keyword.value,
      sortBy: sortBy.value,
      sortOrder: sortOrder.value,
    );
    if (!res.success || res.data == null) return null;
    final body = res.data!;
    final paging = body.pagination;
    return ListPage<PlayListItem>(
      items: body.items,
      page: paging.page,
      pageSize: paging.pageSize,
      total: paging.total,
      hasNextPage: paging.hasNextPage,
    );
  }

  void _applyPage(ListPage<PlayListItem> loaded) {
    total.value = loaded.total;
    page.value = loaded.page;
    pageSize.value = loaded.pageSize;
    hasMore.value = loaded.hasMore;
  }

  Future<void> loadMore() async {
    if (isLoading.value || !hasMore.value) return;
    await loadLists(pageNumber: page.value + 1, append: true);
  }

  PlayListOverlayController _overlay() =>
      Get.isRegistered<PlayListOverlayController>()
      ? Get.find<PlayListOverlayController>()
      : Get.put(PlayListOverlayController());

  void openList(PlayListItem list) => _overlay().openFromItem(list);

  void closeList() {
    if (!Get.isRegistered<PlayListOverlayController>()) return;
    Get.find<PlayListOverlayController>().close();
  }

  /// 名称类的写操作共用一条路径：去空白 → 发请求 → 成功后回第一页。
  Future<bool> _commit(
    String rawName,
    Future<({bool ok, String? message})> Function(String name) request,
  ) async {
    final name = rawName.trim();
    if (name.isEmpty) return false;
    final result = await request(name);
    if (!result.ok) return false;
    await refreshLists();
    return true;
  }

  Future<bool> createList(String name) => _commit(name, (cleaned) async {
    final res = await _api.createList(name: cleaned);
    return (ok: res.success, message: res.message);
  });

  /// 创建后直接返回新建项，供「选择模式且列表为空」时立即选中。
  Future<PlayListItem?> createListReturnItem(String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) return null;
    final res = await _api.createList(name: cleaned);
    if (!res.success || res.data == null || res.data!.id <= 0) return null;
    final created = res.data!;
    await refreshLists();
    return created;
  }

  Future<bool> updateList({required int id, required String name}) =>
      _commit(name, (cleaned) async {
        final res = await _api.updateList(id: id, name: cleaned);
        return (ok: res.success, message: res.message);
      });

  Future<bool> deleteList(int id) async {
    final res = await _api.deleteList(id);
    if (!res.success) return false;
    if (Get.isRegistered<PlayListOverlayController>()) {
      final overlay = Get.find<PlayListOverlayController>();
      if (overlay.active.value?.listId == id) overlay.close();
    }
    await refreshLists();
    return true;
  }
}
