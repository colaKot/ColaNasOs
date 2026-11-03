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
