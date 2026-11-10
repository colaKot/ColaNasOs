import '../../compat/cola_api_controller.dart';
import '../../compat/cola_custom_colors.dart';
import '../../list/models/cola_list_models.dart';
import '../controller/cola_player_controller.dart';
import '../play_ctrl_fullscreen/parts/cola_stage_playlist_drawer.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../compat/getx.dart';

import 'cola_disc_cover.dart';

class AppMusicPlayCtrlFloatingBar extends StatelessWidget {
  final VoidCallback onOpenFullscreen;

  const AppMusicPlayCtrlFloatingBar({
    super.key,
    required this.onOpenFullscreen,
  });

  MusicListItem? _currentItem(MusicPlayServiceController controller) {
    final localIdx = controller.currentIndex.value;
    if (localIdx < 0 || localIdx >= controller.playlist.length) return null;
    return controller.playlist[localIdx];
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

  String _resolveCoverUrl(MusicListItem item, {int size = 240}) {
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

  Future<void> _openPlaylistDrawer(
    BuildContext context, {
    required bool useBottomSheet,
  }) async {
    final controller = MusicPlayServiceController.instance;
    if (!controller.isReady.value) return;
    if (controller.playlist.isEmpty) return;
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

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);
    final localExtendedPalette = localTheme.extension<CustomColors>();
    final localBg =
        (localExtendedPalette?.oprationBarBgColor ??
                localTheme.colorScheme.surface)
            .withValues(alpha: 0.92);

    return LayoutBuilder(
      builder: (context, constraints) {
        final controller = MusicPlayServiceController.instance;
        final localIsCompact = constraints.maxWidth < 750;
        return Obx(() {
          if (!controller.isReady.value) return const SizedBox.shrink();
          if (controller.playlist.isEmpty) return const SizedBox.shrink();
          final item = _currentItem(controller);
          if (item == null) return const SizedBox.shrink();
          final localDiscAsset = controller.discAsset;
          final localCoverUrl = _resolveCoverUrl(
            item,
            size: localIsCompact ? 220 : 320,
          );
          final isPlaying = controller.isPlaying.value;
          final localDownloading =
              !kIsWeb &&
              controller.isDownloading.value &&
              controller.downloadingFileHash.value.trim().isNotEmpty &&
              controller.downloadingFileHash.value.trim() ==
                  item.fileHash.trim();
          final localProgressText = localDownloading
              ? '${(controller.downloadProgress.value.clamp(0, 1) * 100).toStringAsFixed(0)}%'
              : '';
          final localTitleText = localProgressText.isNotEmpty
              ? '$localProgressText ${item.displayTitle}'
              : item.displayTitle;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpenFullscreen,
              borderRadius: BorderRadius.all(Radius.circular(16)),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                height: localIsCompact ? 60 : 68,
                decoration: BoxDecoration(
                  color: localBg,
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                  border: Border.all(
                    color: localTheme.colorScheme.onSurface.withValues(
                      alpha: 0.10,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      offset: const Offset(0, 6),
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 14.0,
                    ),
                  ],
                ),
                child: Row(
                  children: <Widget>[
                    MusicPlayDiscCover(
                      outerSize: localIsCompact ? 44 : 52,
                      isPlaying: isPlaying,
                      innerSize: localIsCompact ? 30 : 36,
                      discAsset: localDiscAsset,
                      coverUrl: localCoverUrl,
                    ),
                    const SizedBox(width: 10.0),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            localTitleText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: localTheme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (!localIsCompact)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
                              child: Text(
                                item.artist.trim().isEmpty
                                    ? '-'
                                    : item.artist.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: localTheme.textTheme.bodySmall?.copyWith(
                                  color:
                                      localTheme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!localIsCompact)
                      IconButton(
                        tooltip: 'music_prev_track'.tr,
                        onPressed: controller.playPrevious,
                        icon: const Icon(Icons.skip_previous),
                      ),
                    IconButton(
                      tooltip: isPlaying ? 'pause'.tr : 'play'.tr,
                      onPressed: () {
                        if (isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                      },
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                      ),
                    ),
                    if (!localIsCompact)
                      IconButton(
                        tooltip: 'music_next_track'.tr,
                        onPressed: controller.playNext,
                        icon: const Icon(Icons.skip_next),
                      ),
                    IconButton(
                      tooltip: 'player_playlist'.tr,
                      onPressed: () => _openPlaylistDrawer(
                        context,
                        useBottomSheet: localIsCompact,
                      ),
                      icon: const Icon(Icons.queue_music_outlined),
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }
}
