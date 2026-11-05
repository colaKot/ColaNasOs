import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'local_book.dart';

/// 内置阅读器（SP3-05 二期）：epub 章节 / txt 分章 / cbz 翻页。
///
/// 优先读本机离线缓存：epub / txt / cbz 由 `LocalBookSource` 在客户端解压解析，
/// 断网也能继续翻页；没有缓存或解析失败时回退服务端 `/book/toc` + `/book/page`。
/// 每次翻页把 `ch:<index>` 写回阅读进度，下次进入从上次位置继续。
class BookReaderPage extends StatefulWidget {
  const BookReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.localPath,
    this.format,
  });

  final String bookId;
  final String title;

  /// 本机离线缓存路径；为空或本地解析失败时走服务端。
  final String? localPath;
  final String? format;

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

/// 本地 / 服务端两种数据源的统一页结构。
class _ReaderPage {
  const _ReaderPage({
    required this.title,
    required this.kind,
    this.text,
    this.imageBytes,
    this.truncated = false,
  });

  final String title;
  final LocalReaderKind kind;
  final String? text;
  final Uint8List? imageBytes;
  final bool truncated;
}

class _BookReaderPageState extends State<BookReaderPage> {
  bool _loading = true;
  String? _error;
  LocalBookSource? _local;
  List<LocalTocPage> _pages = const [];
  _ReaderPage? _page;
  bool _pageLoading = false;
  int _index = 0;
  double _scale = 1.0;

  /// 漫画阅读方向（从右到左 / 从左到右），本机持久化
  static const _rtlKey = 'book.reader.rtl';
  late bool _rtl = SettingsStore.instance.getBool(_rtlKey) ?? false;

  int get _total => _pages.length;
  bool get _isImage => _page?.kind == LocalReaderKind.image;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _local?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // 1) 本地离线缓存优先：断网时也能翻页
    final path = widget.localPath;
    final format = widget.format;
    if (path != null && format != null) {
      final local = await LocalBookSource.open(path, format);
      if (local != null && local.toc.total > 0) {
        _local?.dispose();
        _local = local;
        _pages = local.toc.pages;
        final start = await _readStart();
        if (!mounted) return;
        setState(() => _loading = false);
        await _loadPage(start);
        return;
      }
      local?.dispose();
    }

    // 2) 回退服务端解析
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
      _pages = [
        for (var i = 0; i < toc.pages.length; i++)
          LocalTocPage(index: i, title: '${toc.pages[i]['title'] ?? ''}'),
      ];
      final start = await _readStart();
      if (!mounted) return;
      setState(() => _loading = false);
      await _loadPage(start);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 从服务端阅读进度解析起始页（本地 / 服务端共用）
  Future<int> _readStart() async {
    final total = _total;
    if (total <= 0) return 0;
    try {
      final p = await ApiSession.instance.client.bookProgress(
        id: widget.bookId,
      );
      final m = RegExp(r'(\d+)').firstMatch(p.position);
      if (m != null) return int.parse(m.group(1)!).clamp(0, total - 1);
    } catch (_) {
      // 没有进度是正常情况
    }
    return 0;
  }

  Future<void> _loadPage(int index) async {
    if (index < 0 || index >= _total) return;
    setState(() => _pageLoading = true);
    try {
      _ReaderPage? next;
      final local = _local;
      if (local != null) {
        final p = await local.page(index);
        if (p != null) {
          next = _ReaderPage(
            title: p.title,
            kind: p.kind,
            text: p.text,
            imageBytes: p.imageBytes,
            truncated: p.truncated,
          );
        }
      } else {
        final page = await ApiSession.instance.client.bookPage(
          id: widget.bookId,
          index: index,
        );
        final image = page.kind == 'image';
        Uint8List? bytes;
        if (image) {
          try {
            bytes = base64Decode(page.data ?? '');
          } catch (_) {
            bytes = null;
          }
        }
        next = _ReaderPage(
          title: page.title,
          kind: image ? LocalReaderKind.image : LocalReaderKind.text,
          text: page.text,
          imageBytes: bytes,
          truncated: page.truncated ?? false,
        );
      }
      if (!mounted) return;
      if (next == null) {
        setState(() => _pageLoading = false);
        NasSnack.show(context, tr('ui.book.h6a16ee'), error: true);
        return;
      }
      setState(() {
        _page = next;
        _index = index;
        _pageLoading = false;
      });
      _saveProgress(index);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pageLoading = false);
      NasSnack.show(
        context,
        tr('common.loadFailed', {'error': '$e'}),
        error: true,
      );
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
    if (_pages.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (c, controller) => ListView.builder(
          controller: controller,
          itemCount: _pages.length,
          itemBuilder: (c, i) {
            final p = _pages[i];
            return ListTile(
              dense: true,
              selected: i == _index,
              title: Text(
                p.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
          if (_isImage)
            IconButton(
              tooltip: tr(_rtl ? 'book.reader.rtl' : 'book.reader.ltr'),
              icon: Icon(_rtl ? Icons.swap_horiz : Icons.swap_vert),
              onPressed: () {
                setState(() => _rtl = !_rtl);
                SettingsStore.instance.setBool(_rtlKey, _rtl);
              },
            ),
          if (!_isImage) ...[
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
          ],
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
                      ? page.imageBytes == null
                            ? const NasLoading()
                            : _ComicPageView(
                                imageBytes: page.imageBytes!,
                                rtl: _rtl,
                                canPrev: _index > 0 && !_pageLoading,
                                canNext: _index + 1 < _total && !_pageLoading,
                                onPrev: () => _loadPage(_index - 1),
                                onNext: () => _loadPage(_index + 1),
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

/// 漫画图片页：捏合 / 双击缩放，未放大时点左右两侧翻页（RTL 时左右互换）。
class _ComicPageView extends StatefulWidget {
  const _ComicPageView({
    required this.imageBytes,
    required this.rtl,
    required this.canPrev,
    required this.canNext,
    required this.onPrev,
    required this.onNext,
  });

  final Uint8List imageBytes;
  final bool rtl;
  final bool canPrev;
  final bool canNext;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  State<_ComicPageView> createState() => _ComicPageViewState();
}

class _ComicPageViewState extends State<_ComicPageView> {
  final _tc = TransformationController();
  TapDownDetails? _doubleTapPos;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransform);
    _tc.dispose();
    super.dispose();
  }

  void _onTransform() {
    final scale = _tc.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.01;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  void _toggleZoom() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
      return;
    }
    final pos = _doubleTapPos?.localPosition;
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size;
    const scale = 2.5;
    final dx = pos?.dx ?? (size == null ? 0 : size.width / 2);
    final dy = pos?.dy ?? (size == null ? 0 : size.height / 2);
    _tc.value = Matrix4.identity()
      ..translateByDouble(-dx * (scale - 1), -dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _tap(double x, double width) {
    if (_zoomed) return;
    final left = x < width / 3;
    final right = x > width * 2 / 3;
    if (!left && !right) return;
    // RTL：左侧是「下一页」，右侧是「上一页」
    final goNext = widget.rtl ? left : right;
    if (goNext) {
      if (widget.canNext) widget.onNext();
    } else if (widget.canPrev) {
      widget.onPrev();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (d) => _doubleTapPos = d,
        onDoubleTap: _toggleZoom,
        onTapUp: (d) => _tap(d.localPosition.dx, constraints.maxWidth),
        child: InteractiveViewer(
          transformationController: _tc,
          minScale: 1,
          maxScale: 5,
          boundaryMargin: const EdgeInsets.all(80),
          child: Center(
            child: Image.memory(
              widget.imageBytes,
              gaplessPlayback: true,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
