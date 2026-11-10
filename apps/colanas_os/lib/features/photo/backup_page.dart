/// 相册备份页入口。
///
/// 真实现依赖 `dart:io` / `photo_manager`（系统相册只在手机 / 桌面可用），
/// Web 构建不能编译这两个库，所以按平台条件导出：
/// 原生端 → `backup/backup_page_io.dart`，Web → `backup/backup_page_web.dart`。
library;

export 'backup/backup_page_web.dart'
    if (dart.library.io) 'backup/backup_page_io.dart';
