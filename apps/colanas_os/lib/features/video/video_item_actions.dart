import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'cola_video_detail_page.dart';
import 'video_scrape_dialogs.dart';

/// 影片条目的通用右键 / 长按动作。
///
/// 电影列表、文件夹（图片 / 混合库）、演员作品三个页面共用这一份：
/// 菜单长什么样、每项做什么、删除确认框长什么样，只有一处实现。
/// 页面只负责「动作做完后刷新自己的列表」。

class VideoItemAction {
  static const detail = 'detail';
  static const watched = 'watched';
  static const copyPath = 'copyPath';
  static const scrape = 'scrape';
  static const match = 'match';
  static const cleanup = 'cleanup';
  static const exclude = 'exclude';
  static const delete = 'delete';
}

/// 菜单项规格：id / 文案 / 图标 / 是否危险项 / 是否分隔线。
/// 右键菜单和长按面板都从这一份生成，两边永远不会对不上。
class VideoItemActionSpec {
  const VideoItemActionSpec(
    this.id,
    this.label,
    this.icon, {
    this.danger = false,
    this.divider = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final bool danger;
  final bool divider;
}

List<VideoItemActionSpec> videoItemActionSpecs(
  VideoItem item, {
  bool allowScrape = true,
  bool allowDelete = true,
  List<VideoItemActionSpec> extra = const [],
}) => [
  VideoItemActionSpec(
    VideoItemAction.watched,
    tr(
      item.watched
          ? 'video.action.markUnwatched'
          : (item.series != null
                ? 'video.action.markTvWatched'
                : 'video.action.markWatched'),
    ),
    item.watched ? Icons.remove_done : Icons.done_all,
  ),
  VideoItemActionSpec(
    VideoItemAction.detail,
    tr('video.action.locateFile'),
    Icons.open_in_new,
  ),
  VideoItemActionSpec(
    VideoItemAction.copyPath,
    tr('video.action.copyPath'),
    Icons.copy_all_outlined,
  ),
  // 页面专有动作（设封面 / 移出合集 …）：id 由调用方自定义，自己分发
  ...extra,
  const VideoItemActionSpec('', '', Icons.more_horiz, divider: true),
  if (allowScrape) ...[
    VideoItemActionSpec(
      VideoItemAction.scrape,
      tr('video.action.scrape'),
      Icons.auto_awesome_outlined,
    ),
    VideoItemActionSpec(
      VideoItemAction.match,
      tr('video.action.matchTmdb'),
      Icons.search,
    ),
    VideoItemActionSpec(
      VideoItemAction.cleanup,
      tr('video.action.scrapeCleanup'),
      Icons.cleaning_services_outlined,
    ),
    VideoItemActionSpec(
      VideoItemAction.exclude,
      tr('video.action.excludeScrape'),
      Icons.block,
    ),
    const VideoItemActionSpec('', '', Icons.more_horiz, divider: true),
  ],
  if (allowDelete)
    VideoItemActionSpec(
      VideoItemAction.delete,
      tr('common.delete'),
      Icons.delete_outline,
      danger: true,
    ),
];

/// 右键菜单项（`NasContextMenuRegion` 用）。
/// `allowScrape: false` 给图片条目 —— 图片没有 NFO / TMDB 可刮。
List<NasMenuEntry> videoItemMenuEntries(
  VideoItem item, {
  required ValueChanged<String> onAction,
  bool allowScrape = true,
  bool allowDelete = true,
  List<VideoItemActionSpec> extra = const [],
}) => [
  for (final s in videoItemActionSpecs(
    item,
    allowScrape: allowScrape,
    allowDelete: allowDelete,
    extra: extra,
  ))
    if (s.divider)
      const NasMenuEntry.divider()
    else
      NasMenuEntry(
        label: s.label,
        icon: s.icon,
        danger: s.danger,
        onSelected: () => onAction(s.id),
      ),
];

/// 长按 /「更多」按钮的面板，返回动作 id（取消为 null）。
Future<String?> showVideoItemActionSheet(
  BuildContext context,
  VideoItem item, {
  bool allowScrape = true,
  bool allowDelete = true,
  List<VideoItemActionSpec> extra = const [],
}) {
  final specs = videoItemActionSpecs(
    item,
    allowScrape: allowScrape,
    allowDelete: allowDelete,
    extra: extra,
  );
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final s in specs)
            if (s.divider)
              const Divider()
            else
              ListTile(
                dense: true,
                leading: Icon(s.icon, size: 20),
                title: Text(s.label),
                onTap: () => Navigator.pop(ctx, s.id),
              ),
        ],
      ),
    ),
  );
}

