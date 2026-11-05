import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/app_widgets.dart';
import 'book_cache.dart';
import 'reader_page.dart';

/// 设置 · 缓存下载：本机离线书籍 + 服务端封面 / PDF 页图缓存。
class BookCachePage extends StatefulWidget {
  const BookCachePage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<BookCachePage> createState() => _BookCachePageState();
}

class _BookCachePageState extends State<BookCachePage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<BookCacheEntry> _offline = const [];
  int _files = 0;
  int _bytes = 0;

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
      if (BookCache.instance.supported) {
        await BookCache.instance.ensureIndexed();
      }
      final res = await ApiSession.instance.client.bookCacheStats();
      if (!mounted) return;
      setState(() {
        _offline = BookCache.instance.entries;
        _files = res.files;
        _bytes = res.bytes;
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

  Future<void> _openLocal(BookCacheEntry entry) async {
    final ok = await BookCache.instance.openLocal(entry.path);
    if (!mounted) return;
    if (!ok) {
      NasSnack.show(context, tr('common.errorWith', {'error': entry.path}));
    }
  }

  /// Epub / txt / cbz 直接进内置阅读器（本地解析，断网可用）；
  /// 其它格式（如 pdf）交给系统默认应用。
  Future<void> _readLocal(BookCacheEntry entry) async {
    final ext = entry.format.toLowerCase();
    if (ext != 'epub' && ext != 'txt' && ext != 'cbz') {
      await _openLocal(entry);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BookReaderPage(
          bookId: entry.id,
          title: entry.title.isEmpty ? entry.id : entry.title,
          localPath: entry.path,
          format: entry.format,
        ),
      ),
    );
  }

  Future<void> _removeOffline(BookCacheEntry entry) async {
    await BookCache.instance.remove(entry.id);
    await _load();
  }

  Future<void> _clearOffline() async {
    await BookCache.instance.clear();
    await _load();
  }

  Future<void> _clearServer() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ApiSession.instance.client.bookCacheClear();
      if (!mounted) return;
      NasSnack.showOn(messenger, tr('music.client.clearCache'));
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.errorWith', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _offlineSection() {
    final scheme = Theme.of(context).colorScheme;
    if (!BookCache.instance.supported) {
      return NasCard(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        child: Text(
          tr('book.cache.hint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      );
    }
    return NasCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final e in _offline)
            ListTile(
              dense: true,
              leading: const Icon(Icons.offline_pin_outlined),
              onTap: () => _readLocal(e),
              title: Text(
                e.title.isEmpty ? e.id : e.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${e.format.toUpperCase()} · ${formatBytes(e.bytes)}',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: tr('book.cache.open'),
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => _openLocal(e),
                  ),
                  IconButton(
                    tooltip: tr('common.delete'),
                    icon: Icon(Icons.delete_outline, color: scheme.error),
                    onPressed: () => _removeOffline(e),
                  ),
                ],
              ),
            ),
          if (_offline.isEmpty)
            Padding(
              padding: const EdgeInsets.all(NasTokens.spaceMd),
              child: Text(
                tr('book.cache.empty'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          const Divider(height: 1),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NasTokens.spaceSm,
                vertical: NasTokens.spaceXs,
              ),
              child: TextButton.icon(
                onPressed: _offline.isEmpty ? null : _clearOffline,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: Text(tr('music.client.clearCache')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverSection() {
    return NasCard(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Row(
        children: [
          const Icon(Icons.sd_storage_outlined),
          const SizedBox(width: NasTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _files == 0
                      ? tr('book.cache.empty')
                      : '$_files · ${formatBytes(_bytes)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('book.cache.serverHint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: NasTokens.spaceSm),
          TextButton(
            onPressed: _busy || _files == 0 ? null : _clearServer,
            child: Text(tr('music.client.clearCache')),
          ),
        ],
      ),
    );
  }

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
                tr('book.cache.title'),
                style: const TextStyle(
                  fontSize: NasTokens.fontSubtitle,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            NasRefreshButton(onPressed: _load),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        _offlineSection(),
        const SizedBox(height: NasTokens.spaceLg),
        Text(
          tr('book.cache.serverTitle'),
          style: const TextStyle(
            fontSize: NasTokens.fontSubtitle,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        _serverSection(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _body();
    return Scaffold(
      appBar: AppBar(title: Text(tr('book.cache.title'))),
      body: _body(),
    );
  }
}
