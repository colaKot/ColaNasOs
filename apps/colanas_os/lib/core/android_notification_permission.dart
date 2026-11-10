import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 13+ 的 POST_NOTIFICATIONS 运行时权限。
///
/// 前台服务（audio_service）必须挂一条常驻通知才能保住进程；权限没给时，
/// 系统会在 App 切后台 / 熄屏后直接把服务掐掉 —— 表现就是「一听就断」。
/// 音乐播放链路早就申请了，**播客（BlogPlayer）以前没申请**，2026-11-10 补上。
///
/// 原生侧实现见 `MainActivity.ensureNotificationPermission`
/// （MethodChannel `com.colanas.os/photo_backup`，方法名是历史沿用）。
/// 非 Android / Web 一律返回 true，不弹权限框、不引第三方插件。
Future<bool> ensureAndroidNotificationPermission() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    return await const MethodChannel('com.colanas.os/photo_backup')
            .invokeMethod<bool>('ensureNotificationPermission') ??
        false;
  } catch (_) {
    return false;
  }
}
