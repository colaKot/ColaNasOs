import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 混合库（相册 / 回忆）里的一项视频，用于播放器内的「播放列表」。
class PhotoVideoEntry {
  const PhotoVideoEntry({
    required this.url,
    required this.title,
    this.durationMs,
    this.width,
    this.height,
  });

  final String url;
  final String title;
  final int? durationMs;
  final int? width;
  final int? height;
}

/// 相册 / 混合库里的视频播放（以及动态照片那段小视频）。
///
/// 为什么不复用影视库的 `PlayerPage`：那个页面绑着 `video` 模块的 itemId、
/// 转码会话、画质档位与 HLS，对一个 20 秒的手机视频是纯负担；这里播的是
/// 原文件（`/files/download`，服务端支持 Range/206），不需要任何转码。
///
/// 但「不需要转码」不等于「功能可以缺」—— 倍速、音量、响度归一、降混、
/// 媒体信息、播放列表都在这条直连链路上自己实现（libmpv 属性 / media_kit API）。
class PhotoVideoPage extends StatefulWidget {
  const PhotoVideoPage({
    super.key,
    required this.url,
    this.title,
    this.subtitle,
    this.entries,
    this.initialIndex = 0,
  });

  final String url;
  final String? title;
  final String? subtitle;

  /// 同批次其它视频（可上下切换 / 列表选择）。为空时当作单曲播放。
  final List<PhotoVideoEntry>? entries;
  final int initialIndex;

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

  late int _index;
  double _rate = 1;
  double _volume = 100;
  bool _normalize = false;
  bool _downmix = false;
  /// libmpv 报的视频码率（kbps）；拿不到就是 0
  int _kbps = 0;

  List<PhotoVideoEntry> get _list => widget.entries ?? const <PhotoVideoEntry>[];
  bool get _hasPlaylist => _list.length > 1;

  PhotoVideoEntry? get _current {
    final list = _list;
    if (list.isEmpty) return null;
    final i = _index.clamp(0, list.length - 1);
    return list[i];
  }

