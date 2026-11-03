import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 内置阅读器（SP3-05 二期）：epub 章节 / txt 分章 / cbz 翻页。
///
/// 服务端负责解压与纯文本化（`/book/toc` + `/book/page`），客户端只做排版与翻页；
/// 每次翻页把 `ch:<index>` 写回阅读进度，下次进入从上次位置继续。
class BookReaderPage extends StatefulWidget {
  const BookReaderPage({super.key, required this.bookId, required this.title});

  final String bookId;
  final String title;

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> {
  bool _loading = true;
  String? _error;
  BookTocResponse? _toc;
  BookPageResponse? _page;
  bool _pageLoading = false;
  int _index = 0;
  double _scale = 1.0;

  int get _total => _toc?.total ?? 0;
  bool get _isImage => _page?.kind == 'image';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final toc = await ApiSession.instance.client.bookToc(id: widget.bookId);
      if (!mounted) return;
      if (toc.kind == 'none' || toc.total == 0) {
        setState(() {
          _loading = false;
          _error = tr('ui.book.h6a16ee');
        });
        return;
      }
      int start = 0;
      try {
        final p = await ApiSession.instance.client.bookProgress(
          id: widget.bookId,
        );
        final m = RegExp(r'(\d+)').firstMatch(p.position);
        if (m != null) start = int.parse(m.group(1)!).clamp(0, toc.total - 1);
      } catch (_) {
        // 没有进度是正常情况
      }
      setState(() {
        _toc = toc;
        _loading = false;
      });
      await _loadPage(start);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadPage(int index) async {
    if (index < 0 || (_total > 0 && index >= _total)) return;
    setState(() => _pageLoading = true);
    try {
      final page = await ApiSession.instance.client.bookPage(
        id: widget.bookId,
        index: index,
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _index = index;
        _pageLoading = false;
      });
      _saveProgress(index);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pageLoading = false);
      NasSnack.show(context, tr('common.loadFailed', {'error': '$e'}), error: true);
    }
  }

  Future<void> _saveProgress(int index) async {
    final percent = _total <= 0
        ? 0
        : (((index + 1) * 100) ~/ _total).clamp(0, 100);
    try {
      await ApiSession.instance.client.bookProgressSave(
        body: BookProgressBody(
          id: widget.bookId,
          position: 'ch:$index',
          percent: percent,
        ),
      );
    } catch (_) {
      // 进度上报失败不影响阅读
    }
  }

  void _openToc() {
    final toc = _toc;
    if (toc == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (c, controller) => ListView.builder(
          controller: controller,
          itemCount: toc.pages.length,
          itemBuilder: (c, i) {
            final p = toc.pages[i];
            final title = '${p['title'] ?? ''}';
            return ListTile(
              dense: true,
              selected: i == _index,
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              leading: Text(
                '${i + 1}',
                style: const TextStyle(fontSize: NasTokens.fontCaption),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _loadPage(i);
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: tr('ui.book.028'),
            icon: const Icon(Icons.text_decrease),
            onPressed: _scale <= 0.8
                ? null
                : () => setState(() => _scale -= 0.1),
          ),
          IconButton(
            tooltip: tr('ui.book.029'),
            icon: const Icon(Icons.text_increase),
            onPressed: _scale >= 1.6
                ? null
                : () => setState(() => _scale += 0.1),
          ),
          IconButton(
            tooltip: tr('ui.book.030'),
            icon: const Icon(Icons.list),
            onPressed: _openToc,
          ),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _bootstrap)
          : Column(
              children: [
                Expanded(
                  child: _pageLoading || page == null
                      ? const NasLoading()
                      : _isImage
                      ? InteractiveViewer(
                          minScale: 0.8,
                          maxScale: 4,
                          child: Center(
                            child: Image.memory(
                              base64Decode(page.data ?? ''),
                              gaplessPlayback: true,
                              fit: BoxFit.contain,
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            NasTokens.spaceLg,
                            NasTokens.spaceMd,
                            NasTokens.spaceLg,
                            NasTokens.spaceXl,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                page.title,
                                style: TextStyle(
                                  fontSize: NasTokens.fontHeadline * _scale,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: NasTokens.spaceMd),
                              SelectableText(
                                page.text ?? '',
                                style: TextStyle(
                                  fontSize: NasTokens.fontBody * _scale,
                                  height: 1.8,
                                ),
                              ),
                              if (page.truncated == true) ...[
                                const SizedBox(height: NasTokens.spaceMd),
                                Text(
                                  tr('ui.book.hb4f0a0'),
                                  style: TextStyle(
                                    fontSize: NasTokens.fontCaption,
                                    color: const Color(NasTokens.colorWarning),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
                const Divider(height: 1),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NasTokens.spaceSm,
                      vertical: NasTokens.spaceXs,
                    ),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: _index <= 0 || _pageLoading
                              ? null
                              : () => _loadPage(_index - 1),
                          icon: const Icon(Icons.chevron_left),
                          label: Text(tr('ui.book.031')),
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              '${_index + 1} / $_total',
                              style: TextStyle(
                                fontSize: NasTokens.fontCaption,
                                color: context.nasTextSecondary,
                              ),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _index + 1 >= _total || _pageLoading
                              ? null
                              : () => _loadPage(_index + 1),
                          icon: const Icon(Icons.chevron_right),
                          label: Text(tr('ui.book.032')),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
