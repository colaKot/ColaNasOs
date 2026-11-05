import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'book_detail_page.dart';
import 'book_widgets.dart';

/// 藏书 · 阅读历史：最近读的在前，可清空（不动阅读进度）。
class BookHistoryPage extends StatefulWidget {
  const BookHistoryPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<BookHistoryPage> createState() => _BookHistoryPageState();
}

class _BookHistoryPageState extends State<BookHistoryPage> {
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
      final res = await ApiSession.instance.client.bookHistory(limit: 200);
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

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('book.history.clear')),
        content: Text(tr('book.history.clearConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('book.history.clear')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.bookHistoryClear();
      if (!mounted) return;
      setState(() => _items = const []);
      NasSnack.showOn(messenger, tr('book.history.clear'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _open(BookItem book) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => BookDetailPage(book: book)),
    );
    await _load();
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('book.history.empty'),
        icon: Icons.history,
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => BookRow(
        book: _items[i],
        onOpen: () => _open(_items[i]),
        leading: const Icon(Icons.history, size: 18),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        BookPaneHeader(
          title: tr('book.nav.history'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('book.history.clear'),
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: _items.isEmpty ? null : _clear,
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
      appBar: AppBar(title: Text(tr('book.nav.history'))),
      body: body,
    );
  }
}
