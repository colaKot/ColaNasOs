import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:path/path.dart' as p;

import '../detail/video_detail_router.dart';
import '../player_page.dart';
import 'offline_download_manager.dart';
import 'offline_models.dart';
import 'offline_store.dart';

/// 影视 → 合集 → 本地视频。
///
/// 三条原则：
///   1. **离线可用**：这一页的数据全部来自 `index/*.json` 与本地文件，
///      内核停了也照常显示封面、能播；
///   2. **按来源库分组**：电影 / 日本电影 / 混合库各自一档 chip，
///      不给用户造一套新的分类法；
///   3. **剧集按整剧聚合**：只下了一集，也要显示整剧封面 + `已下载 1/24 集`。
class VideoOfflinePage extends StatefulWidget {
  const VideoOfflinePage({super.key});

  @override
  State<VideoOfflinePage> createState() => _VideoOfflinePageState();
}

class _VideoOfflinePageState extends State<VideoOfflinePage> {
  final NasSelectionController _sel = NasSelectionController();

  OfflineStore? _store;
  bool _loading = true;
  String _library = '';

  @override
  void initState() {
    super.initState();
    _sel.addListener(_onSelectionChanged);
    OfflineDownloadManager.instance.libraryRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _sel.removeListener(_onSelectionChanged);
    OfflineDownloadManager.instance.libraryRevision.removeListener(_load);
    _sel.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final store = await OfflineDownloadManager.instance.ensureStore();
      await store.reconcile();
      if (!mounted) return;
      setState(() {
        _store = store;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (_loading || store == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final groups = store.sortedGroups(libraryId: _library);
    final libraries = store.libraries();
    // 失败的任务也列出来：不给入口的话，用户只能去详情页重新点一遍才会再排一次
    final tasks = OfflineDownloadManager.instance.tasks.value
        .where((t) => t.active || t.state == OfflineTaskState.failed)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, store, tasks),
        if (_sel.active)
          NasSelectionBar(
            title: tr('video.offline.selectedSpace', {
              'n': '${_sel.count}',
              'size': formatBytes(_selectedBytes(store).round()),
            }),
            allSelected: _sel.allSelected(groups.map((g) => g.id)),
            onToggleAll: () => setState(() => _sel.toggleAll(groups.map((g) => g.id))),
            onClose: () => setState(_sel.exit),
            actions: [
              NasSelectionAction(
                label: tr('video.offline.deleteSelected', {'n': '${_sel.count}'}),
                icon: Icons.delete_outline,
                danger: true,
                enabled: _sel.isNotEmpty,
                onPressed: () => _deleteGroups(store),
              ),
            ],
          ),
        if (libraries.length > 1)
          _libraryChips(context, libraries)
        else
          const SizedBox(height: 4),
        Expanded(
          child: groups.isEmpty
              ? _empty(context)
              : _grid(context, store, groups),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 头部

  Widget _header(BuildContext context, OfflineStore store, List<OfflineTaskRecord> tasks) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 8, NasTokens.spaceSm, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('video.offline.title'),
                      style: const TextStyle(
                        fontSize: NasTokens.fontTitle,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('video.offline.hint'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: tr('video.list.multiSelect'),
                onPressed: () => setState(() {
                  if (_sel.active) {
                    _sel.exit();
                  } else {
                    _sel.enter();
                  }
                }),
                icon: Icon(_sel.active ? Icons.close : Icons.checklist),
              ),
            ],
          ),
          if (tasks.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final task in tasks) _taskRow(context, task),
          ],
        ],
      ),
    );
  }

  Widget _taskRow(BuildContext context, OfflineTaskRecord task) {
    final scheme = Theme.of(context).colorScheme;
    final failed = task.state == OfflineTaskState.failed;
    final label = failed
        ? tr('video.offline.failed')
        : (task.state == OfflineTaskState.transcoding || task.state == OfflineTaskState.queued
              ? tr('video.offline.preparing')
              : tr('video.offline.downloading'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: failed
                ? Icon(Icons.error_outline, size: 14, color: scheme.error)
                : CircularProgressIndicator(strokeWidth: 2, value: task.overall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${task.title} · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: failed ? scheme.error : context.nasTextSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => failed
                ? OfflineDownloadManager.instance.retry(task.itemId)
                : OfflineDownloadManager.instance.cancel(task.itemId),
            style: failed ? null : TextButton.styleFrom(foregroundColor: scheme.error),
            child: Text(failed ? tr('video.offline.retry') : tr('video.offline.cancel')),
          ),
        ],
      ),
    );
  }

  Widget _libraryChips(BuildContext context, Map<String, String> libraries) {
    final entries = libraries.entries.toList();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
        children: [
          _chip(context, '', tr('video.nav.libraries')),
          for (final e in entries) _chip(context, e.key, e.value),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String id, String label) {
    final selected = _library == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: NasPillChip(
          label: label,
          selected: selected,
          onTap: () => setState(() {
            _library = id;
            _sel.exit();
          }),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.download_for_offline_outlined,
          size: 48,
          color: context.nasTextSecondary,
        ),
        const SizedBox(height: 12),
        Text(
          tr('video.offline.empty'),
          style: TextStyle(color: context.nasTextSecondary),
        ),
      ],
    ),
  );

  // ---------------------------------------------------------------- 网格

  Widget _grid(BuildContext context, OfflineStore store, List<LocalMediaGroup> groups) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxExtent = constraints.maxWidth > 900 ? 190.0 : 160.0;
        return GridView.builder(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            childAspectRatio: 0.58,
            crossAxisSpacing: NasTokens.spaceMd,
            mainAxisSpacing: NasTokens.spaceMd,
          ),
          itemCount: groups.length,
          itemBuilder: (context, i) => _groupCard(context, store, groups[i]),
        );
      },
    );
  }

  Widget _groupCard(BuildContext context, OfflineStore store, LocalMediaGroup group) {
    final items = store.itemsOfGroup(group.id);
    final bytes = items.fold<int>(0, (sum, i) => sum + i.bytes);
    final selected = _sel.contains(group.id);
    final subtitle = group.isSeries
        ? tr('video.offline.episodes', {
            'done': '${items.length}',
            'total': '${group.totalEpisodes > 0 ? group.totalEpisodes : items.length}',
          })
        : (items.isNotEmpty ? items.first.specLabel : '');

    return GestureDetector(
      onTap: () {
        if (_sel.active) {
          setState(() => _sel.toggle(group.id));
          return;
        }
        if (group.isSeries) {
          _openSeries(group);
        } else if (items.isNotEmpty) {
          _play(store, items.first);
        }
      },
      onLongPress: () {
        if (!_sel.active) setState(() => _sel.enter(initialId: group.id));
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: NasSelectionCover(
              selected: selected,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                child: _cover(context, store, group),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            group.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: NasTokens.fontBody, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          if (bytes > 0)
            Text(
              formatBytes(bytes),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _cover(BuildContext context, OfflineStore store, LocalMediaGroup group) {
    final rel = group.posterPath ?? group.fallbackPosterPath;
    if (rel == null || rel.isEmpty) return _coverPlaceholder(context);
    final file = File(store.absolute(rel));
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _coverPlaceholder(context),
    );
  }

  Widget _coverPlaceholder(BuildContext context) => Container(
    color: context.nasStyle.panelColor,
    alignment: Alignment.center,
    child: Icon(Icons.movie_outlined, color: context.nasTextSecondary, size: 28),
  );

  // ---------------------------------------------------------------- 动作

  double _selectedBytes(OfflineStore store) {
    var total = 0.0;
    for (final id in _sel.ids) {
      final group = store.groups[id];
      if (group == null) continue;
      for (final item in store.itemsOfGroup(group.id)) {
        total += item.bytes;
      }
    }
    return total;
  }

  Future<void> _deleteGroups(OfflineStore store) async {
    final ids = _sel.ids.toList();
    if (ids.isEmpty) return;
    final itemIds = <String>[];
    for (final id in ids) {
      final group = store.groups[id];
      if (group == null) continue;
      itemIds.addAll(group.itemIds);
    }
    final ok = await _confirmDelete(context, ids.length);
    if (ok != true) return;
    await OfflineDownloadManager.instance.deleteItems(itemIds);
    if (!mounted) return;
    setState(_sel.exit);
  }

  Future<bool?> _confirmDelete(BuildContext context, int count) => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('video.offline.deleteTitle')),
      content: Text(tr('video.offline.deleteBody')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('video.offline.deleteSelected', {'n': '$count'})),
        ),
      ],
    ),
  );

  void _openSeries(LocalMediaGroup group) {
    final router = VideoDetailRouter.instance;
    Widget buildPage() => VideoOfflineSeriesPage(groupId: group.id);
    if (router.embeddableFrom(context)) {
      router.open(
        VideoDetailEntry(tag: 'offline:${group.id}', build: (_) => buildPage()),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => buildPage()));
  }

  Future<void> _play(OfflineStore store, LocalMediaItem item) async {
    final file = File(store.absolute(item.filePath));
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(tr('video.offline.empty'))),
      );
      await _load();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          // 本地文件：itemId 留空 = 纯 URL 播放器，不建转码会话、不拉服务端字幕
          url: file.uri.toString(),
          title: item.title,
          durationMs: item.durationMs > 0 ? item.durationMs : null,
          // 续播：少于 5 秒就当没看过，避免刚点开就被弹回开头
          startAt: item.playbackMs > 5000 ? Duration(milliseconds: item.playbackMs) : null,
          // 退出时把位置写进本地索引：断网时也能接着看
          onPosition: (pos) => OfflineDownloadManager.instance
              .savePlayback(item.id, pos.inMilliseconds)
              .ignore(),
          // 下载时抓的外挂字幕（WebVTT）：第一条自动挂上，其余在字幕菜单里切
          localSubtitles: [
            for (final rel in item.subtitlePaths) store.absolute(rel),
          ],
        ),
      ),
    );
  }
}

