import '../../../compat/ui_kit.dart';

import 'dart:math';

import 'package:flutter/material.dart';

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

      final localPlayCtrl = Get.isRegistered<MusicPlayServiceController>()
          ? Get.find<MusicPlayServiceController>()
          : null;
      final localShowPlayerBar =
          localPlayCtrl != null &&
          localPlayCtrl.isReady.value &&
          localPlayCtrl.playlist.isNotEmpty;
      final localPlayerExtraSpace = localShowPlayerBar
          ? (112.0 + MediaQuery.of(context).padding.bottom)
          : 0.0;

      final localShowMultiBar = controller.isMultiSelectMode.value;
      final isApp = DeviceUtils.isMobile || DeviceUtils.isPhone(context);
      final localBottomSpace =
          (localShowMultiBar ? 66.0 : 20.0) + localPlayerExtraSpace;
      return Scrollbar(
        thumbVisibility: true,
        controller: scrollController,
        child: CustomScrollView(
          controller: scrollController,
          slivers: <Widget>[
            SliverFixedExtentList(
              itemExtent: 62,
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = controller.items[index];
                if (isApp) {
                  return _MobileDataRow(
                    key: ValueKey('music_sub_row_mobile_${item.id}'),
                    item: item,
                    index: index,
                    controller: controller,
                  );
                }
                return _DataRow(
                  key: ValueKey('music_sub_row_${item.id}'),
                  item: item,
                  index: index,
                  controller: controller,
                );
              }, childCount: controller.items.length),
            ),
            SliverToBoxAdapter(
              child: KeyedSubtree(
                key: ValueKey('music_sub_list_footer'),
                child: _Footer(controller: controller),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: localBottomSpace)),
          ],
        ),
      );
    });
  }
}

class _DataRow extends StatefulWidget {
  final MusicListItem item;
  final int index;
  final MusicSubListController controller;

  const _DataRow({
    super.key,
    required this.item,
    required this.index,
    required this.controller,
  });

  @override
  State<_DataRow> createState() => _DataRowState();
}

class _DataRowState extends State<_DataRow> {
  bool _hovered = false;

  String _resolvePlayablePath(MusicListItem item) {
    if (item.isSeries) {
      final localP = item.firstFilePath.trim();
      if (localP.isNotEmpty) return localP;
    }
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return full;
    final localName = item.filename.trim();
    final base = item.path.trim();
    if (base.isNotEmpty && localName.isNotEmpty) return '$base/$localName';
    return base;
  }

  MusicListItem? _currentPlayingItem(MusicPlayServiceController controller) {
    final localIdx = controller.currentIndex.value;
    if (localIdx < 0 || localIdx >= controller.playlist.length) return null;
    return controller.playlist[localIdx];
  }

