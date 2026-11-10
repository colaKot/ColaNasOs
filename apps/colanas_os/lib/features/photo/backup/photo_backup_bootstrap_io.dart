import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'cola_photo_backup_controller.dart';

/// 全局唯一的备份控制器（进程级，跟页面生命周期无关）。
final PhotoBackupController photoBackupController =
    PhotoBackupController.instance;

/// 「打开 App 就自动备份」：首次启动走 init 里的 autoStart，
/// 从后台切回前台走这个观察者（带 10 分钟节流，避免频繁切换时反复全量扫 id）。
class _BackupLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(photoBackupController.onAppResumed());
    }
  }
}

bool _observerInstalled = false;

/// 在 `runApp` 之后调用：初始化配置、恢复上次进度、挂登录/网络/前后台监听，
/// 并在开关为开时自动开始一轮**增量**备份。
///
/// 只在手机端启用：桌面没有系统相册，Web 走另一份空实现。
Future<void> startPhotoBackupService() async {
  if (!(Platform.isAndroid || Platform.isIOS)) return;
  if (!_observerInstalled) {
    _observerInstalled = true;
    WidgetsBinding.instance.addObserver(_BackupLifecycleObserver());
  }
  try {
    await photoBackupController.init();
  } catch (e) {
    // 增强项失败不能挡住 App 启动
    debugPrint('相册备份控制器初始化失败：$e');
  }
}