/// 某部剧在本机的已下载集（只列下完并校验通过的）。
class VideoOfflineSeriesPage extends StatefulWidget {
  const VideoOfflineSeriesPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<VideoOfflineSeriesPage> createState() => _VideoOfflineSeriesPageState();
}

class _VideoOfflineSeriesPageState extends State<VideoOfflineSeriesPage> {
  OfflineStore? _store;
  LocalMediaGroup? _group;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await OfflineDownloadManager.instance.ensureStore();
    await store.reconcile();
    if (!mounted) return;
    setState(() {
      _store = store;
      _group = store.groups[widget.groupId];
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final group = _group;
    if (store == null || group == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = store.itemsOfGroup(group.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 12, NasTokens.spaceMd, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: const TextStyle(
                        fontSize: NasTokens.fontTitle,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('video.offline.episodes', {
                        'done': '${items.length}',
                        'total': '${group.totalEpisodes > 0 ? group.totalEpisodes : items.length}',
                      }),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final item = items[i];
              final ep = item.episode ?? (i + 1);
              return ListTile(
                leading: CircleAvatar(
                  radius: 16,
                  child: Text('$ep', style: const TextStyle(fontSize: 12)),
                ),
                title: Text(tr('video.offline.episodeLabel', {'n': '$ep'})),
                subtitle: Text(
                  '${item.specLabel}${item.bytes > 0 ? ' · ${formatBytes(item.bytes)}' : ''}',
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                trailing: IconButton(
                  tooltip: tr('video.offline.deleteTitle'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(store, item),
                ),
                onTap: () => _play(store, item),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _delete(OfflineStore store, LocalMediaItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.offline.deleteTitle')),
        content: Text(tr('video.offline.deleteBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('video.offline.deleteSelected', {'n': '1'})),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await OfflineDownloadManager.instance.deleteItems([item.id]);
    if (!mounted) return;
    await _load();
    // 最后一集被删掉时整剧已经不存在了：退回上一页
    if (mounted && _group == null) Navigator.of(context).maybePop();
  }

  Future<void> _play(OfflineStore store, LocalMediaItem item) async {
    final file = File(store.absolute(item.filePath));
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(tr('video.offline.empty'))));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          url: file.uri.toString(),
          title: item.title,
          durationMs: item.durationMs > 0 ? item.durationMs : null,
          startAt: item.playbackMs > 5000 ? Duration(milliseconds: item.playbackMs) : null,
          onPosition: (pos) => OfflineDownloadManager.instance
              .savePlayback(item.id, pos.inMilliseconds)
              .ignore(),
          localSubtitles: [
            for (final rel in item.subtitlePaths) store.absolute(rel),
          ],
        ),
      ),
    );
    if (mounted) await _load();
  }
}

/// 便于排查时确认路径真实存在（`p` 只在 debug 打印里用得上）
String offlineDebugPath(OfflineStore store, String rel) => p.normalize(store.absolute(rel));
