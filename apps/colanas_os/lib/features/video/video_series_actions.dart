import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_card.dart';
import 'video_item_actions.dart';
import 'video_series_detail_page.dart';

/// 剧 / 季 / 集的右键菜单。
///
/// 剧卡和季卡都不是 `VideoItem`（一部剧是一堆文件、一季是一堆集），所以不能直接
/// 用 `videoItemMenuEntries`；但动作最后落到的是同一批接口：
/// - 标记已看：`/video/watch`（剧级让服务端 `expandSeries`，季级直接给本季的 id）
/// - 删除：`/video/items/delete`（给要删的那几个 id）
/// 单集本身就是一条 `VideoItem`，菜单原样复用影片列表那一套（见详情页选集方块）。
///
/// **刮削没放进剧级菜单**：服务端刮削是「一条一集」的串行网络请求，40 集的剧
/// 点一次就是 40 次网络往返，很容易撞 30s 超时；整剧刮削请走设置里的批量入口。

/// 右键区域：菜单项需要先异步算（剧卡得先拉全集，才知道是不是已经全看完），
/// 算完再在鼠标位置弹出 —— `NasContextMenuRegion` 只支持同步菜单项。
class NasAsyncMenuRegion extends StatelessWidget {
  const NasAsyncMenuRegion({
    super.key,
    required this.entries,
    required this.child,
  });

  final Future<List<NasMenuEntry>> Function() entries;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) async {
        final pos = d.globalPosition;
        final items = await entries();
        if (!context.mounted || items.isEmpty) return;
        await showNasContextMenu(context, pos, items);
      },
      child: child,
    );
  }
}

/// 一部剧的全部集（拉不到就返回空表，调用方自行退到 `coverId`）。
Future<List<VideoItem>> loadSeriesEpisodes(
  String name, {
  String? libraryId,
}) async {
  try {
    final res = await ApiSession.instance.client.videoSeriesItems(
      name: name,
      libraryId: libraryId,
      // 服务端上限 2000：一次拿全，删除 / 计数都靠这份
      limit: 2000,
    );
    return res.items;
  } catch (_) {
    return const [];
  }
}

/// 剧卡右键菜单（整部剧口径）。
Future<List<NasMenuEntry>> seriesMenuEntries(
  BuildContext context,
  VideoSeriesItem item, {
  String? libraryId,
  VoidCallback? onChanged,
}) async {
  final eps = await loadSeriesEpisodes(item.name, libraryId: libraryId);
  final total = eps.isEmpty ? item.episodes : eps.length;
  final allWatched = eps.isNotEmpty && eps.every((e) => e.watched);

  return [
    NasMenuEntry(
      label: tr(
        allWatched ? 'video.action.markUnwatched' : 'video.action.markTvWatched',
      ),
      icon: allWatched ? Icons.remove_done : Icons.done_all,
      onSelected: () => markVideos(
        context,
        eps.map((e) => e.id).toList(),
        watched: !allWatched,
        expandSeries: true,
        // 拉不到集数时退回「封面那一集 + 服务端展开整剧」
        fallbackId: item.coverId,
        count: total,
        onChanged: onChanged,
      ),
    ),
    NasMenuEntry(
      label: tr('video.action.locateFile'),
      icon: Icons.open_in_new,
      onSelected: () => openVideoSeries(
        context,
        name: item.name,
        coverId: item.coverId,
        libraryId: libraryId,
        headers: videoArtHeaders,
      ),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('video.action.deleteSeries', {'count': '$total'}),
      icon: Icons.delete_outline,
      danger: true,
      // 集数拉不到就不给删：宁可什么都不做，也不能删错东西
      // （`NasMenuEntry` 的置灰规则就是 onSelected 为 null）
      onSelected: eps.isEmpty
          ? null
          : () => deleteVideos(
              context,
              eps.map((e) => e.id).toList(),
              onChanged: onChanged,
            ),
    ),
  ];
}

