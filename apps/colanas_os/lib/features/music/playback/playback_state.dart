/// 播放状态的**唯一真相**。
///
/// 旧实现用 `_rebuildToken` / `_desiredPlaying` / `_isCompleted` /
/// `_suppressCompletedUntil` 等五个布尔量互相打补丁 —— 每个都是「怕某件事
/// 在错误的时机发生」。它们之所以必要，是因为状态本身是散的：
/// `isPlaying` 一个 Rx、`position` 一个 Rx、`_player` 可能为 null，
/// 任意组合都能拼出「其实不存在」的状态。
///
/// 这里把状态收敛成**互斥的几档**：任意时刻只有一个值，
/// 每个值自带它该有的数据，界面上不可能出现「在播放但没曲目」这种鬼状态。
library;

import 'track.dart';

sealed class PlayerState {
  const PlayerState();

  /// 当前是否有曲目（除 idle / failed 外都为 true）
  bool get hasTrack => switch (this) {
    PlaybackLoading() => true,
    PlaybackReady() => true,
    PlaybackPaused() => true,
    PlaybackCompleted() => true,
    _ => false,
  };

  /// 供界面直接读的曲目（没有就是 null，不用再判空两次）
  Track? get trackOrNull => switch (this) {
    PlaybackLoading(:final track) => track,
    PlaybackReady(:final track) => track,
    PlaybackPaused(:final track) => track,
    PlaybackCompleted(:final track) => track,
    _ => null,
  };

  bool get isBusy => this is PlaybackLoading;

  bool get isPlaying => this is PlaybackReady;
}

/// 什么都没放（首启、停止、队列被清空）
final class PlaybackIdle extends PlayerState {
  const PlaybackIdle();
}

/// 正在打开 / 缓冲中。此时已经有曲目，但还不能保证出声。
final class PlaybackLoading extends PlayerState {
  const PlaybackLoading(this.track, {this.position = Duration.zero});

  final Track track;

  /// 打开时继承来的位置（切码率 / 重建 URL 时要接着播，不能归零）
  final Duration position;
}

/// 正在播放
final class PlaybackReady extends PlayerState {
  const PlaybackReady({
    required this.track,
    required this.position,
    required this.duration,
    required this.buffered,
  });

  final Track track;
  final Duration position;
  final Duration duration;
  final Duration buffered;

  PlaybackReady copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffered,
  }) => PlaybackReady(
    track: track,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
  );
}

/// 暂停（**有别于 Idle**：暂停时曲目和进度都还在，界面要能继续显示）
final class PlaybackPaused extends PlayerState {
  const PlaybackPaused({
    required this.track,
    required this.position,
    required this.duration,
    required this.buffered,
  });

  final Track track;
  final Duration position;
  final Duration duration;
  final Duration buffered;
}

/// 当前这首自然播完。下一步该做什么由队列决定（下一首 / 重播 / 停在原地）。
final class PlaybackCompleted extends PlayerState {
  const PlaybackCompleted(this.track, {required this.duration});

  final Track track;
  final Duration duration;
}

/// 播放失败。`reason` 是给用户看的一句话，`detail` 是原文（排查用）。
///
/// 以前错误只存在一个可空的 `String? _error` 里，同时 `isPlaying` 还可能是
/// true —— 于是「报错了但进度条还在走」。现在失败是独立状态，互斥。
final class PlaybackFailed extends PlayerState {
  const PlaybackFailed(this.reason, {this.detail, this.track});

  final String reason;
  final String? detail;
  final Track? track;
}
