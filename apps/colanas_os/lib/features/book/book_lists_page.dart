import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'book_detail_page.dart';
import 'book_widgets.dart';

/// 书单 · 我的书单：新建 / 重命名 / 删除，点开看里面的书。
class BookListsPage extends StatefulWidget {
  const BookListsPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<BookListsPage> createState() => _BookListsPageState();
}

class _BookListsPageState extends State<BookListsPage> {
  bool _loading = true;
  String? _error;
  List<BookListItem> _items = const [];

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
      final res = await ApiSession.instance.client.bookLists();
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

  Future<String?> _promptName({required String title, String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('book.lists.create')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.confirm')),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final name = await _promptName(title: tr('book.lists.create'));
    if (name == null || !mounted) return;
    try {
      await ApiSession.instance.client.bookListCreate(
        body: BookListCreateBody(name: name),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _rename(BookListItem item) async {
    final name = await _promptName(
      title: tr('book.lists.rename'),
      initial: item.name,
    );
    if (name == null || !mounted) return;
    try {
      await ApiSession.instance.client.bookListRename(
        body: BookListRenameBody(id: item.id, name: name),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _delete(BookListItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(tr('book.lists.deleteConfirm', {'name': item.name})),
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
      await ApiSession.instance.client.bookListRemove(
        body: BookListRemoveBody(id: item.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  Future<void> _open(BookListItem item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => BookListDetailPage(list: item)),
    );
    await _load();
  }

  List<NasMenuEntry> _menuFor(BookListItem item) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.playlist_play,
      onSelected: () => _open(item),
    ),
    NasMenuEntry(
      label: tr('book.lists.rename'),
      icon: Icons.edit_outlined,
      onSelected: () => _rename(item),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('common.delete'),
      icon: Icons.delete_outline,
      danger: true,
      onSelected: () => _delete(item),
    ),
  ];

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('book.lists.empty'),
        icon: Icons.playlist_add,
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = _items[i];
        return NasContextMenuRegion(
          entries: _menuFor(item),
          child: ListTile(
            leading: const Icon(Icons.playlist_play),
            title: Text(item.name),
            subtitle: Text(tr('book.shelfCount', {'count': '${item.books}'})),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(item),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        BookPaneHeader(
          title: tr('book.nav.myLists'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('book.lists.create'),
                icon: const Icon(Icons.playlist_add),
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
      appBar: AppBar(title: Text(tr('book.nav.myLists'))),
      body: body,
    );
  }
}

/// 书单里的书：点开详情，可移出书单。
class BookListDetailPage extends StatefulWidget {
  const BookListDetailPage({super.key, required this.list});

  final BookListItem list;

  @override
  State<BookListDetailPage> createState() => _BookListDetailPageState();
}

class _BookListDetailPageState extends State<BookListDetailPage> {
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
      final res = await ApiSession.instance.client.bookListItems(
        listId: widget.list.id,
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

  Future<void> _remove(BookItem book) async {
    try {
      await ApiSession.instance.client.bookListRemoveItem(
        body: BookListRefBody(listId: widget.list.id, bookId: book.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _open(BookItem book) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => BookDetailPage(book: book)),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.list.name, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('book.lists.emptyBooks'),
              icon: Icons.playlist_play,
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => BookRow(
                book: _items[i],
                onOpen: () => _open(_items[i]),
                trailing: IconButton(
                  tooltip: tr('book.lists.removeBook'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => _remove(_items[i]),
                ),
              ),
            ),
    );
  }
}
