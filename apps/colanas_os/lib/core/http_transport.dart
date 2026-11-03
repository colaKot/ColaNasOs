import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:nas_core/nas_core.dart';

/// 跨平台 HTTP 传输层：桌面 / 移动走 `IOClient`，Web（浏览器与 Electron 壳里
/// 加载的同一份 Flutter Web 产物）走 `BrowserClient`。
///
/// 为什么不用 `nas_core` 的 [IoTransport]：它基于 `dart:io`，在 Web 上一调用就抛
/// `Unsupported operation: Platform._version` —— 表现为登录页探测静默失败、
/// 「首次安装」永远不出现、登录按钮点了也没反应。
class HttpTransport implements Transport {
  HttpTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  final http.Client _client = http.Client();

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final request = http.Request(method, url);
    if (headers != null) request.headers.addAll(headers);
    if (body != null && body.isNotEmpty) request.bodyBytes = body;

    final response = await _client.send(request).timeout(timeout);
    final bytes = await response.stream.toBytes().timeout(timeout);
    return ApiResponse(
      statusCode: response.statusCode,
      body: bytes,
      headers: response.headers,
    );
  }

  @override
  void close() => _client.close();
}
