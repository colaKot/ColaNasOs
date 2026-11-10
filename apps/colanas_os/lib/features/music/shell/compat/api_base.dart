/// 兼容基线 `core/api/base_api_service.dart` 在音乐模块里的等价实现。
///
/// 音乐模块的 service 层只用到 `apiPost`（全部 POST）+ `ApiResponse` 这几件事，
/// 所以这里只保留这套表面：请求交给 [CompatApi.send]，
/// 由它把 既有实现 的 `/api/music/*` 翻译成本项目的 `/api/v1/music/*`。
library;

import 'package:flutter/foundation.dart';

import 'api_ns.dart';

/// 统一的接口响应包装（字段与既有实现一致，调用点不用改）
class ApiResponse<T> {
  ApiResponse({
    required this.success,
    this.data,
    this.message,
    this.code,
    this.apiErrorKey,
    this.rawResponse,
  });

  final bool success;
  final T? data;
  final String? message;

  /// HTTP 状态码
  final int? code;

  /// 响应体里的业务错误键
  final String? apiErrorKey;

  final dynamic rawResponse;

  factory ApiResponse.success(
    T data, {
    String? message,
    int? code,
    dynamic rawResponse,
  }) => ApiResponse<T>(
    success: true,
    data: data,
    message: message,
    code: code,
    rawResponse: rawResponse,
  );

  factory ApiResponse.failure(
    String message, {
    int? code,
    String? apiErrorKey,
    dynamic rawResponse,
  }) => ApiResponse<T>(
    success: false,
    message: message,
    code: code,
    apiErrorKey: apiErrorKey,
    rawResponse: rawResponse,
  );
}

typedef DataParser<T> = T Function(Map<String, dynamic> json, int code);

/// 既有实现同名基类：音乐模块的 6 个 ApiService 都继承它
abstract class BaseApiService {
  /// 统一的 POST 出口。既有实现里所有音乐接口都是 POST。
  Future<ApiResponse<T>> apiPost<T>(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
    DataParser<T>? dataParser,
    bool showLoading = true,
    Duration? timeout,
  }) async {
    try {
      final raw = await CompatApi.send('POST', path, body: body);
      return ApiResponse<T>.success(
        _parse<T>(raw, dataParser),
        code: 200,
        rawResponse: raw,
      );
    } catch (e) {
      debugPrint('[shell-music] $path failed: $e');
      return ApiResponse<T>.failure('$e');
    }
  }

  Future<ApiResponse<T>> apiGet<T>(
    String path, {
    Map<String, String>? queryParams,
    DataParser<T>? dataParser,
    bool showLoading = true,
    Duration? timeout,
  }) async {
    try {
      final raw = await CompatApi.send('GET', path, query: queryParams);
      return ApiResponse<T>.success(
        _parse<T>(raw, dataParser),
        code: 200,
        rawResponse: raw,
      );
    } catch (e) {
      debugPrint('[shell-music] $path failed: $e');
      return ApiResponse<T>.failure('$e');
    }
  }

  T _parse<T>(dynamic raw, DataParser<T>? parser) {
    if (parser != null) {
      final map = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      return parser(map, 200);
    }
    if (raw is T) return raw;
    if (raw == null) return raw as T;
    // `apiPost<void>` / `apiPost<dynamic>` 这类只关心 `res.success` 的调用点：
    // 不强求形状，原样透出（强转成 void / dynamic 恒成立）。
    try {
      return raw as T;
    } catch (_) {
      throw StateError('unexpected response type ${raw.runtimeType} for $T');
    }
  }
}
