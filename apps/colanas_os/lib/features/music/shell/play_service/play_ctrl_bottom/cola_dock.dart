import '../../compat/cola_custom_colors.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';

import '../../compat/cola_api_controller.dart';
import '../../compat/cola_device_utils.dart';
import '../../compat/host.dart';
import '../../favorite/service/cola_favorite_api_service.dart';
import '../../list/models/cola_list_models.dart';
import '../../playlist/service/cola_playlist_api_service.dart';
import '../../playlist/view/cola_playlist_view.dart';
import '../controller/cola_player_controller.dart';
import '../play_ctrl_fullscreen/parts/cola_stage_playlist_drawer.dart';
import 'parts/cola_dock_center_area.dart';
import 'parts/cola_dock_left_area.dart';
import 'parts/cola_dock_volume_control.dart';

class MusicPlayCtrlBottomBar extends StatefulWidget {
  final VoidCallback? onOpenFullscreen;

  const MusicPlayCtrlBottomBar({super.key, this.onOpenFullscreen});

  @override
  State<MusicPlayCtrlBottomBar> createState() => _MusicPlayCtrlBottomBarState();
}

class _MusicPlayCtrlBottomBarState extends State<MusicPlayCtrlBottomBar> {
  bool _dragging = false;
  double _dragValueMs = 0;
  bool _favoriteLoading = false;

  MusicListItem? _currentItem(MusicPlayServiceController controller) {
    final idx = controller.currentIndex.value;
    if (idx < 0 || idx >= controller.playlist.length) return null;
    return controller.playlist[idx];
  }

  String _resolvePlayablePath(MusicListItem item) {
    if (item.isSeries) {
      final localP = item.firstFilePath.trim();
      if (localP.isNotEmpty) return localP;
    }
    final localFull = item.fullPath.trim();
    if (localFull.isNotEmpty) return localFull;
    final localName = item.filename.trim();
    final base = item.path.trim();
    if (base.isNotEmpty && localName.isNotEmpty) return '$base/$localName';
    return base;
  }

  String _resolveCoverUrl(MusicListItem item, {int size = 500}) {
    if (item.hasInnerCover != 1) return '';
    final localCoverPath = item.isSeries
        ? item.firstFilePath.trim()
        : (item.fullPath.trim().isNotEmpty
              ? item.fullPath.trim()
              : _resolvePlayablePath(item));
    if (localCoverPath.isEmpty) return '';
    return ApiController.instance.getMusicCoverUrl(
      filePath: localCoverPath,
      size: size,
    );
  }

  MusicLoopMode _nextLoopMode(MusicLoopMode mode) {
    return switch (mode) {
      MusicLoopMode.sequence => MusicLoopMode.listLoop,
      MusicLoopMode.listLoop => MusicLoopMode.singleLoop,
      MusicLoopMode.singleLoop => MusicLoopMode.shuffle,
      MusicLoopMode.shuffle => MusicLoopMode.sequence,
    };
  }

  IconData _loopModeIcon(MusicLoopMode mode) {
    return switch (mode) {
      MusicLoopMode.sequence => Icons.format_list_numbered,
      MusicLoopMode.listLoop => Icons.repeat,
      MusicLoopMode.singleLoop => Icons.repeat_one,
      MusicLoopMode.shuffle => Icons.shuffle,
    };
  }

  Future<void> _toggleFavorite(
    MusicPlayServiceController controller,
    MusicListItem item,
  ) async {
    if (_favoriteLoading) return;
    final localId = item.id;
    if (localId <= 0) return;
    final localPrev = item.isFavorite;
    final localNext = !localPrev;

    setState(() {
      _favoriteLoading = true;
    });

    try {
      final ok = localNext
          ? await MusicFavoriteApiService.instance.addFavorite(localId)
          : await MusicFavoriteApiService.instance.removeFavorite(localId);
      if (!ok) {
        ToastUtil.show('operation_failed'.tr);
        return;
      }
      final idx = controller.playlist.indexWhere((e) => e.id == localId);
      if (idx >= 0) {
        controller.playlist[idx] = controller.playlist[idx].copyWith(
          isFavorite: localNext,
        );
        controller.playlist.refresh();
      }
    } finally {
      if (mounted) {
        setState(() {
          _favoriteLoading = false;
        });
      }
    }
  }

