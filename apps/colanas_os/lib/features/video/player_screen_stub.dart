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

/// 退出全屏。
///
/// [portrait] = 要不要锁回竖屏，由调用方按「进播放器时的朝向」决定：
///   - 手机竖着进来 → 锁回竖屏。只「放开朝向」（`DeviceOrientation.values`）
///     是不够的：安卓在 `screenOrientation=unspecified` + 系统自动旋转关闭时
///     会**保持上一次的横屏不动**，用户看到的就是「退出影片以后一直横着」。
///   - 横着进来（TV / 平板横放）→ 放开朝向，别把 TV 的界面掰成竖的。
Future<void> exitPlayerFullscreen({bool portrait = true}) async {
  await SystemChrome.setPreferredOrientations(
    portrait
        ? const [DeviceOrientation.portraitUp]
        : DeviceOrientation.values,
  );
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}