  Widget _buildWaveIndicator(double size, {Color? color}) {
    return SpinKitWave(
      size: size,
      itemCount: 6,
      color: (color ?? Colors.white).withValues(alpha: 0.9),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final selectionMode = widget.controller.isMultiSelectMode.value;
      final localTheme = Theme.of(context);
      final localPlayCtrl = MusicPlayServiceController.instance;
      final localSelected = widget.controller.selectedItems.contains(
        widget.item.id,
      );
      final localCurrentItem = _currentPlayingItem(localPlayCtrl);
      final localCurrentPath = localCurrentItem == null
          ? ''
          : _resolvePlayablePath(localCurrentItem);
      final localItemPath = _resolvePlayablePath(widget.item);
      final isCurrent =
          localCurrentPath.isNotEmpty && localCurrentPath == localItemPath;
      final localIsPlaying = isCurrent && localPlayCtrl.isPlaying.value;
      final localTitleStyle = localTheme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
      );
      final localEffectiveTitleStyle = isCurrent
          ? (localTitleStyle?.copyWith(color: localTheme.colorScheme.primary) ??
                TextStyle(color: localTheme.colorScheme.primary))
          : localTitleStyle;
      final localSubStyle = localTheme.textTheme.bodyMedium?.copyWith(
        color: localTheme.colorScheme.onSurface.withValues(alpha: 0.65),
      );
      final localTagStyle = localTheme.textTheme.labelSmall?.copyWith(
        color: localTheme.colorScheme.onSurface.withValues(alpha: 0.8),
      );
      final localSubtitle = [
        widget.item.artist.trim(),
        widget.item.album.trim(),
      ].where((v) => v.isNotEmpty).join(' · ');
      final localTagText = _buildAudioTagText(widget.item);
      final localEntries = MusicItemContextMenu.buildEntries(
        selectionMode: selectionMode,
        onToggleFavorite: () => widget.controller.toggleFavorite(widget.item),
        onShowInSystem: () async {
          final item = widget.item;
          final full = item.fullPath.trim();
          final localPath = full.isNotEmpty
              ? full
              : (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty)
              ? '${item.path.trim()}/${item.filename.trim()}'
              : '';
          if (localPath.isEmpty) return;
          final localReply = await FileApiService.instance.showInSystem(
            localPath,
          );
          if (!localReply.success) {
            ToastUtil.show(localReply.message ?? 'operation_failed'.tr);
          }
        },
        onRemoveFromPlayList: () =>
            widget.controller.removeFromPlayListItem(widget.item),
        onOpenInSystem: () async {
          final item = widget.item;
          final full = item.fullPath.trim();
          final localPath = full.isNotEmpty
              ? full
              : (item.path.trim().isNotEmpty && item.filename.trim().isNotEmpty)
              ? '${item.path.trim()}/${item.filename.trim()}'
              : '';
          if (localPath.isEmpty) return;
          final localReply = await FileApiService.instance.openInSystem(
            localPath,
          );
          if (!localReply.success) {
            ToastUtil.show(localReply.message ?? 'operation_failed'.tr);
          }
        },
        onFileBrowse: () => _openInFileBrowser(context),
        onDownload: () => widget.controller.downloadItem(widget.item),
        onDelete: () => widget.controller.deleteItem(widget.item),
        onAddToPlayList: () => widget.controller.addToPlayListItem(widget.item),
        isSameMachine:
            DeviceUtils.isDesktopOrWeb && ApiController.instance.isSameMachine,
        isFavorite: widget.item.isFavorite,
        inPlayList: widget.controller.isInPlayList,
      );
      final localOverlayColor = localSelected
          ? localTheme.colorScheme.primary.withValues(alpha: 0.08)
          : localTheme.colorScheme.onSurface.withValues(alpha: 0.03);

      final localRow = InkWell(
        onTap: () {
          if (selectionMode) {
            widget.controller.toggleSelection(widget.item.id);
            return;
          }
          if (isCurrent) {
            if (localPlayCtrl.isPlaying.value) {
              localPlayCtrl.pause();
            } else {
              localPlayCtrl.play();
            }
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
                      child: selectionMode
                          ? CustomCheckbox(
                              value: localSelected,
                              onChanged: (_) => widget.controller
                                  .toggleSelection(widget.item.id),
                              isCircle: false,
                            )
                          : (_hovered
                                ? Icon(
                                    localIsPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    size: 18,
                                  )
                                : localIsPlaying
                                ? _buildWaveIndicator(
                                    14,
                                    color: localTheme.colorScheme.primary,
                                  )
                                : Text(
                                    '${widget.index + 1}',
                                    style: localSubStyle,
                                  )),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _CoverThumb(
                    filePath: _resolvePathForCover(widget.item),
                    hasInnerCover: widget.item.hasInnerCover,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.item.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: localEffectiveTitleStyle,
                        ),
                        if (localTagText.isNotEmpty ||
                            localSubtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: <Widget>[
                              if (localTagText.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: localTheme.colorScheme.secondary
                                          .withValues(alpha: 0.4),
                                    ),
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(6),
                                    ),
                                  ),
                                  child: Text(
                                    localTagText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: localTagStyle,
                                  ),
                                ),
                              if (localTagText.isNotEmpty &&
                                  localSubtitle.isNotEmpty)
                                const SizedBox(width: 6),
                              if (localSubtitle.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    localSubtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: localSubStyle,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: widget.item.isFavorite
                        ? 'unfavorite'.tr
                        : 'favorites'.tr,
                    onPressed: () =>
                        widget.controller.toggleFavorite(widget.item),
                    icon: Icon(
                      widget.item.isFavorite
                          ? Icons.favorite
                          : Icons.favorite_border,
                      size: 20,
                      color: widget.item.isFavorite ? Colors.red : null,
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: Align(
                      alignment: Alignment.center,
                      child: Text(
                        FormatUtil.formatDurationSeconds(
                          widget.item.duration,
                          autoPadZero: true,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: localSubStyle,
                      ),
                    ),
                  ),
                ],
              ),
              if (selectionMode)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(color: localOverlayColor),
                  ),
                ),
            ],
          ),
        ),
      );

      if (!DeviceUtils.isDesktop && !DeviceUtils.isWeb) return localRow;

      final localHoverChild = MouseRegion(
        onExit: (_) {
          if (!_hovered) return;
          setState(() => _hovered = false);
        },
        onEnter: (_) {
          if (widget.controller.isScrolling.value) return;
          if (_hovered) return;
          setState(() => _hovered = true);
        },
        child: localRow,
      );

      if (localEntries.isEmpty) return localHoverChild;
      return ContextMenuUtil.region(
        child: localHoverChild,
        entries: localEntries,
      );
    });
  }

  static String _resolvePathForCover(MusicListItem item) {
    final base = item.path.trim();
    final full = item.fullPath.trim();
    final localName = item.filename.trim();
    return full.isNotEmpty
        ? full
        : (base.isNotEmpty && localName.isNotEmpty ? '$base/$localName' : '');
  }

  static String _buildAudioTagText(MusicListItem item) {
    final sampleRate = item.sampleRate ?? 0;
    final localParts = <String>[];
    final bitDepth = item.bitDepth ?? 0;
    final bitrate = item.bitrate ?? 0;
    if (bitDepth > 0) {
      localParts.add('${bitDepth}bit');
    }
    if (sampleRate > 0) {
      localParts.add(_formatSampleRate(sampleRate));
    } else if (bitrate > 0) {
      localParts.add(_formatBitrate(bitrate));
    }
    if (localParts.isEmpty) return '';
    return localParts.join('|');
  }

  static String _formatBitrate(int bitrate) {
    final localKbps = (bitrate / 1000).round();
    return '${localKbps}kbps';
  }

  static String _formatSampleRate(int sampleRate) {
    final localKhz = sampleRate / 1000;
    final localText = localKhz % 1 == 0
        ? localKhz.toStringAsFixed(0)
        : localKhz.toStringAsFixed(1);
    return '${localText}khz';
  }

  void _openInFileBrowser(BuildContext context) {
    final item = widget.item;
    final base = item.path.trim();
    final full = item.fullPath.trim();
    final String target;
    if (item.isSeries) {
      final localRaw = full.isNotEmpty ? full : base;
      target = browseFolderPathMusic(localRaw);
    } else if (full.isNotEmpty) {
      target = browseFolderPathMusic(full);
    } else {
      target = browseFolderPathMusic(base);
    }
    if (target.isEmpty) return;
    if (DeviceUtils.isDesktop && Get.isRegistered<PcHomeController>()) {
      PcHomeController.instance.openFolderAt(target);
      return;
    }
    AppRoutes.toFiles(initialPath: target);
  }
}

