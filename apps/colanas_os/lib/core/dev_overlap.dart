import 'package:flutter/foundation.dart';

import 'session.dart';

/// 开发版重叠实例状态（仅开发态展示）。
///
/// 开发版内核启动时会探活另一个 ColaNasOs 实例；一旦命中，后台任务（扫描 / 刮削 /
/// AI / 定时任务 / sidecar）全部跳过，只保留界面与接口。这里把这个状态读到客户端，
/// 让开发者一眼看出「任务没跑是因为重叠守卫」，而不是以为功能坏了。
///
/// 正式版内核恒返回 `enabled: true`，因此本状态永远为 false，界面不出现任何提示。
class DevOverlapStatus {
  DevOverlapStatus._();

  /// true = 当前连接的内核处于「重叠模式」，后台任务已跳过
  static final ValueNotifier<bool> skipped = ValueNotifier<bool>(false);

  /// 命中的另一个实例端口（未知为 null）
  static final ValueNotifier<int?> peerPort = ValueNotifier<int?>(null);

  /// 查询一次 `/ready`；失败（未登录 / 老内核 / 网络）一律按「正常」处理。
  static Future<void> refresh() async {
    try {
      final ready = await ApiSession.instance.client.readyCheck();
      final background = ready['background'];
      if (background is! Map) {
        skipped.value = false;
        peerPort.value = null;
        return;
      }
      final enabled = background['enabled'];
      final peer = background['peer'];
      skipped.value = enabled == false;
      peerPort.value = peer is Map ? (peer['port'] as num?)?.toInt() : null;
    } catch (_) {
      // 未登录 / 内核未就绪：保持上一次结果，不弹错误
    }
  }

  static void reset() {
    skipped.value = false;
    peerPort.value = null;
  }
}
