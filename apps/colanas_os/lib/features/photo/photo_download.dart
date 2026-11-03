// 相册单张下载：桌面端另存为，Web 端只提供「复制下载链接」。
//
// 条件导入的原因：`file_selector` 的保存对话框在 Web 上不可用，
// 而相册在 Web 端仍然要能拿到原图链接（右键另存/下载）。见 `photo_download_io.dart`。
export 'photo_download_stub.dart' if (dart.library.io) 'photo_download_io.dart';
