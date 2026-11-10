/// 年度报告长图的落盘能力：桌面 / 移动端弹保存框，Web 触发下载。
///
/// 单独条件导入的原因和 `photo_download_*` 一样：`dart:io` 与 `dart:html`
/// 不能同时出现在一个能编译到所有平台的库里。
library;

export 'photo_annual_export_stub.dart'
    if (dart.library.io) 'photo_annual_export_io.dart'
    if (dart.library.html) 'photo_annual_export_web.dart';