/// 季卡右键菜单（本季口径，不展开到整部剧）。
List<NasMenuEntry> seasonMenuEntries(
  BuildContext context, {
  required List<VideoItem> episodes,
  VoidCallback? onChanged,
}) {
  final ids = episodes.map((e) => e.id).toList();
  final allWatched = episodes.isNotEmpty && episodes.every((e) => e.watched);

  return [
    NasMenuEntry(
      label: tr(
        allWatched ? 'video.action.markUnwatched' : 'video.action.markWatched',
      ),
      icon: allWatched ? Icons.remove_done : Icons.done_all,
      onSelected: ids.isEmpty
          ? null
          : () => markVideos(
              context,
              ids,
              watched: !allWatched,
              onChanged: onChanged,
            ),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('video.action.deleteSeason', {'count': '${ids.length}'}),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: ids.isEmpty
          ? null
          : () => deleteVideos(context, ids, onChanged: onChanged),
    ),
  ];
}

/// 批量标记已看 / 未看。`expandSeries` 只给剧级用（季级绝不能展开，否则会误标整剧）。
Future<void> markVideos(
  BuildContext context,
  List<String> ids, {
  required bool watched,
  bool expandSeries = false,
  String? fallbackId,
  int? count,
  VoidCallback? onChanged,
}) async {
  final fallback = (fallbackId ?? '').trim();
  final targets = ids.isNotEmpty ? ids : [if (fallback.isNotEmpty) fallback];
  if (targets.isEmpty) return;
  final expand = expandSeries && ids.isEmpty;
  try {
    await ApiSession.instance.client.videoWatchMark(
      body: VideoWatchBody(
        ids: targets,
        watched: watched,
        expandSeries: expand,
      ),
    );
    if (!context.mounted) return;
    NasSnack.show(
      context,
      tr(watched ? 'video.watch.marked' : 'video.watch.unmarked', {
        'count': '${count ?? targets.length}',
      }),
    );
    onChanged?.call();
  } catch (e) {
    if (!context.mounted) return;
    NasSnack.show(context, '$e');
  }
}

/// 批量删除（先确认回收站 / 永久删除）。
///
/// 集数少就一次同步请求删完；整季 / 整部剧可能有几十上百集（短剧尤其多），
/// 同步删容易撞 30s 超时，改走服务端后台任务 + 一个挂着的进度框。
Future<void> deleteVideos(
  BuildContext context,
  List<String> ids, {
  VoidCallback? onChanged,
}) async {
  if (ids.isEmpty) return;
  final toTrash = await confirmVideoDelete(context, count: ids.length);
  if (toTrash == null || !context.mounted) return;
  if (ids.length <= 8) {
    final ok = await deleteVideoItemsNow(context, ids, toTrash: toTrash);
    if (ok) onChanged?.call();
    return;
  }
  final ok = await _deleteByTask(context, ids, toTrash: toTrash);
  if (ok) onChanged?.call();
}

/// 后台任务删除：轮询到 done / failed / canceled 为止，超时也不打断（服务端还在删）。
Future<bool> _deleteByTask(
  BuildContext context,
  List<String> ids, {
  required bool toTrash,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context, rootNavigator: true);
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BulkDeleteDialog(),
    ).then((_) => dialogOpen = false),
  );
  try {
    final res = await ApiSession.instance.client.videoItemsDeleteTask(
      body: VideoDeleteItemsBody(ids: ids, permanent: !toTrash),
    );
    final taskId = '${res['taskId'] ?? ''}';
    if (taskId.isEmpty) throw StateError('empty taskId');
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final t = await ApiSession.instance.client.tasksGet(id: taskId);
      final state = '${t['state'] ?? ''}';
      if (state == 'done' || state == 'failed' || state == 'canceled') {
        final done = (t['done_count'] as num?)?.toInt() ?? ids.length;
        if (state == 'failed') {
          NasSnack.showOn(messenger, '${t['error'] ?? state}');
          return false;
        }
        NasSnack.showOn(
          messenger,
          tr(
            toTrash ? 'video.dup.deleteDone' : 'video.dup.deleteDonePermanent',
            {'count': '$done'},
          ),
        );
        return state == 'done';
      }
    }
    // 超时但任务仍在跑：当成已提交，让调用方照常刷新
    return true;
  } catch (e) {
    NasSnack.showOn(messenger, '$e');
    return false;
  } finally {
    if (dialogOpen && nav.canPop()) nav.pop();
  }
}

class _BulkDeleteDialog extends StatelessWidget {
  const _BulkDeleteDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 12),
              Text(tr('video.dup.deleting')),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            tr('video.dup.deletingHint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
