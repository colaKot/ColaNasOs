import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import '../photo/folder_picker.dart';

/// 设置 · 书库来源：添加目录、切换书籍/漫画、扫描、删除。
class BookSourcePage extends StatefulWidget {
  const BookSourcePage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  bool _loading = true;
  String? _error;
  bool _busy = false;
  List<BookLibraryItem> _items = const [];

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
      final res = await ApiSession.instance.client.bookLibraryList();
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

  Future<String?> _promptName(String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.book.004')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('ui.book.004')),
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

  Future<String?> _pickType() {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('book.source.type')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'book'),
            child: Text(tr('book.source.type.book')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'comic'),
            child: Text(tr('book.source.type.comic')),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final path = await showFolderPicker(context);
    if (path == null || path.isEmpty || !mounted) return;
    final fallback =
        path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
    final name = await _promptName(fallback);
    if (name == null || name.isEmpty || !mounted) return;
    final type = await _pickType();
    if (type == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final created = await ApiSession.instance.client.bookLibraryCreate(
        body: BookLibraryCreateBody(name: name, path: path, type: type),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      NasSnack.showOn(messenger, tr('book.source.add'));
      await _scan(created.id);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      NasSnack.showOn(messenger, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _scan(String? libraryId) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.bookScan(
        body: BookScanBody(libraryId: libraryId),
      );
      if (!mounted) return;
      NasSnack.showOn(
        messenger,
        tr('book.scanDone', {
          'added': '${res.added}',
          'updated': '${res.updated}',
          'skipped': '${res.skipped}',
          'parsed': '${res.parsed}',
        }),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('common.scanFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update(
    BookLibraryItem item, {
    String? name,
    String? type,
    bool? scanWhenStart,
    bool? scanWhenChange,
    int? scanIntervalHours,
  }) async {
    try {
      await ApiSession.instance.client.bookLibraryUpdate(
        body: BookLibraryUpdateBody(
          id: item.id,
          name: name,
          type: type,
          scanWhenStart: scanWhenStart,
          scanWhenChange: scanWhenChange,
          scanIntervalHours: scanIntervalHours,
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _rename(BookLibraryItem item) async {
    final name = await _promptName(item.name);
    if (name == null || name.isEmpty || !mounted) return;
    await _update(item, name: name);
  }

  Future<void> _delete(BookLibraryItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(tr('book.source.removeConfirm', {'name': item.name})),
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
      await ApiSession.instance.client.bookLibraryRemove(
        body: BookLibraryRemoveBody(id: item.id),
      );
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('common.delete'));
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  List<NasMenuEntry> _menuFor(BookLibraryItem item) => [
    NasMenuEntry(
      label: tr('book.source.scanNow'),
      icon: Icons.sync,
      onSelected: () => _scan(item.id),
    ),
    NasMenuEntry(
      label: tr('ui.book.004'),
      icon: Icons.edit_outlined,
      onSelected: () => _rename(item),
    ),
    NasMenuEntry(
      label: item.type == 'comic'
          ? tr('book.source.type.book')
          : tr('book.source.type.comic'),
      icon: Icons.swap_horiz,
      onSelected: () =>
          _update(item, type: item.type == 'comic' ? 'book' : 'comic'),
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
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('book.source.title'),
                style: const TextStyle(
                  fontSize: NasTokens.fontSubtitle,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _busy || _items.isEmpty ? null : () => _scan(null),
              icon: const Icon(Icons.sync, size: 18),
              label: Text(tr('common.scanAll')),
            ),
            NasRefreshButton(onPressed: _busy ? null : _load),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: NasTokens.spaceSm),
          const LinearProgressIndicator(minHeight: 2),
        ],
        const SizedBox(height: NasTokens.spaceSm),
        if (_items.isEmpty)
          NasEmptyState(
            title: tr('ui.book.h8eccf0'),
            message: tr('book.source.add'),
            icon: Icons.menu_book_outlined,
          ),
        for (final item in _items) ...[
          _sourceCard(item),
          const SizedBox(height: NasTokens.spaceSm),
        ],
        const SizedBox(height: NasTokens.spaceSm),
        _addCard(),
      ],
    );
  }

  Widget _sourceCard(BookLibraryItem item) {
    final scheme = Theme.of(context).colorScheme;
    final scanned = item.lastScanAt == null
        ? tr('music.source.neverScanned')
        : tr('music.source.scannedAt', {'date': _formatTime(item.lastScanAt!)});
    return NasContextMenuRegion(
      entries: _menuFor(item),
      child: NasCard(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  item.type == 'comic'
                      ? Icons.auto_stories_outlined
                      : Icons.book_outlined,
                  color: scheme.primary,
                ),
                const SizedBox(width: NasTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: NasTokens.fontBody,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        item.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: NasTokens.fontMicro,
                          color: context.nasTextSecondary,
                        ),
                      ),
                      Text(
                        '${tr('book.shelfCount', {'count': '${item.items}'})} · $scanned',
                        style: TextStyle(
                          fontSize: NasTokens.fontMicro,
                          color: context.nasTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  item.type == 'comic'
                      ? tr('book.source.type.comic')
                      : tr('book.source.type.book'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                IconButton(
                  tooltip: tr('book.source.scanNow'),
                  onPressed: _busy ? null : () => _scan(item.id),
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
            const Divider(height: 1),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                tr('book.source.scanWhenStart'),
                style: const TextStyle(fontSize: NasTokens.fontCaption),
              ),
              value: item.scanWhenStart == 1,
              onChanged: _busy ? null : (v) => _update(item, scanWhenStart: v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                tr('book.source.scanWhenChange'),
                style: const TextStyle(fontSize: NasTokens.fontCaption),
              ),
              value: item.scanWhenChange == 1,
              onChanged: _busy ? null : (v) => _update(item, scanWhenChange: v),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('book.source.scanInterval'),
                    style: const TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                ),
                DropdownButton<int>(
                  value: item.scanIntervalHours.clamp(0, 24),
                  items: [
                    DropdownMenuItem(
                      value: 0,
                      child: Text(
                        tr('book.source.scanIntervalOff'),
                        style: const TextStyle(fontSize: NasTokens.fontCaption),
                      ),
                    ),
                    for (var h = 1; h <= 24; h++)
                      DropdownMenuItem(
                        value: h,
                        child: Text(
                          tr('book.source.scanIntervalEvery', {'hours': '$h'}),
                          style: const TextStyle(
                            fontSize: NasTokens.fontCaption,
                          ),
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v == null) return;
                          _update(item, scanIntervalHours: v);
                        },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _addCard() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _busy ? null : _add,
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceMd,
          vertical: NasTokens.spaceLg,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 20, color: scheme.primary),
            const SizedBox(width: NasTokens.spaceXs),
            Text(
              tr('book.source.add'),
              style: TextStyle(
                fontSize: NasTokens.fontBody,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _body();
    return Scaffold(
      appBar: AppBar(title: Text(tr('book.source.title'))),
      body: _body(),
    );
  }
}
