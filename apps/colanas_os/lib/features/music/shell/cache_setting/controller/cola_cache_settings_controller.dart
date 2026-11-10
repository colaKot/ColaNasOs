import 'dart:async';

import '../../compat/getx.dart';
import '../../play_service/controller/cola_player_controller.dart';

/// 音频缓存设置页的状态。
///
/// 开关与上限本身存在播放服务里（全局单例），这个控制器只代理读写并维护
/// 「统计数字 / 正在清理」两类页面状态。两个耗时动作共用 [_exclusive] 防止
/// 连点造成重复请求，加载标志是否需要提前点亮由调用方决定。
class MusicCacheSettingsController extends GetxController {
  final RxBool loading = false.obs;
  final RxBool clearing = false.obs;

  final RxInt cachedCount = 0.obs;
  final RxInt cachedBytes = 0.obs;

  MusicPlayServiceController get _player => MusicPlayServiceController.instance;

  RxBool get enabled => _player.audioCacheEnabled;
  RxInt get maxItems => _player.audioCacheMaxItems;

  @override
  void onInit() {
    super.onInit();
    unawaited(refreshStats(showLoading: true));
  }

  Future<void> toggleEnabled(bool value) =>
      _applySetting(() => _player.setAudioCacheEnabled(value));

  Future<void> setMaxItems(int value) =>
      _applySetting(() => _player.setAudioCacheMaxItems(value));

  Future<void> _applySetting(Future<void> Function() change) async {
    await change();
    await refreshStats();
  }

  Future<void> refreshStats({bool showLoading = false}) =>
      _exclusive(loading, () async {
        final stats = await _player.getAudioCacheStats();
        cachedCount.value = stats.count;
        cachedBytes.value = stats.totalBytes;
      }, raiseOnStart: showLoading);

  Future<void> clearCache() => _exclusive(clearing, () async {
    await _player.clearAudioCache();
    await refreshStats();
  }, raiseOnStart: true);

  Future<void> _exclusive(
    RxBool gate,
    Future<void> Function() body, {
    required bool raiseOnStart,
  }) async {
    if (gate.value) return;
    if (raiseOnStart) gate.value = true;
    try {
      await body();
    } finally {
      gate.value = false;
    }
  }
}