class _MobileDataRow extends StatefulWidget {
  final MusicListItem item;
  final int index;
  final MusicSubListController controller;

  const _MobileDataRow({
    super.key,
    required this.item,
    required this.index,
    required this.controller,
  });

  @override
  State<_MobileDataRow> createState() => _MobileDataRowState();
}

class _MobileDataRowState extends State<_MobileDataRow> {
  String _resolvePlayablePath(MusicListItem item) {
    if (item.isSeries) {
      final localP = item.firstFilePath.trim();
      if (localP.isNotEmpty) return localP;
    }
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return full;
    final localName = item.filename.trim();
    final base = item.path.trim();
    if (base.isNotEmpty && localName.isNotEmpty) return '$base/$localName';
    return base;
  }

  MusicListItem? _currentPlayingItem(MusicPlayServiceController controller) {
    final localIdx = controller.currentIndex.value;
    if (localIdx < 0 || localIdx >= controller.playlist.length) return null;
    return controller.playlist[localIdx];
  }

  void _openItem() {
    if (widget.item.isSeries) {
      _openSeries();
      return;
    }
    final localPlayCtrl = MusicPlayServiceController.instance;
    final localCurrentItem = _currentPlayingItem(localPlayCtrl);
    final localCurrentPath = localCurrentItem == null
        ? ''
        : _resolvePlayablePath(localCurrentItem);
    final localItemPath = _resolvePlayablePath(widget.item);
    final isCurrent =
        localCurrentPath.isNotEmpty && localCurrentPath == localItemPath;
    if (isCurrent) {
      if (localPlayCtrl.isPlaying.value) {
        localPlayCtrl.pause();
      } else {
        localPlayCtrl.play();
      }
      return;
    }
    widget.controller.playAt(widget.index);
  }

