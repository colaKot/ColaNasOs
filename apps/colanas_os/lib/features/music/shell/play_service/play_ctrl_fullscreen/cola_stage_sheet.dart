import 'dart:ui';

import '../../compat/cola_custom_colors.dart';
import '../../compat/cola_device_utils.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';

import '../../compat/cola_api_controller.dart';
import '../../compat/host.dart';
import '../../compat/base_components.dart';
import '../../favorite/service/cola_favorite_api_service.dart';
import '../../list/models/cola_list_models.dart';
import '../../playlist/service/cola_playlist_api_service.dart';
import '../../playlist/view/cola_playlist_view.dart';
import '../controller/cola_player_controller.dart';
import 'parts/cola_stage_body.dart';
import 'parts/cola_stage_bottom_bar.dart';
import 'parts/cola_stage_file_properties_dialog.dart';
import 'parts/cola_stage_header.dart';
import 'parts/cola_stage_playlist_drawer.dart';

class MusicPlayCtrlFullScreenSheet extends StatefulWidget {
  final VoidCallback onClose;

  const MusicPlayCtrlFullScreenSheet({super.key, required this.onClose});

  @override
  State<MusicPlayCtrlFullScreenSheet> createState() =>
      _MusicPlayCtrlFullScreenSheetState();
}

class _MusicPlayCtrlFullScreenSheetState
    extends State<MusicPlayCtrlFullScreenSheet> {
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

  String _resolveCoverUrl(MusicListItem item, {int size = 800}) {
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

  Future<void> _addToPlayList(MusicListItem item) async {
    final localIndexId = item.id;
    if (localIndexId <= 0) return;
    final localCtx = Get.context ?? context;
    try {
      final localList = await showDialog<PlayListItem>(
        context: localCtx,
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

  Future<void> _showFileProperties(MusicListItem item) async {
    final localFilePath = _resolvePlayablePath(item);
    await MusicPlayCtrlFullScreenFilePropertiesDialog.show(
      context: Get.overlayContext ?? context,
      filePath: localFilePath,
    );
  }

  Future<void> _showPlaylistDrawer(
    MusicPlayServiceController controller,
  ) async {
    final useBottomSheet = DeviceUtils.isPhone(context);
    if (useBottomSheet) {
      await MusicPlayCtrlFullScreenPlaylistDrawer.showBottomSheet(
        coverUrlResolver: _resolveCoverUrl,
        controller: controller,
        context: context,
      );
      return;
    }
    await MusicPlayCtrlFullScreenPlaylistDrawer.show(
      coverUrlResolver: _resolveCoverUrl,
      controller: controller,
      context: context,
    );
  }

  void _nextDiscStyle(MusicPlayServiceController controller) {
    controller.nextDiscStyle();
  }

  @override
  Widget build(BuildContext context) {
    final localIsNarrow = DeviceUtils.isMobile;
    final controller = MusicPlayServiceController.instance;

    return Obx(() {
      final item = _currentItem(controller);
      if (!controller.isReady.value || item == null) {
        return const SizedBox.shrink();
      }

      final localDiscAsset = controller.discAsset;
      final localCoverUrl = _resolveCoverUrl(item, size: 1200);
      final localPosition = controller.position.value;
      final isPlaying = controller.isPlaying.value;
      final localBuffered = controller.buffered.value;
      final localDuration = controller.duration.value;
      final localVolume = controller.volume.value;
      final localLoopMode = controller.loopMode.value;
      final localMusicPath = _resolvePlayablePath(item);
      final localLyrics = controller.currentLyrics.value;

      final localBottomCoverUrl = _resolveCoverUrl(item, size: 500);
      final localCanIndexActions =
          item.id > 0 &&
          !item.isFromFile &&
          item.showType.trim().toLowerCase() != 'file_browser';
      final localBgImage = localCoverUrl.trim().isEmpty
          ? Image.asset(
              'assets/music/icons/default_cover.jpg',
              fit: BoxFit.cover,
            )
          : CustomExtendedImage(
              width: double.infinity,
              showLoading: false,
              imageUrl: localCoverUrl,
              height: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Image.asset(
                'assets/music/icons/default_cover.jpg',
                fit: BoxFit.cover,
              ),
              borderRadius: 0,
            );
      final localExtendedPalette = Theme.of(context).extension<CustomColors>();
      return PopScope(
        onPopInvoked: (didPop) {
          if (didPop) return;
          widget.onClose();
        },
        canPop: false,
        child: Material(
          color: localExtendedPalette?.leftTreeBgColor,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Opacity(
                  opacity: 0.2,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                    child: localBgImage,
                  ),
                ),
              ),
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.15)),
              ),
              Column(
                children: <Widget>[
                  MusicPlayCtrlFullScreenHeader(
                    topPadding: localIsNarrow ? 12 : 40,
                    onClose: widget.onClose,
                    height: localIsNarrow ? 60 : 96,
                  ),
                  Expanded(
                    child: MusicPlayCtrlFullScreenBody(
                      isPlaying: isPlaying,
                      coverUrl: localCoverUrl,
                      discAsset: localDiscAsset,
                      musicPath: localMusicPath,
                      trackDuration: localDuration,
                      onToggleFavorite:
                          localCanIndexActions && !_favoriteLoading
                          ? () => _toggleFavorite(controller, item)
                          : null,
                      favoriteLoading: _favoriteLoading,
                      isFavorite: item.isFavorite,
                      onNextDiscStyle: () => _nextDiscStyle(controller),
                      onShowProperties: () => _showFileProperties(item),
                      onShowPlaylist: () => _showPlaylistDrawer(controller),
                      title: item.displayTitle,
                      album: item.album.trim(),
                      artist: item.artist.trim(),
                      lyrics: localLyrics,
                      position: localPosition,
                      onSeekTo: controller.seekTo,
                    ),
                  ),
                  MusicPlayCtrlFullScreenBottomBar(
                    controller: controller,
                    item: item,
                    isPlaying: isPlaying,
                    discAsset: localDiscAsset,
                    position: localPosition,
                    duration: localDuration,
                    buffered: localBuffered,
                    loopIcon: _loopModeIcon(localLoopMode),
                    loopMode: localLoopMode,
                    volume: localVolume,
                    favoriteLoading: _favoriteLoading,
                    coverUrl: localBottomCoverUrl,
                    onToggleFavorite: localCanIndexActions
                        ? () => _toggleFavorite(controller, item)
                        : null,
                    onToggleLoopMode: () =>
                        controller.setLoopMode(_nextLoopMode(localLoopMode)),
                    onPrev: controller.playPrevious,
                    onNext: controller.playNext,
                    onPlayPause: () {
                      if (isPlaying) {
                        controller.pause();
                      } else {
                        controller.play();
                      }
                    },
                    onAddToPlayList: localCanIndexActions
                        ? () => _addToPlayList(item)
                        : null,
                    onVolumeChanged: controller.setVolume,
                    onSeekTo: controller.seekTo,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }
}
