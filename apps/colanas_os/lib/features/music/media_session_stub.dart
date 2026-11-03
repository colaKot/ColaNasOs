/// 桌面 / 移动端没有浏览器 Media Session，播放由系统音频会话接管。
void updateMediaSession({
  required String title,
  String? artist,
  String? album,
  required bool playing,
  required void Function() onPlay,
  required void Function() onPause,
  required void Function() onNext,
  required void Function() onPrevious,
}) {}
