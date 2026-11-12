import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import 'detail/video_detail_router.dart';
import 'video_item_actions.dart';
import 'video_page.dart';

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
  bool _loading = true;
  String? _error;
  List<VideoItem> _items = const [];

  /// 当前封面（服务端返回的是解析后的 id，本地改动后不用整页重拉）
  String? _coverId;

  @override
  void initState() {
    super.initState();
    _coverId = widget.collection.coverItemId;
    _load();
  }

  Future<void> _setCover(VideoItem item) async {
    try {
      await ApiSession.instance.client.videoCollectionUpsert(
        body: VideoCollectionUpsertBody(
          id: widget.collection.id,
          name: widget.collection.name,
          kind: widget.collection.kind,
          coverItemId: item.id,
        ),
      );
      if (!mounted) return;
      setState(() => _coverId = item.id);
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoCollectionItems(
        id: widget.collection.id,
      );
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

  Future<void> _remove(VideoItem item) async {
    try {
      await ApiSession.instance.client.videoCollectionItemsSet(
        body: VideoCollectionItemsBody(
          id: widget.collection.id,
          itemIds: [item.id],
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

  @override
  Widget build(BuildContext context) {
    final base = ApiSession.instance.baseUrl;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    final body = _loading
        ? const NasLoading()
        : _error != null
            ? NasErrorState(message: _error!, onRetry: _load)
            : _items.isEmpty
                ? ListView(
                    children: [
                      NasEmptyState(
                        title: tr('video.collection.emptyItems'),
                        message: tr('video.collection.emptyItemsHint'),
                        icon: Icons.movie_outlined,
                      ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, c) {
                      final columns = gridColumns(c.maxWidth);
                      return GridView.builder(
                        padding: const EdgeInsets.all(NasTokens.spaceSm),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: NasTokens.spaceSm,
                          mainAxisSpacing: NasTokens.spaceSm,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: _items.length,
                        itemBuilder: (context, i) {
                          final item = _items[i];
                          return NasContextMenuRegion(
                            entries: videoItemMenuEntries(
                              item,
                              onAction: (a) => _runItemAction(a, item),
                              extra: _collectionExtras(item),
                              context: context,
                            ),
                            child: InkWell(
                              onLongPress: () => _itemMenu(item),
                              onTap: () => openVideoDetail(context, item),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            NasTokens.radiusSm,
                                          ),
                                          child: NasCoverImage(
                                            url:
                                                '$base/api/v1/video/poster?id=${Uri.encodeComponent(item.id)}',
                                            headers: headers,
                                            cacheWidth: 480,
                                            icon: Icons.movie_outlined,
                                          ),
                                        ),
                                        if (_coverId == item.id)
                                          Positioned(
                                            left: 4,
                                            top: 4,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 5,
                                                vertical: 1,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context).colorScheme.primary,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                tr('video.collection.coverBadge'),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: NasTokens.spaceXs),
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: NasTokens.fontBody,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );

    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: _titleBlock(context),
          actions: [
            NasRefreshButton(onPressed: _load),
          ],
        ),
        body: body,
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
                Expanded(child: body),
              ],
            ),
          ),
        ],
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
