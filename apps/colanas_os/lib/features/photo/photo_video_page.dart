import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 相册里的视频播放（以及动态照片那段小视频）。
///
/// 为什么不复用影视库的 `PlayerPage`：那个页面是给「剧集 / 码率 / 转码会话 /
/// 字幕 / HDR」准备的，一整套画质与会话逻辑对一个 20 秒的手机视频是纯负担，
/// 而且它的入口要求 `video` 模块的 itemId。相册只要「能播、能拖、能关」。
///
/// 播放源两种：
///   - 视频文件：`/api/v1/files/download?path=...`（服务端已支持 Range/206）
///   - 动态照片：`/api/v1/photo/live?id=...`（服务端把 JPEG 尾部那段 mp4
///     当虚拟文件按 Range 发出，不落盘）
class PhotoVideoPage extends StatefulWidget {
  const PhotoVideoPage({
    super.key,
    required this.url,
    this.title,
    this.subtitle,
  });

  final String url;
  final String? title;
  final String? subtitle;

  @override
  State<PhotoVideoPage> createState() => _PhotoVideoPageState();
}

class _PhotoVideoPageState extends State<PhotoVideoPage> {
  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _buffering = true;
  String? _error;
  bool _controlsVisible = true;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _subs.add(_player.stream.playing.listen((v) => _safe(() => _playing = v)));
    _subs.add(_player.stream.position.listen((v) => _safe(() => _position = v)));
    _subs.add(_player.stream.duration.listen((v) => _safe(() => _duration = v)));
    _subs.add(_player.stream.buffering.listen((v) => _safe(() => _buffering = v)));
    _subs.add(
      _player.stream.error.listen((e) {
        // 音轨缺失之类的告警会走这里，但画面是好的，不必弹错误
        final msg = e.toString();
        if (msg.isEmpty || msg.contains('audio')) return;
        _safe(() => _error = msg);
      }),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 鉴权走 Authorization 头：视频流不接受 query token（服务端只认头）
      unawaited(
        _player
            .open(Media(widget.url, httpHeaders: ApiSession.instance.authHeaders))
            .catchError((Object e) {
              _safe(() => _error = e.toString());
            }),
      );
    });
  }

  void _safe(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  void _toggle() {
    if (_player.state.playing) {
      unawaited(_player.pause());
    } else {
      unawaited(_player.play());
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds;
    final value = total <= 0
        ? 0.0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0).toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.space): _toggle,
        },
        child: Focus(
          autofocus: true,
          child: GestureDetector(
            onTap: () => setState(() => _controlsVisible = !_controlsVisible),
            behavior: HitTestBehavior.opaque,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(NasTokens.spaceLg),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline, color: Colors.white54, size: 36),
                              const SizedBox(height: 12),
                              Text(
                                tr('photo.video.failed', {'error': _error!}),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                            ],
                          ),
                        )
                      : Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fit: BoxFit.contain,
                        ),
                ),
                if (_buffering && _error == null)
                  const Center(
                    child: SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (!_playing && _error == null && !_buffering)
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: IconButton(
                        iconSize: 34,
                        color: Colors.white,
                        icon: const Icon(Icons.play_arrow),
                        onPressed: _toggle,
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black54, Colors.transparent, Colors.black87],
                          stops: [0, 0.35, 1],
                        ),
                      ),
                      child: Column(
                        children: [
                          SafeArea(
                            bottom: false,
                            child: Row(
                              children: [
                                IconButton(
                                  color: Colors.white,
                                  icon: const Icon(Icons.close),
                                  onPressed: () => Navigator.of(context).maybePop(),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.title ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontSize: 13),
                                      ),
                                      if (widget.subtitle != null)
                                        Text(
                                          widget.subtitle!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          SafeArea(
                            top: false,
                            child: Row(
                              children: [
                                IconButton(
                                  color: Colors.white,
                                  iconSize: 30,
                                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                                  onPressed: _toggle,
                                ),
                                Text(
                                  _fmt(_position),
                                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                                ),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 12,
                                      ),
                                    ),
                                    child: Slider(
                                      value: value,
                                      activeColor: Colors.white,
                                      inactiveColor: Colors.white24,
                                      onChanged: total <= 0
                                          ? null
                                          : (v) {
                                              final target = Duration(
                                                milliseconds: (v * total).round(),
                                              );
                                              // ignore: discarded_futures
                                              _player.seek(target);
                                            },
                                    ),
                                  ),
                                ),
                                Text(
                                  _fmt(_duration),
                                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                                ),
                                IconButton(
                                  color: Colors.white,
                                  icon: const Icon(Icons.replay_10),
                                  onPressed: () => _player.seek(
                                    _position - const Duration(seconds: 10),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
