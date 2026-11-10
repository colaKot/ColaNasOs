/// 媒体 URL 构造器。
///
/// 路径统一按 POSIX 分隔符编码，避免 Windows 反斜杠泄漏到 HTTP 层。
class MediaUrls {
  MediaUrls(this.baseUrl);

  final String baseUrl;

  String _clean(String p) {
    var s = p.replaceAll('\\', '/');
    if (!s.startsWith('/')) s = '/$s';
    return s;
  }

  /// 缩略图：服务端 `/api/v1/files/thumb?path=&size=`
  ///
  /// [at] 只对视频有意义：从第几秒抽帧当封面。相册里的视频首帧常是黑场，
  /// 网格里要指定位置才不至于一整片黑。
  String thumbnail(String path, {int size = 256, double? at}) {
    final base =
        '$baseUrl/api/v1/files/thumb?path=${Uri.encodeComponent(_clean(path))}&size=$size';
    if (at == null || at <= 0) return base;
    return '$base&at=${at.toStringAsFixed(2)}';
  }

  /// 原图 / 原文件下载（支持 Range，播放器直接用）
  String file(String path) => '$baseUrl/api/v1/files/download?path=${Uri.encodeComponent(_clean(path))}';

  /// 动态照片里那段视频（服务端支持 Range；非动态照片 404）
  String livePhoto(String photoId) =>
      '$baseUrl/api/v1/photo/live?id=${Uri.encodeComponent(photoId)}';

  /// 转码流（HLS 片段）
  String transcode(String path, {String preset = 'web720'}) =>
      '$baseUrl/api/v1/files/transcode?path=${Uri.encodeComponent(_clean(path))}&preset=$preset';
}