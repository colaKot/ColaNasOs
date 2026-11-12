import 'package:flutter/material.dart';

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
import '../play_ctrl_fullscreen/parts/cola_stage_playlist_drawer.dart';
import 'parts/cola_dock_center_area.dart';
import 'parts/cola_dock_left_area.dart';
import 'parts/cola_dock_volume_control.dart';

/// 挂在页面底部的播放条：左曲目、中进度、右工具区。
class ColaMusicDockBar extends StatefulWidget {
  const ColaMusicDockBar({super.key, this.onOpenFullscreen});

  final VoidCallback? onOpenFullscreen;

  @override
  State<ColaMusicDockBar> createState() => _ColaMusicDockBarState();
}

class _ColaMusicDockBarState extends State<ColaMusicDockBar> {
  bool _favoriteBusy = false;
  bool _seeking = false;
  double _seekPreviewMs = 0;

  MusicListItem? _activeTrack(MusicPlayServiceController player) {
    final slot = player.currentIndex.value;
    final queue = player.playlist;
    final inRange = slot >= 0 && slot < queue.length;
    return inRange ? queue[slot] : null;
  }

  /// 优先内封曲目路径，其次完整路径，最后拼接目录与文件名。
  String _playablePathOf(MusicListItem track) {
    if (track.isSeries) {
      final seriesEntry = track.firstFilePath.trim();
      if (seriesEntry.isNotEmpty) return seriesEntry;
    }
    final full = track.fullPath.trim();
    if (full.isNotEmpty) return full;
    final folder = track.path.trim();
    final name = track.filename.trim();
    if (folder.isNotEmpty && name.isNotEmpty) return '$folder/$name';
    return folder;
  }

  /// 只有存在内嵌封面时才向后端请求缩略图。
  String _coverUrlOf(MusicListItem track, {int size = 500}) {
    if (track.hasInnerCover != 1) return '';

    final String source;
    if (track.isSeries) {
      source = track.firstFilePath.trim();
    } else {
      final full = track.fullPath.trim();
      source = full.isNotEmpty ? full : _playablePathOf(track);
    }
    if (source.isEmpty) return '';

    return ApiController.instance.getMusicCoverUrl(
      filePath: source,
      size: size,
    );
  }

  Future<void> _toggleFavorite(
    MusicPlayServiceController player,
    MusicListItem track,
  ) async {
    if (_favoriteBusy) return;
    final trackId = track.id;
    if (trackId <= 0) return;
    final target = !track.isFavorite;

    setState(() {
      _favoriteBusy = true;
    });

    try {
      final favorites = MusicFavoriteApiService.instance;
      final accepted = target
          ? await favorites.addFavorite(trackId)
          : await favorites.removeFavorite(trackId);
      if (!accepted) {
        ToastUtil.show('operation_failed'.tr);
        return;
      }
      final slot = player.playlist.indexWhere((entry) => entry.id == trackId);
      if (slot < 0) return;
      player.playlist[slot] = player.playlist[slot].copyWith(
        isFavorite: target,
      );
      player.playlist.refresh();
    } finally {
      if (mounted) {
        setState(() {
          _favoriteBusy = false;
        });
      }
    }
  }

