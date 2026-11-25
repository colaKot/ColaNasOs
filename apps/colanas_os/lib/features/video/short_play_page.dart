import 'dart:async';

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

  /// 当前这一集的视频纹理真的解出第一帧了。
  ///
  /// 没出帧之前继续盖着这一集的抽帧：换集时抽帧不会「消失一下再出画面」。
  bool _frameReady = false;
  StreamSubscription<VideoParams>? _videoParamsSub;
  Timer? _frameGuard;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.isEmpty ? 0 : widget.items.length - 1);
    _pageController = PageController(initialPage: _base + _index);
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.items.isNotEmpty) {
      _player = Player();
      _videoController = VideoController(_player!);
      _videoParamsSub = _player!.stream.videoParams.listen((p) {
        if (!mounted || !_ready || _frameReady) return;
        if ((p.dw ?? p.w ?? 0) > 0) setState(() => _frameReady = true);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePlayback());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _frameGuard?.cancel();
    final paramsSub = _videoParamsSub;
    if (paramsSub != null) unawaited(paramsSub.cancel());
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

  /// 预热相邻几集的抽帧：服务端抽帧是懒生成的（SMB 来源第一次要先 404 /
  /// 后台排队），提前要一次，滑到下一集时加载占位就能直接出整屏截图。
  void _warmNeighborFrames() {
    for (var d = 1; d <= 2; d++) {
      final j = _index + d;
      if (j >= widget.items.length) break;
      unawaited(
        precacheImage(
          NetworkImage(
            videoFrameUrl(widget.items[j]),
            headers: videoArtHeaders,
          ),
          context,
          onError: (_, _) {},
        ),
      );
    }
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
    _warmNeighborFrames();
    final item = _current;
    if (_loadedId == item.id && _ready) return;
    await _saveProgress();
    _loadedId = item.id;
    _ready = false;
    _frameReady = false;
    _error = null;
    _paused = false;
    _frameGuard?.cancel();
    if (mounted) setState(() {});
    try {
      final res = await ApiSession.instance.client.videoStreamUrl(id: item.id);
      if (!mounted) return;
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      await _player!.open(Media(url), play: true);
      if (!mounted) return;
      // open 完成时第一帧可能已经解出来了（[videoParams] 事件早于这次 setState），
      // 直接读一次状态，免得占位图一直盖着等超时。
      final vp = _player!.state.videoParams;
      setState(() {
        _ready = true;
        if ((vp.dw ?? vp.w ?? 0) > 0) _frameReady = true;
      });
      // 兜底：8 秒还不出帧就撤掉占位，不能让它把画面永久盖住
      _frameGuard?.cancel();
      if (!_frameReady) {
        _frameGuard = Timer(const Duration(seconds: 8), () {
          if (mounted && !_frameReady) setState(() => _frameReady = true);
        });
      }
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
      return Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
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
          ),
          // 纹理还没出第一帧：继续盖着这一集的抽帧，画面直接在同一张图上出现，
          // 不会先露一下黑底（用户反馈的「截帧图消失后又闪一下」）。
          if (!_frameReady)
            IgnorePointer(child: VideoFramePreview(item: item)),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // 换集加载占位用这一条自己的抽帧铺满整屏：竖屏片源抽出来就是竖屏，
        // 和接着起播的画面同构图。以前这里放的是同名横版图（contain 居中），
        // 竖屏视频前面先闪一张横图，割裂感很强。
        VideoFramePreview(item: item),
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
