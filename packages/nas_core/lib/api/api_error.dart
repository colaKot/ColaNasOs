import 'transport.dart';

/// 服务端统一错误（对应 docs/03 契约 §9.2）。
///
/// 内核在 4xx/5xx 返回 `{ error, message, code, traceId, details? }`：
/// [code] 与 [error] 同值（保留 error 兼容旧客户端），[details] 是结构化上下文
/// （如 403 的 `{need, rule, path}`、409 的 `{limit}`），[traceId] 可用于对照内核日志。
class ApiError implements Exception {
  ApiError({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
    this.traceId,
  });

  final int statusCode;
  final String code;
  final String message;
  final Object? details;
  final String? traceId;

  factory ApiError.fromResponse(int statusCode, Object? payload) {
    if (payload is Map) {
      final code = (payload['code'] ?? payload['error'] ?? 'UNKNOWN').toString();
      final message = (payload['message'] ?? '').toString();
      return ApiError(
        statusCode: statusCode,
        code: code,
        message: message.isEmpty ? 'HTTP $statusCode' : message,
        details: payload['details'],
        traceId: payload['traceId']?.toString(),
      );
    }

    return ApiError(
      statusCode: statusCode,
      code: 'UNKNOWN',
      message: payload?.toString() ?? 'HTTP $statusCode',
    );
  }

  factory ApiError.from(ApiResponse res) =>
      ApiError.fromResponse(res.statusCode, _tryDecode(res));

  static Object? _tryDecode(ApiResponse res) {
    try {
      return res.json;
    } catch (_) {
      return res.body.isEmpty ? null : res.text;
    }
  }

  /// 鉴权失效（客户端应触发重新登录）。
  bool get isUnauthorized => statusCode == 401;

  /// 权限不足（不应重试）。
  bool get isForbidden => statusCode == 403;

  /// 可重试：服务端暂时性错误。
  bool get isRetryable => statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'ApiError($statusCode $code): $message';
}