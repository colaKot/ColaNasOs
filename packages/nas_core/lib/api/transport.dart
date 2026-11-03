import 'dart:convert';
import 'dart:io';

/// 一次 HTTP 往返的统一表示。
class ApiResponse {
  ApiResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;

  bool get isOk => statusCode >= 200 && statusCode < 300;

  String get text => utf8.decode(body, allowMalformed: true);

  /// 空响应体返回 null；非 JSON 时抛 [FormatException]。
  Object? get json => body.isEmpty ? null : jsonDecode(text);

  String? header(String name) => headers[name.toLowerCase()];
}

/// 传输层抽象：桌面/移动用 [IoTransport]，web 或测试可自行实现。
abstract class Transport {
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  });

  void close();
}


/// 在响应返回时回调（如统一的 401 处理）。
///
/// `client.dart` / `models.dart` 是 `npm run gen:client` 生成的，**不能手改**；
/// 需要拦截全局响应时用这层包装，而不是往 ApiClient 里加参数。
class CallbackTransport implements Transport {
  CallbackTransport(this.inner, {this.onResponse});

  final Transport inner;
  final void Function(ApiResponse response)? onResponse;

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final res = await inner.send(method, url, headers: headers, body: body);
    onResponse?.call(res);
    return res;
  }

  @override
  void close() => inner.close();
}

/// 基于 `dart:io` 的实现（Electron 桌面、Flutter 移动端通用）。
class IoTransport implements Transport {
  IoTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  final HttpClient _client = HttpClient();

  @override
  Future<ApiResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final request = await _client.openUrl(method, url).timeout(timeout);
    request.followRedirects = true;
    headers?.forEach((k, v) => request.headers.set(k, v));

    if (body != null && body.isNotEmpty) {
      request.headers.contentLength = body.length;
      request.add(body);
    }

    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }

    final responseHeaders = <String, String>{};
    response.headers.forEach((k, v) {
      responseHeaders[k.toLowerCase()] = v.join(',');
    });

    return ApiResponse(
      statusCode: response.statusCode,
      body: bytes,
      headers: responseHeaders,
    );
  }

  @override
  void close() => _client.close(force: true);
}