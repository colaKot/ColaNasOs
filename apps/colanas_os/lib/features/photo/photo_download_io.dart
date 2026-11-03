import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// 相册单张下载（桌面 / 移动端）：弹保存对话框 → 流式写入 → 落地再改名。
///
/// 为什么先写 `.part` 再 rename：下载中断会留下半张图，用户下次打开是坏的，
/// 而 rename 在同一分区是原子的，坏文件不会以"正经文件名"出现。
class PhotoDownload {
  PhotoDownload._();

  static bool get supported => true;

  /// 返回保存路径；用户取消返回 null。
  static Future<String?> save({
    required String url,
    required Map<String, String> headers,
    required String suggestedName,
  }) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return null;
    final target = File(location.path);
    final part = File('${location.path}.part');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final sink = part.openWrite();
      await res.pipe(sink);
      await sink.close();
      if (await part.length() == 0) {
        await part.delete();
        throw const HttpException('empty body');
      }
      await part.rename(target.path);
      return target.path;
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {
        /* 清临时文件失败不影响报错 */
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
