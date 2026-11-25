import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'blog_player.dart';
import 'blog_player_page.dart';

/// 博客 · 博客合集：参考「歌曲合集」的卡片列表 + 详情页。
///
/// 与音乐合集不同的是：合集收的是**具体的音频文件**（不是目录），
/// 因此可以排序、可以单条移除，也不会跟着目录里的新增文件自动变化。
class BlogCollectionsPage extends StatefulWidget {
  const BlogCollectionsPage({super.key});

  @override
  State<BlogCollectionsPage> createState() => _BlogCollectionsPageState();
}

class _BlogCollectionsPageState extends State<BlogCollectionsPage> {
  bool _loading = true;
  String? _error;
  List<BlogCollection> _items = const [];

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
      final res = await ApiSession.instance.client.blogCollections();
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

  Future<void> _create() async {
    final draft = await _editDialog();
    if (draft == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogCollectionCreate(
        body: BlogCollectionBody(name: draft.name, description: draft.description),
      );
      NasSnack.showOn(messenger, tr('blog.collection.created'));
      await _load();
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('blog.collection.createFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  Future<void> _edit(BlogCollection collection) async {
    final draft = await _editDialog(existing: collection);
    if (draft == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogCollectionUpdate(
        body: BlogCollectionUpdateBody(
          id: collection.id,
          name: draft.name,
          description: draft.description,
        ),
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('blog.collection.saveFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  Future<void> _delete(BlogCollection collection) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(tr('blog.collection.deleteConfirm', {'name': collection.name})),
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
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogCollectionRemove(
        body: BlogCollectionIdBody(id: collection.id),
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.deleteFailed', {'error': '$e'}), error: true);
    }
  }

  Future<void> _open(BlogCollection collection) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlogCollectionDetailPage(collection: collection),
      ),
    );
    await _load();
  }

  Future<_CollectionDraft?> _editDialog({BlogCollection? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    return showDialog<_CollectionDraft>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          existing == null ? tr('blog.collection.create') : tr('blog.collection.edit'),
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('blog.collection.name'),
                  hintText: tr('blog.collection.nameHint'),
                ),
              ),
              const SizedBox(height: NasTokens.spaceMd),
              TextField(
                controller: descCtrl,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: tr('blog.collection.description'),
                  hintText: tr('blog.collection.descriptionHint'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(
                ctx,
                _CollectionDraft(name: name, description: descCtrl.text.trim()),
              );
            },
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
  }

  List<NasMenuEntry> _menuFor(BlogCollection c) => [
        NasMenuEntry(
          label: tr('blog.collection.open'),
          icon: Icons.collections_bookmark_outlined,
          onSelected: () => _open(c),
        ),
        NasMenuEntry(
          label: tr('blog.collection.edit'),
          icon: Icons.edit_outlined,
          onSelected: () => _edit(c),
        ),
        const NasMenuEntry.divider(),
        NasMenuEntry(
          label: tr('common.delete'),
          icon: Icons.delete_outline,
          danger: true,
          onSelected: () => _delete(c),
        ),
      ];

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('blog.collection.empty'),
        message: tr('blog.collection.emptyHint'),
        icon: Icons.collections_bookmark_outlined,
      );
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceLg,
            NasTokens.spaceSm,
            NasTokens.spaceLg,
            NasTokens.spaceLg,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.crossAxisExtent < 750;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: compact ? 1 : 3,
                  crossAxisSpacing: NasTokens.spaceMd,
                  mainAxisSpacing: NasTokens.spaceMd,
                  childAspectRatio: 1.8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _CollectionCard(
                    collection: _items[i],
                    menuEntries: _menuFor(_items[i]),
                    onTap: () => _open(_items[i]),
                  ),
                  childCount: _items.length,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceLg,
            NasTokens.spaceLg,
            NasTokens.spaceLg,
            NasTokens.spaceSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('blog.collection.title'),
                      style: const TextStyle(
                        fontSize: NasTokens.fontTitle,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('blog.collection.subtitle'),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(tr('blog.collection.create')),
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }
}

class _CollectionDraft {
  const _CollectionDraft({required this.name, required this.description});

  final String name;
  final String description;
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.collection,
    required this.menuEntries,
    required this.onTap,
  });

  final BlogCollection collection;
  final List<NasMenuEntry> menuEntries;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coverUrl = collection.coverUrl;
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (coverUrl != null && coverUrl.isNotEmpty)
            NasCoverImage(
              url: blogMediaUrl(coverUrl),
              icon: Icons.collections_bookmark_outlined,
              cacheWidth: 480,
              borderRadius: 0,
            )
          else
            ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                Icons.collections_bookmark_outlined,
                size: 36,
                color: context.nasTextSecondary,
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: NasTokens.spaceSm,
            right: 40,
            bottom: NasTokens.spaceSm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  collection.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('blog.collection.tracks', {'count': '${collection.tracks}'}),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: _CardMenuButton(entries: menuEntries),
          ),
        ],
      ),
    );
    return NasContextMenuRegion(
      entries: menuEntries,
      child: GestureDetector(onTap: onTap, child: card),
    );
  }
}