  void _openSeries() {
    final localSeriesIndexId = widget.item.id;
    if (localSeriesIndexId <= 0) return;
    final localOverlayCtrl = Get.isRegistered<MusicSubListOverlayController>()
        ? Get.find<MusicSubListOverlayController>()
        : Get.put(MusicSubListOverlayController());
    localOverlayCtrl.open(
      seriesIndexId: localSeriesIndexId,
      name: widget.item.displayTitle,
      keyType: 'series',
    );
  }

  static String _resolvePathForCover(MusicListItem item) {
    final base = item.path.trim();
    final full = item.fullPath.trim();
    final localName = item.filename.trim();
    return full.isNotEmpty
        ? full
        : (base.isNotEmpty && localName.isNotEmpty ? '$base/$localName' : '');
  }

  List<AppItemActionSheetEntry> _buildMobileActionSheetEntries(
    BuildContext context,
  ) {
    final selectionMode = widget.controller.isMultiSelectMode.value;
    if (selectionMode) return const <AppItemActionSheetEntry>[];
    final localInPlayList = widget.controller.isInPlayList;
    return <AppItemActionSheetEntry>[
      AppItemActionSheetAction(
        title: 'open'.tr,
        onTap: _openItem,
        icon: const Icon(Icons.open_in_new),
      ),
      AppItemActionSheetAction(
        title: 'file_browse'.tr,
        onTap: () => _openInFileBrowser(context),
        icon: const Icon(Icons.folder_open_outlined),
      ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        title: (widget.item.isFavorite ? 'unfavorite'.tr : 'favorites'.tr),
        onTap: () => widget.controller.toggleFavorite(widget.item),
        icon: Icon(
          widget.item.isFavorite ? Icons.favorite : Icons.favorite_border,
          color: widget.item.isFavorite ? Colors.red : null,
        ),
      ),
      AppItemActionSheetAction(
        title: 'download'.tr,
        onTap: () => widget.controller.downloadItem(widget.item),
        icon: const Icon(Icons.download_outlined),
      ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        title: 'add_to_play_list'.tr,
        onTap: () => widget.controller.addToPlayListItem(widget.item),
        icon: const Icon(Icons.playlist_add),
      ),
      if (localInPlayList)
        AppItemActionSheetAction(
          title: 'remove_from_play_list'.tr,
          onTap: () => widget.controller.removeFromPlayListItem(widget.item),
          icon: const Icon(Icons.playlist_remove),
        ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        titleColor: Colors.red,
        title: 'delete'.tr,
        onTap: () => widget.controller.deleteItem(widget.item),
        icon: const Icon(Icons.delete_outline, color: Colors.red),
      ),
    ];
  }

