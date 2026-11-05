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

/// 订阅「SMB 来源上线 / 掉线」（服务端 `video.smb.online`，只在状态**翻转**时发）。
///
/// 离线 SMB 库的内容被服务端过滤掉（列表 / 搜索 / 海报都看不到），探到在线后
/// 由这里触发一次刷新，用户不用手动点「探测」；掉线时同样刷一次，把内容收起来。
/// 做 300 ms 合并：一次心跳可能同时翻转多个来源（一个库连多台机器）。
void Function() listenSmbOnline(
  void Function() onChanged, {
  Duration throttle = const Duration(milliseconds: 300),
}) {
  final events = ApiSession.instance.events;
  Timer? timer;

  void handler(String topic, Map<String, dynamic> data) {
    if (topic != 'video.smb.online') return;
    timer?.cancel();
    timer = Timer(throttle, () {
      timer = null;
      onChanged();
    });
  }

  events.addListener(handler);
  return () {
    timer?.cancel();
    timer = null;
    events.removeListener(handler);
  };
}
