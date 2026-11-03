import 'dart:async';

import 'session.dart';

/// 订阅「某个域的扫描完成」事件（蓝图 §56：监控/轮询入库后页面自动刷新）。
///
/// 事件由服务端 `scan.done` 广播，`payload.domain` 区分 photo / video / music / book；
/// 同一轮大量目录扫描会产生多条事件，这里做 400 ms 合并，避免页面连续重载。
///
/// 返回的函数用于取消订阅（页面 `dispose` 时调用）。
void Function() listenScanDone(
  String domain,
  void Function() onDone, {
  Duration throttle = const Duration(milliseconds: 400),
}) {
  final events = ApiSession.instance.events;
  Timer? timer;

  void handler(String topic, Map<String, dynamic> data) {
    if (topic != 'scan.done') return;
    if ((data['domain'] ?? '') != domain) return;
    timer?.cancel();
    timer = Timer(throttle, () {
      timer = null;
      onDone();
    });
  }

  events.addListener(handler);
  return () {
    timer?.cancel();
    timer = null;
    events.removeListener(handler);
  };
}
