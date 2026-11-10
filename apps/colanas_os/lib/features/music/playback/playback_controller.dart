/// 播放控制器：**唯一**能改播放状态的地方。
///
/// 结构上只有三条规则，但它把旧实现里的五个布尔补丁全替掉了：
///   1. 状态是 `PlayerState` 的互斥值，任何变化走 [_emit]；
///   2. 每个异步动作带一个 [_generation]，老动作回来时对不上号就丢弃
///      （替代 `_rebuildToken`）；
///   3. 「想不想播」不单独存，直接看状态是不是 `PlaybackReady`
///      （替代 `_desiredPlaying`）。
///
/// UI 只做两件事：读 [state]，调下面这些方法。没有别的入口。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback_engine.dart';
import 'playback_queue.dart';
import 'playback_state.dart';
import 'track.dart';

class PlaybackController extends ChangeNotifier {
  /// [engine] 由调用方注入：生产环境传 `MediaKitPlaybackEngine()`，
  /// 测试里塞一个假引擎就能跑完整状态机，不碰真音频。
  ///
  /// 音量与倍速的「听感校准」不在这里做 —— 引擎只认「按 1.2 倍放」，
  /// 校准系数属于业务策略，调用方在 [setRate] 之前自己乘好。
  PlaybackController(this._engine) {
    _bind();
  }

  final PlaybackEngine _engine;

  /// 打开前把 [Track.uri] 换成「真正能播的地址」。
  ///
  /// 音乐壳的 URL 有三种来源：本地缓存文件、服务端转码流、原始直链，
  /// 还要带 token。这些属于业务策略，内核不该知道；默认原样放行。
  Future<Uri> Function(Track track)? resolveUri;

  /// 队列播到末尾时的补给钩子。
  ///
  /// 列表是分页的（一页 36 首），队列只持有已加载的那一段。播到末尾时先让
  /// 外部去拉下一页并 [appendToQueue]，返回 true 表示补到了，可以继续。
  /// 返回 false 就真的结束。
  Future<bool> Function()? onExhausted;

  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  PlayerState _state = const PlaybackIdle();
  PlaybackQueue _queue = PlaybackQueue.empty();

  /// 异步动作代号：每次「换曲 / 重开」自增，回来的旧结果直接丢
  int _generation = 0;

  /// 上一次真正打开过的 URI。重复打开同一首时只 seek，不重载。
  Uri? _openedUri;

  /// 打开时的位置（用于「重建 URL 后接着播」）
  Duration _resumePoint = Duration.zero;

  /// 卡顿看门狗：缓冲迟迟不动时带着进度重开一次
  Timer? _stallTimer;

  double _volume = 1;
  double _rate = 1;

  PlayerState get state => _state;

  PlaybackQueue get queue => _queue;

  Track? get currentTrack => _state.trackOrNull;

  bool get isPlaying => _state.isPlaying;

  Duration get position => switch (_state) {
    PlaybackLoading(:final position) => position,
    PlaybackReady(:final position) => position,
    PlaybackPaused(:final position) => position,
    _ => Duration.zero,
  };

  Duration get duration => switch (_state) {
    PlaybackReady(:final duration) => duration,
    PlaybackPaused(:final duration) => duration,
    PlaybackCompleted(:final duration) => duration,
    _ => currentTrack?.duration ?? Duration.zero,
  };

  double get volume => _volume;

  double get rate => _rate;

  // ---------------------------------------------------------------- 对外动作

  /// 用一批曲目替换队列并从 [startAt] 开始播
  Future<void> playAll(
    List<Track> tracks, {
    int startAt = 0,
    PlaybackLoop loop = PlaybackLoop.none,
  }) {
    _queue = PlaybackQueue.of(tracks, startAt: startAt, loop: loop);
    return _openCurrent(autoPlay: true);
  }

  /// 在现有队列里跳到某一首
  Future<void> jumpTo(int index) {
    _queue = _queue.jumpTo(index);
    return _openCurrent(autoPlay: true);
  }

  /// 队列变了但不想打断当前播放（比如分页加载补数据）
  void appendToQueue(List<Track> more) {
    if (more.isEmpty) return;
    _queue = _queue.append(more);
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (_state is PlaybackReady) {
      await _engine.pause();
      return;
    }
    if (_state is PlaybackPaused) {
      await _engine.play();
      return;
    }
    // 停在 idle / completed / failed 时按播放：有队列就重开当前这首
    if (_queue.isNotEmpty) {
      await _openCurrent(autoPlay: true, forceReload: _state is PlaybackFailed);
    }
  }

