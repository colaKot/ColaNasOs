import '../../../compat/ui_kit.dart';

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/spinkit.dart';
import '../../../compat/getx.dart';
import '../../../compat/cola_api_controller.dart';
import '../../../compat/cola_app_routes.dart';
import '../../../compat/host.dart';
import '../../../compat/cola_device_utils.dart';
import '../../../compat/base_components.dart';
import '../../controller/cola_sub_list_controller.dart';
import '../../../list/models/cola_list_models.dart';
import '../../../list/view/parts/cola_item_context_menu.dart';
import '../../../play_service/controller/cola_player_controller.dart';

String _trackPath(MusicListItem item) {
  if (item.isSeries) {
    final seriesEntry = item.firstFilePath.trim();
    if (seriesEntry.isNotEmpty) return seriesEntry;
  }
  final full = item.fullPath.trim();
  if (full.isNotEmpty) return full;
  final base = item.path.trim();
  final name = item.filename.trim();
  if (base.isEmpty) return '';
  return name.isEmpty ? base : '$base/$name';
}

String _coverPath(MusicListItem item) {
  final full = item.fullPath.trim();
  if (full.isNotEmpty) return full;
  final base = item.path.trim();
  final name = item.filename.trim();
  return base.isNotEmpty && name.isNotEmpty ? '$base/$name' : '';
}

MusicListItem? _playingEntry(MusicPlayServiceController ctrl) {
  final index = ctrl.currentIndex.value;
  if (index < 0 || index >= ctrl.playlist.length) return null;
  return ctrl.playlist[index];
}

bool _isCurrentTrack(MusicPlayServiceController ctrl, MusicListItem item) {
  final playing = _playingEntry(ctrl);
  if (playing == null) return false;
  final now = _trackPath(playing);
  return now.isNotEmpty && now == _trackPath(item);
}

Widget _waveIndicator(double size, {Color? color}) => SpinKitWave(
  size: size,
  itemCount: 6,
  color: (color ?? Colors.white).withValues(alpha: 0.9),
);

void _openFolderFor(BuildContext context, MusicListItem item) {
  final full = item.fullPath.trim();
  final base = item.path.trim();
  final target = browseFolderPathMusic(full.isNotEmpty ? full : base);
  if (target.isEmpty) return;
  if (DeviceUtils.isDesktop && Get.isRegistered<PcHomeController>()) {
    PcHomeController.instance.openFolderAt(target);
    return;
  }
  AppRoutes.toFiles(initialPath: target);
}

String _khzText(int hz) {
  final value = hz / 1000;
  final text = value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '${text}khz';
}

String _audioTagText(MusicListItem item) {
  final parts = <String>[];
  final bitDepth = item.bitDepth ?? 0;
  final sampleRate = item.sampleRate ?? 0;
  final bitrate = item.bitrate ?? 0;
  if (bitDepth > 0) parts.add('${bitDepth}bit');
  if (sampleRate > 0) {
    parts.add(_khzText(sampleRate));
  } else if (bitrate > 0) {
    parts.add('${(bitrate / 1000).round()}kbps');
  }
  return parts.join('|');
}

class MusicSubListTable extends StatelessWidget {
  final MusicSubListController controller;
  final ScrollController scrollController;

  const MusicSubListTable({
    required this.scrollController,
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.items.isEmpty) {
        return const MusicEmptyState();
      }

      final playCtrl = Get.isRegistered<MusicPlayServiceController>()
          ? Get.find<MusicPlayServiceController>()
          : null;
      final playerBar =
          playCtrl != null &&
          playCtrl.isReady.value &&
          playCtrl.playlist.isNotEmpty;
      final playerSpace = playerBar
          ? (112.0 + MediaQuery.of(context).padding.bottom)
          : 0.0;

      final multi = controller.isMultiSelectMode.value;
      final compact = DeviceUtils.isMobile || DeviceUtils.isPhone(context);
      final tailSpace = (multi ? 66.0 : 20.0) + playerSpace;

      return Scrollbar(
        thumbVisibility: true,
        controller: scrollController,
        child: CustomScrollView(
          controller: scrollController,
          slivers: <Widget>[
            _buildRows(compact),
            SliverToBoxAdapter(
              child: KeyedSubtree(
                key: const ValueKey('music_sub_list_footer'),
                child: _PagingFooter(controller: controller),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: tailSpace)),
          ],
        ),
      );
    });
  }

  Widget _buildRows(bool compact) {
    return SliverFixedExtentList(
      itemExtent: 62,
      delegate: SliverChildBuilderDelegate((context, index) {
        final item = controller.items[index];
        if (compact) {
          return _TrackRowCompact(
            key: ValueKey('music_sub_row_mobile_${item.id}'),
            item: item,
            index: index,
            controller: controller,
          );
        }
        return _TrackRowDesktop(
          key: ValueKey('music_sub_row_${item.id}'),
          item: item,
          index: index,
          controller: controller,
        );
      }, childCount: controller.items.length),
    );
  }
}

