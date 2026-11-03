import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 桌面 / 移动的持久化后端：`<应用支持目录>/settings.json`。
bool get persistent => true;

File? _file;

Future<File> _resolve() async {
  final cached = _file;
  if (cached != null) return cached;
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}settings.json');
  _file = file;
  return file;
}

Future<String?> readAll() async {
  try {
    final file = await _resolve();
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (_) {
    // 首次运行 / 权限问题：按空设置启动
    return null;
  }
}

Future<void> writeAll(String json) async {
  try {
    final file = await _resolve();
    await file.parent.create(recursive: true);
    await file.writeAsString(json);
  } catch (_) {
    // 磁盘满 / 只读目录：丢掉这次写入，不阻塞界面
  }
}