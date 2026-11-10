/// `dio` 的最小等价层。
///
/// 搬运过来的 `cola_audio_cache_io.dart` 用 dio 做断点续传下载，用到的那一小撮
/// API 只有：`Dio.get` + `ResponseType.stream` + `ResponseBody.stream` +
/// `CancelToken` + `DioException`。本项目不引 dio（离线拉包会挂），所以这里按
/// **同名同语义**用 `dart:io` 的 HttpClient 实现一份，源文件只换 import 行。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum ResponseType { stream, json, bytes, plain }

enum DioExceptionType {
  cancel,
  badResponse,
  unknown,
  connectionError,
  connectionTimeout,
}

class RequestOptions {
  const RequestOptions({required this.url, this.headers});

  final String url;
  final Map<String, dynamic>? headers;
}

class Options {
  const Options({
    this.responseType = ResponseType.json,
    this.headers,
    this.validateStatus,
    this.receiveTimeout,
    this.sendTimeout,
  });

  final ResponseType responseType;
  final Map<String, dynamic>? headers;

  /// 返回 true 表示这个状态码不算错误
  final bool Function(int? status)? validateStatus;
  final Duration? receiveTimeout;
  final Duration? sendTimeout;
}

class Headers {
  const Headers(this.map);

  /// 键统一小写
  final Map<String, List<String>> map;
}

/// 流式响应体：`stream` 直接给 `sink.add(chunk)`
class ResponseBody {
  ResponseBody(this.stream);

  final Stream<List<int>> stream;
}

class Response<T> {
  const Response({
    this.data,
    this.statusCode,
    this.statusMessage,
    this.headers,
    this.requestOptions,
  });

  final T? data;
  final int? statusCode;
  final String? statusMessage;
  final Headers? headers;
  final RequestOptions? requestOptions;
}

class DioException implements Exception {
  DioException({
    this.message,
    this.type = DioExceptionType.unknown,
    this.response,
    this.requestOptions,
    this.error,
  });

  final String? message;
  final DioExceptionType type;
  final Response<dynamic>? response;
  final RequestOptions? requestOptions;
  final Object? error;

  @override
  String toString() => 'DioException($type): ${message ?? ''}';
}

class CancelToken {
  final Completer<Object?> _completer = Completer<Object?>();

  bool get isCancelled => _completer.isCompleted;

  void cancel([Object? reason]) {
    if (!_completer.isCompleted) _completer.complete(reason);
  }

  Future<Object?> get whenCancel => _completer.future;

  static bool isCancel(Object? error) =>
      error is DioException && error.type == DioExceptionType.cancel;
}

class Dio {
  Dio({HttpClient? httpClient})
    : _client =
          httpClient ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 30));

  final HttpClient _client;

  Future<Response<T>> get<T>(
    String url, {
    Options? options,
    CancelToken? cancelToken,
  }) async {
    final opts = options ?? const Options();
    final requestOptions = RequestOptions(url: url, headers: opts.headers);
    final uri = Uri.parse(url);

    if (cancelToken != null && cancelToken.isCancelled) {
      throw DioException(
        message: 'canceled',
        type: DioExceptionType.cancel,
        requestOptions: requestOptions,
      );
    }

    HttpClientRequest request;
    try {
      request = await _client.getUrl(uri);
    } catch (e) {
      throw DioException(
        message: '$e',
        type: DioExceptionType.connectionError,
        requestOptions: requestOptions,
        error: e,
      );
    }

    opts.headers?.forEach((k, v) {
      if (v == null) return;
      request.headers.set(k, '$v');
    });

    // 取消 → 直接中断底层连接
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) {
          try {
            request.abort();
          } catch (_) {}
        }),
      );
    }

    HttpClientResponse resp;
    try {
      resp = await request.close();
    } catch (e) {
      if (cancelToken != null && cancelToken.isCancelled) {
        throw DioException(
          message: 'canceled',
          type: DioExceptionType.cancel,
          requestOptions: requestOptions,
          error: e,
        );
      }
      throw DioException(
        message: '$e',
        type: DioExceptionType.connectionError,
        requestOptions: requestOptions,
        error: e,
      );
    }

    final headerMap = <String, List<String>>{};
    resp.headers.forEach((name, values) {
      headerMap[name.toLowerCase()] = values;
    });
    final headers = Headers(headerMap);
    final status = resp.statusCode;
    final ok = opts.validateStatus?.call(status) ?? (status < 400);

    final result = Response<T>(
      statusCode: status,
      statusMessage: resp.reasonPhrase,
      headers: headers,
      requestOptions: requestOptions,
    );

    if (!ok) {
      // 丢掉响应体，避免连接悬着
      try {
        await resp.drain<void>();
      } catch (_) {}
      throw DioException(
        message: 'bad response $status',
        type: DioExceptionType.badResponse,
        response: result,
        requestOptions: requestOptions,
      );
    }

    if (T == ResponseBody || opts.responseType == ResponseType.stream) {
      return Response<T>(
        data: ResponseBody(resp) as T,
        statusCode: status,
        statusMessage: resp.reasonPhrase,
        headers: headers,
        requestOptions: requestOptions,
      );
    }

    final bytes = await resp.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    Object? data;
    if (T == String) {
      data = utf8.decode(bytes, allowMalformed: true);
    } else {
      try {
        data = bytes.isEmpty
            ? null
            : jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } catch (_) {
        data = bytes;
      }
    }
    return Response<T>(
      data: data as T?,
      statusCode: status,
      statusMessage: resp.reasonPhrase,
      headers: headers,
      requestOptions: requestOptions,
    );
  }
}

/// 自签证书放行的 HttpClient（NAS 多为 https + 自签）。
/// 参考项目用 dio 的 badCertificateCallback，这里等价。
Dio createDioWithBadCertificateCompat() {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..badCertificateCallback = (cert, host, port) => true;
  return Dio(httpClient: client);
}
