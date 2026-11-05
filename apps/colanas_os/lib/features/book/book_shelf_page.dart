import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/scan_refresh.dart';
import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'book_cache.dart';
import 'book_detail_page.dart';
import 'book_widgets.dart';

/// 藏书 · 书籍 / 漫画 / 收藏：封面卡片网格 + 搜索 / 排序 / 来源筛选。
class BookShelfPage extends StatefulWidget {
  const BookShelfPage({
    super.key,
    this.type,
    this.favoriteOnly = false,
    this.embedded = true,
  });

  /// `book` / `comic`；收藏页为 null
  final String? type;
  final bool favoriteOnly;
  final bool embedded;

  @override
  State<BookShelfPage> createState() => _BookShelfPageState();
}

class _BookShelfPageState extends State<BookShelfPage> {
  final _searchCtrl = TextEditingController();
  late final BookSearchDebouncer _searchDebounce = BookSearchDebouncer(_load);

  bool _loading = true;
  bool _error = false;
  String? _errorText;
  List<BookItem> _items = const [];
  List<BookLibraryItem> _libs = const [];
  String _query = '';
  String? _libraryId;
  String _sort = 'title';
  bool _desc = false;

  bool _selectMode = false;
  Set<String> _selected = <String>{};

  late final void Function() _unsubScan;

  @override
  void initState() {
    super.initState();
    _unsubScan = listenScanDone('book', () {
      if (mounted) _load();
    });
    _searchCtrl.addListener(_onSearchText);
    if (BookCache.instance.supported) {
      BookCache.instance.ensureIndexed().catchError((_) {});
    }
    _load();
    _loadLibs();
  }

