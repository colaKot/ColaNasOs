import 'package:web/web.dart' as web;

/// 条件导出给 UI 判断「能不能点开链接」：不能时改成显示可复制的 URL 文本。
bool get canOpenExternalLinks => true;

/// Web 端打开原文链接。只放行 http(s)，避免把服务端的脏数据当 javascript: 执行。
/// 返回 false 表示没打开（调用方应把链接显示成可复制文本）。
bool openExternalLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return false;
  try {
    web.window.open(url, '_blank', 'noopener,noreferrer');
    return true;
  } catch (_) {
    return false;
  }
}
