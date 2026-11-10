/// 原生端下载：流式写到「应用文档目录 / ColaNasDownload /」。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cola_api_controller.dart';

/// 下载一个 NAS 上的文件。成功返回 true。
Future<bool> downloadRemoteFile(String remotePath) async {
  final base = ApiController.instance.baseUrl;
  final token = ApiController.instance.accessToken;
  if (base.trim().isEmpty) return false;

  final uri = Uri.parse('$base/api/v1/files/download')
      .replace(queryParameters: <String, String>{'path': remotePath});

  final docDir = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docDir.path, 'ColaNasDownload'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final segments = remotePath
      .replaceAll('\\', '/')
      .split('/')
      .where((e) => e.isNotEmpty)
      .toList();
  if (segments.isEmpty) return false;
  final target = File(p.join(dir.path, segments.last));

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..badCertificateCallback = (cert, host, port) => true;
  try {
    final req = await client.getUrl(uri);
    if (token != null && token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final resp = await req.close();
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      return false;
    }
    final sink = target.openWrite();
    try {
      await resp.pipe(sink);
    } finally {
      await sink.close();
    }
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Web 端才有意义；原生端给同一份 URL 便于复用
String downloadUrlFor(String remotePath) {
  final base = ApiController.instance.baseUrl;
  final token = ApiController.instance.accessToken;
  final q = <String>['path=${Uri.encodeQueryComponent(remotePath)}'];
  if (token != null && token.isNotEmpty) {
    q.add('token=${Uri.encodeQueryComponent(token)}');
  }
  return '$base/api/v1/files/download?${q.join('&')}';
}
