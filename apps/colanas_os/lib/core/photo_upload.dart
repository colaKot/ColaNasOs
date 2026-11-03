import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'session.dart';

/// 相册网页上传（SP3-02 二期）。
///
/// 后端 `POST /api/v1/photo/upload` 收 `application/x-colanas-upload` 原始流，
/// 生成的 `ApiClient.photoUpload` 只会发 JSON，所以这里直接用 http。
/// 单张上限 64 MB（服务端限制），超过会 413。
class PhotoUploader {
  PhotoUploader._();

  static Uri uploadUri({
    required String libraryId,
    required String fileName,
    String? dir,
  }) {
    return Uri.parse('${ApiSession.instance.baseUrl}/api/v1/photo/upload').replace(
      queryParameters: {
        'libraryId': libraryId,
        'fileName': fileName,
        if (dir != null && dir.trim().isNotEmpty) 'dir': dir.trim(),
      },
    );
  }

  /// 成功返回服务端给的相对路径；失败抛异常（含 413）。
  static Future<String> upload({
    required String libraryId,
    required String fileName,
    required Uint8List bytes,
    String? dir,
  }) async {
    final token = ApiSession.instance.token;
    if (token == null) throw StateError('not signed in');

    final request = http.Request(
      'POST',
      uploadUri(libraryId: libraryId, fileName: fileName, dir: dir),
    );
    request.headers['authorization'] = 'Bearer $token';
    request.headers['content-type'] = 'application/x-colanas-upload';
    request.bodyBytes = bytes;

    final client = http.Client();
    try {
      final response = await client.send(request);
      final text = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}: $text');
      }
      if (text.isEmpty) return fileName;
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      return (decoded['path'] ?? fileName).toString();
    } finally {
      client.close();
    }
  }
}