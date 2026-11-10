import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 通知栏桥（只在原生 Android 生效）。
///
/// 前台服务在 Kotlin 侧（`BackupForegroundService`），它只负责把进程保活并显示
/// 常驻通知；枚举相册、去重、分片上传全在 Dart 主 isolate 里跑，这里只把进度
/// 推过去。非 Android（Windows / macOS / iOS / Web 构建不会引用本文件）一律空转。
///
/// 之所以要前台服务：App 切后台 / 熄屏后只是普通进程，Android 会冻结甚至回收，
/// Dart 侧的上传循环一断，页面再进来就只能从头开始。
class PhotoBackupNotification {
  PhotoBackupNotification();

  static const MethodChannel _channel =
      MethodChannel('com.colanas.os/photo_backup');

  /// `dart:io` 只在原生端编译本文件（Web 走 backup_page_web.dart，不引用它）。
  bool get _supported => Platform.isAndroid;

  bool _active = false;
  String _lastKey = '';
  int _lastPushMs = 0;
  Timer? _finishTimer;

  /// 两次通知刷新至少间隔 800ms，且内容没变就不刷（通知栏一直重绘很费电）。
  static const int _minGapMs = 800;

  Future<bool> ensurePermission() async {
    if (!_supported) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'ensureNotificationPermission',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> start({
    required String title,
    required String text,
    required String channelName,
  }) async {
    _finishTimer?.cancel();
    _finishTimer = null;
    _active = true;
    _lastKey = '';
    _lastPushMs = 0;
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('start', <String, Object>{
        'title': title,
        'text': text,
        'channelName': channelName,
      });
    } catch (e) {
      debugPrint('相册备份前台服务启动失败：$e');
    }
  }

  void update({
    required String title,
    required String text,
    required int percent,
    required bool indeterminate,
  }) {
    if (!_supported || !_active) return;
    final key = '$title|$text|$percent|$indeterminate';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (key == _lastKey && now - _lastPushMs < _minGapMs) return;
    _lastKey = key;
    _lastPushMs = now;
    unawaited(_push('update', title, text, percent, indeterminate));
  }

  /// 一轮跑完：把通知刷成 100% + 完成文案，几秒后自动撤掉，别一直挂一条常驻通知。
  Future<void> finish({
    required String title,
    required String text,
  }) async {
    if (!_supported || !_active) return;
    _lastKey = '';
    _lastPushMs = 0;
    await _push('update', title, text, 100, false);
    _finishTimer?.cancel();
    _finishTimer = Timer(const Duration(seconds: 5), () {
      _finishTimer = null;
      unawaited(stop());
    });
  }

  Future<void> stop() async {
    _finishTimer?.cancel();
    _finishTimer = null;
    _active = false;
    _lastKey = '';
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('相册备份前台服务停止失败：$e');
    }
  }

  Future<void> _push(
    String method,
    String title,
    String text,
    int percent,
    bool indeterminate,
  ) async {
    try {
      await _channel.invokeMethod<void>(method, <String, Object>{
        'title': title,
        'text': text,
        'progress': indeterminate ? -1 : percent.clamp(0, 100),
        'max': 100,
      });
    } catch (e) {
      debugPrint('相册备份通知刷新失败：$e');
    }
  }
}

/// 进程级单例：通知栏归整机，不归某个页面。
final PhotoBackupNotification photoBackupNotification =
    PhotoBackupNotification();