  Future<void> seek(Duration position) async {
    if (!_state.hasTrack) return;
    final total = duration;
    final target = position.isNegative
        ? Duration.zero
        : (total > Duration.zero && position > total ? total : position);
    await _engine.seek(target);
    // 乐观更新：等引擎回来之前界面先跟上，避免拖动条回弹一下
    if (_state is PlaybackReady) {
      _emit((_state as PlaybackReady).copyWith(position: target));
    }
  }

  Future<void> next({bool userInitiated = true}) async {
    if (_queue.isEmpty) return;
    // 手动点「下一首」时忽略单曲循环：用户就是想换歌
    final before = _queue.loop;
    final queue = userInitiated && before == PlaybackLoop.one
        ? _queue.withLoop(PlaybackLoop.none)
        : _queue;
    final (advanced, action) = queue.advance();
    _queue = queue.withLoop(before);
    if (action == QueueAdvance.exhausted) return;
    if (action == QueueAdvance.repeatCurrent) {
      await seek(Duration.zero);
      await _engine.play();
      return;
    }
    _queue = advanced;
    await _openCurrent(autoPlay: true);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    // 播了 3 秒以上时，「上一首」先回到本曲开头（和主流播放器一致）
    if (position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    _queue = _queue.retreat();
    await _openCurrent(autoPlay: true);
  }

  Future<void> setLoop(PlaybackLoop mode) async {
    _queue = _queue.withLoop(mode);
    await _engine.setLoop(mode);
    notifyListeners();
  }

  /// 停止并清空队列（保留引擎实例，随时可以再播）
  Future<void> stop() async {
    // 让所有在飞的异步动作作废，避免它们回来后又把状态点亮
    _generation++;
    _openedUri = null;
    _resumePoint = Duration.zero;
    _queue = PlaybackQueue.empty();
    try {
      await _engine.pause();
    } catch (_) {
      // 引擎已经停了也会走到这里，忽略即可
    }
    _emit(const PlaybackIdle());
  }

  void setShuffle(bool enabled) {
    _queue = _queue.withShuffle(enabled);
    notifyListeners();
  }

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    await _engine.setVolume(_volume);
    notifyListeners();
  }

  Future<void> setRate(double value) async {
    _rate = value <= 0 ? 1 : value;
    await _engine.setRate(_rate);
    notifyListeners();
  }

  /// 从队列里移除某一首（删文件后调用）
  void removeAt(int index) {
    final wasCurrent = index == _queue.cursor;
    _queue = _queue.removeAt(index);
    notifyListeners();
    if (wasCurrent && _queue.isNotEmpty) {
      unawaited(_openCurrent(autoPlay: isPlaying));
    } else if (_queue.isEmpty) {
      _emit(const PlaybackIdle());
    }
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    unawaited(_engine.dispose());
    super.dispose();
  }

  // ---------------------------------------------------------------- 内部实现

  void _bind() {
    _subs.addAll(<StreamSubscription<Object?>>[
      _engine.playingStream.listen((playing) {
        if (!_state.hasTrack) return;
        // completed 之后引擎还会发一次 false，不能把它当成「用户暂停」
        if (_state is PlaybackCompleted) return;
        if (playing && _state is! PlaybackReady) {
          _emit(_readyFrom(_state, position: position));
        } else if (!playing && _state is PlaybackReady) {
          _emit(
            PlaybackPaused(
              track: (_state as PlaybackReady).track,
              position: (_state as PlaybackReady).position,
              duration: (_state as PlaybackReady).duration,
              buffered: (_state as PlaybackReady).buffered,
            ),
          );
        }
      }),
      _engine.positionStream.listen((position) {
        final next = _state;
        if (next is PlaybackReady) {
          _emit(next.copyWith(position: position));
        } else if (next is PlaybackPaused) {
          _emit(
            PlaybackPaused(
              track: next.track,
              position: position,
              duration: next.duration,
              buffered: next.buffered,
            ),
          );
        }
      }),
      _engine.durationStream.listen((duration) {
        final next = _state;
        if (next is PlaybackReady) {
          _emit(next.copyWith(duration: duration));
        } else if (next is PlaybackPaused) {
          _emit(
            PlaybackPaused(
              track: next.track,
              position: next.position,
              duration: duration,
              buffered: next.buffered,
            ),
          );
        }
      }),
      _engine.bufferedStream.listen((buffered) {
        final next = _state;
        if (next is PlaybackReady) _emit(next.copyWith(buffered: buffered));
      }),
      // 卡住恢复：缓冲超过 12 秒还没动静，就带着当前进度重开一次。
      // 旧实现靠轮询检查 `_player.isBuffering`，新内核直接用引擎的 buffering 流。
      _engine.bufferingStream.listen((buffering) {
        if (!buffering || !_state.isPlaying) {
          _stallTimer?.cancel();
          _stallTimer = null;
          return;
        }
        _stallTimer ??= Timer(const Duration(seconds: 12), () {
          _stallTimer = null;
          if (!_state.isPlaying) return;
          unawaited(_recoverFromStall());
        });
      }),
      _engine.completedStream.listen((_) {
        if (!_state.hasTrack) return;
        final track = _state.trackOrNull!;
        _emit(PlaybackCompleted(track, duration: duration));
        unawaited(_handleCompleted());
      }),
      _engine.errorStream.listen((error) {
        // 传输层噪声不切状态：播放器自己会续上，切了反而让界面闪一下错误页
        if (error.benign) return;
        _emit(PlaybackFailed('播放失败', detail: error.message, track: currentTrack));
      }),
    ]);
  }

