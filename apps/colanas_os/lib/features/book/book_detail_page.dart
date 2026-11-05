import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'book_cache.dart';
import 'book_widgets.dart';
import 'reader_page.dart';

/// 书籍详情：封面 / 元信息 / 收藏 / 归档 / 加入书单 / 内置阅读 / 手动进度。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.book});

  final BookItem book;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
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
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
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
      NasSnack.showOn(messenger, next ? tr('ui.book.018') : tr('ui.book.019'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addToList() async {
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
              child: Text(
                '${l.name}（${tr('book.shelfCount', {'count': '${l.books}'})}）',
              ),
            ),
        ],
      ),
    );
    if (target == null) return;
    try {
      await ApiSession.instance.client.bookListAdd(
        body: BookListRefBody(listId: target.id, bookId: widget.book.id),
      );
      NasSnack.showOn(messenger, tr('music.addedTo', {'name': target.name}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
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
      NasSnack.showOn(
        messenger,
        tr('common.progressSaved', {'percent': '${p.percent}'}),
      );
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '$e'}));
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
      NasSnack.showOn(
        messenger,
        tr('book.shareCopied', {'minutes': '${res.expiresInSec ~/ 60}'}),
      );
    } catch (e) {
      NasSnack.showOn(messenger, tr('book.shareFailed', {'error': '$e'}));
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.book.path));
    if (!mounted) return;
    NasSnack.show(context, tr('ui.book.020'));
  }

  Future<void> _cacheToLocal() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!BookCache.instance.supported) {
      NasSnack.showOn(messenger, tr('book.cache.hint'));
      return;
    }
    try {
      await BookCache.instance.download(
        book: widget.book,
        url:
            '${ApiSession.instance.baseUrl}/api/v1/book/file?id=${Uri.encodeComponent(widget.book.id)}',
        headers: ApiSession.instance.authHeaders,
      );
      NasSnack.showOn(messenger, tr('music.cache.done'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('music.cache.failed', {'error': '$e'}));
    }
  }

  Future<void> _openReader() async {
    if (BookCache.instance.supported) {
      await BookCache.instance.ensureIndexed();
    }
    // 有本机离线文件就让阅读器优先本地解析（断网可读），否则回退服务端
    final localPath = BookCache.instance.pathOf(widget.book.id);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BookReaderPage(
          bookId: widget.book.id,
          title: widget.book.title,
          localPath: localPath,
          format: localPath == null ? null : widget.book.format,
        ),
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
      (tr('ui.book.h9d2601'), tr('book.source.type.${book.type}')),
      (tr('ui.discover.002'), book.language ?? tr('ui.book.hd9c32a')),
      (tr('ui.book.h4b60a3'), book.publisher ?? tr('ui.book.hd9c32a')),
      (
        tr('ui.book.hbadd9d'),
        book.pageCount == null ? tr('ui.book.hd9c32a') : '${book.pageCount}',
      ),
      (tr('common.size'), formatBytes(book.size)),
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
            tooltip: tr('book.lists.addBook'),
            icon: const Icon(Icons.playlist_add),
            onPressed: _busy ? null : _addToList,
          ),
          IconButton(
            tooltip: tr('music.cache.download'),
            icon: const Icon(Icons.download_outlined),
            onPressed: _busy ? null : _cacheToLocal,
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
                        url: bookCoverUrl(book.id),
                        headers: ApiSession.instance.authHeaders,
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
          Wrap(
            spacing: NasTokens.spaceSm,
            runSpacing: NasTokens.spaceXs,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _openReader,
                icon: const Icon(Icons.menu_book),
                label: Text(tr('ui.book.023')),
              ),
              OutlinedButton.icon(
                onPressed: _copyReadUrl,
                icon: const Icon(Icons.link),
                label: Text(tr('ui.book.024')),
              ),
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
        ],
      ),
    );
  }
}
