/// 相册备份服务的启动入口。
///
/// 开关是**整机状态**：App 一启动就要把控制器挂到进程上，不能等用户点进备份页。
/// 以前控制器是页面的一个字段，页面 dispose 时连网络监听一起取消，切出去就停。
/// 原生端依赖 `dart:io` / `photo_manager`，Web 构建用空实现顶掉。
library;

export 'photo_backup_bootstrap_web.dart'
    if (dart.library.io) 'photo_backup_bootstrap_io.dart';
