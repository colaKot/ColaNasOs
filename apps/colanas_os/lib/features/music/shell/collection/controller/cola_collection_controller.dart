import 'dart:async';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/paged_list.dart';
import '../models/cola_collection_model.dart';
import '../service/cola_collection_api_service.dart';

/// 合集列表：翻页、检索、排序和增删改。
///
/// 分页状态流转交给 [PagedListLoader]，搜索节流交给 [SearchDebouncer]，
/// 排序偏好交给 [SortPreference]；这里只描述合集接口的参数映射，
/// 以及「操作成功后回到第一页」这类业务决定。
class MusicCollectionController extends GetxController {
  static const String keySortField = 'music_collection_sort_field';
  static const String keySortOrder = 'music_collection_sort_order';

  static const SortPreference _sortStore = SortPreference(
    fieldKey: keySortField,
    orderKey: keySortOrder,
  );

  final MusicCollectionApiService _api = MusicCollectionApiService();

  final RxBool isLoading = false.obs;
  final RxBool hasMore = true.obs;
  final RxList<MusicCollectionItem> items = <MusicCollectionItem>[].obs;
  final RxInt page = 1.obs;
  final RxInt pageSize = 20.obs;
  final RxInt total = 0.obs;
  final RxString keyword = ''.obs;
  final RxString sortField = 'create_time'.obs;
  final RxString sortOrder = 'desc'.obs;

  final TextEditingController searchController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final Rxn<MusicCollectionItem> activeCollection = Rxn<MusicCollectionItem>();

  final SearchDebouncer _search = SearchDebouncer(
    const Duration(milliseconds: 500),
  );

  SortValues get _currentSort =>
      SortValues(field: sortField.value, order: sortOrder.value);

  /// loader 本身没有状态，按取即用；持有它的控制器才拥有 Rx 字段。
  PagedListLoader<MusicCollectionItem> get _loader =>
      PagedListLoader<MusicCollectionItem>(
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
    scrollController.addListener(_onScroll);
    _restoreSort();
    unawaited(refreshCollections());
  }

  @override
  void onClose() {
    _search.cancel();
    searchController.dispose();
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    super.onClose();
  }

  void _onScroll() =>
      triggerLoadMoreOnScroll(scrollController, () => unawaited(loadMore()));

  void onSearchChanged(String value) => _search.submit(value, (text) {
    keyword.value = text;
    unawaited(refreshCollections());
  });

  void clearSearch() {
    keyword.value = '';
    searchController.clear();
    unawaited(refreshCollections());
  }

  void setSort({required String field, required String order}) {
    final next = SortValues(field: field, order: order);
    if (next.sameAs(_currentSort)) return;
    sortField.value = next.field;
    sortOrder.value = next.order;
    _sortStore.write(next);
    unawaited(refreshCollections());
  }

  void _restoreSort() {
    final saved = _sortStore.read(
      const SortValues(field: 'create_time', order: 'desc'),
    );
    sortField.value = saved.field;
    sortOrder.value = saved.order;
  }

  Future<void> refreshCollections() async {
    hasMore.value = true;
    if (scrollController.hasClients) scrollController.jumpTo(0);
    await loadCollections(pageNumber: 1, append: false);
  }

  Future<void> loadCollections({
    required int pageNumber,
    required bool append,
  }) => _loader.load(pageNumber: pageNumber, append: append);

  Future<ListPage<MusicCollectionItem>?> _requestPage(int pageNumber) async {
    final res = await _api.listCollections(
      page: pageNumber,
      pageSize: pageSize.value,
      keyword: keyword.value,
      sortField: sortField.value,
      sortOrder: sortOrder.value,
    );
    if (!res.success || res.data == null) return null;
    final body = res.data!;
    return ListPage<MusicCollectionItem>(
      items: body.items,
      page: body.page,
      pageSize: body.pageSize,
      total: body.total,
    );
  }

  void _applyPage(ListPage<MusicCollectionItem> loaded) {
    total.value = loaded.total;
    page.value = loaded.page;
    pageSize.value = loaded.pageSize;
    hasMore.value = loaded.hasMore;
  }

  Future<void> loadMore() async {
    if (isLoading.value || !hasMore.value) return;
    await loadCollections(pageNumber: page.value + 1, append: true);
  }

  void openCollection(MusicCollectionItem collection) =>
      activeCollection.value = collection;

  void closeCollection() => activeCollection.value = null;

  /// 名称与路径都去掉空白；任一为空就不发请求。
  ({String name, List<String> paths})? _cleanInput(
    String name,
    List<String> pathList,
  ) {
    final title = name.trim();
    final paths = pathList
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (title.isEmpty || paths.isEmpty) return null;
    return (name: title, paths: paths);
  }

  Future<bool> _commit(
    Future<({bool ok, String? message})> Function() request,
  ) async {
    final result = await request();
    if (!result.ok) {
      reportMutationFailure(result.message);
      return false;
    }
    await refreshCollections();
    return true;
  }

  Future<bool> createCollection({
    required String name,
    required List<String> pathList,
  }) {
    final input = _cleanInput(name, pathList);
    if (input == null) return Future<bool>.value(false);
    return _commit(() async {
      final res = await _api.createCollection(
        name: input.name,
        pathList: input.paths,
      );
      return (ok: res.success, message: res.message);
    });
  }

  Future<bool> updateCollection({
    required int id,
    required String name,
    required List<String> pathList,
  }) {
    final input = _cleanInput(name, pathList);
    if (input == null) return Future<bool>.value(false);
    return _commit(() async {
      final res = await _api.updateCollection(
        id: id,
        name: input.name,
        pathList: input.paths,
      );
      return (ok: res.success, message: res.message);
    });
  }

  Future<bool> deleteCollection(int id) async {
    final res = await _api.deleteCollection(id);
    if (!res.success) return false;
    if (activeCollection.value?.id == id) closeCollection();
    await refreshCollections();
    return true;
  }
}
