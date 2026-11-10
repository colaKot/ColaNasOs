/// 下载能力：Web 与非 Web 实现不同，用条件导出分开。
///
/// 默认走 stub（Web），有 `dart:io` 时切到真下载。
library;

export 'download_stub.dart' if (dart.library.io) 'download_io.dart';
