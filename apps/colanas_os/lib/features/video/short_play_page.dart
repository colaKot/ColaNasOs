import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'video_card.dart';

/// 短剧连播：竖屏上下滑动 / 键盘 ↑↓ 切上一条下一条，当前集自动起播。
///
/// 为什么单独一个页面而不是给通用 `PlayerPage` 加队列：短剧的核心交互就是
/// 「连续刷」，不需要完整的转码 / 字幕 / 画质面板；独立页只复用 media_kit 的
/// Player，既不动通用播放器，也能把上下切换做成和图片浏览一样顺手。
Future<void> openShortPlay(
  BuildContext context,
  List<VideoItem> items,
  int initialIndex,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ShortPlayPage(items: items, initialIndex: initialIndex),
    ),
  );
}

class ShortPlayPage extends StatefulWidget {
  const ShortPlayPage({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  final List<VideoItem> items;
  final int initialIndex;

  @override
  State<ShortPlayPage> createState() => _ShortPlayPageState();
}

class _ShortPlayPageState extends State<ShortPlayPage> {
  static const _base = 100000;

  late final PageController _pageController;
  late int _index;

  Player? _player;
  VideoController? _videoController;
  String? _loadedId;
  bool _ready = false;
  String? _error;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.isEmpty ? 0 : widget.items.length - 1);
    _pageController = PageController(initialPage: _base + _index);
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.items.isNotEmpty) {
      _player = Player();
      _videoController = VideoController(_player!);
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePlayback());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    // 退出时尽力存一次进度（不 await，页面已经在销毁）
    _saveProgress();
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
      _togglePause();
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

  void _togglePause() {
    final p = _player;
    if (p == null) return;
    p.playOrPause();
    setState(() => _paused = !_paused);
  }

  /// 换集前先把上一集的观看位置落库，短剧集短、丢进度很影响续看。
  Future<void> _saveProgress() async {
    final id = _loadedId;
    final p = _player;
    if (id == null || p == null) return;
    final pos = p.state.position;
    final dur = p.state.duration;
    if (pos.inMilliseconds <= 0 || dur.inMilliseconds <= 0) return;
    final percent = (pos.inMilliseconds / dur.inMilliseconds * 100).clamp(0, 100).round();
    try {
      await ApiSession.instance.client.videoProgressSave(
        body: VideoProgressBody(
          id: id,
          percent: percent,
          position: '${pos.inMilliseconds}',
        ),
      );
    } catch (_) {
      // 进度是锦上添花，失败不打断连播
    }
  }

  Future<void> _ensurePlayback() async {
    if (!mounted || widget.items.isEmpty || _player == null) return;
    final item = _current;
    if (_loadedId == item.id && _ready) return;
    await _saveProgress();
    _loadedId = item.id;
    _ready = false;
    _error = null;
    _paused = false;
    if (mounted) setState(() {});
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: item.id);
      if (!mounted) return;
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      await _player!.open(Media(url), play: true);
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: Text('—')));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
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
                return _page(widget.items[i], i == _index);
              },
            ),
          ),
          Positioned(left: 0, right: 0, top: 0, child: _topBar()),
          Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar()),
        ],
      ),
    );
  }

  Widget _page(VideoItem item, bool active) {
    if (active && _ready && _videoController != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _togglePause,
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
          child: _error == null
              ? const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 42, color: Colors.white70),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ],
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

  String _episodeLabel(VideoItem item) {
    final n = item.episode ?? 0;
    return n > 0 ? tr('video.series.episode', {'n': '$n'}) : '${_index + 1}';
  }

  Widget _topBar() {
    final item = _current;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.62), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      (item.series ?? '').trim().isNotEmpty
                          ? '${item.series} · ${_episodeLabel(item)}'
                          : item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_index + 1} / ${widget.items.length} · ${tr('video.shortPlay.hint')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: tr('video.media.close'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.only(bottom: 18, top: 24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.5), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_paused)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Icon(Icons.play_arrow, size: 34, color: Colors.white70),
              ),
            const Icon(Icons.keyboard_arrow_up, size: 22, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
