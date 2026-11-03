import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_download.dart';
import 'photo_similar_page.dart';

/// 统一的大图查看器：左右翻页、键盘、双击缩放、1600 预览 + 手动原图。
///
/// 打开时只加载 1600 长边缩略图（服务端 JPEG），避免 Web 端直接解码手机原图；
/// 需要原图时点右上角「原图」。预加载前后各一张，关闭后不触发调用方刷新。
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.items,
    required this.initialIndex,
    this.title,
  });

  final List<PhotoItem> items;
  final int initialIndex;
  final String? title;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller;
  late int _index;
  final Set<int> _original = <int>{};
  bool _zoomed = false;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheNeighbors());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _previewUrl(PhotoItem item) => _media.thumbnail(item.path, size: 1600);

  String _originalUrl(PhotoItem item) => _media.file(item.path);

  void _precacheNeighbors() {
    for (final i in [_index - 1, _index + 1]) {
      if (i < 0 || i >= widget.items.length) continue;
      final url = _previewUrl(widget.items[i]);
      // ignore: discarded_futures
      precacheImage(NetworkImage(url, headers: ApiSession.instance.authHeaders), context);
    }
  }

  void _go(int next) {
    if (next < 0 || next >= widget.items.length) return;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _close() => Navigator.of(context).maybePop();

  /// 另存原图（桌面）；Web 端没有保存入口，改用复制链接
  Future<void> _save(PhotoItem item, String filename) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await PhotoDownload.save(
        url: _media.file(item.path),
        headers: ApiSession.instance.authHeaders,
        suggestedName: filename,
      );
      if (!mounted || path == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(tr('photo.longPress.saved', {'path': path}))),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(tr('photo.longPress.saveFailed', {'error': '$e'}))),
      );
    }
  }

  Future<void> _copyLink(PhotoItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _media.file(item.path)));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(tr('photo.longPress.linkCopied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index];
    final filename = item.path.split('/').last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title ?? filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              '${_index + 1} / ${widget.items.length}',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          // 查看器里也要能下载：长按菜单那条入口在浏览大图时够不着
          if (PhotoDownload.supported)
            IconButton(
              tooltip: tr('photo.longPress.save'),
              icon: const Icon(Icons.download_outlined),
              onPressed: () => _save(item, filename),
            )
          else
            IconButton(
              tooltip: tr('photo.longPress.copyLink'),
              icon: const Icon(Icons.link),
              onPressed: () => _copyLink(item),
            ),
          TextButton.icon(
            onPressed: () {
              setState(() {
                if (_original.contains(_index)) {
                  _original.remove(_index);
                } else {
                  _original.add(_index);
                }
              });
            },
            icon: const Icon(Icons.hd_outlined, size: 18),
            label: Text(_original.contains(_index) ? tr('photo.preview') : tr('photo.original')),
          ),
          IconButton(
            tooltip: tr('photo.similar.title'),
            icon: const Icon(Icons.image_search),
            onPressed: () {
              final item = widget.items[_index];
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PhotoSimilarPage(
                    photoId: item.id,
                    title: item.path.split('/').last,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: tr('common.close'),
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(_index - 1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(_index + 1),
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.home): () => _go(0),
          const SingleActivator(LogicalKeyboardKey.end): () =>
              _go(widget.items.length - 1),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: widget.items.length,
                onPageChanged: (i) {
                  setState(() {
                    _index = i;
                    _zoomed = false;
                  });
                  _precacheNeighbors();
                },
                itemBuilder: (context, i) {
                  final current = widget.items[i];
                  final useOriginal = _original.contains(i);
                  final url = useOriginal ? _originalUrl(current) : _previewUrl(current);
                  final image = Image.network(
                    url,
                    headers: ApiSession.instance.authHeaders,
                    fit: BoxFit.contain,
                    cacheWidth: useOriginal ? null : 1600,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      final total = progress.expectedTotalBytes;
                      final value = total == null
                          ? null
                          : progress.cumulativeBytesLoaded / total;
                      return Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(value: value, strokeWidth: 2),
                        ),
                      );
                    },
                    errorBuilder: (context, error, stack) => const Center(
                      child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
                    ),
                  );
                  final zoomed = i == _index && _zoomed;
                  return GestureDetector(
                    onDoubleTap: () => setState(() => _zoomed = !_zoomed),
                    child: Center(
                      child: zoomed
                          ? InteractiveViewer(
                              minScale: 1,
                              maxScale: 5,
                              child: image,
                            )
                          : image,
                    ),
                  );
                },
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _ArrowButton(
                  icon: Icons.chevron_left,
                  enabled: _index > 0,
                  onTap: () => _go(_index - 1),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _ArrowButton(
                  icon: Icons.chevron_right,
                  enabled: _index < widget.items.length - 1,
                  onTap: () => _go(_index + 1),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: IgnorePointer(
                  child: Text(
                    [
                      item.path,
                      if (item.width != null && item.height != null)
                        '${item.width}×${item.height}',
                      _formatTime(item.takenAt),
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 64,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: enabled ? 0.7 : 0,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
      ),
    );
  }
}