  @override
  void dispose() {
    _unsubScan();
    _searchCtrl.removeListener(_onSearchText);
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  void _onSearchText() {
    final next = _searchCtrl.text.trim();
    if (next == _query) return;
    _query = next;
    _searchDebounce.run();
  }

  Future<void> _loadLibs() async {
    try {
      final res = await ApiSession.instance.client.bookLibraryList();
      if (!mounted) return;
      setState(() => _libs = res.items);
    } catch (_) {
      // 来源列表失败不影响书架
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _errorText = null;
    });
    try {
      final res = await ApiSession.instance.client.bookList(
        type: widget.type,
        q: _query.isEmpty ? null : _query,
        favorite: widget.favoriteOnly ? '1' : null,
        libraryId: _libraryId,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _items = _sorted(res.items);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _errorText = '$e';
        _loading = false;
      });
    }
  }

  List<BookItem> _sorted(List<BookItem> input) {
    final list = [...input];
    int cmp(BookItem a, BookItem b) => switch (_sort) {
      'author' => (a.author ?? '').compareTo(b.author ?? ''),
      'progress' => (a.progressPercent ?? 0).compareTo(b.progressPercent ?? 0),
      _ => a.title.compareTo(b.title),
    };
    list.sort((a, b) => _desc ? cmp(b, a) : cmp(a, b));
    return list;
  }

  Future<void> _toggleFavorite(BookItem book) async {
    final next = !book.favorite;
    try {
      if (next) {
        await ApiSession.instance.client.bookFavoriteAdd(
          body: BookFavoriteBody(id: book.id),
        );
      } else {
        await ApiSession.instance.client.bookFavoriteRemove(
          body: BookFavoriteBody(id: book.id),
        );
      }
      if (!mounted) return;
      if (widget.favoriteOnly && !next) {
        setState(() => _items = _items.where((x) => x.id != book.id).toList());
      } else {
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _toggleArchive(BookItem book) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final next = !book.archived;
      await ApiSession.instance.client.bookArchive(
        body: BookArchiveBody(id: book.id, archived: next),
      );
      if (!mounted) return;
      NasSnack.showOn(messenger, next ? tr('ui.book.018') : tr('ui.book.019'));
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _addToList(BookItem book) async {
    final messenger = ScaffoldMessenger.of(context);
    final lists = await ApiSession.instance.client.bookLists();
    if (!mounted) return;
    if (lists.items.isEmpty) {
      NasSnack.showOn(messenger, tr('book.lists.empty'));
      return;
    }
    final target = await showDialog<BookListItem>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('book.lists.addBook')),
        children: [
          for (final l in lists.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, l),
              child: Text(l.name),
            ),
        ],
      ),
    );
    if (target == null) return;
    try {
      await ApiSession.instance.client.bookListAdd(
        body: BookListRefBody(listId: target.id, bookId: book.id),
      );
      NasSnack.showOn(messenger, tr('music.addedTo', {'name': target.name}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _copyPath(BookItem book) async {
    await Clipboard.setData(ClipboardData(text: book.path));
    if (!mounted) return;
    NasSnack.show(context, tr('ui.book.020'));
  }

  Future<void> _cacheToLocal(BookItem book) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!BookCache.instance.supported) {
      NasSnack.showOn(messenger, tr('book.cache.hint'));
      return;
    }
    try {
      await BookCache.instance.download(
        book: book,
        url:
            '${ApiSession.instance.baseUrl}/api/v1/book/file?id=${Uri.encodeComponent(book.id)}',
        headers: ApiSession.instance.authHeaders,
      );
      NasSnack.showOn(messenger, tr('music.cache.done'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('music.cache.failed', {'error': '$e'}));
    }
  }

  Future<void> _open(BookItem book) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => BookDetailPage(book: book)),
    );
    await _load();
  }

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selected = <String>{};
    });
  }

  void _toggleSelected(BookItem book) {
    setState(() {
      if (_selected.contains(book.id)) {
        _selected.remove(book.id);
      } else {
        _selected.add(book.id);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _items.length) {
        _selected.clear();
      } else {
        _selected = _items.map((b) => b.id).toSet();
      }
    });
  }

  List<BookItem> get _selectedBooks =>
      _items.where((b) => _selected.contains(b.id)).toList();

  Future<void> _batchFavorite() async {
    final messenger = ScaffoldMessenger.of(context);
    final books = _selectedBooks;
    if (books.isEmpty) return;
    final allFav = books.every((b) => b.favorite);
    try {
      for (final b in books) {
        if (allFav) {
          await ApiSession.instance.client.bookFavoriteRemove(
            body: BookFavoriteBody(id: b.id),
          );
        } else {
          await ApiSession.instance.client.bookFavoriteAdd(
            body: BookFavoriteBody(id: b.id),
          );
        }
      }
      if (!mounted) return;
      _toggleSelectMode();
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _batchArchive() async {
    final messenger = ScaffoldMessenger.of(context);
    final books = _selectedBooks;
    if (books.isEmpty) return;
    final allArchived = books.every((b) => b.archived);
    try {
      for (final b in books) {
        await ApiSession.instance.client.bookArchive(
          body: BookArchiveBody(id: b.id, archived: !allArchived),
        );
      }
      if (!mounted) return;
      _toggleSelectMode();
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _batchAddToList() async {
    final messenger = ScaffoldMessenger.of(context);
    final books = _selectedBooks;
    if (books.isEmpty) return;
    final lists = await ApiSession.instance.client.bookLists();
    if (!mounted) return;
    if (lists.items.isEmpty) {
      NasSnack.showOn(messenger, tr('book.lists.empty'));
      return;
    }
    final target = await showDialog<BookListItem>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('book.lists.addBook')),
        children: [
          for (final l in lists.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, l),
              child: Text(l.name),
            ),
        ],
      ),
    );
    if (target == null) return;
    try {
      for (final b in books) {
        await ApiSession.instance.client.bookListAdd(
          body: BookListRefBody(listId: target.id, bookId: b.id),
        );
      }
      if (!mounted) return;
      _toggleSelectMode();
      NasSnack.showOn(messenger, tr('music.addedTo', {'name': target.name}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Widget _selectBar() {
    final scheme = Theme.of(context).colorScheme;
    final all = _items.isNotEmpty && _selected.length == _items.length;
    final disabled = _selected.isEmpty;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Checkbox(value: all, onChanged: (_) => _toggleSelectAll()),
          const SizedBox(width: NasTokens.spaceXs),
          Text(
            all ? tr('book.select.none') : tr('book.select.all'),
            style: const TextStyle(fontSize: NasTokens.fontCaption),
          ),
          const SizedBox(width: NasTokens.spaceMd),
          Text(
            tr('book.select.count', {'count': '${_selected.length}'}),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: tr('ui.book.014'),
            icon: const Icon(Icons.favorite_border),
            onPressed: disabled ? null : _batchFavorite,
          ),
          IconButton(
            tooltip: tr('ui.book.015'),
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: disabled ? null : _batchArchive,
          ),
          IconButton(
            tooltip: tr('book.lists.addBook'),
            icon: const Icon(Icons.playlist_add),
            onPressed: disabled ? null : _batchAddToList,
          ),
          IconButton(
            tooltip: tr('common.cancel'),
            icon: const Icon(Icons.close),
            onPressed: _toggleSelectMode,
          ),
        ],
      ),
    );
  }

  List<NasMenuEntry> _menuFor(BookItem book) => [
    NasMenuEntry(
      label: tr('common.open'),
      icon: Icons.menu_book,
      onSelected: () => _open(book),
    ),
    NasMenuEntry(
      label: book.favorite ? tr('ui.book.021') : tr('ui.book.014'),
      icon: book.favorite ? Icons.favorite : Icons.favorite_border,
      onSelected: () => _toggleFavorite(book),
    ),
    NasMenuEntry(
      label: book.archived ? tr('ui.book.022') : tr('ui.book.015'),
      icon: book.archived
          ? Icons.unarchive_outlined
          : Icons.inventory_2_outlined,
      onSelected: () => _toggleArchive(book),
    ),
    const NasMenuEntry.divider(),
    NasMenuEntry(
      label: tr('book.lists.addBook'),
      icon: Icons.playlist_add,
      onSelected: () => _addToList(book),
    ),
    NasMenuEntry(
      label: tr('ui.book.025'),
      icon: Icons.copy,
      onSelected: () => _copyPath(book),
    ),
    NasMenuEntry(
      label: tr('music.cache.download'),
      icon: Icons.download_outlined,
      onSelected: () => _cacheToLocal(book),
    ),
  ];

  Widget _sourceButton() {
    if (_libs.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String?>(
      tooltip: tr('book.source.title'),
      icon: Icon(
        Icons.source_outlined,
        size: 20,
        color: _libraryId == null
            ? null
            : Theme.of(context).colorScheme.primary,
      ),
      onSelected: (v) {
        setState(() => _libraryId = v);
        _load();
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem<String?>(
          value: null,
          checked: _libraryId == null,
          child: Text(tr('book.filter.all')),
        ),
        for (final l in _libs)
          CheckedPopupMenuItem<String?>(
            value: l.id,
            checked: _libraryId == l.id,
            child: Text(l.name),
          ),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error) {
      return NasErrorState(message: _errorText ?? '', onRetry: _load);
    }
    if (_items.isEmpty) {
      return NasEmptyState(
        title: widget.favoriteOnly
            ? tr('ui.book.017')
            : widget.type == 'comic'
            ? tr('book.empty.comics')
            : tr('book.empty.books'),
        message: _query.isEmpty ? tr('ui.book.h8eccf0') : null,
        icon: Icons.menu_book_outlined,
      );
    }
    return CustomScrollView(
      slivers: [
        BookGridSliver(
          books: _items,
          itemBuilder: (context, book, i) => BookCard(
            book: book,
            onOpen: () => _open(book),
            onToggleFavorite: () => _toggleFavorite(book),
            menuEntries: _menuFor(book),
            selectionMode: _selectMode,
            selected: _selected.contains(book.id),
            onToggleSelected: () => _toggleSelected(book),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        BookToolbar(
          searchController: _searchCtrl,
          searchHint: tr('ui.book.013'),
          onSubmitted: (v) {
            final next = v.trim();
            if (next == _query) return;
            _query = next;
            _load();
          },
          onClear: () {
            if (_query.isEmpty) return;
            setState(() => _query = '');
            _load();
          },
          actions: [
            _sourceButton(),
            BookSortButton(
              value: _sort,
              desc: _desc,
              options: const [
                ('title', 'book.sort.title'),
                ('author', 'book.sort.author'),
                ('progress', 'book.sort.progress'),
              ],
              onChanged: (value, desc) {
                setState(() {
                  _sort = value;
                  _desc = desc;
                  _items = _sorted(_items);
                });
              },
            ),
            NasRefreshButton(onPressed: _load),
            IconButton(
              tooltip: tr('common.select'),
              icon: Icon(_selectMode ? Icons.close : Icons.checklist),
              onPressed: _items.isEmpty ? null : _toggleSelectMode,
            ),
          ],
        ),
        Expanded(child: _body()),
        if (_selectMode) _selectBar(),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.favoriteOnly
              ? tr('nav.favorites')
              : widget.type == 'comic'
              ? tr('book.nav.comics')
              : tr('book.nav.books'),
        ),
      ),
      body: body,
    );
  }
}
