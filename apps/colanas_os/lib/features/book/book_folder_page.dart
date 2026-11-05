import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'book_detail_page.dart';
import 'book_widgets.dart';

/// 藏书 · 文件视图：按目录聚合已索引的书（客户端分组，最多取 200 本）。
class BookFolderPage extends StatefulWidget {
  const BookFolderPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<BookFolderPage> createState() => _BookFolderPageState();
}

class _BookFolderPageState extends State<BookFolderPage> {
  bool _loading = true;
  String? _error;
  List<BookItem> _books = const [];

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
      final res = await ApiSession.instance.client.bookList(limit: 200);
      if (!mounted) return;
      setState(() {
        _books = res.items;
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

  Map<String, List<BookItem>> get _folders {
    final map = <String, List<BookItem>>{};
    for (final b in _books) {
      final i = b.path.lastIndexOf('/');
      final dir = i < 0 ? '/' : b.path.substring(0, i);
      map.putIfAbsent(dir, () => []).add(b);
    }
    final keys = map.keys.toList()..sort();
    return {for (final k in keys) k: map[k]!};
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final folders = _folders;
    if (folders.isEmpty) {
      return NasEmptyState(
        title: tr('ui.book.016'),
        icon: Icons.folder_outlined,
      );
    }
    return ListView.separated(
      itemCount: folders.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final name = folders.keys.elementAt(i);
        final books = folders[name]!;
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(name),
          subtitle: Text(tr('book.shelfCount', {'count': '${books.length}'})),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => _FolderBooksPage(folder: name, books: books),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _body();
    return Scaffold(
      appBar: AppBar(title: Text(tr('nav.filesView'))),
      body: _body(),
    );
  }
}

class _FolderBooksPage extends StatelessWidget {
  const _FolderBooksPage({required this.folder, required this.books});

  final String folder;
  final List<BookItem> books;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(folder, overflow: TextOverflow.ellipsis)),
      body: ListView.separated(
        itemCount: books.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => BookRow(
          book: books[i],
          onOpen: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => BookDetailPage(book: books[i]),
            ),
          ),
        ),
      ),
    );
  }
}
