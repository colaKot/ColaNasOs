import 'package:flutter/services.dart';

/// 进入播放器「全屏」：隐藏系统栏 + 按视频朝向锁屏幕方向。
///
/// 为什么要按**视频自身**的宽高比定朝向：竖屏片子（手机拍的、竖构图动画）
/// 进全屏后如果还是横屏，正片只剩中间一条、两边全是黑边。
/// 只切 `SystemUiMode` 不锁朝向是以前的做法，`_immersive` 一开画面反而更小。
///
/// 桌面端（Windows / macOS / Linux）没有朝向概念，`setPreferredOrientations`
/// 是空实现，调了也无害，所以不额外分叉。
Future<void> enterPlayerFullscreen({
  required int videoWidth,
  required int videoHeight,
}) async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  if (videoWidth <= 0 || videoHeight <= 0) return;
  await SystemChrome.setPreferredOrientations(
    videoHeight > videoWidth
        ? const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
        : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  );
}

/// 退出全屏：朝向放开成「跟随系统」，别把用户锁死在某一个方向里。
Future<void> exitPlayerFullscreen() async {
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}
