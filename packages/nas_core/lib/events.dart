import 'dart:async';

import 'api/api_error.dart';
import 'api/client.dart';

/// 一个事件的监听器（`topic` + 已解码的 `data`）。
typedef NasEventHandler = void Function(String topic, Map<String, dynamic> data);

/// 服务端事件增量拉取（蓝图 §56：扫描完成后让页面自动刷新）。
///
/// 为什么不用 SSE：
/// 传输层只有「整包响应」一种形态（`Transport.send`），桌面 / Web / 移动同一份实现；
/// 引流式读取就要给 `Transport` 加分叉实现，而媒体扫描本就是分钟级低频事件，
/// 4 秒的拉取延迟无感知。服务端只保留最近 256 条历史，每轮拿几十条，开销可忽略。
///
/// - 首次连接只对齐序号、**派发历史事件**：页面刚打开时不该被旧事件触发一轮重载。
/// - 失败按 2 倍退避、上限 60 s；任意一次成功即复位。
/// - 401/403 属于「权限本身不对」，直接停轮询（否则每轮都打一次 403）；下次登录会重新 `start()`。
class EventPoller {
  EventPoller(
    this._client, {
    this.interval = const Duration(seconds: 4),
  });

  final ApiClient _client;
  final Duration interval;

  final List<NasEventHandler> _handlers = [];
  Timer? _timer;
  int _seq = 0;
  int _failures = 0;
  bool _primed = false;
  bool _polling = false;
  bool _stopped = true;

  bool get running => _timer != null;

  /// 当前游标（上次拿到的 `nextSeq`），便于调试与测试
  int get cursor => _seq;

  void addListener(NasEventHandler handler) {
    if (!_handlers.contains(handler)) _handlers.add(handler);
  }

  void removeListener(NasEventHandler handler) {
    _handlers.remove(handler);
  }

  void start() {
    if (_timer != null) return;
    _stopped = false;
    _seq = 0;
    _primed = false;
    _failures = 0;
    _schedule(Duration.zero);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _handlers.clear();
  }

  void _schedule(Duration delay) {
    if (_stopped) return;
    _timer?.cancel();
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    if (_polling || _stopped) return;
    _polling = true;
    try {
      final res = await _client.eventsRecent(since: _seq, limit: 64);
      final rawItems = res['items'];
      final nextSeq = res['nextSeq'];
      if (!_primed) {
        // 首次只对齐游标：历史事件不派发，避免页面刚打开就立刻重载
        _primed = true;
        if (nextSeq is int) _seq = nextSeq;
        _failures = 0;
        _schedule(interval);
        return;
      }
      if (rawItems is List) {
        for (final raw in rawItems) {
          if (raw is! Map) continue;
          // 服务端已按 since 过滤；这里再挡一次，防止重试/并发导致的重复事件
          final seq = raw['seq'];
          if (seq is int && seq <= _seq) continue;
          final topic = raw['topic'];
          if (topic is! String) continue;
          final data = raw['data'];
          final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
          for (final handler in List<NasEventHandler>.of(_handlers)) {
            try {
              handler(topic, map);
            } catch (_) {
              /* 单个监听器异常不影响其他监听器 */
            }
          }
        }
      }
      if (nextSeq is int) _seq = nextSeq;
      _failures = 0;
      _schedule(interval);
    } catch (e) {
      if (e is ApiError && (e.isUnauthorized || e.isForbidden)) {
        // 权限本身不对：继续重试只会每轮打一次 403，直接停
        _stopped = true;
        _timer?.cancel();
        _timer = null;
        return;
      }
      _failures = (_failures + 1).clamp(0, 4);
      final backoff = interval * (1 << _failures);
      _schedule(backoff > const Duration(seconds: 60) ? const Duration(seconds: 60) : backoff);
    } finally {
      _polling = false;
    }
  }
}