class _CardMenuButton extends StatelessWidget {
  const _CardMenuButton({required this.entries});

  final List<NasMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final e in entries)
          if (e.isDivider)
            const Divider(height: 1)
          else
            MenuItemButton(
              leadingIcon: e.icon == null ? null : Icon(e.icon, size: NasTokens.iconSm),
              onPressed: e.onSelected,
              child: Text(e.label),
            ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tr('common.more'),
        icon: const Icon(Icons.more_horiz, color: Colors.white),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// 合集详情：合集信息 + 播放全部 + 有序音频列表（移除 / 上移 / 下移）。
class BlogCollectionDetailPage extends StatefulWidget {
  const BlogCollectionDetailPage({super.key, required this.collection});

  final BlogCollection collection;

  @override
  State<BlogCollectionDetailPage> createState() =>
      _BlogCollectionDetailPageState();
}

class _BlogCollectionDetailPageState extends State<BlogCollectionDetailPage> {
  bool _loading = true;
  String? _error;
  BlogCollectionItemsResponse? _res;

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
      final res = await ApiSession.instance.client.blogCollectionItems(
        id: widget.collection.id,
      );
      if (!mounted) return;
      setState(() {
        _res = res;
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

  Future<void> _playAt(int index) async {
    final items = _res?.items ?? const <BlogCollectionItem>[];
    if (index < 0 || index >= items.length) return;
    final queue = items.map(_toEpisode).toList(growable: false);
    await BlogPlayer.instance.play(
      queue[index],
      queue,
      kind: BlogPlaybackKind.localBlog,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BlogPlayerPage()),
    );
  }

  static BlogEpisodeItem _toEpisode(BlogCollectionItem i) => BlogEpisodeItem(
        id: i.id,
        title: i.title,
        sourcePath: i.path,
        coverUrl: blogMediaUrl(i.coverUrl),
        voice: '',
        speed: 1,
        durationSec: 0,
        sizeBytes: i.size,
        itemCount: 0,
        status: 'done',
        error: null,
        parts: 0,
        doneParts: 0,
        sections: const <String>[],
        headlines: const <String>[],
        createdAt: 0,
        finishedAt: null,
      );

  Future<void> _remove(BlogCollectionItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('blog.collection.removeItem')),
        content: Text(tr('blog.collection.removeConfirm', {'name': item.title})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogCollectionRemoveItem(
        body: BlogCollectionRemoveItemBody(
          id: widget.collection.id,
          itemId: item.id,
        ),
      );
      NasSnack.showOn(messenger, tr('blog.collection.removeDone'));
      await _load();
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('blog.collection.removeFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  Future<void> _move(int index, int delta) async {
    final res = _res;
    if (res == null) return;
    final target = index + delta;
    if (target < 0 || target >= res.items.length) return;
    final items = List<BlogCollectionItem>.of(res.items);
    final moved = items.removeAt(index);
    items.insert(target, moved);
    setState(() {
      _res = BlogCollectionItemsResponse(
        id: res.id,
        name: res.name,
        description: res.description,
        items: items,
      );
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.blogCollectionReorder(
        body: BlogCollectionReorderBody(
          id: res.id,
          itemIds: items.map((e) => e.id).toList(growable: false),
        ),
      );
    } catch (e) {
      NasSnack.showOn(
        messenger,
        tr('blog.collection.saveFailed', {'error': '$e'}),
        error: true,
      );
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _res;
    final items = res?.items ?? const <BlogCollectionItem>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(res?.name ?? widget.collection.name),
        actions: [
          IconButton(
            tooltip: tr('blog.collection.playAll'),
            icon: const Icon(Icons.play_circle_outline),
            onPressed: items.isEmpty ? null : () => _playAt(0),
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: _load)
              : Column(
                  children: [
                    _infoCard(context, res),
                    Expanded(child: _list(items)),
                  ],
                ),
    );
  }

  Widget _infoCard(BuildContext context, BlogCollectionItemsResponse? res) {
    final items = res?.items ?? const <BlogCollectionItem>[];
    final description = res?.description ?? widget.collection.description;
    return Padding(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      child: NasCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    res?.name ?? widget.collection.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: NasTokens.fontSubtitle,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    tr('blog.collection.tracks', {'count': '${items.length}'}),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: NasTokens.spaceMd),
            FilledButton.icon(
              onPressed: items.isEmpty ? null : () => _playAt(0),
              icon: const Icon(Icons.play_arrow),
              label: Text(tr('blog.collection.playAll')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(List<BlogCollectionItem> items) {
    if (items.isEmpty) {
      return NasEmptyState(
        title: tr('blog.collection.itemsEmpty'),
        message: tr('blog.collection.itemsEmptyHint'),
        icon: Icons.podcasts_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        0,
        NasTokens.spaceLg,
        NasTokens.spaceLg,
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = items[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 48,
            height: 48,
            child: _thumb(context, item.coverUrl),
          ),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _sizeText(item.size),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          onTap: () => _playAt(i),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('blog.collection.moveUp'),
                onPressed: i == 0 ? null : () => _move(i, -1),
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              IconButton(
                tooltip: tr('blog.collection.moveDown'),
                onPressed: i == items.length - 1 ? null : () => _move(i, 1),
                icon: const Icon(Icons.arrow_downward, size: 18),
              ),
              IconButton(
                tooltip: tr('blog.collection.removeItem'),
                onPressed: () => _remove(item),
                icon: const Icon(Icons.remove_circle_outline, size: 18),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _thumb(BuildContext context, String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        ),
        child: const Icon(Icons.podcasts, size: 22),
      );
    }
    return NasCoverImage(
      url: blogMediaUrl(coverUrl),
      icon: Icons.podcasts,
      cacheWidth: 128,
      borderRadius: NasTokens.radiusSm,
    );
  }

  static String _sizeText(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i += 1;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}

/// 加入博客合集的弹层：勾选已有合集，或直接新建一个并加入。
///
/// 返回真正加入成功的条数；用户取消返回 null。
Future<int?> showAddToBlogCollectionSheet(
  BuildContext context,
  List<String> paths,
) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: _AddToCollectionSheet(paths: paths),
    ),
  );
}

class _AddToCollectionSheet extends StatefulWidget {
  const _AddToCollectionSheet({required this.paths});

  final List<String> paths;

  @override
  State<_AddToCollectionSheet> createState() => _AddToCollectionSheetState();
}

class _AddToCollectionSheetState extends State<_AddToCollectionSheet> {
  bool _loading = true;
  String? _error;
  bool _busy = false;
  List<BlogCollection> _items = const [];
  final Set<String> _checked = <String>{};
  final TextEditingController _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.blogCollections();
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

  Future<int> _addTo(String collectionId) async {
    final res = await ApiSession.instance.client.blogCollectionAdd(
      body: BlogCollectionAddBody(id: collectionId, paths: widget.paths),
    );
    return res.added;
  }

  Future<void> _submit() async {
    if (_checked.isEmpty || _busy) return;
    setState(() => _busy = true);
    var added = 0;
    try {
      for (final id in _checked) {
        added += await _addTo(id);
      }
      if (!mounted) return;
      Navigator.pop(context, added);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      NasSnack.show(context, '$e', error: true);
    }
  }

  Future<void> _createAndAdd() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final created = await ApiSession.instance.client.blogCollectionCreate(
        body: BlogCollectionBody(name: name),
      );
      final added = await _addTo(created.id);
      if (!mounted) return;
      Navigator.pop(context, added);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      NasSnack.show(
        context,
        tr('blog.collection.createFailed', {'error': '$e'}),
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  tr('blog.collection.addTitle'),
                  style: const TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.paths.length}',
                  style: TextStyle(color: context.nasTextSecondary),
                ),
              ],
            ),
            const SizedBox(height: NasTokens.spaceSm),
            Flexible(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(NasTokens.spaceLg),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(NasTokens.spaceLg),
                          child: Text('$_error'),
                        )
                      : _items.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(NasTokens.spaceLg),
                              child: Text(
                                tr('blog.collection.addNone'),
                                style: TextStyle(color: context.nasTextSecondary),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: _items.length,
                              itemBuilder: (context, i) {
                                final c = _items[i];
                                return CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: _checked.contains(c.id),
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() {
                                            if (v == true) {
                                              _checked.add(c.id);
                                            } else {
                                              _checked.remove(c.id);
                                            }
                                          }),
                                  title: Text(
                                    c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    tr('blog.collection.tracks',
                                        {'count': '${c.tracks}'}),
                                    style: const TextStyle(
                                      fontSize: NasTokens.fontCaption,
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
            const Divider(height: NasTokens.spaceLg),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr('blog.collection.addNewHint'),
                    ),
                    onSubmitted: (_) => _createAndAdd(),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                TextButton.icon(
                  onPressed: _busy ? null : _createAndAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('blog.collection.createAndAdd')),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr('common.cancel')),
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  FilledButton(
                    onPressed: _checked.isEmpty || _busy ? null : _submit,
                    style: FilledButton.styleFrom(backgroundColor: scheme.primary),
                    child: Text(tr('blog.collection.add')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
