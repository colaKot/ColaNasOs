// 只在 Web 条件导入分支里编译，dart:html 的弃用提示在这里没有替代价值。
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

/// Web 端：把 PNG 字节包成 blob，用临时 <a download> 触发下载。
Future<String?> saveAnnualReportPng(Uint8List bytes, String suggestedName) async {
  final blob = html.Blob(<Object>[bytes], 'image/png');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = suggestedName
    ..click();
  html.Url.revokeObjectUrl(url);
  return suggestedName;
}