  Future<void> _appendToPlayList(MusicListItem track) async {
    final trackId = track.id;
    if (trackId <= 0) return;
    final dialogContext = Get.context;
    if (dialogContext == null) return;

    PlayListItem? target;
    try {
      target = await showDialog<PlayListItem>(
        context: dialogContext,
        barrierDismissible: true,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
            child: const PlayListListView(selectionMode: true),
          ),
        ),
      );
    } catch (_) {
      ToastUtil.show('operation_failed'.tr);
      return;
    }
    if (target == null) return;

    try {
      final reply = await PlayListApiService.instance.addIndexes(
        listId: target.id,
        indexIds: <int>[trackId],
      );
      final message = reply.success
          ? 'operation_success'.tr
          : (reply.message ?? 'operation_failed'.tr);
      ToastUtil.show(message);
    } catch (_) {
      ToastUtil.show('operation_failed'.tr);
    }
  }

  Future<void> _openNowPlaying(MusicPlayServiceController player) {
    final hostContext = Get.overlayContext ?? Get.context ?? context;
    if (DeviceUtils.isPhone(hostContext)) {
      return ColaMusicStageQueueSheet.showBottomSheet(
        context: hostContext,
        controller: player,
        coverUrlResolver: _coverUrlOf,
      );
    }
    return ColaMusicStageQueueSheet.show(
      context: hostContext,
      controller: player,
      coverUrlResolver: _coverUrlOf,
    );
  }

  /// 拖动进度条开始：进入拖动态并记录预览毫秒值。
  void _beginSeek(double milliseconds) {
    setState(() {
      _seeking = true;
      _seekPreviewMs = milliseconds;
    });
  }

  Future<void> _finishSeek(
    MusicPlayServiceController player,
    double milliseconds,
  ) async {
    setState(() {
      _seeking = false;
      _seekPreviewMs = milliseconds;
    });
    await player.seekTo(Duration(milliseconds: milliseconds.round()));
  }

  bool _isDownloading(MusicPlayServiceController player, MusicListItem track) {
    if (!player.isDownloading.value) return false;
    final activeHash = player.downloadingFileHash.value.trim();
    if (activeHash.isEmpty) return false;
    return activeHash == track.fileHash.trim();
  }

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayServiceController.instance;
    final palette = Theme.of(context);
    final customColors = palette.extension<CustomColors>();

    return Obx(() {
      if (!player.isReady.value || player.playlist.isEmpty) {
        return const SizedBox.shrink();
      }
      final track = _activeTrack(player);
      if (track == null) return const SizedBox.shrink();

      final playing = player.isPlaying.value;
      final loopMode = player.loopMode.value;
      final downloading = _isDownloading(player, track);
      final indexable = track.canShowIndexActions;

      return SafeArea(
        top: false,
        child: ClipRRect(
          child: Container(
            decoration: BoxDecoration(
              color: customColors!.leftTreeBgColor,
              border: Border(
                top: BorderSide(
                  color: palette.dividerColor.withValues(alpha: 0.55),
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
                      child: _buildTrackInfo(
                        player: player,
                        track: track,
                        playing: playing,
                        downloading: downloading,
                        indexable: indexable,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: _buildProgress(
                      player: player,
                      track: track,
                      playing: playing,
                      loopMode: loopMode,
                      indexable: indexable,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _buildTools(
                        player: player,
                        track: track,
                        loopMode: loopMode,
                        indexable: indexable,
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

  Widget _buildTrackInfo({
    required MusicPlayServiceController player,
    required MusicListItem track,
    required bool playing,
    required bool downloading,
    required bool indexable,
  }) {
    return ColaMusicDockInfo(
      item: track,
      isPlaying: playing,
      favoriteLoading: _favoriteBusy,
      downloading: downloading,
      downloadProgress: downloading ? player.downloadProgress.value : 0.0,
      coverUrl: _coverUrlOf(track),
      discAsset: player.discAsset,
      onToggleFavorite: indexable ? () => _toggleFavorite(player, track) : null,
      onOpenFullscreen: widget.onOpenFullscreen,
    );
  }

  Widget _buildProgress({
    required MusicPlayServiceController player,
    required MusicListItem track,
    required bool playing,
    required MusicLoopMode loopMode,
    required bool indexable,
  }) {
    return ColaMusicDockProgress(
      isPlaying: playing,
      loopMode: loopMode,
      loopIcon: loopMode.icon,
      onToggleLoopMode: () => player.setLoopMode(loopMode.next),
      showLoopButton: false,
      onPrev: player.playPrevious,
      onNext: player.playNext,
      onPlayPause: () {
        if (playing) {
          player.pause();
        } else {
          player.play();
        }
      },
      onAddToPlayList: indexable ? () => _appendToPlayList(track) : null,
      showAddToPlayListButton: false,
      position: player.position.value,
      duration: player.duration.value,
      buffered: player.buffered.value,
      dragging: _seeking,
      dragValueMs: _seekPreviewMs,
      onDragStart: _beginSeek,
      onDragUpdate: _beginSeek,
      onDragEnd: (milliseconds) => _finishSeek(player, milliseconds),
    );
  }

  Widget _buildTools({
    required MusicPlayServiceController player,
    required MusicListItem track,
    required MusicLoopMode loopMode,
    required bool indexable,
  }) {
    return ColaMusicDockVolume(
      volume: player.volume.value,
      onChanged: player.setVolume,
      onToggleMute: player.toggleMute,
      showInlineSlider: false,
      showLoopButton: true,
      loopIcon: loopMode.icon,
      loopTooltip: loopMode.i18nKey.tr,
      onToggleLoopMode: () => player.setLoopMode(loopMode.next),
      showPlayListButton: true,
      playListTooltip: 'add_to_play_list'.tr,
      onAddToPlayList: indexable ? () => _appendToPlayList(track) : null,
      showNowPlayingButton: true,
      nowPlayingTooltip: 'player_playlist'.tr,
      onShowNowPlaying: () => _openNowPlaying(player),
    );
  }
}
