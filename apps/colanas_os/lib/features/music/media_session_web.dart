import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web 端把曲目信息写进浏览器 Media Session：
/// 系统媒体面板 / 媒体键能显示歌名并直接暂停、切歌，切到后台标签页也不中断。
void updateMediaSession({
  required String title,
  String? artist,
  String? album,
  required bool playing,
  required void Function() onPlay,
  required void Function() onPause,
  required void Function() onNext,
  required void Function() onPrevious,
}) {
  try {
    final session = web.window.navigator.mediaSession;
    session.metadata = web.MediaMetadata(
      web.MediaMetadataInit(
        title: title,
        artist: artist ?? '',
        album: album ?? '',
      ),
    );
    session.playbackState = playing ? 'playing' : 'paused';

    session.setActionHandler(
      'play',
      ((JSObject _) => onPlay()).toJS,
    );
    session.setActionHandler(
      'pause',
      ((JSObject _) => onPause()).toJS,
    );
    session.setActionHandler(
      'nexttrack',
      ((JSObject _) => onNext()).toJS,
    );
    session.setActionHandler(
      'previoustrack',
      ((JSObject _) => onPrevious()).toJS,
    );
  } catch (_) {
    // 极少数浏览器没有 Media Session：播放本身不受影响
  }
}

/// 锁屏 / 通知栏的进度条。浏览器不要求它才能后台播放，但没有它系统面板
/// 会把时长显示成 0，拖不动进度；Android 上也更容易保持音频会话。
void updateMediaSessionPosition({
  required Duration duration,
  required Duration position,
  double playbackRate = 1,
}) {
  final total = duration.inMilliseconds / 1000;
  if (total <= 0) return;
  try {
    web.window.navigator.mediaSession.setPositionState(
      web.MediaPositionState(
        duration: total,
        playbackRate: playbackRate,
        position: (position.inMilliseconds / 1000).clamp(0, total).toDouble(),
      ),
    );
  } catch (_) {
    // 浏览器不支持 positionState：不影响播放
  }
}
