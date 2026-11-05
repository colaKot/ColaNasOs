import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import '../photo/folder_picker.dart';
import 'book_detail_page.dart';
import 'book_widgets.dart';

/// 书单 · 合集：用户自建的一组图书目录（目录里新放的书自动进来）。
class BookCollectionsPage extends StatefulWidget {
  const BookCollectionsPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<BookCollectionsPage> createState() => _BookCollectionsPageState();
}

class _BookCollectionsPageState extends State<BookCollectionsPage> {
  bool _loading = true;
  String? _error;
  List<BookUserCollection> _items = const [];

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
      final res = await ApiSession.instance.client.bookUserCollectionList();
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

  Future<_CollectionDraft?> _editDialog({BookUserCollection? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final paths = <String>[...?existing?.paths];
    return showDialog<_CollectionDraft>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
            existing == null
                ? tr('book.collection.create')
                : tr('book.collection.edit'),
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('book.collection.name'),
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                Text(
                  tr('book.collection.paths'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                if (paths.isEmpty)
                  Text(
                    tr('book.collection.noPath'),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  for (final p in paths)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: tr('common.delete'),
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setLocal(() => paths.remove(p)),
                        ),
                      ],
                    ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final picked = await showFolderPicker(ctx);
                      if (picked == null || picked.isEmpty) return;
                      if (!paths.contains(picked)) {
                        setLocal(() => paths.add(picked));
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: Text(tr('book.collection.addPath')),
                  ),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  tr('book.collection.pathsHint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
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
                if (name.isEmpty || paths.isEmpty) return;
                Navigator.pop(
                  ctx,
                  _CollectionDraft(name: name, paths: [...paths]),
                );
              },
              child: Text(tr('common.confirm')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    final draft = await _editDialog();
    if (draft == null || !mounted) return;
    try {
      await ApiSession.instance.client.bookUserCollectionCreate(
        body: BookUserCollectionBody(name: draft.name, paths: draft.paths),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _edit(BookUserCollection c) async {
    final draft = await _editDialog(existing: c);
    if (draft == null || !mounted) return;
    try {
      await ApiSession.instance.client.bookUserCollectionUpdate(
        body: BookUserCollectionUpdateBody(
          id: c.id,
          name: draft.name,
          paths: draft.paths,
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _delete(BookUserCollection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(tr('book.collection.deleteConfirm', {'name': c.name})),
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
    try {
      await ApiSession.instance.client.bookUserCollectionRemove(
        body: BookLibraryRemoveBody(id: c.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  Future<void> _open(BookUserCollection c) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BookCollectionDetailPage(collection: c),
      ),
    );
    await _load();
  }

  List<NasMenuEntry> _menuFor(BookUserCollection c) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.collections_bookmark_outlined,
      onSelected: () => _open(c),
    ),
    NasMenuEntry(
      label: tr('book.collection.edit'),
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
        title: tr('book.collection.empty'),
        message: tr('book.collection.emptyHint'),
        icon: Icons.collections_bookmark_outlined,
      );
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceXs,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.crossAxisExtent < 750;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: compact ? 1 : 3,
                  crossAxisSpacing: NasTokens.spaceSm,
                  mainAxisSpacing: NasTokens.spaceSm,
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
    final body = Column(
      children: [
        BookPaneHeader(
          title: tr('book.nav.collections'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('book.collection.create'),
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _create,
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('book.nav.collections'))),
      body: body,
    );
  }
}

class _CollectionDraft {
  const _CollectionDraft({required this.name, required this.paths});

  final String name;
  final List<String> paths;
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.collection,
    required this.menuEntries,
    required this.onTap,
  });

  final BookUserCollection collection;
  final List<NasMenuEntry> menuEntries;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (collection.coverId != null)
            NasCoverImage(
              url: bookCoverUrl(collection.coverId!),
              headers: ApiSession.instance.authHeaders,
              cacheWidth: 480,
              fallbackText: collection.name,
              icon: Icons.collections_bookmark_outlined,
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
                  tr('book.shelfCount', {'count': '${collection.books}'}),
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
            child: _CollectionMenuButton(entries: menuEntries),
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

class _CollectionMenuButton extends StatelessWidget {
  const _CollectionMenuButton({required this.entries});

  final List<NasMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          ),
        ),
      ),
      menuChildren: [
        for (final e in entries)
          if (e.isDivider)
            const Divider(height: 9, thickness: 1)
          else
            MenuItemButton(
              leadingIcon: e.icon == null
                  ? null
                  : Icon(
                      e.icon,
                      size: NasTokens.iconSm,
                      color: e.danger ? scheme.error : scheme.onSurface,
                    ),
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

/// 合集里的书。
class BookCollectionDetailPage extends StatefulWidget {
  const BookCollectionDetailPage({super.key, required this.collection});

  final BookUserCollection collection;

  @override
  State<BookCollectionDetailPage> createState() =>
      _BookCollectionDetailPageState();
}

class _BookCollectionDetailPageState extends State<BookCollectionDetailPage> {
  bool _loading = true;
  String? _error;
  List<BookItem> _items = const [];

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
      final res = await ApiSession.instance.client.bookUserCollectionItems(
        id: widget.collection.id,
        limit: 500,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.collection.name, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('book.collection.empty'),
              message: tr('book.collection.emptyHint'),
              icon: Icons.collections_bookmark_outlined,
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => BookRow(
                book: _items[i],
                onOpen: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => BookDetailPage(book: _items[i]),
                  ),
                ),
              ),
            ),
    );
  }
}
