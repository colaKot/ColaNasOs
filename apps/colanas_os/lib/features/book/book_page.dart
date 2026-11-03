import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/scan_refresh.dart';
import '../../core/session.dart';
import 'reader_page.dart';

/// 书房：书架 / 搜索 / 格式过滤 / 收藏 / 归档筛选 / 合集 / 阅读进度 / 复制阅读地址。
///
/// 内置阅读器（epub / txt / cbz）与合集、归档已交付；epub 的 CSS 版式还原与 pdf 内置阅读仍属二期。
class BookPage extends StatefulWidget {
  const BookPage({super.key});

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  static const _pageSize = 60;

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _nextCursor;
  String _query = '';
  String? _format;
  bool _favoriteOnly = false;
  bool _archivedOnly = false;

  List<BookItem> _books = const [];
  List<BookLibraryItem> _libraries = const [];
  BookStatsResponse? _stats;

  late final void Function() _unsubScan;

  @override
  void initState() {
    super.initState();
    _unsubScan = listenScanDone('book', () {
      if (mounted) _bootstrap();
    });
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _unsubScan();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _nextCursor == null) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _load(more: true);
    }
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      final list = await client.bookList(limit: _pageSize);
      final stats = await client.bookStats();
      final libraries = await client.bookLibraryList();
      if (!mounted) return;
      setState(() {
        _books = list.items;
        _nextCursor = list.nextCursor;
        _stats = stats;
        _libraries = libraries.items;
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

  Future<void> _load({bool more = false}) async {
    if (more && (_loadingMore || _nextCursor == null)) return;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final res = await ApiSession.instance.client.bookList(
        q: _query.isEmpty ? null : _query,
        format: _format,
        favorite: _favoriteOnly ? '1' : null,
        archived: _archivedOnly ? '1' : null,
        cursor: more ? _nextCursor : null,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _books = more ? [..._books, ...res.items] : res.items;
        _nextCursor = res.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _scan() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.bookScan(
        body: const BookScanBody(),
      );
      final missing = res.missing ?? 0;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('book.scanDone', {'added': '${res.added}', 'updated': '${res.updated}', 'skipped': '${res.skipped}', 'parsed': '${res.parsed}'}) +
                (missing > 0 ? tr('common.missingOnDisk', {'count': '$missing'}) : ''),
          ),
          action: missing > 0
              ? SnackBarAction(
                  label: tr('ui.book.001'),
                  onPressed: () => _pruneMissing(missing),
                )
              : null,
        ),
      );
      await _bootstrap();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.scanFailed', {'error': '$e'}))));
    }
  }

  /// 清理「索引有、磁盘无」的书（服务端默认不删，需显式 prune）
  Future<void> _pruneMissing(int count) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.book.002')),
        content: Text(tr('book.pruneConfirm', {'count': '$count'})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.book.001')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ApiSession.instance.client.bookScan(
        body: const BookScanBody(prune: true),
      );
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.prunedRecords', {'count': '${res.pruned ?? 0}'}))),
      );
      await _bootstrap();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.cleanupFailed', {'error': '$e'}))));
    }
  }

  Future<void> _createLibrary() async {
    final nameCtrl = TextEditingController(text: tr('ui.book.h2c598c'));
    final pathCtrl = TextEditingController(text: 'books');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.book.003')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: tr('ui.book.004')),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: pathCtrl,
              decoration: InputDecoration(
                labelText: tr('ui.book.005'),
                hintText: 'books',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.006')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiSession.instance.client.bookLibraryCreate(
        body: BookLibraryCreateBody(
          name: nameCtrl.text.trim(),
          path: pathCtrl.text.trim(),
        ),
      );
      await _bootstrap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.createFailed', {'error': '$e'}))));
    }
  }

  Future<void> _openBook(BookItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _BookDetailPage(
          book: item,
          coverUrl: ApiSession.instance.coverUrl('book', item.id),
          headers: ApiSession.instance.authHeaders,
        ),
      ),
    );
    await _bootstrap();
  }

  Future<void> _fulltextSearch() async {
    final ctrl = TextEditingController();
    final keyword = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.book.006')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('ui.book.007'),
            helperText: tr('ui.book.008'),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(tr('common.search')),
          ),
        ],
      ),
    );
    if (keyword == null || keyword.trim().isEmpty) return;

    try {
      final res = await ApiSession.instance.client.bookFulltextSearch(
        q: keyword.trim(),
        limit: 50,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('book.fulltextTitle', {'keyword': keyword.trim()})),
          content: SizedBox(
            width: 560,
            height: 380,
            child: res.items.isEmpty
                ? Center(child: Text(tr('ui.book.009')))
                : ListView.separated(
                    itemCount: res.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final hit = res.items[i];
                      return ListTile(
                        title: Text(hit.title),
                        subtitle: Text(
                          [
                            if (hit.author != null && hit.author!.isNotEmpty)
                              hit.author!,
                            hit.snippet,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.close')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.searchFailed', {'error': '$e'}))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('ui.book.010')),
        actions: [
          IconButton(
            tooltip: tr('ui.book.003'),
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _createLibrary,
          ),
          IconButton(
            tooltip: tr('ui.book.011'),
            icon: const Icon(Icons.collections_bookmark_outlined),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => _CollectionsPage(headers: ApiSession.instance.authHeaders),
              ),
            ),
          ),
          IconButton(
            tooltip: tr('ui.book.006'),
            icon: const Icon(Icons.manage_search),
            onPressed: _fulltextSearch,
          ),
          IconButton(
            tooltip: tr('ui.book.012'),
            icon: const Icon(Icons.sync),
            onPressed: _scan,
          ),
          IconButton(
            tooltip: tr('ui.accounts.021'),
            icon: const Icon(Icons.refresh),
            onPressed: _bootstrap,
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _bootstrap)
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NasTokens.spaceMd,
                    NasTokens.spaceSm,
                    NasTokens.spaceMd,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: NasSearchField(
                          controller: _searchCtrl,
                          hintText: tr('ui.book.013'),
                          onClear: () {
                            setState(() => _query = '');
                            _load();
                          },
                          onSubmitted: (v) {
                            setState(() => _query = v.trim());
                            _load();
                          },
                        ),
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      FilterChip(
                        label: Text(tr('ui.book.014')),
                        selected: _favoriteOnly,
                        onSelected: (v) {
                          setState(() => _favoriteOnly = v);
                          _load();
                        },
                      ),
                      const SizedBox(width: NasTokens.spaceXs),
                      FilterChip(
                        label: Text(tr('ui.book.015')),
                        selected: _archivedOnly,
                        onSelected: (v) {
                          setState(() => _archivedOnly = v);
                          _load();
                        },
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      Text(
                        stats == null
                            ? ''
                            : tr('book.stats', {'books': '${stats.books}', 'favorites': '${stats.favorites}'}),
                        style: TextStyle(
                          color: context.nasTextSecondary,
                          fontSize: NasTokens.fontCaption,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NasTokens.spaceMd,
                  ),
                  child: Wrap(
                    spacing: NasTokens.spaceSm,
                    children: [
                      for (final f in const ['epub', 'pdf', 'txt', 'cbz'])
                        ChoiceChip(
                          label: Text(f.toUpperCase()),
                          selected: _format == f,
                          onSelected: (v) {
                            setState(() => _format = v ? f : null);
                            _load();
                          },
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _books.isEmpty
                      ? NasEmptyState(
                          title: _query.isEmpty && !_favoriteOnly
                              ? tr('ui.book.016')
                              : tr('ui.book.017'),
                          message: _libraries.isEmpty
                              ? tr('ui.book.h8eccf0')
                              : tr('ui.book.h39ee20'),
                          icon: Icons.menu_book_outlined,
                        )
                      : LayoutBuilder(
                          builder: (context, c) {
                            final columns = gridColumns(c.maxWidth);
                            return GridView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.all(NasTokens.spaceSm),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: NasTokens.spaceSm,
                                    mainAxisSpacing: NasTokens.spaceSm,
                                    childAspectRatio: 0.62,
                                  ),
                              itemCount: _books.length + (_loadingMore ? 1 : 0),
                              itemBuilder: (context, i) {
                                if (i >= _books.length) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }
                                final item = _books[i];
                                return _BookTile(
                                  book: item,
                                  coverUrl: ApiSession.instance.coverUrl('book', item.id),
                                  headers: ApiSession.instance.authHeaders,
                                  onTap: () => _openBook(item),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.coverUrl,
    required this.headers,
    required this.onTap,
  });

  final BookItem book;
  final String coverUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  child: book.hasCover
                      ? NasCoverImage(
                          url: coverUrl,
                          fit: BoxFit.cover,
                          cacheWidth: 360,
                          headers: headers,
                          fallbackText: book.title,
                          borderRadius: NasTokens.radiusSm,
                        )
                      : NasCoverImage(
                          url: null,
                          fallbackText: book.title,
                          borderRadius: NasTokens.radiusSm,
                        ),
                ),
                if (book.favorite)
                  const Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      Icons.favorite,
                      size: 16,
                      color: Colors.redAccent,
                    ),
                  ),
                if (book.progressPercent != null && book.progressPercent! > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: book.progressPercent! / 100,
                      minHeight: 3,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: NasTokens.fontBody),
          ),
          Text(
            [
              book.author ?? tr('ui.book.h9c5bde'),
              book.format.toUpperCase(),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BookDetailPage extends StatefulWidget {
  const _BookDetailPage({
    required this.book,
    required this.coverUrl,
    required this.headers,
  });

  final BookItem book;
  final String coverUrl;
  final Map<String, String> headers;

  @override
  State<_BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<_BookDetailPage> {
  late bool _favorite = widget.book.favorite;
  late bool _archived = widget.book.archived;
  int _percent = 0;
  String _position = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    try {
      final p = await ApiSession.instance.client.bookProgress(
        id: widget.book.id,
      );
      if (!mounted) return;
      setState(() {
        _percent = p.percent;
        _position = p.position;
      });
    } catch (_) {
      // 进度读取失败不影响详情展示
    }
  }

  Future<void> _toggleFavorite() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (_favorite) {
        await ApiSession.instance.client.bookFavoriteRemove(
          body: BookFavoriteBody(id: widget.book.id),
        );
      } else {
        await ApiSession.instance.client.bookFavoriteAdd(
          body: BookFavoriteBody(id: widget.book.id),
        );
      }
      if (!mounted) return;
      setState(() => _favorite = !_favorite);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.errorWith', {'error': '$e'}))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleArchive() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final next = !_archived;
      await ApiSession.instance.client.bookArchive(
        body: BookArchiveBody(id: widget.book.id, archived: next),
      );
      if (!mounted) return;
      setState(() => _archived = next);
      messenger.showSnackBar(
        SnackBar(content: Text(next ? tr('ui.book.018') : tr('ui.book.019'))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.errorWith', {'error': '$e'}))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveProgress(int percent) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final p = await ApiSession.instance.client.bookProgressSave(
        body: BookProgressBody(
          id: widget.book.id,
          position: 'manual:$percent',
          percent: percent,
        ),
      );
      if (!mounted) return;
      setState(() {
        _percent = p.percent;
        _position = p.position;
      });
      messenger.showSnackBar(SnackBar(content: Text(tr('common.progressSaved', {'percent': '${p.percent}'}))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.saveFailed', {'error': '$e'}))));
    }
  }

  Future<void> _copyReadUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.bookFileUrl(
        id: widget.book.id,
      );
      await Clipboard.setData(
        ClipboardData(text: '${ApiSession.instance.baseUrl}${res.url}'),
      );
      messenger.showSnackBar(
        SnackBar(content: Text(tr('book.shareCopied', {'minutes': '${res.expiresInSec ~/ 60}'}))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('book.shareFailed', {'error': '$e'}))));
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.book.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('ui.book.020'))));
  }

  /// 打开内置阅读器；关闭后刷新进度（阅读器内翻页会写回 `ch:<index>`）。
  Future<void> _openReader() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            BookReaderPage(bookId: widget.book.id, title: widget.book.title),
      ),
    );
    if (!mounted) return;
    await _loadProgress();
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final rows = <(String, String)>[
      (tr('ui.book.h698bea'), book.author ?? tr('ui.book.hd9c32a')),
      (tr('ui.book.h9d2601'), book.format.toUpperCase()),
      (tr('ui.discover.002'), book.language ?? tr('ui.book.hd9c32a')),
      (tr('ui.book.h4b60a3'), book.publisher ?? tr('ui.book.hd9c32a')),
      (
        tr('ui.book.hbadd9d'),
        book.pageCount == null ? tr('ui.book.hd9c32a') : '${book.pageCount}',
      ),
      (tr('files.size'), formatBytes(book.size)),
      (
        tr('ui.book.hacf014'),
        _percent == 0
            ? tr('ui.book.h062e5e')
            : '$_percent%${_position.isEmpty ? '' : ' · $_position'}',
      ),
      (tr('ui.book.025'), book.path),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(book.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _favorite ? tr('ui.book.021') : tr('ui.book.014'),
            icon: Icon(_favorite ? Icons.favorite : Icons.favorite_border),
            onPressed: _busy ? null : _toggleFavorite,
          ),
          IconButton(
            tooltip: _archived ? tr('ui.book.022') : tr('ui.book.015'),
            icon: Icon(
              _archived ? Icons.unarchive_outlined : Icons.inventory_2_outlined,
            ),
            onPressed: _busy ? null : _toggleArchive,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusMd),
              child: SizedBox(
                width: 160,
                height: 232,
                child: book.hasCover
                    ? NasCoverImage(
                        url: widget.coverUrl,
                        headers: widget.headers,
                        fallbackText: book.title,
                        borderRadius: NasTokens.radiusMd,
                      )
                    : NasCoverImage(
                        url: null,
                        fallbackText: book.title,
                        borderRadius: NasTokens.radiusMd,
                      ),
              ),
            ),
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _openReader,
                icon: const Icon(Icons.menu_book),
                label: Text(tr('ui.book.023')),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              OutlinedButton.icon(
                onPressed: _copyReadUrl,
                icon: const Icon(Icons.link),
                label: Text(tr('ui.book.024')),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              OutlinedButton.icon(
                onPressed: _copyPath,
                icon: const Icon(Icons.copy),
                label: Text(tr('ui.book.025')),
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceMd),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      label,
                      style: TextStyle(
                        color: context.nasTextSecondary,
                        fontSize: NasTokens.fontCaption,
                      ),
                    ),
                  ),
                  Expanded(child: SelectableText(value)),
                ],
              ),
            ),
          const SizedBox(height: NasTokens.spaceMd),
          Text(
            tr('ui.book.hde1cb6'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          Slider(
            value: _percent.toDouble(),
            max: 100,
            divisions: 20,
            label: '$_percent%',
            onChanged: (v) => setState(() => _percent = v.round()),
            onChangeEnd: (v) => _saveProgress(v.round()),
          ),
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            tr('ui.book.h693575'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 合集：按「书系」聚合的书目（合集的维护在服务端按书设置，客户端只读聚合结果）。
class _CollectionsPage extends StatefulWidget {
  const _CollectionsPage({required this.headers});

  final Map<String, String> headers;

  @override
  State<_CollectionsPage> createState() => _CollectionsPageState();
}

class _CollectionsPageState extends State<_CollectionsPage> {
  bool _loading = true;
  String? _error;
  List<BookCollectionItem> _items = const [];

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
      final res = await ApiSession.instance.client.bookCollections(limit: 200);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('ui.book.011')),
        actions: [
          IconButton(
            tooltip: tr('ui.accounts.021'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('ui.book.026'),
              message: tr('ui.book.hd403d5'),
              icon: Icons.collections_bookmark_outlined,
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = _items[i];
                return ListTile(
                  leading: const Icon(Icons.collections_bookmark_outlined),
                  title: Text(c.name),
                  subtitle: Text(tr('book.shelfCount', {'count': '${c.books}'})),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => _CollectionBooksPage(
                        name: c.name,
                        headers: widget.headers,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 某个合集内的书：按服务端给的序号顺序展示。
class _CollectionBooksPage extends StatefulWidget {
  const _CollectionBooksPage({required this.name, required this.headers});

  final String name;
  final Map<String, String> headers;

  @override
  State<_CollectionBooksPage> createState() => _CollectionBooksPageState();
}

class _CollectionBooksPageState extends State<_CollectionBooksPage> {
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
      final res = await ApiSession.instance.client.bookCollectionItems(
        name: widget.name,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _books = res.items;
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

  Future<void> _open(BookItem item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _BookDetailPage(
          book: item,
          coverUrl: ApiSession.instance.coverUrl('book', item.id),
          headers: widget.headers,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _books.isEmpty
          ? NasEmptyState(
              title: tr('ui.book.027'),
              message: tr('ui.book.h2662b5'),
              icon: Icons.menu_book_outlined,
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
                    childAspectRatio: 0.62,
                  ),
                  itemCount: _books.length,
                  itemBuilder: (context, i) {
                    final item = _books[i];
                    return _BookTile(
                      book: item,
                      coverUrl: ApiSession.instance.coverUrl('book', item.id),
                      headers: widget.headers,
                      onTap: () => _open(item),
                    );
                  },
                );
              },
            ),
    );
  }
}
