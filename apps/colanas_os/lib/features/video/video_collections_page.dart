import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
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
                    return Padding(
                      padding: const EdgeInsets.only(
                        bottom: NasTokens.spaceSm,
                      ),
                      child: NasCard(
                        padding: const EdgeInsets.all(NasTokens.spaceSm),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => VideoCollectionDetailPage(
                              collection: c,
                              onChanged: _load,
                            ),
                          ),
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
  });

  final VideoCollection collection;
  final VoidCallback? onChanged;

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.collection.coverSet'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// 长按：设封面 / 移出。此前长按直接移出且无提示，误触就丢。
  Future<void> _itemMenu(VideoItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: Text(tr('video.collection.setCover')),
              enabled: _coverId != item.id,
              onTap: () => Navigator.pop(ctx, 'cover'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(tr('video.collection.removeItem')),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'cover') await _setCover(item);
    if (action == 'remove') await _remove(item);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = ApiSession.instance.baseUrl;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.collection.name),
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
        ),
        actions: [
          IconButton(
            tooltip: tr('common.refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
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
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: NasTokens.spaceSm,
                            mainAxisSpacing: NasTokens.spaceSm,
                            childAspectRatio: 0.72,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            return InkWell(
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
                            );
                          },
                        );
                      },
                    ),
    );
  }
}
