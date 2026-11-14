import '../../compat/cola_api_controller.dart';
import '../../compat/cola_custom_colors.dart';
import '../../list/models/cola_list_models.dart';
import '../../shared/music_item_logic.dart';
import '../controller/cola_player_controller.dart';
import '../play_ctrl_fullscreen/parts/cola_stage_playlist_drawer.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart' show NasStyleContext;

import '../../compat/getx.dart';

import 'cola_disc_cover.dart';

/// 列表页底部常驻的小播放条：点任意区域进全屏，右侧按钮直接控制播放。
class ColaMusicFloatingBar extends StatelessWidget {
  final VoidCallback onOpenFullscreen;

  const ColaMusicFloatingBar({super.key, required this.onOpenFullscreen});

  MusicListItem? _activeItem(MusicPlayServiceController controller) {
    final index = controller.currentIndex.value;
    if (index < 0 || index >= controller.playlist.length) return null;
    return controller.playlist[index];
  }

  String _coverOf(MusicListItem item, {int size = 240}) {
    if (item.hasInnerCover != 1) return '';
    return musicCoverUrlOf(
      item,
      size: size,
      build: ApiController.instance.getMusicCoverUrl,
    );
  }

  Future<void> _showQueue(
    BuildContext context, {
    required bool compact,
  }) async {
    final controller = MusicPlayServiceController.instance;
    if (!controller.isReady.value || controller.playlist.isEmpty) return;

    if (compact) {
      await ColaMusicStageQueueSheet.showBottomSheet(
        coverUrlResolver: _coverOf,
        controller: controller,
        context: context,
      );
      return;
    }
    await ColaMusicStageQueueSheet.show(
      coverUrlResolver: _coverOf,
      controller: controller,
      context: context,
    );
  }

  Widget _buildTitle(
    ThemeData theme,
    MusicListItem item,
    MusicPlayServiceController controller,
  ) {
    final downloading =
        !kIsWeb &&
        controller.isDownloading.value &&
        controller.downloadingFileHash.value.trim() == item.fileHash.trim();
    final percent = downloading
        ? '${(controller.downloadProgress.value.clamp(0, 1) * 100).toStringAsFixed(0)}%'
        : '';
    final text = percent.isEmpty ? item.displayTitle : '$percent ${item.displayTitle}';

    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _buildSubtitle(ThemeData theme, MusicListItem item) {
    final artist = item.artist.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        artist.isEmpty ? '-' : artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  List<Widget> _buildControls(
    BuildContext context, {
    required MusicPlayServiceController controller,
    required bool compact,
    required bool playing,
  }) {
    return <Widget>[
      if (!compact)
        IconButton(
          tooltip: 'music_prev_track'.tr,
          onPressed: controller.playPrevious,
          icon: const Icon(Icons.skip_previous),
        ),
      IconButton(
        tooltip: playing ? 'pause'.tr : 'play'.tr,
        onPressed: playing ? controller.pause : controller.play,
        icon: Icon(
          playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
        ),
      ),
      if (!compact)
        IconButton(
          tooltip: 'music_next_track'.tr,
          onPressed: controller.playNext,
          icon: const Icon(Icons.skip_next),
        ),
      IconButton(
        tooltip: 'player_playlist'.tr,
        onPressed: () => _showQueue(context, compact: compact),
        icon: const Icon(Icons.queue_music_outlined),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final palette = theme.extension<CustomColors>();
        final barColor = (palette?.oprationBarBgColor ??
                context.nasStyle.panelColor)
            .withValues(alpha: 0.92);
        final compact = constraints.maxWidth < 750;

        return Obx(() {
          final controller = MusicPlayServiceController.instance;
          if (!controller.isReady.value || controller.playlist.isEmpty) {
            return const SizedBox.shrink();
          }
          final item = _activeItem(controller);
          if (item == null) return const SizedBox.shrink();

          final playing = controller.isPlaying.value;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpenFullscreen,
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              child: Container(
                height: compact ? 60 : 68,
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  border: Border.all(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
                  ),
                  boxShadow: [
                    BoxShadow(
                      offset: const Offset(0, 6),
                      blurRadius: 14,
                      color: Colors.black.withValues(alpha: 0.18),
                    ),
                  ],
                ),
                child: Row(
                  children: <Widget>[
                    MusicPlayDiscCover(
                      outerSize: compact ? 44 : 52,
                      innerSize: compact ? 30 : 36,
                      isPlaying: playing,
                      discAsset: controller.discAsset,
                      coverUrl: _coverOf(item, size: compact ? 220 : 320),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _buildTitle(theme, item, controller),
                          if (!compact) _buildSubtitle(theme, item),
                        ],
                      ),
                    ),
                    ..._buildControls(
                      context,
                      controller: controller,
                      compact: compact,
                      playing: playing,
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