  String get _url => _current?.url ?? widget.url;
  String get _title => _current?.title ?? widget.title ?? '';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.entries == null ? 0 : widget.entries!.length - 1);
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
      _openCurrent();
    });
  }

  /// 打开当前项。鉴权走 Authorization 头：视频流不接受 query token（只认头）。
  void _openCurrent() {
    _error = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    unawaited(
      _player
          .open(Media(_url, httpHeaders: ApiSession.instance.authHeaders))
          .then((_) async {
        // open 之后再把音频链与倍速应用一遍：属性在 open 前设在部分构建上会丢
        await _applyAudio();
        await _player.setRate(_rate);
        await _player.setVolume(_volume);
        _readBitrate();
      }).catchError((Object e) {
        _safe(() => _error = e.toString());
      }),
    );
  }

  /// 读 libmpv 的 video-bitrate（直连播放时容器头里有）。Web 端没有该属性，跳过。
  void _readBitrate() {
    if (kIsWeb) return;
    try {
      // ignore: avoid_dynamic_calls
      final f = (_player.platform as dynamic).getProperty('video-bitrate');
      if (f is Future) {
        f.then((v) {
          final n = int.tryParse('$v') ?? 0;
          if (n > 0 && mounted) setState(() => _kbps = (n / 1000).round());
        }).catchError((Object _) {});
      }
    } catch (_) {
      // 拿不到就显示 —
    }
  }

  void _setProp(String key, String value) {
    if (kIsWeb) return;
    try {
      // NativePlayer 在 Web 上是空壳（没有 setProperty），且 Web 解码交给浏览器；
      // 静态调用会让 flutter build web 编译失败，所以运行时动态派发。
      // ignore: avoid_dynamic_calls
      (_player.platform as dynamic).setProperty(key, value);
    } catch (_) {
      // 不支持该属性就算了
    }
  }

  /// 响应端也能做的两条音频处理（服务端转码参数在这里对应到 libmpv 滤镜）。
  Future<void> _applyAudio() async {
    // 响度归一：dynaudnorm 是实时滤镜，边播边把音量拉平，不需要预扫。
    _setProp('af', _normalize ? 'lavfi=[dynaudnorm=f=250:g=15]' : '');
    // 降混：把 5.1/7.1 混成双声道（耳机 / 笔记本扬声器不会丢中置人声以外的声道）
    _setProp('audio-channels', _downmix ? 'stereo' : 'auto');
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

  void _playAt(int i) {
    final list = _list;
    if (list.isEmpty || i < 0 || i >= list.length) return;
    setState(() {
      _index = i;
      _kbps = 0;
    });
    _openCurrent();
  }

  void _prev() => _playAt(_index - 1);
  void _next() => _playAt(_index + 1);

  /// `1x` / `1.25x` —— 整数倍速不显示 `.0`
  String _rateText(double v) {
    final head = v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    return '${head}x';
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
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _player.seek(_position + const Duration(seconds: 5)),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _player.seek(_position - const Duration(seconds: 5)),
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
                                        _title,
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
                                IconButton(
                                  tooltip: tr('player.mediaInfo'),
                                  color: Colors.white,
                                  icon: const Icon(Icons.tune),
                                  onPressed: _showSettings,
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
                                if (_hasPlaylist) ...[
                                  IconButton(
                                    tooltip: tr('player.prev'),
                                    color: Colors.white,
                                    icon: const Icon(Icons.skip_previous),
                                    onPressed: _index > 0 ? _prev : null,
                                  ),
                                  IconButton(
                                    tooltip: tr('player.next'),
                                    color: Colors.white,
                                    icon: const Icon(Icons.skip_next),
                                    onPressed: _index < _list.length - 1 ? _next : null,
                                  ),
                                ],
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

  // ------------------------------------------------------------------ 设置面板

  /// 倍速 / 音量 / 响度归一 / 降混 / 媒体信息 / 播放列表 全在这一个面板里。
  ///
  /// 直连播放没有服务端转码会话，这些能力只能由客户端自己提供（libmpv 属性
  /// 与 media_kit API），所以不能照搬影视库那套「画质档位」菜单。
  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            void sync(VoidCallback fn) {
              fn();
              setSheet(() {});
              if (mounted) setState(() {});
            }

            final w = _player.state.width ?? _current?.width ?? 0;
            final h = _player.state.height ?? _current?.height ?? 0;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.78,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(NasTokens.spaceLg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sheetLabel(tr('player.speed')),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final r in const <double>[0.5, 0.75, 1, 1.25, 1.5, 2, 3])
                            ChoiceChip(
                              label: Text(_rateText(r)),
                              selected: _rate == r,
                              onSelected: (_) => sync(() {
                                _rate = r;
                                unawaited(_player.setRate(r));
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: NasTokens.spaceMd),
                      _sheetLabel('${tr('player.volume')}  ${_volume.round()}%'),
                      Slider(
                        value: _volume,
                        max: 100,
                        divisions: 20,
                        onChanged: (v) => sync(() {
                          _volume = v;
                          unawaited(_player.setVolume(v));
                        }),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr('player.audioNormalize'),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        value: _normalize,
                        onChanged: (v) => sync(() {
                          _normalize = v;
                          unawaited(_applyAudio());
                        }),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr('player.audioDownmix'),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        value: _downmix,
                        onChanged: (v) => sync(() {
                          _downmix = v;
                          unawaited(_applyAudio());
                        }),
                      ),
                      const Divider(color: Colors.white12, height: NasTokens.spaceLg),
                      _sheetLabel(tr('player.mediaInfo')),
                      _infoRow(
                        tr('player.resolution'),
                        w > 0 && h > 0 ? '$w × $h' : '—',
                      ),
                      _infoRow(
                        tr('player.bitrate'),
                        _kbps > 0 ? '$_kbps kbps' : '—',
                      ),
                      _infoRow('${tr('player.speed')} ×', _rateText(_rate)),
                      if (_hasPlaylist) ...[
                        const Divider(color: Colors.white12, height: NasTokens.spaceLg),
                        _sheetLabel(
                          '${tr('player.playlist')}  ${_index + 1}/${_list.length}',
                        ),
                        for (var i = 0; i < _list.length; i += 1)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            selected: i == _index,
                            title: Text(
                              _list[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: i == _index ? Colors.white : Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            trailing: i == _index
                                ? const Icon(Icons.equalizer, size: 16, color: Colors.white)
                                : null,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _playAt(i);
                            },
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sheetLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      );

  Widget _infoRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            Text(v, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      );
}
