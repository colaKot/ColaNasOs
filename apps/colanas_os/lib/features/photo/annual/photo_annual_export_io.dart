import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

/// 弹保存框写 PNG；用户取消返回 null。
Future<String?> saveAnnualReportPng(Uint8List bytes, String suggestedName) async {
  final location = await getSaveLocation(suggestedName: suggestedName);
  if (location == null) return null;
  await File(location.path).writeAsBytes(bytes, flush: true);
  return location.path;
}