  Widget _buildActionSheetLeading(BuildContext context) {
    final filePath = _resolvePathForCover(widget.item);
    final localTheme = Theme.of(context);
    final localUrl = filePath.trim().isEmpty || widget.item.hasInnerCover != 1
        ? ''
        : ApiController.instance.getMusicCoverUrl(
            filePath: filePath,
            size: 180,
          );
    final localBorder = BorderRadius.all(Radius.circular(10));

    Widget fallback() {
      final localSeed = filePath.hashCode;
      final localIdx = Random(localSeed).nextInt(20) + 1;
      return ClipRRect(
        borderRadius: localBorder,
        child: Container(
          width: 52,
          height: 52,
          color: localTheme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
          child: Image.asset(
            'assets/music/musicCover/other$localIdx.jpg',
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    if (localUrl.isEmpty) return fallback();
    return ClipRRect(
      borderRadius: localBorder,
      child: CustomExtendedImage(
        width: 52,
        showLoading: false,
        imageUrl: localUrl,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback(),
        borderRadius: 0,
      ),
    );
  }

  Future<void> _showMobileActionSheet(BuildContext context) async {
    await AppItemActionSheet.show(
      context,
      headerLeading: _buildActionSheetLeading(context),
      headerTitle: widget.item.displayTitle,
      headerSubtitle: widget.item.displaySubtitle,
      entries: _buildMobileActionSheetEntries(context),
    );
  }

  void _openInFileBrowser(BuildContext context) {
    final item = widget.item;
    final base = item.path.trim();
    final full = item.fullPath.trim();
    final String target;
    if (item.isSeries) {
      final localRaw = full.isNotEmpty ? full : base;
      target = browseFolderPathMusic(localRaw);
    } else if (full.isNotEmpty) {
      target = browseFolderPathMusic(full);
    } else {
      target = browseFolderPathMusic(base);
    }
    if (target.isEmpty) return;
    if (DeviceUtils.isDesktop && Get.isRegistered<PcHomeController>()) {
      PcHomeController.instance.openFolderAt(target);
      return;
    }
    AppRoutes.toFiles(initialPath: target);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final selectionMode = widget.controller.isMultiSelectMode.value;
      final localTheme = Theme.of(context);
      final localSelected = widget.controller.selectedItems.contains(
        widget.item.id,
      );

      final localPlayCtrl = MusicPlayServiceController.instance;
      final localCurrentItem = _currentPlayingItem(localPlayCtrl);
      final localCurrentPath = localCurrentItem == null
          ? ''
          : _resolvePlayablePath(localCurrentItem);
      final localItemPath = _resolvePlayablePath(widget.item);
      final isCurrent =
          localCurrentPath.isNotEmpty && localCurrentPath == localItemPath;
      final localIsPlaying = isCurrent && localPlayCtrl.isPlaying.value;

      final localTitleStyle = localTheme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
      );
      final localEffectiveTitleStyle = isCurrent
          ? (localTitleStyle?.copyWith(color: localTheme.colorScheme.primary) ??
                TextStyle(color: localTheme.colorScheme.primary))
          : localTitleStyle;
      final localSubStyle = localTheme.textTheme.bodyMedium?.copyWith(
        color: localTheme.colorScheme.onSurface.withValues(alpha: 0.65),
      );

      Widget cover() {
        final base = _CoverThumb(
          filePath: _resolvePathForCover(widget.item),
          hasInnerCover: widget.item.hasInnerCover,
        );
        if (!localIsPlaying) return base;
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
                      color: localTheme.colorScheme.primary.withValues(
                        alpha: 0.9,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }

      final localRow = InkWell(
        onTap: () {
          if (selectionMode) {
            widget.controller.toggleSelection(widget.item.id);
            return;
          }
          _openItem();
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(15, 0, 15, 0),
          height: 62,
          child: Row(
            children: <Widget>[
              if (selectionMode) ...[
                CustomCheckbox(
                  value: localSelected,
                  onChanged: (_) =>
                      widget.controller.toggleSelection(widget.item.id),
                  isCircle: false,
                ),
                const SizedBox(width: 10),
              ],
              cover(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.item.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: localEffectiveTitleStyle,
                    ),
                    if (widget.item.displaySubtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.item.displaySubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: localSubStyle,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: selectionMode
                    ? null
                    : () => _showMobileActionSheet(context),
                icon: const Icon(Icons.more_vert, size: 20),
              ),
            ],
          ),
        ),
      );

      if (!selectionMode) return localRow;

      final localOverlayColor = localSelected
          ? localTheme.colorScheme.primary.withValues(alpha: 0.08)
          : localTheme.colorScheme.onSurface.withValues(alpha: 0.03);
      return Stack(
        children: <Widget>[
          localRow,
          Positioned.fill(
            child: IgnorePointer(child: Container(color: localOverlayColor)),
          ),
        ],
      );
    });
  }
}

class _CoverThumb extends StatelessWidget {
  final String filePath;
  final int hasInnerCover;
  const _CoverThumb({required this.filePath, this.hasInnerCover = 0});

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);
    final localUrl = filePath.trim().isEmpty || hasInnerCover != 1
        ? ''
        : ApiController.instance.getMusicCoverUrl(
            filePath: filePath,
            size: 120,
          );
    final localBorder = BorderRadius.all(Radius.circular(8));

    Widget fallback() {
      final localSeed = filePath.hashCode;
      final localIdx = Random(localSeed).nextInt(20) + 1;
      return ClipRRect(
        borderRadius: localBorder,
        child: Container(
          width: 46,
          height: 46,
          color: localTheme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
          child: Image.asset(
            'assets/music/musicCover/other$localIdx.jpg',
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    if (localUrl.isEmpty) return fallback();
    return ClipRRect(
      borderRadius: localBorder,
      child: CustomExtendedImage(
        width: 46,
        showLoading: false,
        imageUrl: localUrl,
        height: 46,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback(),
        borderRadius: 0,
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final MusicSubListController controller;
  const _Footer({required this.controller});

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
