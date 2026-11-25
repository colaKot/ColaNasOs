import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvMedia3State {
  const TvMedia3State({
    this.positionMs = 0,
    this.durationMs = 0,
    this.bufferedPositionMs = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.videoDecoder = '',
    this.firstFrameMs,
    this.viewWidth = 0,
    this.viewHeight = 0,
    this.surfaceWidth = 0,
    this.surfaceHeight = 0,

    /// 当前流里没有任何可用的音频解码器（手机上的 E-AC3 / DTS-HD 很常见）
    this.audioUnsupported = false,
    this.error,
  });

  final int positionMs;
  final int durationMs;
  final int bufferedPositionMs;
  final int videoWidth;
  final int videoHeight;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;
  final String videoDecoder;
  final int? firstFrameMs;

  /// 原生 PlayerView 与内部 SurfaceView 的真实像素尺寸，排障用。
  final int viewWidth;
  final int viewHeight;
  final int surfaceWidth;
  final int surfaceHeight;

  /// 当前流里没有可用的音频解码器（手机 E-AC3 / DTS-HD）
  final bool audioUnsupported;

  final String? error;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);
  Duration get bufferedPosition => Duration(milliseconds: bufferedPositionMs);
  Duration get buffer {
    final aheadMs = bufferedPositionMs - positionMs;
    return Duration(milliseconds: aheadMs > 0 ? aheadMs : 0);
  }

  factory TvMedia3State.fromMap(Map<Object?, Object?> map) => TvMedia3State(
    positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    bufferedPositionMs: (map['bufferedPositionMs'] as num?)?.toInt() ?? 0,
    videoWidth: (map['videoWidth'] as num?)?.toInt() ?? 0,
    videoHeight: (map['videoHeight'] as num?)?.toInt() ?? 0,
    isPlaying: map['isPlaying'] == true,
    isBuffering: map['isBuffering'] == true,
    isCompleted: map['isCompleted'] == true,
    videoDecoder: map['videoDecoder']?.toString() ?? '',
    firstFrameMs: (map['firstFrameMs'] as num?)?.toInt(),
    viewWidth: (map['viewWidth'] as num?)?.toInt() ?? 0,
    viewHeight: (map['viewHeight'] as num?)?.toInt() ?? 0,
    surfaceWidth: (map['surfaceWidth'] as num?)?.toInt() ?? 0,
    surfaceHeight: (map['surfaceHeight'] as num?)?.toInt() ?? 0,
    audioUnsupported: map['audioUnsupported'] == true,
    error: map['error']?.toString(),
  );
}

/// 原生视频播放器控制器。
///
/// 视频画面不再由 Flutter 平台视图提供：原生层把 `PlayerView`（裸 SurfaceView）
/// 插到 Activity 内容层最底部，Flutter 用透明像素把它露出来。所以这里只负责
/// 「挂上 / 摘下原生层」和发控制命令、收状态事件。
class TvMedia3PlayerController {
  static const _methodChannel = MethodChannel('com.colanas.os/tv_media3');
  static const _eventChannel = EventChannel('com.colanas.os/tv_media3/events');

  /// 原生 PlayerView 与会话在进程内是**唯一**的（Activity 只有一个底层 Surface）。
  /// 换集时新页面先建、旧页面后 dispose，旧页面若无条件 detach / dispose，
  /// 会把新页面刚挂上的视频层摘掉，表现为「页面在、画面全空」。
  /// 因此只有最后创建 / 最后挂上的控制器才有权操作原生层。
  static TvMedia3PlayerController? _active;

  /// 原生事件通道：整个进程只订阅一次。
  ///
  /// 每个播放页各自 `receiveBroadcastStream()` 会在同一条 EventChannel 上重复
  /// listen / cancel。Android 侧一条通道只维护一个活动流，旧页面销毁时 cancel
  /// 会抛 `PlatformException(No active stream to cancel)`，还会把新会话打断
  /// （表现：切集后黑屏不播）。这里持有一条共享流，各控制器只听本地广播。
  static Stream<dynamic>? _sharedEvents;
  static Stream<dynamic> get _events =>
      _sharedEvents ??= _eventChannel.receiveBroadcastStream();

  final _stateChanges = StreamController<TvMedia3State>.broadcast();
  TvMedia3State _state = const TvMedia3State();
  StreamSubscription<dynamic>? _eventSubscription;
  bool _disposed = false;
  bool _attached = false;
  Map<String, Object?>? _lastOpen;

