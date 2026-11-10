import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../compat/getx.dart';
import '../../detail/controller/music_detail_router.dart';
import '../../list/service/cola_list_api_service.dart';
import '../../play_service/controller/cola_player_controller.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';

/// 音乐主页的壳层状态：左侧菜单、侧栏宽度、全屏播放器开关、曲目总数。
///
/// 播放器本身是全局单例，这里不持有音频状态，只在进出全屏时做一次进度守护。
class MusicMainController extends GetxController {
  final RxString currentPageKey = 'library.songs'.obs;
  final RxDouble leftWidth = 160.0.obs;
  final RxBool sidebarCollapsed = false.obs;
  final RxBool hidePlayerBar = false.obs;
  final RxBool showFullPlayer = false.obs;

  final RxBool isLibraryExpanded = true.obs;
  final RxBool isSettingsExpanded = true.obs;
  final RxBool isPlaylistsExpanded = true.obs;

  final RxInt songCount = 0.obs;

  final MusicListApiService _api = MusicListApiService.instance;

  @override
  void onInit() {
    super.onInit();
    unawaited(fetchLibraryCounts());
  }

  Future<void> fetchLibraryCounts() async {
    final reply = await _api.getLibraryCounts();
    final counts = reply.data;
    if (!reply.success || counts == null) return;
    songCount.value = counts.songs;
  }

  void selectPage(String key) {
    _dismissSubListOverlay();
    _dismissDetailPages();
    hidePlayerBar.value = false;
    showFullPlayer.value = false;
    currentPageKey.value = key;
  }

  /// 换二级菜单时关掉专辑 / 歌手三级页面。
  /// 推到微任务：调用点常常在别的页面的 build / 回调里，同步改 Rx 会撞 build。
  void _dismissDetailPages() {
    if (!Get.isRegistered<MusicDetailRouter>()) return;
    final router = Get.find<MusicDetailRouter>();
    if (!router.active) return;
    Future.microtask(router.closeAll);
  }

  void _dismissSubListOverlay() {
    if (!Get.isRegistered<MusicSubListOverlayController>()) return;
    Get.find<MusicSubListOverlayController>().close();
  }

  void openFullPlayer() {
    _guardPlaybackProgress('进入');
    showFullPlayer.value = true;
  }

  void closeFullPlayer() {
    _guardPlaybackProgress('退出');
    showFullPlayer.value = false;
  }

  /// 全屏切换只改一个 bool，播放器不重建；但部分平台的 media 元素会被重新
  /// 挂载并把进度抹回 0。这里记一份位置，350ms 后仅在「确实归零且仍在播放」
  /// 时 seek 回去，正常情况零副作用，并留一条日志便于定位。
  void _guardPlaybackProgress(String phase) {
    final player = MusicPlayServiceController.instance;
    final saved = player.position.value;
    if (saved.inSeconds < 3) return;
    Future<void>.delayed(
      const Duration(milliseconds: 350),
      () => unawaited(_restoreIfReset(player, saved, phase)),
    );
  }

  Future<void> _restoreIfReset(
    MusicPlayServiceController player,
    Duration saved,
    String phase,
  ) async {
    if (!player.isPlaying.value || player.position.value.inSeconds >= 3) return;
    debugPrint('[music] 全屏$phase后进度被重置，恢复到 ${saved.inSeconds}s');
    await player.seekTo(saved);
  }
}
