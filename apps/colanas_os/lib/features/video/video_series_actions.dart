import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'series_display.dart';
import 'video_card.dart';
import 'video_item_actions.dart';
import 'video_scrape_dialogs.dart';
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
  final ids = eps.map((e) => e.id).toList();
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
    // 刮削类的四项跟影片列表对齐；剧级是「对这一部的每一集都做」，
    // 拉不到集数就没法定位到具体文件，直接置灰。
    NasMenuEntry(
      label: tr('video.action.scrape'),
      icon: Icons.auto_awesome_outlined,
      onSelected: ids.isEmpty
          ? null
          : () => scrapeVideos(context, ids, onChanged: onChanged),
    ),
    NasMenuEntry(
      label: tr('video.action.matchTmdb'),
      icon: Icons.search,
      onSelected: ids.isEmpty
          ? null
          : () => matchSeries(context, eps, item, onChanged: onChanged),
    ),
    NasMenuEntry(
      label: tr('video.action.scrapeCleanup'),
      icon: Icons.cleaning_services_outlined,
      onSelected: ids.isEmpty
          ? null
          : () => cleanupVideos(context, ids, onChanged: onChanged),
    ),
    NasMenuEntry(
      label: tr('video.action.excludeScrapeSeries'),
      icon: Icons.block,
      onSelected: ids.isEmpty
          ? null
          : () => excludeVideos(context, ids, onChanged: onChanged),
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

// ---------------------------------------------------------------- 剧级刮削

/// 刮削整部剧。
///
/// 服务端的 `/video/scrape/batch` 是**同步串行**的（一条一次网络请求），
/// 一次性丢几十条进去很容易撞 30s 超时，所以按 12 条一批分批调，边跑边报进度。
/// `mode: auto` 与影片卡上的「刮削影片信息」同口径：已经有 NFO 的会直接跳过。
Future<void> scrapeVideos(
  BuildContext context,
  List<String> ids, {
  VoidCallback? onChanged,
}) async {
  if (ids.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier<({int done, int total})>((
    done: 0,
    total: ids.length,
  ));
  final closer = _BusyCloser(context, progress);
  var scraped = 0, skipped = 0, notfound = 0, unavailable = 0;
  try {
    const chunk = 12;
    for (var i = 0; i < ids.length; i += chunk) {
      final end = i + chunk > ids.length ? ids.length : i + chunk;
      final res = await ApiSession.instance.client.videoScrapeBatch(
        body: VideoScrapeBatchBody(ids: ids.sublist(i, end), mode: 'auto'),
      );
      scraped += res.scraped;
      skipped += res.skipped;
      notfound += res.notfound;
      unavailable += res.unavailable;
      progress.value = (done: end, total: ids.length);
    }
    NasSnack.showOn(
      messenger,
      tr('video.scrape.batchDone', {
        'scraped': '$scraped',
        'skipped': '$skipped',
        'notfound': '$notfound',
        'unavailable': '$unavailable',
      }),
    );
    onChanged?.call();
  } catch (e) {
    NasSnack.showOn(messenger, '$e');
  } finally {
    closer.close();
  }
}

/// 手动匹配整部剧：搜一次 TMDB，选中的条目套到这部剧的每一集上。
Future<void> matchSeries(
  BuildContext context,
  List<VideoItem> eps,
  VideoSeriesItem item, {
  VoidCallback? onChanged,
}) async {
  if (eps.isEmpty) return;
  final query = SeriesDisplayStore.nameOf(item.name) ?? item.name;
  final ok = await showTmdbMatchDialog(
    context,
    item: eps.first,
    applyIds: eps.map((e) => e.id).toList(),
    initialQuery: query,
  );
  if (ok) onChanged?.call();
}

/// 清除整部剧的刮削信息（逐条调，纯本地库操作，很快）。
Future<void> cleanupVideos(
  BuildContext context,
  List<String> ids, {
  VoidCallback? onChanged,
}) => _runPerItem(
  context,
  ids,
  (id) => ApiSession.instance.client.videoScrapeCleanup(
    body: VideoScrapeCleanupBody(id: id),
  ),
  tr('video.scrape.bulkCleaned', {'count': '${ids.length}'}),
  onChanged: onChanged,
);

/// 整部剧「不再自动刮削」。
Future<void> excludeVideos(
  BuildContext context,
  List<String> ids, {
  VoidCallback? onChanged,
}) => _runPerItem(
  context,
  ids,
  (id) => ApiSession.instance.client.videoScrapeMatch(
    body: VideoMatchNfoBody(id: id, match: false),
  ),
  tr('video.scrape.bulkExcluded', {'count': '${ids.length}'}),
  onChanged: onChanged,
);

/// 逐条跑一批本地操作，带进度框；单条失败不中断（数量对得上更重要）。
Future<void> _runPerItem(
  BuildContext context,
  List<String> ids,
  Future<void> Function(String id) step,
  String doneText, {
  VoidCallback? onChanged,
}) async {
  if (ids.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier<({int done, int total})>((
    done: 0,
    total: ids.length,
  ));
  final closer = _BusyCloser(context, progress);
  var ok = 0;
  try {
    for (var i = 0; i < ids.length; i += 1) {
      try {
        await step(ids[i]);
        ok += 1;
      } catch (_) {
        // 单条失败继续，最后统一提示
      }
      progress.value = (done: i + 1, total: ids.length);
    }
    NasSnack.showOn(messenger, ok == ids.length ? doneText : '$ok/${ids.length}');
    if (ok > 0) onChanged?.call();
  } finally {
    closer.close();
  }
}

/// 批量操作的进度框：挂上去、跑完关掉，并保证 notifier 不会用到别人身上。
class _BusyCloser {
  _BusyCloser(BuildContext context, ValueNotifier<({int done, int total})> p) {
    _progress = p;
    _nav = Navigator.of(context, rootNavigator: true);
    _open = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BulkJobDialog(progress: p),
      ).then((_) => _open = false),
    );
  }

  late final ValueNotifier<({int done, int total})> _progress;
  late final NavigatorState _nav;
  bool _open = false;

  void close() {
    if (_open && _nav.canPop()) _nav.pop();
    // 弹窗还在退场动画里引着这个 notifier，下一帧再销毁
    WidgetsBinding.instance.addPostFrameCallback((_) => _progress.dispose());
  }
}

class _BulkJobDialog extends StatelessWidget {
  const _BulkJobDialog({required this.progress});

  final ValueNotifier<({int done, int total})> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: ValueListenableBuilder<({int done, int total})>(
        valueListenable: progress,
        builder: (context, p, _) => Column(
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
                Text(
                  tr('video.scrape.bulkRunning', {
                    'done': '${p.done}',
                    'total': '${p.total}',
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: p.total > 0 ? (p.done / p.total).clamp(0.0, 1.0) : null,
              minHeight: 3,
            ),
          ],
        ),
      ),
    );
  }
}
