import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web 的「全屏」= 浏览器 Fullscreen API。
///
/// 不沿用 `SystemChrome.setEnabledSystemUIMode`：它在 Web 上是空实现，
/// 用户点「全屏」页面纹丝不动，看起来像按钮坏了。这里直接对整个文档请求
/// 全屏，效果和视频网站一致（Esc 退出由浏览器负责）。
///
/// 顺带尝试锁朝向：`screen.orientation.lock` 只有在全屏状态下才被允许，
/// 桌面端基本都会抛，所以整体包在 try 里 —— 拿不到就算了，不能因为锁不了
/// 朝向把全屏也一起搞挂。
Future<void> enterPlayerFullscreen({
  required int videoWidth,
  required int videoHeight,
}) async {
  try {
    await web.document.documentElement?.requestFullscreen().toDart;
  } catch (_) {
    /* 用户拒绝 / 浏览器不允许（无手势）：保持原状 */
  }
  if (videoWidth <= 0 || videoHeight <= 0) return;
  try {
    await web.window.screen.orientation
        .lock(videoHeight > videoWidth ? 'portrait' : 'landscape')
        .toDart;
  } catch (_) {
    /* 桌面浏览器不支持朝向锁 */
  }
}

/// 退出全屏。
///
/// `document.fullscreenElement` 为 null 说明用户已经用 Esc 退掉了，
/// 这时再调 `exitFullscreen()` 会抛 InvalidStateError，所以先判断再调。
Future<void> exitPlayerFullscreen() async {
  try {
    if (web.document.fullscreenElement != null) {
      await web.document.exitFullscreen().toDart;
    }
  } catch (_) {
    /* 已经不在全屏 */
  }
  try {
    web.window.screen.orientation.unlock();
  } catch (_) {
    /* 没锁过朝向 */
  }
}