  /// 卡顿恢复：带着当前位置把同一首重新打开一次（保留进度，不回到开头）
  Future<void> _recoverFromStall() async {
    if (!_state.isPlaying || _queue.isEmpty) return;
    _resumePoint = position;
    // 清掉「已打开」标记，绕过「同一首只 seek 不重开」的短路
    _openedUri = null;
    await _openCurrent(autoPlay: true, forceReload: true);
  }

  Future<void> _handleCompleted() async {
    final (advanced, action) = _queue.advance();
    switch (action) {
      case QueueAdvance.repeatCurrent:
        await seek(Duration.zero);
        await _engine.play();
        return;
      case QueueAdvance.next:
        _queue = advanced;
        await _openCurrent(autoPlay: true);
        return;
      case QueueAdvance.exhausted:
        // 分页列表：先问外部能不能补给（拉下一页），补上了才真的结束
        final supplier = onExhausted;
        if (supplier == null || !await supplier()) return;
        final (again, retry) = _queue.advance();
        if (retry != QueueAdvance.next) return;
        _queue = again;
        await _openCurrent(autoPlay: true);
    }
  }

  Future<void> _openCurrent({
    required bool autoPlay,
    bool forceReload = false,
  }) async {
    final track = _queue.current;
    if (track == null) {
      _emit(const PlaybackIdle());
      return;
    }

    // 同一首、只是「重新播」：不重载，seek 回起点就够（省一次加载 + 不停音）
    final sameTrack = !forceReload && _openedUri == track.uri;
    if (sameTrack) {
      await seek(Duration.zero);
      if (autoPlay) await _engine.play();
      return;
    }

    final generation = ++_generation;
    final resumeFrom = _resumePoint;
    _emit(PlaybackLoading(track, position: resumeFrom));
    try {
      // 缓存文件 / 转码流 / 带 token 的直链由外部决定，内核只拿最终地址
      final target = await (resolveUri?.call(track) ?? Future<Uri>.value(track.uri));
      if (generation != _generation) return;
      await _engine.setLoop(_queue.loop);
      await _engine.setVolume(_volume);
      await _engine.setRate(_rate);
      await _engine.open(target, startAt: resumeFrom, autoPlay: autoPlay);
      if (generation != _generation) return;
      _openedUri = track.uri;
      _resumePoint = Duration.zero;
      // 先给一个 ready 壳子，真实 duration/position 由流补上
      _emit(
        PlaybackReady(
          track: track,
          position: resumeFrom,
          duration: track.duration ?? Duration.zero,
          buffered: Duration.zero,
        ),
      );
    } catch (error) {
      if (generation != _generation) return;
      _emit(
        PlaybackFailed('无法播放这首歌', detail: '$error', track: track),
      );
    }
  }

  PlaybackReady _readyFrom(
    PlayerState from, {
    required Duration position,
  }) => PlaybackReady(
    track: from.trackOrNull!,
    position: position,
    duration: duration,
    buffered: switch (from) {
      PlaybackReady(:final buffered) => buffered,
      PlaybackPaused(:final buffered) => buffered,
      _ => Duration.zero,
    },
  );

  void _emit(PlayerState next) {
    _state = next;
    notifyListeners();
  }
}
