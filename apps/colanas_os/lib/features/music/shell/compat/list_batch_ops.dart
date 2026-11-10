/// 曲目列表的批量操作公共实现。
///
/// 主列表与子列表各自有一套「多选 → 收藏 / 歌单 / 下载 / 删除」，
/// 两边的路径解析、确认弹窗、删除落库、下载提交此前是逐行相同的副本。
/// 这里收成与页面无关的工具：控制器只负责把选中项交进来，以及删除成功后
/// 自己要不要补一页这类差异化决定。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/app_navigator.dart';

import '../favorite/service/cola_favorite_api_service.dart';
import '../list/models/cola_list_models.dart';
import '../list/service/cola_list_api_service.dart';
import '../playlist/service/cola_playlist_api_service.dart';
import '../playlist/view/cola_playlist_view.dart';
import 'cola_api_controller.dart';
import 'getx.dart';
import 'host.dart';

/// 一条曲目在磁盘上的完整路径：优先用服务端给的 fullPath，否则拼目录 + 文件名。
String musicFilePathOf(MusicListItem item) {
  final full = item.fullPath.trim();
  if (full.isNotEmpty) return full;
  final base = item.path.trim();
  final name = item.filename.trim();
  return base.isNotEmpty && name.isNotEmpty ? '$base/$name' : '';
}

/// 去重后的路径列表，排序保证确认弹窗里的顺序稳定。
List<String> musicPathsOf(Iterable<MusicListItem> entries) {
  final unique = <String>{};
  for (final entry in entries) {
    final path = musicFilePathOf(entry);
    if (path.isNotEmpty) unique.add(path);
  }
  return unique.toList()..sort();
}

/// 选中的 indexId：丢掉非法值并排序，让批量请求可复现。
List<int> sortedIndexIds(Set<int> selected) =>
    (selected.where((id) => id > 0).toSet().toList()..sort());

/// 删除操作要同时知道路径（发给服务端）和 id（从本地列表移除）。
class MusicDeleteTargets {
  const MusicDeleteTargets({required this.paths, required this.ids});

  final List<String> paths;
  final Set<int> ids;

  bool get isEmpty => paths.isEmpty;
}

MusicDeleteTargets musicDeleteTargetsOf(Iterable<MusicListItem> entries) {
  final ids = <int>{};
  final paths = <String>{};
  for (final entry in entries) {
    final path = musicFilePathOf(entry);
    if (path.isEmpty) continue;
    paths.add(path);
    if (entry.id > 0) ids.add(entry.id);
  }
  return MusicDeleteTargets(paths: paths.toList()..sort(), ids: ids);
}

/// 删除确认：≤5 条列出路径，更多只给数量；回收站选项只在 shell 可用时点亮。
Future<bool?> confirmMusicDeletion(List<String> paths) async {
  final context = Get.context;
  if (context == null || paths.isEmpty) return null;

  final count = paths.length;
  final content = count <= 5
      ? <String>[
          'book_delete_confirm_list'.tr,
          ...paths.map(
            (path) => 'book_delete_confirm_path_line'.trParams({'path': path}),
          ),
        ].join('\n')
      : 'book_delete_confirm_count'.trParams({'count': '$count'});

  final shellReady = ApiController.instance.state.shellSupported;
  var recycle = shellReady;

  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => StatefulBuilder(
      builder: (builderContext, setState) => DialogUtil.createAlertDialog(
        title: Text('need_confirm'.tr),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(content),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                CustomCheckbox(
                  value: recycle,
                  onChanged: shellReady
                      ? (value) => setState(() => recycle = value ?? false)
                      : null,
                  isCircle: false,
                ),
                const SizedBox(width: 8),
                Text(
                  'put_in_recycle_bin'.tr,
                  style: TextStyle(
                    color: shellReady
                        ? null
                        : Theme.of(builderContext).textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('cancel'.tr),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(recycle),
            child: Text('ok'.tr),
          ),
        ],
      ),
    ),
  );
}

/// 删除落库并同步本地列表。失败时弹错误框，不改动任何一项。
Future<bool> performMusicDeletion({
  required List<String> paths,
  required Set<int> removeIds,
  required bool recycle,
  required RxList<MusicListItem> items,
  required RxInt total,
  VoidCallback? onRemoved,
}) async {
  if (paths.isEmpty) return false;
  try {
    final reply = await MusicListApiService.instance.deleteEntries(
      paths,
      recycle: recycle,
    );
    if (!reply.success) {
      DialogUtil.showErrorDialog(
        title: 'error'.tr,
        message: reply.message ?? 'operation_failed'.tr,
      );
      return false;
    }
  } catch (_) {
    DialogUtil.showErrorDialog(
      title: 'error'.tr,
      message: 'operation_failed'.tr,
    );
    return false;
  }

  if (removeIds.isNotEmpty) {
    items.removeWhere((entry) => removeIds.contains(entry.id));
    total.value = (total.value - removeIds.length).clamp(0, 1 << 30);
  }
  ToastUtil.show('delete_success'.tr);
  onRemoved?.call();
  return true;
}

