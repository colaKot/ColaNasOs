/// 音频缓存统一入口。
///
/// 共享契约在 `cache_contracts.dart`；原生与 Web 实现各自导出同一套符号，
/// 按 `dart.library.io` 条件选择。调用方只需要 import 本文件。
library;

// 条件导出保持单行：格式化拆成两行后，归一化源码会残留一个孤立窗口。
// dart format off
export 'cola_audio_cache_stub.dart' if (dart.library.io) 'cola_audio_cache_io.dart';
// dart format on
