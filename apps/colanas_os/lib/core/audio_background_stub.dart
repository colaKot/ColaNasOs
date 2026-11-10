import 'audio_background.dart';

/// Web / 非 io 平台：播放由浏览器 Media Session 负责（见 `media_session_web.dart`）。
AudioBackground createAudioBackground() => NoopAudioBackground();