/// 把路径交给全局下载控制器；首次使用时注册为常驻实例。
Future<void> submitMusicDownload(List<String> paths) async {
  if (paths.isEmpty) return;
  if (!Get.isRegistered<DownloadController>()) {
    Get.put(DownloadController(), permanent: true);
  }
  await Get.find<DownloadController>().handleDownload(paths);
}

/// 弹出歌单选择浮层，返回用户选中的歌单；取消返回 null。
Future<PlayListItem?> pickMusicPlayList() {
  // ⚠️ 不能用 `Get.context`：项目是 `MaterialApp` 不是 `GetMaterialApp`，
  // 它恒为 null ⇒ 之前「多选 → 加入歌单」点了完全没反应（也不报错）。
  // 用全局 Navigator 的 context 兜底。
  final context = Get.context ?? appNavigatorContext;
  if (context == null) return Future<PlayListItem?>.value(null);
  return showDialog<PlayListItem>(
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
}

/// 批量收藏：成功后逐条回写本地状态并给反馈。
Future<bool> applyBatchFavorite({
  required List<int> ids,
  required bool makeFavorite,
  required void Function(int id, bool next) onState,
}) async {
  if (ids.isEmpty) return false;
  final ok = await MusicFavoriteApiService.instance.batchFavorite(
    ids,
    makeFavorite,
  );
  if (!ok) {
    ToastUtil.show('operation_failed'.tr);
    return false;
  }
  for (final id in ids) {
    onState(id, makeFavorite);
  }
  ToastUtil.show('operation_success'.tr);
  return true;
}

/// 批量把曲目加入歌单；成功状态由调用方决定要不要退出多选。
Future<bool> addIndexesToPlayList({
  required int listId,
  required List<int> ids,
}) async {
  final reply = await PlayListApiService.instance.addIndexes(
    listId: listId,
    indexIds: ids,
  );
  ToastUtil.show(
    reply.success
        ? 'operation_success'.tr
        : (reply.message ?? 'operation_failed'.tr),
  );
  return reply.success;
}

/// 批量从歌单移除；成功时把本地条目摘掉并修正总数。
Future<bool> removeIndexesFromPlayList({
  required int listId,
  required List<int> ids,
  required RxList<MusicListItem> items,
  required RxInt total,
  VoidCallback? onRemoved,
}) async {
  final reply = await PlayListApiService.instance.removeIndexes(
    listId: listId,
    indexIds: ids,
  );
  if (!reply.success) {
    ToastUtil.show(reply.message ?? 'operation_failed'.tr);
    return false;
  }
  final before = items.length;
  items.removeWhere((entry) => ids.contains(entry.id));
  final removed = before - items.length;
  if (removed > 0) total.value = (total.value - removed).clamp(0, 1 << 30);
  ToastUtil.show('operation_success'.tr);
  onRemoved?.call();
  return true;
}

/// 多选状态的单一实现：选中集合、多选开关、当前列表三者联动。
class MusicSelection {
  MusicSelection({
    required this.selected,
    required this.multiMode,
    required this.items,
  });

  final RxSet<int> selected;
  final RxBool multiMode;
  final RxList<MusicListItem> items;

  bool get hasSelection => selected.isNotEmpty;
  int get selectedCount => selected.length;

  void toggle(int id) {
    if (id <= 0) return;
    if (!selected.add(id)) selected.remove(id);
    if (selected.isEmpty) {
      clear();
      return;
    }
    if (!multiMode.value) multiMode.value = true;
  }

  void clear() {
    multiMode.value = false;
    selected.clear();
  }

  List<int> get currentIds =>
      items.map((entry) => entry.id).where((id) => id > 0).toList();

  bool get allSelected {
    final ids = currentIds;
    return ids.isNotEmpty && ids.every(selected.contains);
  }

  void toggleAll() {
    final ids = currentIds;
    if (ids.isEmpty) return;
    if (allSelected) {
      selected.removeAll(ids);
      clear();
      return;
    }
    selected.addAll(ids);
    if (!multiMode.value) multiMode.value = true;
  }

  bool get allFavorited {
    final chosen = items.where((entry) => selected.contains(entry.id)).toList();
    return chosen.isNotEmpty && chosen.every((entry) => entry.isFavorite);
  }

  List<MusicListItem> get chosen =>
      items.where((entry) => selected.contains(entry.id)).toList();
}