  Future<void> _addToPlayList(MusicListItem item) async {
    final localIndexId = item.id;
    if (localIndexId <= 0) return;
    final context = Get.context;
    if (context == null) return;
    try {
      final localList = await showDialog<PlayListItem>(
        context: context,
        builder: (_) {
          return Dialog(
            insetPadding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
              child: const PlayListListView(selectionMode: true),
            ),
          );
        },
        barrierDismissible: true,
      );
      if (localList == null) return;
      final localReply = await PlayListApiService.instance.addIndexes(
        listId: localList.id,
        indexIds: [localIndexId],
      );
      if (localReply.success) {
        ToastUtil.show('operation_success'.tr);
      } else {
        ToastUtil.show(localReply.message ?? 'operation_failed'.tr);
      }
    } catch (_) {
      ToastUtil.show('operation_failed'.tr);
    }
  }

  Future<void> _showNowPlayingDrawer(
    MusicPlayServiceController controller,
  ) async {
    final localCtx = Get.overlayContext ?? Get.context ?? context;
    final useBottomSheet = DeviceUtils.isPhone(localCtx);
    if (useBottomSheet) {
      await MusicPlayCtrlFullScreenPlaylistDrawer.showBottomSheet(
        coverUrlResolver: _resolveCoverUrl,
        controller: controller,
        context: localCtx,
      );
      return;
    }
    await MusicPlayCtrlFullScreenPlaylistDrawer.show(
      coverUrlResolver: _resolveCoverUrl,
      controller: controller,
      context: localCtx,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = MusicPlayServiceController.instance;
    final localTheme = Theme.of(context);

    return Obx(() {
      if (!controller.isReady.value) return const SizedBox.shrink();
      if (controller.playlist.isEmpty) return const SizedBox.shrink();
      final item = _currentItem(controller);
      if (item == null) return const SizedBox.shrink();

      final localPosition = controller.position.value;
      final isPlaying = controller.isPlaying.value;
      final localBuffered = controller.buffered.value;
      final localDuration = controller.duration.value;
      final localVolume = controller.volume.value;
      final loopMode = controller.loopMode.value;
      final localDiscAsset = controller.discAsset;
      final localLoopTip = switch (loopMode) {
        MusicLoopMode.sequence => 'music_loop_sequence'.tr,
        MusicLoopMode.listLoop => 'music_loop_list_loop'.tr,
        MusicLoopMode.singleLoop => 'music_loop_single_loop'.tr,
        MusicLoopMode.shuffle => 'music_loop_shuffle'.tr,
      };
      final localDownloading =
          controller.isDownloading.value &&
          controller.downloadingFileHash.value.trim().isNotEmpty &&
          controller.downloadingFileHash.value.trim() == item.fileHash.trim();
      final localDownloadProgress = localDownloading
          ? controller.downloadProgress.value
          : 0.0;
      final localCanIndexActions =
          item.id > 0 &&
          !item.isFromFile &&
          item.showType.trim().toLowerCase() != 'file_browser';

      final localExtendedPalette = Theme.of(context).extension<CustomColors>();
      final localBg = localExtendedPalette!.leftTreeBgColor;
      return SafeArea(
        top: false,
        child: ClipRRect(
          child: Container(
            decoration: BoxDecoration(
              color: localBg,
              border: Border(
                top: BorderSide(
                  color: localTheme.dividerColor.withValues(alpha: 0.55),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 3, 12, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: MusicPlayCtrlBottomLeftArea(
                        onToggleFavorite: localCanIndexActions
                            ? () => _toggleFavorite(controller, item)
                            : null,
                        onOpenFullscreen: widget.onOpenFullscreen,
                        item: item,
                        isPlaying: isPlaying,
                        favoriteLoading: _favoriteLoading,
                        downloadProgress: localDownloadProgress,
                        downloading: localDownloading,
                        discAsset: localDiscAsset,
                        coverUrl: _resolveCoverUrl(item, size: 500),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: MusicPlayCtrlBottomCenterArea(
                      showLoopButton: false,
                      showAddToPlayListButton: false,
                      position: localPosition,
                      onToggleLoopMode: () =>
                          controller.setLoopMode(_nextLoopMode(loopMode)),
                      onPrev: controller.playPrevious,
                      onPlayPause: () {
                        if (isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                      },
                      onNext: controller.playNext,
                      onDragUpdate: (v) {
                        setState(() {
                          _dragging = true;
                          _dragValueMs = v;
                        });
                      },
                      onDragStart: (v) {
                        setState(() {
                          _dragging = true;
                          _dragValueMs = v;
                        });
                      },
                      onDragEnd: (v) async {
                        setState(() {
                          _dragging = false;
                          _dragValueMs = v;
                        });
                        await controller.seekTo(
                          Duration(milliseconds: v.round()),
                        );
                      },
                      onAddToPlayList: localCanIndexActions
                          ? () => _addToPlayList(item)
                          : null,
                      loopMode: loopMode,
                      loopIcon: _loopModeIcon(loopMode),
                      isPlaying: isPlaying,
                      duration: localDuration,
                      dragValueMs: _dragValueMs,
                      dragging: _dragging,
                      buffered: localBuffered,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: MusicPlayCtrlBottomVolumeControl(
                        volume: localVolume,
                        showPlayListButton: true,
                        showNowPlayingButton: true,
                        showLoopButton: true,
                        showInlineSlider: false,
                        playListTooltip: 'add_to_play_list'.tr,
                        onToggleMute: controller.toggleMute,
                        onToggleLoopMode: () =>
                            controller.setLoopMode(_nextLoopMode(loopMode)),
                        onShowNowPlaying: () =>
                            _showNowPlayingDrawer(controller),
                        onChanged: controller.setVolume,
                        onAddToPlayList: localCanIndexActions
                            ? () => _addToPlayList(item)
                            : null,
                        nowPlayingTooltip: 'player_playlist'.tr,
                        loopTooltip: localLoopTip,
                        loopIcon: _loopModeIcon(loopMode),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