  /// 是否是当前原生层的所有者。桌面 / Web 没有原生层，恒为 true。
  bool get isActiveInstance => !_supported || identical(_active, this);

  TvMedia3State get state => _state;
  Stream<TvMedia3State> get states => _stateChanges.stream;
  late final Stream<Duration> positionStream = states
      .map((state) => state.position)
      .distinct();
  late final Stream<Duration> durationStream = states
      .map((state) => state.duration)
      .distinct();
  late final Stream<bool> playingStream = states
      .map((state) => state.isPlaying)
      .distinct();
  late final Stream<bool> bufferingStream = states
      .map((state) => state.isBuffering)
      .distinct();
  late final Stream<bool> completedStream = states
      .map((state) => state.isCompleted)
      .distinct();
  late final Stream<String> errorStream = states
      .map((state) => state.error)
      .where((error) => error != null && error.isNotEmpty)
      .cast<String>();

  TvMedia3PlayerController() {
    // 只有 Android 装了原生视频通道。桌面 / Web 监听会拿到 MissingPluginException，
    // 反而把播放页顶成错误页，所以这里直接不订阅。
    if (!_supported) return;
    _active = this;
    _eventSubscription = _events.listen(
      (event) {
        // 已被新播放页接管：原生状态属于新会话，旧页面不能再跟着动
        // （否则旧页面会用自己那部片重开会话，和新页面互相顶，表现为黑屏）
        if (!isActiveInstance) return;
        if (event is Map) {
          _update(TvMedia3State.fromMap(Map<Object?, Object?>.from(event)));
        }
      },
      onError: (Object error) {
        if (!isActiveInstance) return;
        _update(
          TvMedia3State(error: 'Native video event channel failed: $error'),
        );
      },
    );
  }

  static Future<bool> supportsDolbyVision() async {
    try {
      return await _methodChannel.invokeMethod<bool>('supportsDolbyVision') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// 播放链路诊断文本（轨道 MIME / 设备 DV、HEVC 解码器能力），只用于排障日志。
  static Future<String> codecDiagnostics() async {
    try {
      return await _methodChannel.invokeMethod<String>('codecDiagnostics') ?? '';
    } on PlatformException {
      return '';
    }
  }

  /// 让原生层把视频 Surface 挂到 Flutter 下面。
  Future<void> attach() async {
    if (_disposed) return;
    // 谁最后挂上谁拥有原生层（从上层页面返回时也会走到这里）
    if (_supported) _active = this;
    if (_attached) return;
    _attached = true;
    try {
      await _methodChannel.invokeMethod<void>('attach');
    } on PlatformException {
      _attached = false;
    }
  }

  /// 重新接管原生层所有权：页面重新回到最上层时调用，
  /// 此时新页面已经销毁，原生层需要交还给这个还活着的页面。
  void claim() {
    if (_disposed || !_attached) return;
    if (!_supported) return;
    final cur = _active;
    // 只有当前没有别的活控制器时才接管：换集时旧页面还会再 build 一次，
    // 不能让它把新页面的所有权抢回去（抢回去 => 新页面无法 open => 黑屏）
    if (cur == null || identical(cur, this) || cur._disposed) {
      _active = this;
    }
  }

  /// 从窗口里摘下原生视频层（离开播放页时调用）。
  Future<void> detach() async {
    if (!_attached) return;
    _attached = false;
    // 已被新播放页接管：原生层现在归它，不能摘
    if (!isActiveInstance) return;
    try {
      await _methodChannel.invokeMethod<void>('detach');
    } on PlatformException {
      // 原生层可能已经随 Activity 一起销毁，忽略
    }
  }

  Future<void> open({
    required String url,
    required int positionMs,
    required bool play,
    required String formatHint,

    /// 隧道模式：只有电视芯片支持。手机 / 平板打开会黑屏（解码器就绪但
    /// VideoSize 停在 0x0，只有声音），所以默认关，由 TV 模式显式打开。
    bool tunneled = false,

    /// 视频与音频分开取：视频用 [url]（原片，杜比视界配置完整），音频用这条
    /// 服务端转好的 AAC 流。
    String? audioUrl,

    /// 媒体通知 / 状态栏显示的标题
    String? title,
  }) async {
    if (_disposed) throw StateError('TV Media3 player is disposed');
    // 已被新播放页接管：旧页面的延迟回调（直连判定 / 补播）不能再改共享会话
    if (!isActiveInstance) return;
    final args = <String, Object?>{
      'url': url,
      'positionMs': positionMs < 0 ? 0 : positionMs,
      'play': play,
      'formatHint': formatHint,
      'tunneled': tunneled,
      if (audioUrl != null && audioUrl.isNotEmpty) 'audioUrl': audioUrl,
      if (title != null && title.isNotEmpty) 'title': title,
    };
    _lastOpen = args;
    _update(const TvMedia3State(isBuffering: true));
    await _methodChannel.invokeMethod<void>('open', args);
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seekTo(Duration position) =>
      _invoke('seekTo', {'positionMs': position.inMilliseconds});
  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume.clamp(0, 100) / 100});
  Future<void> setRate(double rate) =>
      _invoke('setRate', {'rate': rate.clamp(0.5, 2.0)});

  Future<void> setAudioTrack(int index) =>
      _invoke('setAudioTrack', {'index': index});
  Future<void> setRepeatMode(String mode) =>
      _invoke('setRepeatMode', {'mode': mode});
  Future<void> setShuffle(bool enabled) =>
      _invoke('setShuffle', {'enabled': enabled});

  Future<void> stop() async {
    if (_disposed || !isActiveInstance) return;
    _lastOpen = null;
    try {
      await _methodChannel.invokeMethod<void>('stop');
    } on PlatformException {
      // 播放器还没建出来：没有可停的东西
    }
    _update(const TvMedia3State());
  }

  /// 跟手平移原生视频层（上下滑动切集时用）。传 0 复原。
  Future<void> setOffset(double dy) async {
    if (_disposed || !isActiveInstance) return;
    try {
      await _methodChannel.invokeMethod<void>('setOffset', {'dy': dy});
    } on PlatformException {
      // 原生层不在：忽略，画面最多不跟手
    } on MissingPluginException {
      // 桌面 / Web 没有原生层
    }
  }

  /// 位置：重新打开（换档 / 续播）时用上一次的源与播放意图。
  Map<String, Object?>? get lastOpen => _lastOpen;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final wasActive = isActiveInstance;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    if (!_supported) {
      await _stateChanges.close();
      return;
    }
    if (wasActive) {
      if (identical(_active, this)) _active = null;
      try {
        await _methodChannel.invokeMethod<void>('dispose');
      } on PlatformException {
        // Activity 已销毁：原生层随之释放
      } on MissingPluginException {
        // 原生通道不存在（极少数桌面 / 测试环境）
      }
    }
    await _stateChanges.close();
  }

