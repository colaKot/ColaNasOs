import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 手机 / 桌面：备份数据落在 `<应用支持目录>/photo_backup/`。
bool get persistent => true;

Directory? _dir;

Future<Directory> _resolve() async {
  final cached = _dir;
  if (cached != null) return cached;
  final base = await getApplicationSupportDirectory();
  final dir = Directory(
    '${base.path}${Platform.pathSeparator}photo_backup',
  );
  await dir.create(recursive: true);
  _dir = dir;
  return dir;
}

Future<String?> readText(String name) async {
  try {
    final f = File('${(await _resolve()).path}${Platform.pathSeparator}$name');
    if (!await f.exists()) return null;
    return await f.readAsString();
  } catch (_) {
    return null;
  }
}

Future<void> writeText(String name, String content) async {
  try {
    final f = File('${(await _resolve()).path}${Platform.pathSeparator}$name');
    await f.writeAsString(content, flush: true);
  } catch (_) {
    // 磁盘满 / 权限问题：不阻塞备份主流程
  }
}

Future<void> appendLine(String name, String line) async {
  try {
    final f = File('${(await _resolve()).path}${Platform.pathSeparator}$name');
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 同上
  }
}
