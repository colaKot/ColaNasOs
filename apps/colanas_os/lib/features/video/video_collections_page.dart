import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'detail/video_detail_router.dart';
import 'player_page.dart';
import 'series_display.dart';
import 'video_card.dart';
import 'video_item_actions.dart';
import 'video_series_actions.dart';
import 'video_series_detail_page.dart';
import 'video_series_widgets.dart';

/// 影视自定义合集（每用户）：列表 + 新建 / 重命名 / 删除 + 合集内影片。
class VideoCollectionsPage extends StatefulWidget {
  const VideoCollectionsPage({super.key});

  @override
  State<VideoCollectionsPage> createState() => _VideoCollectionsPageState();
}

class _VideoCollectionsPageState extends State<VideoCollectionsPage> {
  bool _loading = true;
  String? _error;
  List<VideoCollection> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoCollectionList();
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _upsert({VideoCollection? editing}) async {
    final name = TextEditingController(text: editing?.name ?? '');
    final desc = TextEditingController(text: editing?.description ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          editing == null
              ? tr('video.collection.new')
              : tr('video.collection.edit'),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('video.collection.name'),
                  hintText: tr('video.collection.nameHint'),
                ),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              TextField(
                controller: desc,
                maxLength: 200,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: tr('video.collection.description'),
                  hintText: tr('video.collection.descriptionHint'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.save')),
          ),
        ],
      ),
    );
    final text = name.text.trim();
    if (ok != true || text.isEmpty) return;
    try {
      await ApiSession.instance.client.videoCollectionUpsert(
        body: VideoCollectionUpsertBody(
          id: editing?.id,
          name: text,
          kind: editing?.kind ?? 'custom',
          description: desc.text.trim(),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  /// 手排顺序：与相邻合集交换。按「索引 × 10」重排一次再写，
  /// 否则默认全是 0 时互换同一个值等于没动（相册那边踩过同样的坑）。
  Future<void> _move(VideoCollection c, int delta) async {
    final index = _items.indexWhere((x) => x.id == c.id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= _items.length) return;
    final next = <VideoCollection>[..._items];
    final moved = next.removeAt(index);
    next.insert(target, moved);
    try {
      for (var i = 0; i < next.length; i += 1) {
        final x = next[i];
        await ApiSession.instance.client.videoCollectionUpsert(
          body: VideoCollectionUpsertBody(
            id: x.id,
            name: x.name,
            kind: x.kind,
            sortOrder: (i + 1) * 10,
          ),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  /// 合集卡右键：打开 / 编辑 / 删除
  List<NasMenuEntry> _collectionMenuEntries(VideoCollection c) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.collections_bookmark_outlined,
      onSelected: () => openVideoCollection(context, c, onChanged: _load),
    ),
    NasMenuEntry(
      label: tr('video.collection.edit'),
      icon: Icons.edit_outlined,
      onSelected: () => _upsert(editing: c),
    ),
    NasMenuEntry(
      label: tr('video.collection.merge'),
      icon: Icons.merge_type,
      onSelected: () => _merge(c),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('common.delete'),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () => _delete(c),
    ),
  ];

  /// 合并合集：把当前合集的影片并入另一个合集，当前合集随后删除。
  Future<void> _merge(VideoCollection source) async {
    final targets = _items.where((x) => x.id != source.id).toList(growable: false);
    if (targets.isEmpty) {
      NasSnack.show(context, tr('video.collection.mergeNoTarget'));
      return;
    }
    var targetId = targets.first.id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('video.collection.mergeTitle')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('video.collection.mergeBody', {'source': source.name})),
                const SizedBox(height: NasTokens.spaceMd),
                DropdownButtonFormField<String>(
                  initialValue: targetId,
                  decoration: InputDecoration(
                    labelText: tr('video.collection.mergeTarget'),
                  ),
                  items: [
                    for (final t in targets)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setLocal(() => targetId = v ?? targetId),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('video.collection.merge')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final merged = await ApiSession.instance.client.videoCollectionMerge(
        body: {'sourceId': source.id, 'targetId': targetId},
      );
      if (!mounted) return;
      NasSnack.show(
        context,
        tr('video.collection.merged', {'count': '${merged.items}'}),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _delete(VideoCollection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.collection.delete')),
        content: Text(tr('video.collection.deleteBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiSession.instance.client.videoCollectionDelete(
        body: VideoCollectionIdBody(id: c.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('video.collection.hint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _upsert(),
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('video.collection.new')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? ListView(
                  children: [
                    NasEmptyState(
                      title: tr('video.collection.empty'),
                      icon: Icons.collections_bookmark_outlined,
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(NasTokens.spaceMd),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final c = _items[i];
                    // 桌面 / Web 右键
                    return NasContextMenuRegion(
                      entries: _collectionMenuEntries(c),
                      child: Padding(
                      padding: const EdgeInsets.only(
                        bottom: NasTokens.spaceSm,
                      ),
                      child: NasCard(
                        padding: const EdgeInsets.all(NasTokens.spaceSm),
                        onTap: () => openVideoCollection(
                          context,
                          c,
                          onChanged: _load,
                        ),
                        child: Row(
                          children: [
                            if (c.coverItemId != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                                child: SizedBox(
                                  width: 44,
                                  height: 64,
                                  child: NasCoverImage(
                                    url:
                                        '${ApiSession.instance.baseUrl}/api/v1/video/poster'
                                        '?id=${Uri.encodeComponent(c.coverItemId!)}',
                                    headers: ApiSession.instance.token == null
                                        ? const {}
                                        : {'Authorization': 'Bearer ${ApiSession.instance.token}'},
                                    cacheWidth: 160,
                                    icon: Icons.movie_outlined,
                                  ),
                                ),
                              )
                            else
                              const Icon(
                                Icons.collections_bookmark_outlined,
                                size: NasTokens.iconLg,
                              ),
                            const SizedBox(width: NasTokens.spaceSm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: NasTokens.fontSubtitle,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if ((c.description ?? '').isNotEmpty)
                                    Text(
                                      c.description!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: NasTokens.fontCaption,
                                        color: context.nasTextSecondary,
                                      ),
                                    ),
                                  Text(
                                    tr('video.collection.itemsCount', {
                                      'count': c.items,
                                    }),
                                    style: TextStyle(
                                      fontSize: NasTokens.fontCaption,
                                      color: context.nasTextSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: tr('video.collection.moveUp'),
                              onPressed: i == 0 ? null : () => _move(c, -1),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              tooltip: tr('video.collection.moveDown'),
                              onPressed:
                                  i == _items.length - 1 ? null : () => _move(c, 1),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                            IconButton(
                              tooltip: tr('video.collection.edit'),
                              onPressed: () => _upsert(editing: c),
                              icon: const Icon(Icons.edit_outlined, size: 18),
                            ),
                            IconButton(
                              tooltip: tr('common.delete'),
                              onPressed: () => _delete(c),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ],
                        ),
                      ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 合集详情：合集内影片海报墙。
class VideoCollectionDetailPage extends StatefulWidget {
  const VideoCollectionDetailPage({
    super.key,
    required this.collection,
    this.onChanged,
    this.embedded = false,
  });

  final VideoCollection collection;
  final VoidCallback? onChanged;

  /// true = 作为三级页放进影视壳的内容区：不画 AppBar，标题与刷新改成本页页头，
  /// 返回交给外壳（`ShellBack`）。
  final bool embedded;

  @override
  State<VideoCollectionDetailPage> createState() =>
      _VideoCollectionDetailPageState();
}

class _VideoCollectionDetailPageState extends State<VideoCollectionDetailPage> {
  static const _kFanart = 'video.collection.fanart';
  static const _kWaterfall = 'video.collection.waterfall';

  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<VideoItem> _items = const [];

  /// 当前封面（服务端返回的是解析后的 id，本地改动后不用整页重拉）
  String? _coverId;

  /// 竖版海报 / 横版剧照：同一套网格换个图源，等于「封面图 ↔ 缩略图」。
  bool _fanart = false;

  /// 瀑布流：横版缩略图按画面比例密排，短剧竖屏 / 老片 4:3 会自然错落。
  bool _waterfall = false;

  /// 观看进度（itemId → 百分比），只服务于「继续播放」定位。
  /// 没有它也能播，只是永远从第一部开始。
  Map<String, int> _progress = const {};

  @override
  void initState() {
    super.initState();
    _coverId = widget.collection.coverItemId;
    final store = SettingsStore.instance;
    _fanart = store.getBool(_kFanart) ?? false;
    _waterfall = store.getBool(_kWaterfall) ?? false;
    _load();
  }

  void _setView({bool? fanart, bool? waterfall}) {
    setState(() {
      if (fanart != null) _fanart = fanart;
      if (waterfall != null) _waterfall = waterfall;
    });
    final store = SettingsStore.instance;
    store.setBool(_kFanart, _fanart);
    store.setBool(_kWaterfall, _waterfall);
  }

  Future<void> _setCover(VideoItem item) => _setCoverId(item.id);

  Future<void> _setCoverId(String coverId) async {
    try {
      await ApiSession.instance.client.videoCollectionUpsert(
        body: VideoCollectionUpsertBody(
          id: widget.collection.id,
          name: widget.collection.name,
          kind: widget.collection.kind,
          coverItemId: coverId,
        ),
      );
      if (!mounted) return;
      setState(() => _coverId = coverId);
      widget.onChanged?.call();
      NasSnack.show(context, tr('video.collection.coverSet'));
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  /// 合集专有动作，和全站通用动作一起进同一个菜单（右键 / 长按）。
  List<VideoItemActionSpec> _collectionExtras(VideoItem item) => [
    if (_coverId != item.id)
      VideoItemActionSpec(
        'collection:cover',
        tr('video.collection.setCover'),
        Icons.star_outline,
      ),
    VideoItemActionSpec(
      'collection:remove',
      tr('video.collection.removeItem'),
      Icons.remove_circle_outline,
    ),
  ];

  /// 长按：专有项 + 全站统一的影片动作。此前长按直接移出且无提示，误触就丢。
  Future<void> _itemMenu(VideoItem item) async {
    final action = await showVideoItemActionSheet(
      context,
      item,
      extra: _collectionExtras(item),
    );
    if (!mounted || action == null) return;
    await _runItemAction(action, item);
  }

  Future<void> _runItemAction(String action, VideoItem item) async {
    if (action == 'collection:cover') {
      await _setCover(item);
      return;
    }
    if (action == 'collection:remove') {
      await _remove(item);
      return;
    }
    final changed = await runVideoItemAction(context, action, item);
    if (changed && mounted) await _load();
  }

  /// `silent`：从播放器回来时只刷新进度，别把整页打回 Loading 闪一下。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await ApiSession.instance.client.videoCollectionItems(
        id: widget.collection.id,
      );
      // 进度只影响「继续播放」从哪部起，拉不到不该让整页报错
      var progress = <String, int>{};
      try {
        final p = await ApiSession.instance.client.videoProgressList(limit: 500);
        progress = <String, int>{
          for (final row in p.items) row.itemId: row.percent,
        };
      } catch (_) {
        // 忽略：没有进度就退化成「播第一部没看过的」
      }
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _progress = progress;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 「继续播放」的起播位置：先找看过一半的那部，再找第一部没看过的，
  /// 都找不到就从头开始（与剧集详情页的续播口径一致）。
  int get _resumeIndex {
    var best = -1;
    var bestPercent = 0;
    for (var i = 0; i < _items.length; i += 1) {
      final p = _progress[_items[i].id] ?? 0;
      if (p > bestPercent && p < 95) {
        bestPercent = p;
        best = i;
      }
    }
    if (best >= 0) return best;
    for (var i = 0; i < _items.length; i += 1) {
      final it = _items[i];
      if (!it.watched && (_progress[it.id] ?? 0) == 0) return i;
    }
    return 0;
  }

  /// 播放队列：合集里一部剧只显示一张卡，但真正播的时候要回到「整部剧」
  /// 的集粒度，否则「播放全部 / 下一个」会一剧只播一集。
  Future<List<VideoItem>> _expandedQueue() async {
    if (_items.every((x) => x.seriesInfo == null)) return _items;
    final out = <VideoItem>[];
    for (final it in _items) {
      final info = it.seriesInfo;
      if (info == null) {
        out.add(it);
        continue;
      }
      final eps = await loadSeriesEpisodes(info.name, libraryId: it.libraryId);
      out.addAll(eps.isEmpty ? [it] : eps);
    }
    return out;
  }

  /// 起播：**整个合集**都进播放队列，所以点了任意一部、按「下一个」、
  /// 键盘 ↑↓、手机上滑，都是在合集里翻，播完一部接下一部。
  Future<void> _play(int index) async {
    if (_busy || index < 0 || index >= _items.length) return;
    final item = _items[index];
    setState(() => _busy = true);
    try {
      final queue = await _expandedQueue();
      final res = await ApiSession.instance.client.videoStreamUrl(id: item.id);
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            url: url,
            title: item.title,
            itemId: item.id,
            compat: res.compat,
            sourceHeight: item.height,
            sourceBytes: item.size,
            durationMs: item.durationMs,
            playlist: queue,
          ),
        ),
      );
      if (!mounted) return;
      // 播完回来进度变了，「继续播放」要跟着挪；静默刷新避免整屏闪一下
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('video.playUrlFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(VideoItem item) => _removeIds([item.id]);

  /// 剧卡「移出合集」要落到这部剧的每一集（合集里存的是条目 id）
  Future<void> _removeIds(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      await ApiSession.instance.client.videoCollectionItemsSet(
        body: VideoCollectionItemsBody(
          id: widget.collection.id,
          itemIds: ids,
          action: 'remove',
        ),
      );
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  /// 剧卡菜单：合集专有（设封面 / 移出）在前，整部剧口径的通用动作在后。
  Future<List<NasMenuEntry>> _seriesMenuEntries(
    VideoItem item,
    VideoSeriesItem info,
  ) async {
    final eps = await loadSeriesEpisodes(info.name, libraryId: item.libraryId);
    if (!mounted) return const <NasMenuEntry>[];
    final ids = eps.map((e) => e.id).toList();
    return [
      if (info.coverId != null && _coverId != info.coverId)
        NasMenuEntry(
          label: tr('video.collection.setCover'),
          icon: Icons.star_outline,
          onSelected: () => _setCoverId(info.coverId!),
        ),
      NasMenuEntry(
        label: tr('video.collection.removeItem'),
        icon: Icons.remove_circle_outline,
        onSelected: ids.isEmpty ? null : () => _removeIds(ids),
      ),
      const NasMenuEntry.divider(),
      ...await seriesMenuEntries(
        context,
        info,
        libraryId: item.libraryId,
        onChanged: () => _load(silent: true),
      ),
    ];
  }

  Future<void> _showSeriesMenu(
    VideoItem item,
    VideoSeriesItem info,
    Offset globalPosition,
  ) async {
    final entries = await _seriesMenuEntries(item, info);
    if (!mounted) return;
    await showNasContextMenu(context, globalPosition, entries);
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    final toolbar = _toolbar(context);

    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: _titleBlock(context),
          actions: [
            NasRefreshButton(onPressed: _load),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                NasTokens.spaceXs,
                NasTokens.spaceMd,
                0,
              ),
              child: toolbar,
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    // 三级页：顶栏交给外壳，标题做成页内页头；底色必须自己铺
    //（本项目 `scaffoldBackgroundColor` 是透明的，不铺会跟下面的列表叠在一起）
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(child: context.nasStyle.background),
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NasTokens.spaceMd,
                    NasTokens.spaceSm,
                    NasTokens.spaceXs,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: _titleBlock(context)),
                      NasRefreshButton(onPressed: _load),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NasTokens.spaceMd,
                    NasTokens.spaceXs,
                    NasTokens.spaceMd,
                    0,
                  ),
                  child: toolbar,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工具行：继续播放 / 播放全部 + 封面 · 缩略图 · 瀑布流。
  ///
  /// 两个播放按钮都会把**整个合集**放进播放队列，区别只在起播位置：
  /// 继续播放从看过的下一部接着来，播放全部从第一部开始。
  Widget _toolbar(BuildContext context) {
    final enabled = !_busy && _items.isNotEmpty;
    return Wrap(
      spacing: NasTokens.spaceXs,
      runSpacing: NasTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: enabled ? () => _play(_resumeIndex) : null,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(tr('video.collection.continuePlay')),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? () => _play(0) : null,
          icon: const Icon(Icons.playlist_play, size: 18),
          label: Text(tr('video.collection.playAll')),
        ),
        Text(
          tr('video.collection.itemsCount', {'count': '${_items.length}'}),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        _viewToggle(context),
      ],
    );
  }

  Widget _viewToggle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, bool active, VoidCallback onTap) {
      return IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
        icon: Icon(icon, size: 20, color: active ? scheme.primary : null),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(
          Icons.image_outlined,
          tr('video.list.showPoster'),
          !_waterfall && !_fanart,
          () => _setView(fanart: false, waterfall: false),
        ),
        btn(
          Icons.view_agenda_outlined,
          tr('video.list.showFanart'),
          !_waterfall && _fanart,
          () => _setView(fanart: true, waterfall: false),
        ),
        btn(
          Icons.view_quilt_rounded,
          tr('video.media.waterfall'),
          _waterfall,
          () => _setView(waterfall: !_waterfall),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.collection.emptyItems'),
            message: tr('video.collection.emptyItemsHint'),
            icon: Icons.movie_outlined,
          ),
        ],
      );
    }
    if (_waterfall) return _waterfallBody();
    return _gridBody();
  }

  Widget _gridBody() {
    return LayoutBuilder(
      builder: (context, c) {
        final columns = gridColumns(c.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: NasTokens.spaceSm,
            mainAxisSpacing: NasTokens.spaceSm,
            // 竖版海报 2:3 的格子；横版剧照换成 3:2，标题行高度才不会被挤掉
            childAspectRatio: _fanart ? 1.5 : 0.72,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) => _cell(context, i),
        );
      },
    );
  }

  /// 瀑布流：按「列」手工排布，卡片高度由画面比例决定。
  /// 短剧竖屏、老片 4:3 混在一起才会真的错落，而不是把整齐网格重画一遍。
  Widget _waterfallBody() {
    return LayoutBuilder(
      builder: (context, c) {
        const spacing = 12.0;
        final cols = (c.maxWidth / 260).floor().clamp(2, 6);
        final usable = c.maxWidth - NasTokens.spaceSm * 2 - spacing * (cols - 1);
        final w = usable / cols;
        final buckets = List.generate(cols, (_) => <Widget>[]);
        final heights = List<double>.filled(cols, 0);
        for (var i = 0; i < _items.length; i += 1) {
          final ratio = _aspectOf(_items[i]);
          var target = 0;
          for (var j = 1; j < cols; j += 1) {
            if (heights[j] < heights[target]) target = j;
          }
          buckets[target].add(_cell(context, i, fixedWidth: w));
          heights[target] += w / ratio + 22 + spacing;
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var j = 0; j < cols; j += 1) ...[
                if (j > 0) const SizedBox(width: spacing),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final wgt in buckets[j])
                        Padding(
                          padding: const EdgeInsets.only(bottom: spacing),
                          child: wgt,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  double _aspectOf(VideoItem item) {
    // 剧卡固定用 2:3 竖版封面（与剧库列表一致），不跟着某一集的文件画面走
    if (item.seriesInfo != null) return 2 / 3;
    final w = item.width ?? 0;
    final h = item.height ?? 0;
    if (w > 0 && h > 0) return w / h;
    return 16 / 9;
  }

  /// 剧卡：整部剧一张竖版封面；点进去与「电视剧列表」点一部剧一致
  /// （多季 → 季封面网格，单季 → 直接进剧集详情）。
  Widget _seriesCell(
    BuildContext context,
    VideoItem item,
    VideoSeriesItem info, {
    double? fixedWidth,
  }) {
    final name = SeriesDisplayStore.nameOf(info.name) ?? info.name;
    final px = fixedWidth == null ? 480 : (fixedWidth * 2).round();
    final image = Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          child: SeriesCoverImage(
            artUrl: seriesArtUrl(info.posterId, size: px),
            posterUrl: SeriesDisplayStore.posterOf(info.name),
            stillUrl: episodeStillFallbackUrl(info.coverId),
            fallbackText: name,
            cacheWidth: px,
          ),
        ),
        Positioned(
          top: 6,
          left: 6,
          child: SeriesWatchBadge(
            watched: info.watchedEpisodes ?? 0,
            total: info.episodes,
          ),
        ),
        if (info.coverId != null && _coverId == info.coverId)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tr('video.collection.coverBadge'),
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
      ],
    );

    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fixedWidth == null)
          Expanded(
            child: Center(
              child: AspectRatio(aspectRatio: 2 / 3, child: image),
            ),
          )
        else
          AspectRatio(aspectRatio: 2 / 3, child: image),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: NasTokens.fontBody),
        ),
        Text(
          tr('video.seasonsEpisodes', {
            'seasons': '${info.seasons}',
            'episodes': '${info.episodes}',
          }),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: NasTokens.fontMicro,
            color: context.nasTextSecondary,
          ),
        ),
      ],
    );

    return GestureDetector(
      onLongPressStart: (d) => _showSeriesMenu(item, info, d.globalPosition),
      child: NasAsyncMenuRegion(
        entries: () => _seriesMenuEntries(item, info),
        child: InkWell(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          onTap: () => openVideoSeries(
            context,
            name: info.name,
            coverId: info.coverId,
            posterId: info.posterId,
            libraryId: item.libraryId,
            headers: videoArtHeaders,
          ),
          child: card,
        ),
      ),
    );
  }

  /// 单个影格：网格与瀑布流共用同一份实现。
  /// `fixedWidth` 有值时是瀑布流（高度按画面比例算），为 null 时撑满网格格子。
  Widget _cell(BuildContext context, int index, {double? fixedWidth}) {
    final item = _items[index];
    // 服务端已把电视剧按剧聚合：这一条代表整部剧（一部剧一张卡）
    final info = item.seriesInfo;
    if (info != null) {
      return _seriesCell(context, item, info, fixedWidth: fixedWidth);
    }
    final px = fixedWidth == null ? 480 : (fixedWidth * 2).round();
    final percent = _progress[item.id] ?? 0;
    final image = Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          child: NasCoverImage(
            // 封面 = 竖版海报，缩略图 / 瀑布流 = 横版剧照；
            // 统一走 `art`（带 size 走缩略图缓存），别用原图直出
            url: videoPosterUrl(
              item,
              kind: !_waterfall && !_fanart ? 'poster' : 'fanart',
              size: px,
            ),
            headers: videoArtHeaders,
            cacheWidth: px,
            icon: Icons.movie_outlined,
          ),
        ),
        if (_coverId == item.id)
          Positioned(
            left: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tr('video.collection.coverBadge'),
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
        // 看到了哪儿：进度条压在封面底部，回到合集一眼能挑出续看的那部
        if (percent > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: (percent / 100).clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Colors.black26,
            ),
          ),
      ],
    );

    return NasContextMenuRegion(
      entries: videoItemMenuEntries(
        item,
        onAction: (a) => _runItemAction(a, item),
        extra: _collectionExtras(item),
        context: context,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onLongPress: () => _itemMenu(item),
        // 点一下就播，不再先跳详情多一步；详情 / 设封面 / 移出都在右键菜单里
        onTap: () => _play(index),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fixedWidth == null)
              Expanded(child: image)
            else
              AspectRatio(aspectRatio: _aspectOf(item), child: image),
            const SizedBox(height: NasTokens.spaceXs),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: NasTokens.fontBody),
            ),
          ],
        ),
      ),
    );
  }

  /// 标题块：合集名 + 描述（AppBar 与嵌入页头共用一份）
  Widget _titleBlock(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.collection.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        if ((widget.collection.description ?? '').isNotEmpty)
          Text(
            widget.collection.description!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
      ],
    );
  }
}

/// 打开合集详情的统一入口（与 `openVideoDetail` 同口径）。
///
/// 影视壳挂载且调用方在内容区时叠三级页；否则退回整页 push。
Future<void> openVideoCollection(
  BuildContext context,
  VideoCollection collection, {
  VoidCallback? onChanged,
}) {
  final router = VideoDetailRouter.instance;
  if (router.embeddableFrom(context)) {
    router.open(
      VideoDetailEntry(
        tag: 'collection:${collection.id}',
        build: (_) => VideoCollectionDetailPage(
          collection: collection,
          onChanged: onChanged,
          embedded: true,
        ),
      ),
    );
    return Future<void>.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideoCollectionDetailPage(
        collection: collection,
        onChanged: onChanged,
      ),
    ),
  );
}
