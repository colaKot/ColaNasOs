import 'package:flutter/foundation.dart';

import 'audio_background_stub.dart'
    if (dart.library.io) 'audio_background_io.dart' as impl;

/// 当前音源的一份快照。
///
/// 播放器每次状态变化推一份过来，Android 的前台服务据此画通知栏 / 锁屏面板；
/// 面板上按下的键再反过来调 [onPlay] / [onPause] … 转回播放器。
///
/// [owner] 是播放器实例本身（按 identity 比较）。音乐和播客各推各的，
/// 只有**持有音频焦点**的那一路能写面板 —— 暂停的那路不许把面板抢过去。
@immutable
class AudioSnapshot {
  const AudioSnapshot({
    required this.owner,
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onPlay,
    required this.onPause,
    required this.onNext,
    required this.onPrevious,
    required this.onSeek,
    required this.onStop,
  });

  final Object owner;
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final bool playing;
  final Duration position;
  final Duration duration;

  final void Function() onPlay;
  final void Function() onPause;
  final void Function() onNext;
  final void Function() onPrevious;
  final void Function(Duration to) onSeek;
  final void Function() onStop;

  /// 除进度外的「变了就得重画面板」部分。
  bool sameSurface(AudioSnapshot other) =>
      identical(owner, other.owner) &&
      id == other.id &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      playing == other.playing &&
      duration == other.duration;
}

/// 后台续播（Android 前台服务 + MediaSession）。
///
/// 为什么需要它（2026-11-06）：Web 端靠浏览器 Media Session 就能在切后台时
/// 保住播放，原生 Android 没有等价物 —— App 进后台后只是普通进程，
/// 熄屏 / 内存吃紧时会被系统冻结甚至回收，音频跟着断，通知栏也没有任何控制。
///
/// 桌面端不需要（窗口一直在），Web 端已有自己的实现（`media_session_web.dart`），
/// 两边都走空实现，行为与改动前一致。
abstract class AudioBackground {
  /// 拉起前台服务。失败不抛：后台续播是增强项，不能挡住启动。
  Future<void> ensureStarted({required String channelName});

  /// 推一份新快照（见 [AudioSnapshot.sameSurface] 的节流约定）。
  void update(AudioSnapshot snapshot);

  /// 某一路彻底停止 / 清队列：[owner] 不匹配时忽略，别把另一路的面板清掉。
  void clear(Object owner);
}

/// 空实现：Web / 桌面。
class NoopAudioBackground implements AudioBackground {
  @override
  Future<void> ensureStarted({required String channelName}) async {}

  @override
  void update(AudioSnapshot snapshot) {}

  @override
  void clear(Object owner) {}
}

/// 全局单例：前台服务是进程级的，跟页面无关。
final AudioBackground audioBackground = impl.createAudioBackground();
