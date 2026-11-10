/// 音乐壳列表控制器的通用零件。
///
/// 各列表页（合集 / 歌单 / 曲目 / 专辑歌手）以前各写一整套：加载标志防重入、
/// 拼页去重、按 total 推 hasMore、搜索防抖、排序偏好读写、滚动触底。
/// 这些代码彼此只差接口名，改一处要同步四个地方。这里把它们收成与业务无关的
/// 小零件，控制器只负责「怎么请求」和「请求结果怎么映射到自己的字段」。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'cola_dialog_util.dart';
import 'getx.dart';
import 'host.dart' show CacheManager;

/// 一页数据的统一形状。
///
/// [hasNextPage] 由服务端明确给出时优先采用；否则按 `total / pageSize`
/// 推算（与合集列表原有的推算方式一致：total 为 0 视为没有下一页）。
class ListPage<T> {
  const ListPage({
    required this.items,
    required this.page,
    required this.pageSize,
    this.total = 0,
    this.hasNextPage,
  });

  final List<T> items;
  final int page;
  final int pageSize;
  final int total;
  final bool? hasNextPage;

  bool get hasMore {
    final explicit = hasNextPage;
    if (explicit != null) return explicit;
    if (total <= 0) return false;
    final size = pageSize <= 0 ? 20 : pageSize;
    return page < (total + size - 1) ~/ size;
  }
}

/// 分页加载骨架：`防重入 → 请求 → 合并 → 回写 → 复位`。
///
/// 不持有任何 Rx 字段，状态读写通过回调注入，因此不同控制器可以保留
/// 自己那套对外字段名（UI 已经在用），只把方法体换成本类调用。
class PagedListLoader<T> {
  PagedListLoader({
    required this.fetchPage,
    required this.isBusy,
    required this.setBusy,
    required this.items,
    required this.onApplied,
    this.identity,
  });

  /// 返回 null 表示请求失败或无数据，调用方保持原状
  final Future<ListPage<T>?> Function(int pageNumber) fetchPage;
  final bool Function() isBusy;
  final void Function(bool value) setBusy;
  final RxList<T> items;
  final void Function(ListPage<T> page) onApplied;

  /// 追加时用它判重；不提供则直接拼接
  final Object? Function(T item)? identity;

  Future<void> load({required int pageNumber, required bool append}) async {
    if (isBusy()) return;
    setBusy(true);
    try {
      final page = await fetchPage(pageNumber);
      if (page == null) return;
      _merge(page, append);
      onApplied(page);
    } finally {
      setBusy(false);
    }
  }

  void _merge(ListPage<T> page, bool append) {
    if (!append) {
      items.assignAll(page.items);
      return;
    }
    final keyOf = identity;
    if (keyOf == null) {
      items.addAll(page.items);
      return;
    }
    final seen = items.map(keyOf).toSet();
    for (final item in page.items) {
      if (seen.add(keyOf(item))) items.add(item);
    }
  }
}

/// 排序偏好的本地读写。只接受白名单里的值，避免缓存被写坏后界面出现越界状态。
class SortPreference {
  const SortPreference({
    required this.fieldKey,
    required this.orderKey,
    this.allowedFields = const <String>['name', 'create_time'],
    this.allowedOrders = const <String>['asc', 'desc'],
  });

  final String fieldKey;
  final String orderKey;
  final List<String> allowedFields;
  final List<String> allowedOrders;

  SortValues read(SortValues defaults) {
    final field = CacheManager().getString(fieldKey);
    final order = CacheManager().getString(orderKey);
    return SortValues(
      field: field != null && allowedFields.contains(field)
          ? field
          : defaults.field,
      order: order != null && allowedOrders.contains(order)
          ? order
          : defaults.order,
    );
  }

  void write(SortValues values) {
    CacheManager().setString(fieldKey, values.field);
    CacheManager().setString(orderKey, values.order);
  }
}

class SortValues {
  const SortValues({required this.field, required this.order});

  final String field;
  final String order;

  bool sameAs(SortValues other) => other.field == field && other.order == order;
}

/// 搜索输入防抖。定时器只保留最后一个，[cancel] 同时供 onClose 使用。
class SearchDebouncer {
  SearchDebouncer([this.latency = const Duration(milliseconds: 450)]);

  final Duration latency;
  Timer? _timer;

  bool get isActive => _timer?.isActive ?? false;

  void submit(String text, void Function(String keyword) run) {
    if (isActive) cancel();
    final keyword = text.trim();
    _timer = Timer(latency, () => run(keyword));
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 滚动到离底部 [threshold] 像素时请求下一页。
void triggerLoadMoreOnScroll(
  ScrollController controller,
  VoidCallback loadMore, {
  double threshold = 200,
}) {
  if (!controller.hasClients) return;
  final position = controller.position;
  if (position.maxScrollExtent <= 0) return;
  if (position.pixels >= position.maxScrollExtent - threshold) loadMore();
}

/// 统一的失败提示。业务失败时把服务端 message 交给调用方决定要不要弹，
/// 这里只负责弹窗本身，避免每个 CRUD 方法都写一遍同样的三行。
void reportMutationFailure(String? message) {
  if (message == null || message.isEmpty) return;
  DialogUtil.showInfoDialog(title: 'tip'.tr, content: message);
}
