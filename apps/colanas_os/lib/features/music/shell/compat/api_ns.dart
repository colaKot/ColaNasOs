/// 既有实现 `/api/music/*` → 本项目 `/api/v1/music/compat/*` 的唯一映射点。
///
/// 为什么只有「转发」而没有字段映射：30 多个字段的映射、cursor → page 的换算、
/// int id ↔ uuid 的互转，全部放在服务端 `src/modules/music/routes/compat.ts` 里。
/// 这样做的好处是改一次、跑个 `smoke:music-compat` 就能回归，不用重编客户端。
///
/// 这里只处理两件本地差异：
/// 1. `/api/music/detail/get` 在服务端叫 `/compat/detail`；
/// 2. `source/update/$id`、`source/relocate/$id` 在既有实现里是**路径参数**，
///    服务端统一收 body 里的 `id`。
///
/// **不要改搬运过来的 controller / view 源文件**，差异就该烂在这一层。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cola_api_controller.dart';

class CompatApi {
  const CompatApi._();

  /// 前缀：参考侧 `apiBaseUrl` 是 `/api`，这里补成内核的真实前缀
  static const String _compatPrefix = '/api/v1/music/compat';

  /// 参考侧路径里拼了 id 的三个端点（正则里只抓数字）
  static final RegExp _sourceIdPath = RegExp(
    r'^/api/music/source/(update|relocate)/(\d+)$',
  );

  static Future<dynamic> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final target = _targetOf(path, body: body, query: query);
    final base = ApiController.instance.baseUrl.trim();
    if (base.isEmpty) {
      throw StateError('尚未配置服务器地址');
    }
    final uri = Uri.parse('$base${target.path}')
        .replace(queryParameters: target.query.isEmpty ? null : target.query);

    final headers = <String, String>{
      'accept': 'application/json',
      if (target.body != null)
        'content-type': 'application/json; charset=utf-8',
      ..._authHeaders(),
    };

    final http.Response resp;
    if (method.toUpperCase() == 'GET') {
      resp = await http.get(uri, headers: headers);
    } else {
      resp = await http.post(
        uri,
        headers: headers,
        body: target.body == null ? null : jsonEncode(target.body),
      );
    }

    final text = resp.bodyBytes.isEmpty ? '' : utf8.decode(resp.bodyBytes);
    dynamic decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
    }
    if (resp.statusCode >= 400) {
      final msg = decoded is Map && decoded['message'] != null
          ? '${decoded['message']}'
          : 'HTTP ${resp.statusCode}';
      throw StateError(msg);
    }
    // 空响应（204 / 极少数只回状态码的口）给一个空对象，调用方统一按 Map 处理
    return decoded ?? <String, dynamic>{};
  }

  static Map<String, String> _authHeaders() {
    final token = ApiController.instance.accessToken?.trim() ?? '';
    return token.isEmpty
        ? const <String, String>{}
        : {'authorization': 'Bearer $token'};
  }

  /// 参考路径 → 服务端真实路径 + 真实 query + 真实 body
  static ({String path, Map<String, String> query, Map<String, dynamic>? body})
  _targetOf(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) {
    final q = <String, String>{...(query ?? const <String, String>{})};
    var payload = body == null ? null : Map<String, dynamic>.from(body);

    // 路径参数 → body.id
    final m = _sourceIdPath.firstMatch(path);
    if (m != null) {
      payload ??= <String, dynamic>{};
      payload['id'] = int.parse(m.group(2)!);
      return (
        path: '$_compatPrefix/source/${m.group(1)}',
        query: q,
        body: payload,
      );
    }

    // 只是名字不同
    if (path == '/api/music/detail/get') {
      return (path: '$_compatPrefix/detail', query: q, body: payload);
    }

    final rest = path.startsWith('/api/music/')
        ? path.substring('/api/music/'.length)
        : path;
    return (path: '$_compatPrefix/$rest', query: q, body: payload);
  }
}
