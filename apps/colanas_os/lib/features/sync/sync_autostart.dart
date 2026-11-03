import 'sync_autostart_stub.dart'
    if (dart.library.io) 'sync_autostart_io.dart'
    if (dart.library.html) 'sync_autostart_web.dart';

/// 同步独立端的开机自启（登录时拉起，不是常驻系统服务）。
///
/// 只负责「随系统登录启动」，调度仍由 `SyncScheduler` 在应用内按间隔执行：
/// 做成系统服务需要管理员权限与自签服务宿主，收益与复杂度不匹配。
abstract class SyncAutoStart {
  /// 当前端是否支持写入自启项（Web 端不支持）
  bool get supported;

  /// 不支持时的 i18n 键（UI 用 tr(...) 展示）
  String get unsupportedReasonKey;

  /// 系统里是否已存在自启项（以操作系统状态为准，不另存一份设置）
  bool get enabled;

  /// 实际写入自启项的可执行文件路径（排障用）
  String get targetPath;

  /// 写入 / 移除自启项；返回操作后的实际状态
  Future<bool> setEnabled(bool value);
}

SyncAutoStart createSyncAutoStart() => createPlatformSyncAutoStart();
