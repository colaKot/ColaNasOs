import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'http_transport.dart';
import 'session.dart';

/// 把前端异常 / 警告 / 普通日志送回服务端（`设置 → 日志` 里统一呈现）。
///
/// 两种上报通道，但**两端都收 error / warn / info**：
/// - 连开发内核（API 端口 7888）：攒批上报到 `/api/v1/system/dev-log`；
/// - 装机版 / 正式服务端：单条上报到 `/api/v1/system/client-log`。
///  以前正式态直接丢掉 info，装机版的服务端日志里只剩零星几条错误，
///  排查「第一次播不了」「界面卡」时根本看不到客户端侧发生了什么。
///
/// 防止客户端噪音冲爆日志（2026-11-03 反馈后定的约束）：
///   - 同一条 `级别 + 消息 + 位置` 5 分钟内只报一次；
///   - 每分钟条数上限（dev 120 / 正式 60）；服务端还有 300/分钟的硬兜底；
///   - dev 内存队列封顶 200 条，满了丢最旧；
///   - 上报自身失败静默丢弃，绝不递归上报。
class ClientLogger {
  ClientLogger._();

  static final ClientLogger instance = ClientLogger._();

  static const Duration _dedupe = Duration(minutes: 5);
  static const int _maxPerMinuteNormal = 60;
  static const int _maxPerMinuteDev = 120;
  static const int _maxQueue = 200;
  static const int _batchSize = 20;
  static const Duration _flushEvery = Duration(seconds: 2);

  final Map<String, DateTime> _seen = <String, DateTime>{};
  final Queue<DateTime> _sent = Queue<DateTime>();
  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  final HttpTransport _transport = HttpTransport(
    timeout: const Duration(seconds: 8),
  );
  Timer? _timer;
  bool _flushing = false;
  bool _installed = false;
  String _app = 'full';

  String get _platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  /// 只认「API 地址端口是 7888」：Web 开发页是 5173，API 才是 7888
  ///（`dev.bat` 用 `--dart-define=COLANAS_API_BASE=...:7888` 固定）。
  bool get _dev {
    final base = ApiSession.instance.baseUrl;
    if (base.isEmpty) return false;
    return Uri.tryParse(base)?.port == 7888;
  }

  /// 装全局钩子：Flutter 框架异常 + 未捕获异步异常 + 全库 `debugPrint`。
  /// 四个端的 `main.dart` 都走 `runColanasApp()`，所以只在这一处装就全覆盖。
  void install({String app = 'full'}) {
    if (_installed) return;
    _installed = true;
    _app = app;

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      error(
        details.exceptionAsString(),
        route: details.library ?? 'flutter',
        detail: details.stack?.toString(),
      );
    };

    PlatformDispatcher.instance.onError = (e, stack) {
      error('$e', route: 'uncaught', detail: stack.toString());
      // 已上报并吞掉：再抛给框架只会多一条同样的记录
      return true;
    };

    // 全库 12 处 debugPrint 一次收编；不要碰 dart:core 的 print（会递归）。
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      previousDebugPrint(message, wrapWidth: wrapWidth);
      if (message != null && message.trim().isNotEmpty) {
        info(message, route: 'debugPrint');
      }
    };
  }

  void error(String message, {String? route, String? detail}) =>
      _send('error', message, route, detail);

  void warn(String message, {String? route, String? detail}) =>
      _send('warn', message, route, detail);

  void info(String message, {String? route, String? detail}) =>
      _send('info', message, route, detail);

  void _send(String level, String message, String? route, String? detail) {
    final text = message.trim();
    if (text.isEmpty) return;
    // 装机版同样收 info：播放链路的关键节点（建会话 / open / 状态变化）都是
    // info 级，只收 error 等于把这些线索全丢掉。频率由每分钟限额与去重控制。

    final now = DateTime.now();
    final key = '$level|$text|${route ?? ''}';
    final last = _seen[key];
    if (last != null && now.difference(last) < _dedupe) return;
    _seen[key] = now;
    if (_seen.length > 500) _seen.remove(_seen.keys.first);

    while (_sent.isNotEmpty &&
        now.difference(_sent.first) > const Duration(minutes: 1)) {
      _sent.removeFirst();
    }
    final limit = _dev ? _maxPerMinuteDev : _maxPerMinuteNormal;
    if (_sent.length >= limit) return;
    _sent.add(now);

    final entry = <String, dynamic>{
      'level': level,
      'message': text.length > 1900 ? text.substring(0, 1900) : text,
      'app': _app,
      'platform': _platform,
      'ts': now.millisecondsSinceEpoch,
      if (route != null && route.isNotEmpty)
        'route': route.length > 300 ? route.substring(0, 300) : route,
      if (detail != null && detail.isNotEmpty)
        'detail': detail.length > 3500 ? detail.substring(0, 3500) : detail,
    };

    if (_dev) {
      _enqueue(entry);
    } else {
      unawaited(_postSingle(entry));
    }
  }

  void _enqueue(Map<String, dynamic> entry) {
    if (_queue.length >= _maxQueue) _queue.removeAt(0);
    _queue.add(entry);
    if (_queue.length >= _batchSize) {
      unawaited(_flush());
      return;
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _timer ??= Timer(_flushEvery, () {
      _timer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (_flushing || _queue.isEmpty) return;
    // 未登录时先留着队列，登录后自然会补发；不在这里打日志，避免递归。
    if (ApiSession.instance.token == null) {
      _scheduleFlush();
      return;
    }
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final base = ApiSession.instance.baseUrl;
        if (base.isEmpty || !_dev) return;
        final batch = _queue.take(_batchSize).toList(growable: false);
        final res = await _transport.send(
          'POST',
          Uri.parse('$base/api/v1/system/dev-log'),
          headers: <String, String>{
            ...ApiSession.instance.authHeaders,
            'content-type': 'application/json',
          },
          body: utf8.encode(jsonEncode(<String, dynamic>{'entries': batch})),
        );
        if (res.statusCode >= 400) return; // 静默丢弃，别刷屏
        _queue.removeRange(
          0,
          batch.length > _queue.length ? _queue.length : batch.length,
        );
      }
    } catch (_) {
      // 上报失败就算了：这条路径本身不能再产生日志，否则会无限递归
    } finally {
      _flushing = false;
      if (_queue.isNotEmpty) _scheduleFlush();
    }
  }

  /// 非 dev：单条上报（契约里的 `systemClientLog`）。
  /// 把端标识拼进 route，服务端那行日志就能直接看出来自 PC / 安卓 / Web。
  Future<void> _postSingle(Map<String, dynamic> entry) async {
    try {
      final route = entry['route'] as String?;
      final src = '$_app/$_platform';
      await ApiSession.instance.client.systemClientLog(
        body: <String, dynamic>{
          'level': entry['level'],
          'message': entry['message'],
          'route': route == null || route.isEmpty
              ? src
              : '$src:$route',
          if (entry['detail'] != null) 'detail': entry['detail'],
        },
      );
    } catch (_) {
      // 上报失败静默丢弃，绝不递归
    }
  }
}
