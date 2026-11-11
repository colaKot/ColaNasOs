import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../photo/photo_download.dart';
import 'video_card.dart';

/// 图片库 / 混合库的全屏浏览。
///
/// 图片：上下滑动 / ↑↓ 翻页，首尾循环，双指缩放。
/// 视频：进这一页就**自动起播**（混合库点条目不再绕详情页），翻到图片时自动暂停。
/// 一个 Player 复用给所有视频页，避免每翻一页都新建一个平台视图。
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

  Player? _player;
  VideoController? _videoController;
  String? _loadedId;
  bool _playReady = false;
  String? _playError;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.isEmpty ? 0 : widget.items.length - 1);
    _pageController = PageController(initialPage: _base + _index);
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.items.isNotEmpty) {
      _player = Player();
      _videoController = VideoController(_player!);
      // initState 里不能取 InheritedWidget，首帧之后再起播
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePlayback());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _player?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return true;
    }
    if (key == LogicalKeyboardKey.space) {
      _player?.playOrPause();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
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

  /// 当前页是视频就起播，是图片就暂停。翻页时复用同一个 Player，只换片源。
  Future<void> _ensurePlayback() async {
    if (!mounted || widget.items.isEmpty || _player == null) return;
    final item = _current;
    if (item.mediaType == 'image') {
      await _player!.pause();
      if (!mounted) return;
      setState(() {
        _playReady = false;
        _loadedId = null;
        _playError = null;
      });
      return;
    }
    if (_loadedId == item.id && _playReady) return;
    _loadedId = item.id;
    _playReady = false;
    _playError = null;
    if (mounted) setState(() {});
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: item.id);
      if (!mounted) return;
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      await _player!.open(Media(url), play: true);
      if (!mounted) return;
      setState(() => _playReady = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _playReady = false;
        _playError = '$e';
      });
    }
  }

  Future<void> _download(VideoItem item) async {
    final url =
        '${ApiSession.instance.baseUrl}/api/v1/files/download?path=${Uri.encodeComponent(item.path)}';
    final name = item.fileTitle.isEmpty ? item.title : item.fileTitle;
    if (PhotoDownload.supported) {
      try {
        await PhotoDownload.save(url: url, headers: videoArtHeaders, suggestedName: name);
      } catch (e) {
        if (mounted) {
          NasSnack.show(context, '$e');
        }
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      NasSnack.show(context, tr('video.media.copyLink'));
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
      NasSnack.show(context, '$e');
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
              scrollDirection: Axis.vertical,
              onPageChanged: (page) {
                setState(() => _index = page % widget.items.length);
                _ensurePlayback();
              },
              itemBuilder: (ctx, page) {
                final i = page % widget.items.length;
                final item = widget.items[i];
                return item.mediaType == 'image'
                    ? _imagePage(item)
                    : _videoPage(item, i == _index);
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
      // 单指平移交给外层纵向 PageView，双指缩放照旧
      panEnabled: false,
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

  Widget _videoPage(VideoItem item, bool active) {
    if (active && _playReady && _videoController != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _player?.playOrPause(),
        child: Center(
          child: AspectRatio(
            aspectRatio: _aspectOf(item),
            child: Video(
              controller: _videoController!,
              controls: null,
              fit: BoxFit.contain,
              fill: Colors.black,
            ),
          ),
        ),
      );
    }
    return Stack(
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
            decoration: const BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: _playError == null
                ? const SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                  )
                : const Icon(Icons.error_outline, size: 42, color: Colors.white70),
          ),
        ),
        if (_playError != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 80,
            child: Text(
              _playError!,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
      ],
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

  /// 左右两侧的点击区保留（鼠标用户方便），图标按「上一个 / 下一个」语义改上下箭头。
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
              left ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
      ),
    );
  }
}
