import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'session.dart';

/// 远程挂载上传（SP3-07 二期）。
///
/// 后端 `POST /api/v1/mount/upload` 收 `application/x-colanas-upload` **原始流**，
/// 而生成的 `ApiClient.mountUpload` 只会发 JSON，所以这里直接用 http 分块写，
/// 顺带把进度回报给 UI（NAS 上大文件很常见）。
class MountUploader {
  MountUploader._();

  static Uri uploadUri({required String mountId, required String path, required int size}) {
    return Uri.parse('${ApiSession.instance.baseUrl}/api/v1/mount/upload').replace(
      queryParameters: {'id': mountId, 'path': path, 'size': '$size'},
    );
  }

  /// [onProgress] 参数为「已发送 / 总字节」，UI 可据此画进度条。
  static Future<void> upload({
    required String mountId,
    required String remotePath,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final token = ApiSession.instance.token;
    if (token == null) throw StateError('not signed in');

    final client = http.Client();
    try {
      final request = http.StreamedRequest(
        'POST',
        uploadUri(mountId: mountId, path: remotePath, size: bytes.length),
      );
      request.headers['authorization'] = 'Bearer $token';
      request.headers['content-type'] = 'application/x-colanas-upload';
      request.contentLength = bytes.length;

      final responseFuture = client.send(request);

      const chunkSize = 256 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = math.min(offset + chunkSize, bytes.length);
        request.sink.add(Uint8List.sublistView(bytes, offset, end));
        onProgress?.call(end, bytes.length);
        // 让出事件循环，保证进度条能刷新
        await Future<void>.delayed(Duration.zero);
      }
      await request.sink.close();

      final response = await responseFuture;
      final text = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}: $text');
      }
    } finally {
      client.close();
    }
  }
}

/// 远程路径拼接（纯函数，便于单测）：目录为空 → 文件名；去掉两侧多余斜杠。
String joinRemotePath(String dir, String name) {
  final d = dir.trim().replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
  final n = name.trim().replaceAll(RegExp(r'^/+'), '');
  if (n.isEmpty) return d;
  if (d.isEmpty) return n;
  return '$d/$n';
}