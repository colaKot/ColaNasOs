/// Web 端占位：浏览器里没有稳定的"另存为"入口，界面改为「复制下载链接」。
/// 不做成"点了没反应的按钮"，而是如实告诉调用方不支持，由调用方换一种出口。
class PhotoDownload {
  PhotoDownload._();

  static bool get supported => false;

  static Future<String?> save({
    required String url,
    required Map<String, String> headers,
    required String suggestedName,
  }) async {
    throw UnsupportedError('web 端请复制下载链接');
  }
}
