import 'dart:ui';

import 'package:flutter/material.dart';

import '../../compat/base_components.dart';
import '../../compat/cola_api_controller.dart';
import '../../compat/cola_custom_colors.dart';
import '../../compat/cola_device_utils.dart';
import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../favorite/service/cola_favorite_api_service.dart';
import '../../list/models/cola_list_models.dart';
import '../../playlist/service/cola_playlist_api_service.dart';
import '../../playlist/view/cola_playlist_view.dart';
import '../../shared/music_item_logic.dart';
import '../../shared/music_playback_logic.dart';
import '../controller/cola_player_controller.dart';
import 'parts/cola_stage_body.dart';
import 'parts/cola_stage_bottom_bar.dart';
import 'parts/cola_stage_file_properties_dialog.dart';
import 'parts/cola_stage_header.dart';
import 'parts/cola_stage_playlist_drawer.dart';

const String _kFallbackCover = 'assets/music/icons/default_cover.jpg';

/// 全屏播放舞台：封面虚化底 + 顶栏 + 中段（唱片/歌词）+ 底部控制。
class ColaMusicStageSheet extends StatefulWidget {
  const ColaMusicStageSheet({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<ColaMusicStageSheet> createState() => _ColaMusicStageState();
}

class _ColaMusicStageState extends State<ColaMusicStageSheet> {
  bool _favoriteBusy = false;

  MusicListItem? _trackAt(MusicPlayServiceController controller) {
    final index = controller.currentIndex.value;
    final queue = controller.playlist;
    if (index < 0 || index >= queue.length) return null;
    return queue[index];
  }

  /// 封面接口要的路径：整碟用首曲，单曲优先完整路径。
  String _coverFor(MusicListItem item, {int size = 800}) {
    if (item.hasInnerCover != 1) return '';
    return ApiController.instance.getMusicCoverUrl(
      filePath: item.coverFilePath,
      size: size,
    );
  }

  /// 播放 / 属性弹窗用的真实文件路径：整碟取首曲，单曲取完整路径。
  String _playablePath(MusicListItem item) {
    final resolved = item.playablePath;
    return resolved.isNotEmpty ? resolved : item.fullPath.trim();
  }

  Future<void> _pickTargetPlaylist(MusicListItem item) async {
    final indexId = item.id;
    if (indexId <= 0) return;
    final hostContext = Get.context ?? context;

    try {
      final target = await showDialog<PlayListItem>(
        context: hostContext,
        barrierDismissible: true,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
            child: const PlayListListView(selectionMode: true),
          ),
        ),
      );
      if (target == null) return;

      final reply = await PlayListApiService.instance.addIndexes(
        listId: target.id,
        indexIds: <int>[indexId],
      );
      if (reply.success) {
        ToastUtil.show('operation_success'.tr);
      } else {
        ToastUtil.show(reply.message ?? 'operation_failed'.tr);
      }
    } catch (_) {
      ToastUtil.show('operation_failed'.tr);
    }
  }