  Future<void> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed) throw StateError('TV Media3 player is disposed');
    if (!isActiveInstance) return;
    await _methodChannel.invokeMethod<void>(method, args);
  }

  void _update(TvMedia3State state) {
    if (_disposed) return;
    _state = state;
    _stateChanges.add(state);
  }
}

/// 透明占位：真正的画面由 Activity 底层的原生 SurfaceView 提供。
///
/// 它仍然要占据播放页的布局位置，这样 Flutter 不会在整页透明时把控件算成 0 尺寸；
/// 同时通过 attach / detach 告诉原生层什么时候该挂、什么时候该摘。
class TvMedia3PlayerSurface extends StatefulWidget {
  const TvMedia3PlayerSurface({
    required this.controller,
    this.onTap,
    this.onAttached,
    super.key,
  });

  final TvMedia3PlayerController controller;
  final VoidCallback? onTap;

  /// 原生 SurfaceView 真正挂进窗口后的回调。
  ///
  /// 播放页要等这一刻才把黑底 / 根背景撤掉：更早撤的话，窗口会短暂透明，
  /// 手机桌面的画面可能从缝里闪出来。
  final VoidCallback? onAttached;

  @override
  State<TvMedia3PlayerSurface> createState() => _TvMedia3PlayerSurfaceState();
}

class _TvMedia3PlayerSurfaceState extends State<TvMedia3PlayerSurface> {
  @override
  void initState() {
    super.initState();
    unawaited(_attach());
  }

  Future<void> _attach() async {
    await widget.controller.attach();
    if (mounted) widget.onAttached?.call();
  }

  @override
  void didUpdateWidget(covariant TvMedia3PlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(oldWidget.controller.detach());
      unawaited(_attach());
    }
  }

  @override
  void dispose() {
    unawaited(widget.controller.detach());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    // 不能返回不透明底色：Flutter 这一块必须全透明，才能看到下面原生 Surface。
    return const SizedBox.expand();
  }
}