class _TrackRowDesktop extends StatefulWidget {
  final MusicListItem item;
  final int index;
  final MusicSubListController controller;

  const _TrackRowDesktop({
    super.key,
    required this.item,
    required this.index,
    required this.controller,
  });

  @override
  State<_TrackRowDesktop> createState() => _TrackRowDesktopState();
}

class _TrackRowDesktopState extends State<_TrackRowDesktop> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final multi = widget.controller.isMultiSelectMode.value;
      final theme = Theme.of(context);
      final selected = widget.controller.selectedItems.contains(widget.item.id);
      final playCtrl = MusicPlayServiceController.instance;
      final current = _isCurrentTrack(playCtrl, widget.item);
      final playing = current && playCtrl.isPlaying.value;
      final titleStyle = theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
      );
      final activeTitleStyle = current
          ? (titleStyle ?? const TextStyle()).copyWith(
              color: theme.colorScheme.primary,
            )
          : titleStyle;
      final subStyle = theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
      );
      final tagStyle = theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
      );
      final tag = _audioTagText(widget.item);
      final subtitle = <String>[
        widget.item.artist.trim(),
        widget.item.album.trim(),
      ].where((value) => value.isNotEmpty).join(' · ');
      final entries = _buildEntries(context);
      final overlayColor = selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.colorScheme.onSurface.withValues(alpha: 0.03);

      final row = InkWell(
        onTap: () {
          if (multi) {
            widget.controller.toggleSelection(widget.item.id);
            return;
          }
          if (current) {
            playCtrl.isPlaying.value ? playCtrl.pause() : playCtrl.play();
            return;
          }
          widget.controller.playAt(widget.index);
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          height: 62,
          child: Stack(
            children: <Widget>[
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 26,
                    child: Center(
                      child: _buildLeading(
                        multi: multi,
                        selected: selected,
                        playing: playing,
                        subStyle: subStyle,
                        theme: theme,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _TrackCover(
                    filePath: _coverPath(widget.item),
                    hasInnerCover: widget.item.hasInnerCover,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildInfo(
                      activeTitleStyle: activeTitleStyle,
                      subStyle: subStyle,
                      tagStyle: tagStyle,
                      tag: tag,
                      subtitle: subtitle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildFavoriteButton(),
                  SizedBox(
                    width: 72,
                    child: Center(
                      child: Text(
                        FormatUtil.formatDurationSeconds(
                          widget.item.duration,
                          autoPadZero: true,
                        ),
                        style: subStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              if (multi)
                Positioned.fill(
                  child: IgnorePointer(child: Container(color: overlayColor)),
                ),
            ],
          ),
        ),
      );

      if (!DeviceUtils.isDesktop && !DeviceUtils.isWeb) return row;

      final hoverChild = MouseRegion(
        onEnter: (_) {
          if (widget.controller.isScrolling.value || _hovered) return;
          setState(() => _hovered = true);
        },
        onExit: (_) {
          if (!_hovered) return;
          setState(() => _hovered = false);
        },
        child: row,
      );

      if (entries.isEmpty) return hoverChild;
      return ContextMenuUtil.region(child: hoverChild, entries: entries);
    });
  }

  Widget _buildLeading({
    required bool multi,
    required bool selected,
    required bool playing,
    required TextStyle? subStyle,
    required ThemeData theme,
  }) {
    if (multi) {
      return CustomCheckbox(
        value: selected,
        onChanged: (_) => widget.controller.toggleSelection(widget.item.id),
        isCircle: false,
      );
    }
    if (_hovered) {
      return Icon(playing ? Icons.pause : Icons.play_arrow, size: 18);
    }
    if (playing) {
      return _waveIndicator(14, color: theme.colorScheme.primary);
    }
    return Text('${widget.index + 1}', style: subStyle);
  }

  Widget _buildInfo({
    required TextStyle? activeTitleStyle,
    required TextStyle? subStyle,
    required TextStyle? tagStyle,
    required String tag,
    required String subtitle,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.item.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: activeTitleStyle,
        ),
        if (tag.isNotEmpty || subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              if (tag.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.secondary
                          .withValues(alpha: 0.4),
                    ),
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                  child: Text(
                    tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tagStyle,
                  ),
                ),
              if (tag.isNotEmpty && subtitle.isNotEmpty)
                const SizedBox(width: 6),
              if (subtitle.isNotEmpty)
                Expanded(
                  child: Text(
                    subtitle,
                    style: subStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildFavoriteButton() {
    return IconButton(
      tooltip: widget.item.isFavorite ? 'unfavorite'.tr : 'favorites'.tr,
      onPressed: () => widget.controller.toggleFavorite(widget.item),
      icon: Icon(
        widget.item.isFavorite ? Icons.favorite : Icons.favorite_border,
        size: 20,
        color: widget.item.isFavorite ? Colors.red : null,
      ),
    );
  }

  List<ContextMenuEntry> _buildEntries(BuildContext context) {
    Future<void> systemCall(Future<ApiResult> Function(String p) call) async {
      final path = _coverPath(widget.item);
      if (path.isEmpty) return;
      final result = await call(path);
      if (!result.success) {
        ToastUtil.show(result.message ?? 'operation_failed'.tr);
      }
    }

    return MusicItemContextMenu.buildEntries(
      selectionMode: widget.controller.isMultiSelectMode.value,
      onToggleFavorite: () => widget.controller.toggleFavorite(widget.item),
      onShowInSystem: () =>
          systemCall((path) => FileApiService.instance.showInSystem(path)),
      onRemoveFromPlayList: () =>
          widget.controller.removeFromPlayListItem(widget.item),
      onOpenInSystem: () =>
          systemCall((path) => FileApiService.instance.openInSystem(path)),
      onFileBrowse: () => _openFolderFor(context, widget.item),
      onDownload: () => widget.controller.downloadItem(widget.item),
      onDelete: () => widget.controller.deleteItem(widget.item),
      onAddToPlayList: () => widget.controller.addToPlayListItem(widget.item),
      isSameMachine:
          DeviceUtils.isDesktopOrWeb && ApiController.instance.isSameMachine,
      isFavorite: widget.item.isFavorite,
      inPlayList: widget.controller.insidePlaylist,
    );
  }
}

class _TrackRowCompact extends StatefulWidget {
  final MusicListItem item;
  final int index;
  final MusicSubListController controller;

  const _TrackRowCompact({
    super.key,
    required this.item,
    required this.index,
    required this.controller,
  });

  @override
  State<_TrackRowCompact> createState() => _TrackRowCompactState();
}

class _TrackRowCompactState extends State<_TrackRowCompact> {
  void _activate() {
    if (widget.item.isSeries) {
      _enterSeries();
      return;
    }
    final playCtrl = MusicPlayServiceController.instance;
    if (_isCurrentTrack(playCtrl, widget.item)) {
      playCtrl.isPlaying.value ? playCtrl.pause() : playCtrl.play();
      return;
    }
    widget.controller.playAt(widget.index);
  }

  void _enterSeries() {
    final seriesId = widget.item.id;
    if (seriesId <= 0) return;
    final overlay = Get.isRegistered<MusicSubListOverlayController>()
        ? Get.find<MusicSubListOverlayController>()
        : Get.put(MusicSubListOverlayController());
    overlay.open(
      seriesIndexId: seriesId,
      name: widget.item.displayTitle,
      keyType: 'series',
    );
  }

  List<AppItemActionSheetEntry> _sheetEntries(BuildContext context) {
    if (widget.controller.isMultiSelectMode.value) {
      return const <AppItemActionSheetEntry>[];
    }
    return <AppItemActionSheetEntry>[
      AppItemActionSheetAction(
        onTap: _activate,
        title: 'open'.tr,
        icon: const Icon(Icons.open_in_new),
      ),
      AppItemActionSheetAction(
        onTap: () => _openFolderFor(context, widget.item),
        title: 'file_browse'.tr,
        icon: const Icon(Icons.folder_open_outlined),
      ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        onTap: () => widget.controller.toggleFavorite(widget.item),
        title: widget.item.isFavorite ? 'unfavorite'.tr : 'favorites'.tr,
        icon: Icon(
          widget.item.isFavorite ? Icons.favorite : Icons.favorite_border,
          color: widget.item.isFavorite ? Colors.red : null,
        ),
      ),
      AppItemActionSheetAction(
        onTap: () => widget.controller.downloadItem(widget.item),
        title: 'download'.tr,
        icon: const Icon(Icons.download_outlined),
      ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        onTap: () => widget.controller.addToPlayListItem(widget.item),
        title: 'add_to_play_list'.tr,
        icon: const Icon(Icons.playlist_add),
      ),
      if (widget.controller.insidePlaylist)
        AppItemActionSheetAction(
          onTap: () => widget.controller.removeFromPlayListItem(widget.item),
          title: 'remove_from_play_list'.tr,
          icon: const Icon(Icons.playlist_remove),
        ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        onTap: () => widget.controller.deleteItem(widget.item),
        title: 'delete'.tr,
        titleColor: Colors.red,
        icon: const Icon(Icons.delete_outline, color: Colors.red),
      ),
    ];
  }

  Future<void> _openSheet(BuildContext context) async {
    await AppItemActionSheet.show(
      context,
      headerLeading: _TrackCover(
        filePath: _coverPath(widget.item),
        hasInnerCover: widget.item.hasInnerCover,
        size: 52,
        radius: 10,
        requestSize: 180,
      ),
      headerTitle: widget.item.displayTitle,
      headerSubtitle: widget.item.displaySubtitle,
      entries: _sheetEntries(context),
    );
  }

  Widget _cover(bool playing, ThemeData theme) {
    final base = _TrackCover(
      filePath: _coverPath(widget.item),
      hasInnerCover: widget.item.hasInnerCover,
    );
    if (!playing) return base;
    return Stack(
      children: <Widget>[
        base,
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            child: Container(
              color: Colors.black.withValues(alpha: 0.25),
              child: Center(
                child: SpinKitWave(
                  size: 16,
                  itemCount: 6,
                  color: theme.colorScheme.primary.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final multi = widget.controller.isMultiSelectMode.value;
      final theme = Theme.of(context);
      final selected = widget.controller.selectedItems.contains(widget.item.id);
      final playCtrl = MusicPlayServiceController.instance;
      final current = _isCurrentTrack(playCtrl, widget.item);
      final playing = current && playCtrl.isPlaying.value;

      final titleStyle = theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
      );
      final activeTitleStyle = current
          ? (titleStyle ?? const TextStyle()).copyWith(
              color: theme.colorScheme.primary,
            )
          : titleStyle;
      final subStyle = theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
      );

      final row = InkWell(
        onTap: () {
          if (multi) {
            widget.controller.toggleSelection(widget.item.id);
            return;
          }
          _activate();
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(15, 0, 15, 0),
          height: 62,
          child: Row(
            children: <Widget>[
              if (multi) ...[
                CustomCheckbox(
                  value: selected,
                  onChanged: (_) =>
                      widget.controller.toggleSelection(widget.item.id),
                  isCircle: false,
                ),
                const SizedBox(width: 10),
              ],
              _cover(playing, theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.item.displayTitle,
                      style: activeTitleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.item.displaySubtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.item.displaySubtitle,
                        style: subStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: multi ? null : () => _openSheet(context),
                icon: const Icon(Icons.more_vert, size: 20),
              ),
            ],
          ),
        ),
      );

      if (!multi) return row;

      final overlayColor = selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.colorScheme.onSurface.withValues(alpha: 0.03);
      return Stack(
        children: <Widget>[
          row,
          Positioned.fill(
            child: IgnorePointer(child: Container(color: overlayColor)),
          ),
        ],
      );
    });
  }
}

class _TrackCover extends StatelessWidget {
  final String filePath;
  final int hasInnerCover;
  final double size;
  final double radius;
  final int requestSize;

  const _TrackCover({
    required this.filePath,
    this.hasInnerCover = 0,
    this.size = 46,
    this.radius = 8,
    this.requestSize = 120,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = (filePath.trim().isEmpty || hasInnerCover != 1)
        ? ''
        : ApiController.instance.getMusicCoverUrl(
            filePath: filePath,
            size: requestSize,
          );
    final fallback = ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      child: Container(
        width: size,
        height: size,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: Image.asset(
          'assets/music/musicCover/other${Random(filePath.hashCode).nextInt(20) + 1}.jpg',
          fit: BoxFit.cover,
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      child: CustomExtendedImage(
        width: size,
        showLoading: false,
        imageUrl: url,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback,
        borderRadius: 0,
      ),
    );
  }
}

class _PagingFooter extends StatelessWidget {
  final MusicSubListController controller;
  const _PagingFooter({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.loadingMore.value) {
        return const Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Center(child: CircularProgressIndicator()),
        );
      }

      if (!controller.hasMore.value) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 14, 0, 14),
          child: Center(child: Text('music_list_no_more'.tr)),
        );
      }

      if (!controller.autoLoadFailed.value) {
        return const SizedBox(height: 20);
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 14),
        child: Center(
          child: OutlinedButton(
            onPressed: () =>
                controller.loadMore(fromAuto: false).catchError((_) {}),
            child: Text('music_list_load_more'.tr),
          ),
        ),
      );
    });
  }
}
