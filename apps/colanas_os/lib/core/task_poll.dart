import 'dart:async';

import 'session.dart';

/// 长任务的统一轮询（扫描 / 索引 / 刮削都改成了「入队 + 轮询」）。
///
/// 为什么需要：这些接口原先在请求里同步跑完，全库扫描几分钟起，而 HTTP 传输层
/// 统一 30 秒超时 —— 用户看到「扫描失败」，服务端其实还在跑，于是再点一次。
/// 现在接口立即返回 `taskId`，进度靠 `GET /api/v1/tasks/{id}`。
///
/// 返回最终那一行（含 `state` / `error` / `progress`）；超时返回 null。
Future<Map<String, dynamic>?> waitTask(
  String taskId, {
  Duration interval = const Duration(milliseconds: 800),
  Duration timeout = const Duration(minutes: 30),
  void Function(int progress)? onProgress,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final Map<String, dynamic> t;
    try {
      t = await ApiSession.instance.client.tasksGet(id: taskId);
    } catch (_) {
      // 网络抖动不该让整个等待失败：等下一轮
      await Future<void>.delayed(interval);
      continue;
    }
    onProgress?.call((t['progress'] as num?)?.toInt() ?? 0);
    final state = '${t['state'] ?? ''}';
    if (state == 'done' || state == 'failed' || state == 'canceled') return t;
    await Future<void>.delayed(interval);
  }
  return null;
}
