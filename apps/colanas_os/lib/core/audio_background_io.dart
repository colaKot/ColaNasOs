import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'audio_background.dart';

/// 只在 Android 上真正拉起前台服务；其余 io 平台（Windows / macOS / Linux）
/// 保持改动前的行为 —— 桌面窗口常驻，不需要系统托底。
AudioBackground createAudioBackground() =>
    Platform.isAndroid ? _AndroidAudioBackground() : NoopAudioBackground();

/// 通知 / 锁屏面板的下发口。系统按键在这里收，转手交给最近一次快照的回调。
class _ColanasAudioHandler extends BaseAudioHandler with SeekHandler {
  /// 最新快照：命令总是转给它，所以即使面板是节流过的，按下去也作用于当前音源。
  AudioSnapshot? latest;

  /// 写一次面板（跨 channel，调用方负责节流）。
  void apply(AudioSnapshot? s) {
    if (s == null || s.id.isEmpty) {
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          controls: const [],
          systemActions: const {},
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      return;
    }
    mediaItem.add(
      MediaItem(
        id: s.id,
        title: s.title,
        artist: s.artist ?? '',
        album: s.album ?? '',
        duration: s.duration,
      ),
    );
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (s.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {MediaAction.seek},
        // 折叠态通知只放得下三个：上一期 / 播放暂停 / 下一期
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: s.playing,
        updatePosition: s.position,
        bufferedPosition: s.duration,
        speed: 1,
      ),
    );
  }

  @override
  Future<void> play() async => latest?.onPlay();

  @override
  Future<void> pause() async => latest?.onPause();

  @override
  Future<void> skipToNext() async => latest?.onNext();

  @override
  Future<void> skipToPrevious() async => latest?.onPrevious();

  @override
  Future<void> seek(Duration position) async => latest?.onSeek(position);

  @override
  Future<void> stop() async {
    final s = latest;
    latest = null;
    s?.onStop();
    await super.stop();
  }
}

class _AndroidAudioBackground implements AudioBackground {
  _ColanasAudioHandler? _handler;

  /// 上次真正写面板的内容：拿它和推送来的快照比，只有「面子变了」才跨 channel。
  AudioSnapshot? _pushed;

  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// media_kit 的 position 流大约每秒 10 次，全推过去会让通知栏一直重绘。
  static const _minPushGap = Duration(milliseconds: 900);

  @override
  Future<void> ensureStarted({required String channelName}) async {
    if (_handler != null) return;
    try {
      _handler = await AudioService.init(
        builder: _ColanasAudioHandler.new,
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.colanas.os.playback',
          androidNotificationChannelName: channelName,
          // 播放时保持常驻：Android 才会把进程当前台服务，熄屏不被冻
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationClickStartsActivity: true,
        ),
      );
    } catch (e) {
      // 增强项失败不能挡住启动：退化成「只有 App 在前台时才保证出声」
      debugPrint('音频前台服务不可用：$e');
      _handler = null;
    }
  }

  @override
  void update(AudioSnapshot snapshot) {
    final h = _handler;
    if (h == null) return;
    h.latest = snapshot;
    final now = DateTime.now();
    final changed = _pushed == null || !_pushed!.sameSurface(snapshot);
    if (!changed && now.difference(_lastPush) < _minPushGap) return;
    _pushed = snapshot;
    _lastPush = now;
    h.apply(snapshot);
  }

  @override
  void clear(Object owner) {
    final current = _pushed;
    if (current != null && !identical(current.owner, owner)) return;
    _pushed = null;
    final h = _handler;
    if (h == null) return;
    h.latest = null;
    h.apply(null);
  }
}