/// 删除确认：返回 `true` = 放回收站、`false` = 永久删除、`null` = 取消。
/// 用户口径：**默认不勾选**回收站，所以把「不勾选 = 永久删除」写红字讲明白。
Future<bool?> confirmVideoDelete(BuildContext context, {int count = 1}) {
  var toTrash = false;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('video.delete.confirm', {'count': '$count'})),
            const SizedBox(height: 6),
            CheckboxListTile(
              value: toTrash,
              onChanged: (v) => setLocal(() => toTrash = v ?? false),
              title: Text(tr('video.dup.toTrash')),
              subtitle: Text(tr('video.dup.toTrashHint')),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            if (!toTrash)
              Text(
                tr('video.delete.permanentHint'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: Theme.of(ctx).colorScheme.error,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, toTrash),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    ),
  );
}

/// 真正删片。`toTrash` 为 false 时是永久删除，调用方必须先弹确认。
Future<bool> deleteVideoItemsNow(
  BuildContext context,
  List<String> ids, {
  required bool toTrash,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ApiSession.instance.client.videoItemsDelete(
      body: VideoDeleteItemsBody(ids: ids, permanent: !toTrash),
    );
    NasSnack.showOn(
      messenger,
      tr(toTrash ? 'video.delete.doneTrash' : 'video.delete.done', {
        'count': '${ids.length}',
      }),
    );
    return true;
  } catch (e) {
    NasSnack.showOn(messenger, '$e');
    return false;
  }
}

/// 执行一条动作。返回 true 表示数据变了，调用方应刷新列表。
Future<bool> runVideoItemAction(
  BuildContext context,
  String action,
  VideoItem item,
) async {
  final messenger = ScaffoldMessenger.of(context);
  switch (action) {
    case VideoItemAction.detail:
      await openVideoDetail(context, item);
      return true;
    case VideoItemAction.watched:
      try {
        await ApiSession.instance.client.videoWatchMark(
          body: VideoWatchBody(ids: [item.id], watched: !item.watched),
        );
        return true;
      } catch (e) {
        NasSnack.showOn(messenger, '$e');
        return false;
      }
    case VideoItemAction.copyPath:
      await Clipboard.setData(ClipboardData(text: item.path));
      NasSnack.showOn(messenger, tr('video.media.copyLink'));
      return false;
    case VideoItemAction.scrape:
      try {
        final res = await ApiSession.instance.client.videoScrapeStart(
          body: VideoScrapeBody(id: item.id),
        );
        if (!context.mounted) return true;
        await showScrapeOutcome(context, res);
        return true;
      } catch (e) {
        NasSnack.showOn(messenger, '$e');
        return false;
      }
    case VideoItemAction.match:
      final ok = await showTmdbMatchDialog(context, item: item);
      return ok;
    case VideoItemAction.cleanup:
      try {
        await ApiSession.instance.client.videoScrapeCleanup(
          body: VideoScrapeCleanupBody(id: item.id),
        );
        NasSnack.showOn(messenger, tr('video.scrape.cleaned'));
        return true;
      } catch (e) {
        NasSnack.showOn(messenger, '$e');
        return false;
      }
    case VideoItemAction.exclude:
      try {
        await ApiSession.instance.client.videoScrapeMatch(
          body: VideoMatchNfoBody(id: item.id, match: false),
        );
        NasSnack.showOn(messenger, tr('video.scrape.excluded'));
        return true;
      } catch (e) {
        NasSnack.showOn(messenger, '$e');
        return false;
      }
    case VideoItemAction.delete:
      final toTrash = await confirmVideoDelete(context);
      if (toTrash == null || !context.mounted) return false;
      return deleteVideoItemsNow(context, [item.id], toTrash: toTrash);
  }
  return false;
}
