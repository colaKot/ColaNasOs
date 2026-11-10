/// 播放引擎：**只管一件事** —— 打开一个 URI，然后把变化以事件流吐出来。
///
/// 这是旧实现最缺的一层。以前「打开 / 重试 / 缓存 / 转码 / 状态同步」
/// 全纠缠在同一个 controller 的 extension 里（`playback.dart` 995 行），
/// 于是任何一处想改行为，都得先搞清楚另外四件事的影响。
///
/// 抽成接口后：
/// - 换实现（media_kit / just_audio / 原生）不影响业务；
/// - 业务层只订阅事件，不轮询；
/// - 单测可以塞一个假引擎，不碰真音频。
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'track.dart';

/// 引擎对外暴露的全部能力。刻意保持很小：**不认识的都别加**。
abstract interface class PlaybackEngine {
  /// 当前播放位置（引擎推送，不是轮询）
  Stream<Duration> get positionStream;

  /// 总时长。元数据就绪后才会有值。
  Stream<Duration> get durationStream;

  /// 已缓冲到哪儿（进度条第二段）
  Stream<Duration> get bufferedStream;

  /// 是否正在出声
  Stream<bool> get playingStream;

  /// 是否在缓冲（用于「转圈」而不是「播放失败」）
  Stream<bool> get bufferingStream;

  /// 一首播完（自然结束，不是被切走）
  Stream<void> get completedStream;

  /// 引擎级错误
  Stream<PlaybackError> get errorStream;

  /// 打开并（可选）开始播放。`startAt` 用于「重建 URL 时接着播」。
  Future<void> open(Uri uri, {Duration startAt = Duration.zero, bool autoPlay = true});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  /// 1.0 = 原速。引擎只负责「按这个倍率放」，业务校准系数在外面。
  Future<void> setRate(double rate);
  Future<void> setLoop(PlaybackLoop loop);

  /// 释放底层资源。调用后引擎不可再用。
  Future<void> dispose();
}

/// 引擎报上来的错误。
///
/// `benign` 用来区分「真的播不了」和「传输层抖了一下」：
/// mpv 在分片结束、keep-alive 断开时会报 `tcp: ffurl read returned 0` 这类，
/// 数据其实还在管道里。旧实现把这类和真错误混在一个 `String?` 里，
/// 只能靠字符串匹配去猜（`_isBenignPlaybackError`），猜漏了就糊一整层错误页。
class PlaybackError {
  const PlaybackError(this.message, {this.benign = false});

  final String message;
  final bool benign;

  /// mpv / libavformat 的传输层噪声判定。**只做兜底**：
  /// 真断开时引擎也会走到这里，所以上层仍应允许重试，别一律吞掉。
  static PlaybackError fromEngine(String message) {
    final text = message.toLowerCase();
    final transport =
        (text.contains('tcp:') ||
            text.contains('ffurl') ||
            text.contains('http:')) &&
        (text.contains('read returned') ||
            text.contains('eof') ||
            text.contains('connection reset'));
    return PlaybackError(message, benign: transport);
  }

  @override
  String toString() => 'PlaybackError($message${benign ? ', benign' : ''})';
}

/// 基于 media_kit 的唯一实现。
///
/// 为什么只留一条链路：旧实现按平台分叉（移动端 just_audio、桌面/web media_kit），
/// 两条链路对「seek 之后 position 怎么报」「完成事件何时发」的脾气不一样，
/// 于是上层不得不写一堆平台判断。同一套 media_kit 在 Android / iOS / Windows /
/// Linux / macOS / Web 都跑得起来（web 走 wasm），分叉的理由已经不存在。
class MediaKitPlaybackEngine implements PlaybackEngine {
  MediaKitPlaybackEngine({Player? player}) : _player = player ?? Player();

  final Player _player;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<Duration> get bufferedStream => _player.stream.buffer;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<void> get completedStream =>
      _player.stream.completed.where((done) => done).map((_) {});

  @override
  Stream<PlaybackError> get errorStream =>
      _player.stream.error.map(PlaybackError.fromEngine);

  @override
  Future<void> open(
    Uri uri, {
    Duration startAt = Duration.zero,
    bool autoPlay = true,
  }) async {
    await _player.open(Media(uri.toString()), play: autoPlay);
    // `open` 的 play 参数在部分平台上只保证「开始加载后播」，
    // 起播位置必须单独 seek，否则会从 0 开始（这正是「切码率回到开头」的成因）。
    if (startAt > Duration.zero) {
      await _player.seek(startAt);
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume.clamp(0.0, 1.0)) * 100);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setLoop(PlaybackLoop loop) async {
    // media_kit 的 PlaylistMode 只有 none / single / loop；
    // 「随机」不在这里实现 —— 那是队列的职责，引擎不该知道顺序。
    await _player.setPlaylistMode(switch (loop) {
      PlaybackLoop.none => PlaylistMode.none,
      PlaybackLoop.all => PlaylistMode.loop,
      PlaybackLoop.one => PlaylistMode.single,
    });
  }

  @override
  Future<void> dispose() => _player.dispose();
}
