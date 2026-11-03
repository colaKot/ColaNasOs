import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../photo/photo_download.dart';
import 'video_card.dart';

/// 图片库 / 混合库的全屏浏览。
///
/// 图片：左右滑动 / 方向键翻页，首尾循环，双指或按钮缩放。
/// 视频：显示海报 + 播放按钮，点一下进详情。
Future<void> openMediaViewer(
  BuildContext context, {
  required List<VideoItem> items,
  required int initialIndex,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideoMediaViewerPage(items: items, initialIndex: initialIndex),
    ),
  );
}

class VideoMediaViewerPage extends StatefulWidget {
  const VideoMediaViewerPage({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  final List<VideoItem> items;
  final int initialIndex;

  @override
  State<VideoMediaViewerPage> createState() => _VideoMediaViewerPageState();
}

class _VideoMediaViewerPageState extends State<VideoMediaViewerPage> {
  static const _base = 100000;
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.isEmpty ? 0 : widget.items.length - 1);
    _pageController = PageController(initialPage: _base + _index);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pageController.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return true;
    }
    return false;
  }

  void _go(int delta) {
    if (!_pageController.hasClients || widget.items.isEmpty) return;
    final page = _pageController.page?.round() ?? (_base + _index);
    _pageController.animateToPage(
      page + delta,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  VideoItem get _current => widget.items[_index];

  Future<void> _download(VideoItem item) async {
    final url =
        '${ApiSession.instance.baseUrl}/api/v1/files/download?path=${Uri.encodeComponent(item.path)}';
    final name = item.fileTitle.isEmpty ? item.title : item.fileTitle;
    if (PhotoDownload.supported) {
      try {
        await PhotoDownload.save(url: url, headers: videoArtHeaders, suggestedName: name);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.media.copyLink'))),
      );
    }
  }

  Future<void> _delete(VideoItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.media.delete')),
        content: Text(item.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ApiSession.instance.client.videoItemsDelete(
        body: VideoDeleteItemsBody(ids: [item.id]),
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const Scaffold(body: Center(child: Text('—')));
    }
    return Material(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (page) {
                setState(() => _index = page % widget.items.length);
              },
              itemBuilder: (ctx, page) {
                final item = widget.items[page % widget.items.length];
                return item.mediaType == 'image' ? _imagePage(item) : _videoPage(item);
              },
            ),
          ),
          _sideNav(left: true),
          _sideNav(left: false),
          Positioned(left: 0, right: 0, top: 0, child: _topBar()),
          Positioned(
            left: 12,
            right: 12,
            bottom: 18,
            child: IgnorePointer(
              child: Text(
                tr('video.media.viewerHint'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imagePage(VideoItem item) {
    final url =
        '${ApiSession.instance.baseUrl}/api/v1/files/download?path=${Uri.encodeComponent(item.path)}&inline=1';
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 8,
      child: Center(
        child: Image.network(
          url,
          headers: videoArtHeaders,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 64,
          ),
        ),
      ),
    );
  }

  Widget _videoPage(VideoItem item) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openVideoDetail(context, item),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _aspectOf(item),
              child: NasCoverImage(
                url: videoPosterUrl(item, kind: 'fanart'),
                headers: videoArtHeaders,
                fit: BoxFit.contain,
                icon: Icons.movie_outlined,
              ),
            ),
          ),
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow, size: 42, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  double _aspectOf(VideoItem item) {
    final w = item.width ?? 0;
    final h = item.height ?? 0;
    return w > 0 && h > 0 ? w / h : 16 / 9;
  }

  Widget _topBar() {
    final item = _current;
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            Text(
              '${_index + 1} / ${widget.items.length}',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            IconButton(
              tooltip: tr('video.media.download'),
              onPressed: () => _download(item),
              icon: const Icon(Icons.download_outlined, color: Colors.white),
            ),
            IconButton(
              tooltip: tr('video.media.delete'),
              onPressed: () => _delete(item),
              icon: const Icon(Icons.delete_outline, color: Colors.white),
            ),
            IconButton(
              tooltip: tr('video.media.close'),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideNav({required bool left}) {
    final width = MediaQuery.of(context).size.width;
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      width: width * 0.16,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _go(left ? -1 : 1),
        child: Align(
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            width: 52,
            height: 52,
            margin: EdgeInsets.only(left: left ? 12 : 0, right: left ? 0 : 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.42),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Icon(
              left ? Icons.chevron_left : Icons.chevron_right,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
      ),
    );
  }
}
