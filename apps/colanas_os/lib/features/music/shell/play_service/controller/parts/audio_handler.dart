part of '../cola_player_controller.dart';

class _MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final MusicPlayServiceController controller;
  int? _lastQueueIndex;
  AudioProcessingState? _lastProcessingState;
  DateTime? _lastPositionUpdate;
  bool? _lastPlaying;

  _MusicAudioHandler(this.controller);

  @override
  Future<void> skipToQueueItem(int index) async {
    await controller.playAt(index);
  }

  /// 系统循环模式 → 播放器循环模式。随机播放是独立状态，
  /// 除「单曲循环」外都要给随机让路（系统切 none/all 不该悄悄退出随机）。
  MusicLoopMode _loopFor(AudioServiceRepeatMode mode) => switch (mode) {
    AudioServiceRepeatMode.one => MusicLoopMode.singleLoop,
    AudioServiceRepeatMode.all ||
    AudioServiceRepeatMode.group => MusicLoopMode.listLoop,
    AudioServiceRepeatMode.none => MusicLoopMode.sequence,
  };

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final shuffling = controller.loopMode.value == MusicLoopMode.shuffle;
    if (shuffling && repeatMode != AudioServiceRepeatMode.one) return;
    await controller.setLoopMode(_loopFor(repeatMode));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (shuffleMode != AudioServiceShuffleMode.none) {
      await controller.setLoopMode(MusicLoopMode.shuffle);
      return;
    }
    if (controller.loopMode.value != MusicLoopMode.shuffle) return;
    // 退出随机时按系统当前循环模式回落；这里不能再走 setRepeatMode，
    // 因为那条路径在 shuffle 状态下会主动让路。
    await controller.setLoopMode(_loopFor(playbackState.value.repeatMode));
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    queue.add(newQueue);
  }

  @override
  Future<void> play() async {
    await controller.play();
  }

  @override
  Future<void> pause() async {
    await controller.pause();
  }

  @override
  Future<void> stop() async {
    await controller.stop();
    await super.stop();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button != MediaButton.media) {
      await super.click(button);
      return;
    }
    await (controller.isPlaying.value ? pause() : play());
  }

  @override
  Future<void> seek(Duration position) async {
    await controller.seekTo(position);
  }

  /// 切歌失败时把通知栏状态重新对齐一次，再把异常交给调用方。
  Future<void> _skipTo({required bool next}) async {
    try {
      await (next
          ? controller.playNext(forcePlay: true)
          : controller.playPrevious(forcePlay: true));
    } catch (_) {
      controller._syncHandlerPlaybackState();
      rethrow;
    }
  }

  @override
  Future<void> skipToNext() => _skipTo(next: true);

  @override
  Future<void> skipToPrevious() => _skipTo(next: false);

  void _syncPlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
    required Duration updatePosition,
    required Duration bufferedPosition,
    required int queueIndex,
  }) {
    if (!_shouldEmit(
      playing: playing,
      processingState: processingState,
      queueIndex: queueIndex,
    )) {
      return;
    }

    playbackState.add(
      PlaybackState(
        updatePosition: updatePosition,
        systemActions: const <MediaAction>{
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        speed: 1.0,
        shuffleMode: _shuffleMode,
        repeatMode: _repeatMode,
        queueIndex: queueIndex,
        processingState: processingState,
        playing: playing,
        controls: _controlsFor(playing),
        bufferedPosition: bufferedPosition,
        androidCompactActionIndices: const <int>[0, 1, 2],
      ),
    );
  }

  /// 通知栏状态不能每帧都推：播放/暂停、处理状态、队列位置这类关键变化立即推，
  /// 纯进度最多每秒一次。这里同时记住本次快照。
  bool _shouldEmit({
    required bool playing,
    required AudioProcessingState processingState,
    required int queueIndex,
  }) {
    final critical =
        _lastPlaying != playing ||
        _lastProcessingState != processingState ||
        _lastQueueIndex != queueIndex;
    final previous = _lastPositionUpdate;
    final now = DateTime.now();
    final dueToPosition =
        previous == null ||
        now.difference(previous) >= const Duration(seconds: 1);

    _lastPlaying = playing;
    _lastProcessingState = processingState;
    _lastQueueIndex = queueIndex;
    final emit = critical || dueToPosition;
    if (emit) _lastPositionUpdate = now;
    return emit;
  }

  AudioServiceRepeatMode get _repeatMode => switch (controller.loopMode.value) {
    MusicLoopMode.singleLoop => AudioServiceRepeatMode.one,
    MusicLoopMode.listLoop ||
    MusicLoopMode.shuffle => AudioServiceRepeatMode.all,
    MusicLoopMode.sequence => AudioServiceRepeatMode.none,
  };

  AudioServiceShuffleMode get _shuffleMode =>
      controller.loopMode.value == MusicLoopMode.shuffle
      ? AudioServiceShuffleMode.all
      : AudioServiceShuffleMode.none;

  List<MediaControl> _controlsFor(bool playing) => <MediaControl>[
    MediaControl.skipToPrevious,
    playing ? MediaControl.pause : MediaControl.play,
    MediaControl.skipToNext,
  ];
}
