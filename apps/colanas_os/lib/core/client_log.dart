import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'session.dart';

/// 把前端异常 / 警告送回服务端日志（`设置 → 日志` 里统一呈现）。
///
/// 为什么需要：日志页读的是 `data/logs/kernel.log`，只有服务端视角。
/// 客户端抛的 `TimeoutException`、渲染异常、接口报错在里面一条痕迹都没有，
/// 用户报「删除报错」时后台日志一片安静，等于无法排查（2026-11-03 反馈）。
///
/// 约束（防止日志被客户端噪音冲爆）：
///   - 只报 error / warn；
///   - 同一条 `级别 + 消息 + 位置` 5 分钟内只报一次；
///   - 每分钟最多 30 条；
///   - 上报自身失败静默丢弃，绝不递归上报。
class ClientLogger {
  ClientLogger._();

  static final ClientLogger instance = ClientLogger._();

  static const Duration _dedupe = Duration(minutes: 5);
  static const int _maxPerMinute = 30;

  final Map<String, DateTime> _seen = <String, DateTime>{};
  final Queue<DateTime> _sent = Queue<DateTime>();
  bool _installed = false;

  /// 装全局钩子：Flutter 框架异常 + 未捕获的异步异常
  void install() {
    if (_installed) return;
    _installed = true;

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
  }

  void error(String message, {String? route, String? detail}) =>
      _send('error', message, route, detail);

  void warn(String message, {String? route, String? detail}) =>
      _send('warn', message, route, detail);

  void _send(String level, String message, String? route, String? detail) {
    final text = message.trim();
    if (text.isEmpty) return;
    // 没登录就发不出去，也别把队列撑满
    if (ApiSession.instance.token == null) return;

    final now = DateTime.now();
    final key = '$level|$text|${route ?? ''}';
    final last = _seen[key];
    if (last != null && now.difference(last) < _dedupe) return;
    _seen[key] = now;

    while (_sent.isNotEmpty && now.difference(_sent.first) > const Duration(minutes: 1)) {
      _sent.removeFirst();
    }
    if (_sent.length >= _maxPerMinute) return;
    _sent.add(now);

    unawaited(_post(level, text, route, detail));
  }

  Future<void> _post(String level, String message, String? route, String? detail) async {
    try {
      await ApiSession.instance.client.systemClientLog(
        body: <String, dynamic>{
          'level': level,
          'message': message.length > 1900 ? message.substring(0, 1900) : message,
          if (route != null && route.isNotEmpty) 'route': route,
          if (detail != null && detail.isNotEmpty)
            'detail': detail.length > 3500 ? detail.substring(0, 3500) : detail,
        },
      );
    } catch (_) {
      // 上报失败就算了：这条路径本身不能再产生日志，否则会无限递归
    }
  }
}