  Future<void> _toggleFavorite(
    MusicPlayServiceController controller,
    MusicListItem item,
  ) async {
    if (_favoriteBusy) return;
    final id = item.id;
    if (id <= 0) return;

    final wanted = !item.isFavorite;
    setState(() => _favoriteBusy = true);
    try {
      final ok = wanted
          ? await MusicFavoriteApiService.instance.addFavorite(id)
          : await MusicFavoriteApiService.instance.removeFavorite(id);
      if (!ok) {
        ToastUtil.show('operation_failed'.tr);
        return;
      }

      final queue = controller.playlist;
      final index = queue.indexWhere((e) => e.id == id);
      if (index < 0) return;
      queue[index] = queue[index].copyWith(isFavorite: wanted);
      queue.refresh();
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  Future<void> _openFileInfo(MusicListItem item) {
    return ColaMusicStageFileInfo.show(
      context: Get.overlayContext ?? context,
      filePath: _playablePath(item),
    );
  }

  Future<void> _openQueue(MusicPlayServiceController controller) async {
    final resolver = _coverFor;
    if (DeviceUtils.isPhone(context)) {
      await ColaMusicStageQueueSheet.showBottomSheet(
        coverUrlResolver: resolver,
        controller: controller,
        context: context,
      );
      return;
    }
    await ColaMusicStageQueueSheet.show(
      coverUrlResolver: resolver,
      controller: controller,
      context: context,
    );
  }

  Widget _coverBackdrop(String coverUrl) {
    final Widget picture = coverUrl.trim().isEmpty
        ? Image.asset(_kFallbackCover, fit: BoxFit.cover)
        : CustomExtendedImage(
            imageUrl: coverUrl,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            showLoading: false,
            borderRadius: 0,
            errorBuilder: (_, _, _) =>
                Image.asset(_kFallbackCover, fit: BoxFit.cover),
          );

    return Positioned.fill(
      child: Opacity(
        opacity: 0.2,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
          child: picture,
        ),
      ),
    );
  }

  Widget _content(
    MusicPlayServiceController controller,
    MusicListItem item,
    bool narrow,
  ) {
    final isPlaying = controller.isPlaying.value;
    final position = controller.position.value;
    final duration = controller.duration.value;
    final loopMode = controller.loopMode.value;
    final indexActions = item.canShowIndexActions;

    return Column(
      children: <Widget>[
        ColaMusicStageHeader(
          onClose: widget.onClose,
          height: narrow ? 60 : 96,
          topPadding: narrow ? 12 : 40,
        ),
        Expanded(
          child: ColaMusicStageBody(
            isPlaying: isPlaying,
            coverUrl: _coverFor(item, size: 1200),
            discAsset: controller.discAsset,
            musicPath: _playablePath(item),
            trackDuration: duration,
            onToggleFavorite: indexActions && !_favoriteBusy
                ? () => _toggleFavorite(controller, item)
                : null,
            favoriteLoading: _favoriteBusy,
            isFavorite: item.isFavorite,
            onNextDiscStyle: controller.nextDiscStyle,
            onShowProperties: () => _openFileInfo(item),
            onShowPlaylist: () => _openQueue(controller),
            title: item.displayTitle,
            album: item.album.trim(),
            artist: item.artist.trim(),
            lyrics: controller.currentLyrics.value,
            position: position,
            onSeekTo: controller.seekTo,
          ),
        ),
        ColaMusicStageControls(
          controller: controller,
          item: item,
          isPlaying: isPlaying,
          discAsset: controller.discAsset,
          position: position,
          duration: duration,
          buffered: controller.buffered.value,
          loopIcon: loopMode.icon,
          loopMode: loopMode,
          volume: controller.volume.value,
          favoriteLoading: _favoriteBusy,
          coverUrl: _coverFor(item, size: 500),
          onToggleFavorite: indexActions
              ? () => _toggleFavorite(controller, item)
              : null,
          onToggleLoopMode: () => controller.setLoopMode(loopMode.next),
          onPrev: controller.playPrevious,
          onNext: controller.playNext,
          onPlayPause: () => isPlaying ? controller.pause() : controller.play(),
          onAddToPlayList: indexActions
              ? () => _pickTargetPlaylist(item)
              : null,
          onVolumeChanged: controller.setVolume,
          onSeekTo: controller.seekTo,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = MusicPlayServiceController.instance;
    final narrow = DeviceUtils.isMobile;

    return Obx(() {
      final item = _trackAt(controller);
      if (!controller.isReady.value || item == null) {
        return const SizedBox.shrink();
      }

      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) widget.onClose();
        },
        child: Material(
          color: Theme.of(context).extension<CustomColors>()?.leftTreeBgColor,
          child: Stack(
            children: <Widget>[
              _coverBackdrop(_coverFor(item, size: 1200)),
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.15)),
              ),
              _content(controller, item, narrow),
            ],
          ),
        ),
      );
    });
  }
}
