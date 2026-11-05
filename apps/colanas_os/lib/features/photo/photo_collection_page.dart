import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 集合：把照片聚成一组（比相册更轻），按用户隔离。
class PhotoCollectionPage extends StatefulWidget {
  const PhotoCollectionPage({super.key});

  @override
  State<PhotoCollectionPage> createState() => _PhotoCollectionPageState();
}

class _PhotoCollectionPageState extends State<PhotoCollectionPage> {
  bool _loading = true;
  String? _error;
  List<PhotoCollection> _items = const [];

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

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
      final res = await ApiSession.instance.client.photoCollectionList();
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.collection.new')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('ui.photo.051')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.create')),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    if (ok != true || name.isEmpty) return;
    try {
      await ApiSession.instance.client.photoCollectionCreate(
        body: PhotoCollectionCreateBody(name: name),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
    }
  }

  /// 合集卡右键：打开 / 删除（参考实现还有「编辑」，我们暂无重命名接口）
  List<NasMenuEntry> _collectionMenuEntries(PhotoCollection c) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.collections_outlined,
      onSelected: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _CollectionDetailPage(
              collection: c,
              imageUrl: _media.thumbnail,
              headers: ApiSession.instance.authHeaders,
            ),
          ),
        );
        await _load();
      },
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('common.delete'),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () => _delete(c),
    ),
  ];

  Future<void> _delete(PhotoCollection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.collection.delete')),
        content: Text(tr('photo.collection.confirmDelete')),
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
      await ApiSession.instance.client.photoCollectionDelete(
        body: PhotoCollectionDeleteBody(id: c.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
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
                  tr('photo.nav.collection'),
                  style: TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('photo.collection.new')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? ListView(
                  children: [
                    NasEmptyState(
                      title: tr('photo.collection.empty'),
                      icon: Icons.collections_outlined,
                    ),
                  ],
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(NasTokens.spaceMd),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        mainAxisSpacing: NasTokens.spaceMd,
                        crossAxisSpacing: NasTokens.spaceMd,
                        childAspectRatio: 1.15,
                      ),
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final c = _items[i];
                    // 桌面 / Web 右键
                    return NasContextMenuRegion(
                      entries: _collectionMenuEntries(c),
                      child: InkWell(
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _CollectionDetailPage(
                              collection: c,
                              imageUrl: _media.thumbnail,
                              headers: ApiSession.instance.authHeaders,
                            ),
                          ),
                        );
                        await _load();
                      },
                      onLongPress: () => _delete(c),
                      child: NasCard(
                        padding: const EdgeInsets.all(NasTokens.spaceXs),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: c.coverPath == null
                                  ? const Center(
                                      child: Icon(Icons.collections_outlined),
                                    )
                                  : NasCoverImage(
                                      url: _media.thumbnail(
                                        c.coverPath!,
                                        size: 320,
                                      ),
                                      headers: ApiSession.instance.authHeaders,
                                      cacheWidth: 320,
                                      borderRadius: NasTokens.radiusSm,
                                      icon: Icons.broken_image_outlined,
                                    ),
                            ),
                            const SizedBox(height: NasTokens.spaceXs),
                            Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: NasTokens.fontBody,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              tr('photo.collection.count').replaceAll(
                                '{n}',
                                '${c.items}',
                              ),
                              style: TextStyle(
                                fontSize: NasTokens.fontMicro,
                                color: context.nasTextSecondary,
                              ),
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

class _CollectionDetailPage extends StatefulWidget {
  const _CollectionDetailPage({
    required this.collection,
    required this.imageUrl,
    required this.headers,
  });

  final PhotoCollection collection;
  final String Function(String path, {int size}) imageUrl;
  final Map<String, String> headers;

  @override
  State<_CollectionDetailPage> createState() => _CollectionDetailPageState();
}

class _CollectionDetailPageState extends State<_CollectionDetailPage> {
  bool _loading = true;
  String? _error;
  List<PhotoItem> _items = const [];

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
      final res = await ApiSession.instance.client.photoCollectionItems(
        collectionId: widget.collection.id,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addPhotos() async {
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _PickPhotosDialog(
        imageUrl: widget.imageUrl,
        headers: widget.headers,
      ),
    );
    if (picked == null || picked.isEmpty) return;
    try {
      await ApiSession.instance.client.photoCollectionAdd(
        body: PhotoCollectionMembersBody(
          collectionId: widget.collection.id,
          itemIds: picked.toList(),
        ),
      );
      if (!mounted) return;
      NasSnack.show(context, 
            tr('photo.collection.added').replaceAll('{n}', '${picked.length}'),
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collection.name),
        actions: [
          TextButton.icon(
            onPressed: _addPhotos,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: Text(tr('photo.collection.addPhotos')),
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
                  title: tr('photo.collection.empty'),
                  icon: Icons.collections_outlined,
                ),
              ],
            )
          : GridView.builder(
              padding: const EdgeInsets.all(NasTokens.spaceSm),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _items.length,
              itemBuilder: (context, i) => NasCoverImage(
                url: widget.imageUrl(_items[i].path, size: 320),
                headers: widget.headers,
                cacheWidth: 320,
                icon: Icons.broken_image_outlined,
              ),
            ),
    );
  }
}

/// 从最近的时间轴照片里挑要加入集合的图
class _PickPhotosDialog extends StatefulWidget {
  const _PickPhotosDialog({required this.imageUrl, required this.headers});

  final String Function(String path, {int size}) imageUrl;
  final Map<String, String> headers;

  @override
  State<_PickPhotosDialog> createState() => _PickPhotosDialogState();
}

class _PickPhotosDialogState extends State<_PickPhotosDialog> {
  bool _loading = true;
  List<PhotoItem> _items = const [];
  final Set<String> _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiSession.instance.client.photoTimeline(limit: 120);
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('photo.collection.pickTitle')),
      content: SizedBox(
        width: 720,
        height: 460,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 110,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: _items.length,
                itemBuilder: (context, i) {
                  final item = _items[i];
                  final selected = _picked.contains(item.id);
                  return GestureDetector(
                    onTap: () => setState(() {
                      if (selected) {
                        _picked.remove(item.id);
                      } else {
                        _picked.add(item.id);
                      }
                    }),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        NasCoverImage(
                          url: widget.imageUrl(item.path, size: 320),
                          headers: widget.headers,
                          cacheWidth: 320,
                          icon: Icons.broken_image_outlined,
                        ),
                        if (selected)
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              border: Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Icons.check_circle,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _picked),
          child: Text(tr('photo.collection.addPhotos')),
        ),
      ],
    );
  }
}