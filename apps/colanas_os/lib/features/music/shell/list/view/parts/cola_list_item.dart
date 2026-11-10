import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/spinkit.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../../compat/cola_device_utils.dart';
import '../../../compat/base_components.dart';
import '../../../compat/cola_api_controller.dart';
import '../../../compat/cola_app_routes.dart';
import '../../controller/cola_list_controller.dart';
import '../../models/cola_list_models.dart';
import '../../../playlist/service/cola_playlist_api_service.dart';
import '../../../playlist/view/cola_playlist_view.dart';
import '../../../favorite/service/cola_favorite_api_service.dart';
import '../../../play_service/controller/cola_player_controller.dart';
import '../../../sub_list/controller/cola_sub_list_controller.dart';
import 'cola_item_context_menu.dart';

class MusicItemCard extends StatefulWidget {
  final double width;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelected;
  final MusicListItem item;
  final double coverSize;
  final MusicListController controller;
  const MusicItemCard({
    super.key,
    required this.controller,
    required this.item,
    required this.width,
    required this.coverSize,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
  });

  @override
  State<MusicItemCard> createState() => _MusicItemCardState();
}

class _MusicItemCardState extends State<MusicItemCard> {
  bool _hovered = false;
  bool _favoriteLoading = false;
  bool? _isFavorite;

  bool get _effectiveFavorite => _isFavorite ?? widget.item.isFavorite;

  List<AppItemActionSheetEntry> _buildMobileActionSheetEntries(
    BuildContext context,
  ) {
    if (widget.selectionMode) return const <AppItemActionSheetEntry>[];
    final localInPlayList = (widget.controller.listId ?? 0) > 0;
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
        title: (_effectiveFavorite ? 'unfavorite'.tr : 'favorites'.tr),
        onTap: _toggleFavorite,
        icon: Icon(
          _effectiveFavorite ? Icons.favorite : Icons.favorite_border,
          color: _effectiveFavorite ? Colors.red : null,
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
        onTap: () => _addToPlayList(context),
        icon: const Icon(Icons.playlist_add),
      ),
      if (localInPlayList)
        AppItemActionSheetAction(
          title: 'remove_from_play_list'.tr,
          onTap: _removeFromPlayList,
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

  Future<void> _showMobileActionSheet(BuildContext context) async {
    final theme = Theme.of(context);
    final localLeading = ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(10)),
      child: SizedBox(width: 52, height: 52, child: _buildCover(theme)),
    );
    await AppItemActionSheet.show(
      context,
      headerLeading: localLeading,
      headerTitle: widget.item.displayTitle,
      entries: _buildMobileActionSheetEntries(context),
    );
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
    final localPlayableItems = widget.controller.items
        .where((e) => !e.isSeries)
        .toList(growable: false);
    if (localPlayableItems.isEmpty) return;
    localPlayCtrl.playFromList(
      startItem: widget.item,
      paging: MusicPlaylistPaging.fromQuery(
        widget.controller.buildPagingQuery(),
      ),
      items: localPlayableItems,
    );
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

  @override
  void didUpdateWidget(covariant MusicItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _hovered = false;
      _favoriteLoading = false;
      _isFavorite = null;
      return;
    }
    if (oldWidget.item.isFavorite != widget.item.isFavorite) {
      if (_isFavorite == null) return;
      _isFavorite = null;
    }
  }

  List<ContextMenuEntry> _buildContextMenuEntries(BuildContext context) {
    final item = widget.item;
    final localIsSameMachine =
        DeviceUtils.isDesktopOrWeb && ApiController.instance.isSameMachine;

    String resolvePath() {
      final localFull = item.fullPath.trim();
      if (localFull.isNotEmpty) return localFull;
      final localName = item.filename.trim();
      final localDir = item.path.trim();
      if (localDir.isNotEmpty && localName.isNotEmpty)
        return '$localDir/$localName';
      return '';
    }

    return MusicItemContextMenu.buildEntries(
      selectionMode: widget.selectionMode,
      onToggleFavorite: _toggleFavorite,
      onShowInSystem: () async {
        final localPath = resolvePath();
        if (localPath.isEmpty) return;
        final localReply = await FileApiService.instance.showInSystem(
          localPath,
        );
        if (!localReply.success) {
          ToastUtil.show(localReply.message ?? 'operation_failed'.tr);
        }
      },
      onRemoveFromPlayList: _removeFromPlayList,
      onOpenInSystem: () async {
        final localPath = resolvePath();
        if (localPath.isEmpty) return;
        final localReply = await FileApiService.instance.openInSystem(
          localPath,
        );
        if (!localReply.success) {
          ToastUtil.show(localReply.message ?? 'operation_failed'.tr);
        }
      },
      onOpen: _openItem,
      onFileBrowse: () => _openInFileBrowser(context),
      onDownload: () => widget.controller.downloadItem(widget.item),
      onDelete: () => widget.controller.deleteItem(widget.item),
      onAddToPlayList: () => _addToPlayList(context),
      isSameMachine: localIsSameMachine,
      isFavorite: _effectiveFavorite,
      inPlayList: (widget.controller.listId ?? 0) > 0,
    );
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteLoading) return;
    final id = widget.item.id;
    if (id <= 0) return;

    final localPrev = _effectiveFavorite;
    final localNext = !localPrev;

    setState(() {
      _favoriteLoading = true;
      _isFavorite = localNext;
    });

    try {
      final ok = localNext
          ? await MusicFavoriteApiService.instance.addFavorite(id)
          : await MusicFavoriteApiService.instance.removeFavorite(id);
      if (!ok) {
        if (mounted) {
          setState(() {
            _isFavorite = localPrev;
          });
        }
        return;
      }
      widget.controller.updateFavoriteState(id, localNext);
    } finally {
      if (mounted) {
        setState(() {
          _favoriteLoading = false;
        });
      }
    }
  }

  Future<void> _addToPlayList(BuildContext context) async {
    final localIndexId = widget.item.id;
    if (localIndexId <= 0) return;
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

  Future<void> _removeFromPlayList() async {
    await widget.controller.removeFromPlayListItem(widget.item);
  }

  String _buildSubtitleText() {
    if (widget.item.isSeries) {
      final localCnt = widget.item.musicCount;
      return '${localCnt < 0 ? 0 : localCnt}首';
    }
    final localA = widget.item.artist.trim();
    final localAl = widget.item.album.trim();
    if (localAl.isNotEmpty && localA.isNotEmpty) return '$localA · $localAl';
    if (localAl.isNotEmpty) return localAl;
    if (localA.isNotEmpty) return localA;
    return '';
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

  String _badgeLabel() {
    if (widget.item.isSeries) return 'series'.tr;
    var localExt = widget.item.ext.trim();
    if (localExt.isEmpty) {
      final localName = widget.item.filename.trim();
      final localI = localName.lastIndexOf('.');
      localExt = (localI >= 0 && localI < localName.length - 1)
          ? localName.substring(localI + 1)
          : '';
    }
    localExt = localExt.replaceAll('.', '').trim();
    return localExt.isEmpty ? '' : localExt.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localTitleStyle = theme.textTheme.bodySmall;
    final localSubtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    final localEntries = _buildContextMenuEntries(context);
    final localSubtitle = _buildSubtitleText();
    final localShowMoreButton = _hovered && localEntries.isNotEmpty;
    final localBadgeLabel = _badgeLabel();
    final localShowFavoriteButton =
        (_hovered || _effectiveFavorite) && !widget.selectionMode;
    final localShowSelectBox =
        widget.selectionMode || _hovered || widget.selected;

    final localChild = Column(
      children: <Widget>[
        SizedBox(
          width: widget.coverSize,
          height: widget.coverSize,
          child: CustomAlbum(
            preview: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildCover(theme),
                if (_hovered)
                  Container(color: Colors.black.withValues(alpha: 0.2)),
                if (!widget.selectionMode)
                  Obx(() {
                    final localPlayCtrl = MusicPlayServiceController.instance;
                    final localCurrentItem = _currentPlayingItem(localPlayCtrl);
                    final localCurrentPath = localCurrentItem == null
                        ? ''
                        : _resolvePlayablePath(localCurrentItem);
                    final localItemPath = _resolvePlayablePath(widget.item);
                    final isCurrent =
                        localCurrentPath.isNotEmpty &&
                        localCurrentPath == localItemPath;
                    final showHoverControl = _hovered;
                    final isPlaying =
                        isCurrent && localPlayCtrl.isPlaying.value;
                    if (!showHoverControl && !isPlaying) {
                      return const SizedBox.shrink();
                    }
                    if (showHoverControl) {
                      return Positioned.fill(
                        child: Center(
                          child: Material(
                            shape: const CircleBorder(),
                            color: Colors.black.withValues(alpha: 0.45),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () {
                                _openItem();
                              },
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Icon(
                                  widget.item.isSeries
                                      ? Icons.folder_open
                                      : (isPlaying
                                            ? Icons.pause
                                            : Icons.play_arrow),
                                  size: 20,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    return Positioned.fill(
                      child: Center(child: _buildWaveIndicator(26)),
                    );
                  }),
                if (localShowFavoriteButton)
                  Positioned(
                    top: 4,
                    left: 6,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _toggleFavorite,
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.75,
                            ),
                            borderRadius: BorderRadius.all(
                              Radius.circular(999),
                            ),
                            border: Border.all(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.12,
                              ),
                            ),
                          ),
                          child: Icon(
                            _effectiveFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 18,
                            color: _effectiveFavorite
                                ? Colors.red
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (localShowMoreButton)
                  Positioned(
                    top: 4,
                    right: 6,
                    child: Builder(
                      builder: (context) {
                        final key = GlobalKey();
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              final localBox =
                                  key.currentContext?.findRenderObject()
                                      as RenderBox?;
                              final localOverlay =
                                  Overlay.of(context).context.findRenderObject()
                                      as RenderBox?;
                              if (localBox == null || localOverlay == null)
                                return;
                              final localPos = localBox.localToGlobal(
                                Offset.zero,
                                ancestor: localOverlay,
                              );
                              ContextMenuUtil.showAtPosition(
                                context,
                                entries: localEntries,
                                position: localPos + const Offset(0, 30),
                              );
                            },
                            borderRadius: BorderRadius.all(
                              Radius.circular(999),
                            ),
                            child: Container(
                              key: key,
                              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface.withValues(
                                  alpha: 0.75,
                                ),
                                borderRadius: BorderRadius.all(
                                  Radius.circular(999),
                                ),
                                border: Border.all(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                              ),
                              child: Icon(
                                Icons.more_horiz,
                                size: 18,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (!localShowMoreButton && localBadgeLabel.isNotEmpty)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.all(Radius.circular(6)),
                      ),
                      child: Text(
                        localBadgeLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (DeviceUtils.isMobile && localEntries.isNotEmpty)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Builder(
                      builder: (context) {
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              _showMobileActionSheet(context);
                            },
                            borderRadius: BorderRadius.all(
                              Radius.circular(999),
                            ),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface.withValues(
                                  alpha: 0.75,
                                ),
                                borderRadius: BorderRadius.all(
                                  Radius.circular(999),
                                ),
                                border: Border.all(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                              ),
                              child: Icon(
                                Icons.more_horiz,
                                size: 18,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (localShowSelectBox)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: CustomCheckbox(
                      value: widget.selected,
                      side: const BorderSide(color: Colors.white, width: 2.0),
                      onChanged: (_) => widget.onToggleSelected?.call(),
                      isCircle: true,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 46,
          child: Column(
            children: <Widget>[
              Obx(() {
                final localPlayCtrl = MusicPlayServiceController.instance;
                final localCurrentItem = _currentPlayingItem(localPlayCtrl);
                final localCurrentPath = localCurrentItem == null
                    ? ''
                    : _resolvePlayablePath(localCurrentItem);
                final localItemPath = _resolvePlayablePath(widget.item);
                final isCurrent =
                    localCurrentPath.isNotEmpty &&
                    localCurrentPath == localItemPath;
                final localEffectiveTitleStyle = isCurrent
                    ? (localTitleStyle?.copyWith(
                            color: theme.colorScheme.primary,
                          ) ??
                          TextStyle(color: theme.colorScheme.primary))
                    : localTitleStyle;
                return Tooltip(
                  message: widget.item.displayTitle,
                  child: Text(
                    widget.item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: localEffectiveTitleStyle,
                  ),
                );
              }),
              const SizedBox(height: 4),
              if (localSubtitle.isNotEmpty)
                Tooltip(
                  message: widget.item.isSeries ? "" : localSubtitle,
                  child: Text(
                    localSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: localSubtitleStyle,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    final localTappableChild =
        widget.selectionMode && widget.onToggleSelected != null
        ? GestureDetector(onTap: widget.onToggleSelected, child: localChild)
        : GestureDetector(onTap: _openItem, child: localChild);

    if (!DeviceUtils.isDesktop && !DeviceUtils.isWeb) return localTappableChild;

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
      cursor: SystemMouseCursors.basic,
      child: localTappableChild,
    );

    if (localEntries.isEmpty) return localHoverChild;
    return ContextMenuUtil.region(
      child: localHoverChild,
      entries: localEntries,
    );
  }

  Widget _buildCover(ThemeData theme) {
    String coverFilePath = '';
    if (widget.item.isSeries) {
      coverFilePath = widget.item.firstFilePath.trim();
    } else {
      coverFilePath = widget.item.fullPath.trim();
      if (coverFilePath.isEmpty) {
        final localName = widget.item.filename.trim();
        final base = widget.item.path.trim();
        coverFilePath = base.isNotEmpty && localName.isNotEmpty
            ? '$base/$localName'
            : base;
      }
    }

    // 别用 hasInnerCover 提前退出：老库这个标记常常没回填，直接 return 会让
    // 所有曲目跳过网络封面、一律落到占位图。让 /compat/cover 自己判断有没有，
    // 抽不到再走 errorBuilder 的 fallback。
    if (coverFilePath.isNotEmpty) {
      final localUrl = ApiController.instance.getMusicCoverUrl(
        filePath: coverFilePath,
        size: 200,
      );
      if (localUrl.isNotEmpty) {
        return CustomExtendedImage(
          showLoading: false,
          imageUrl: localUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _fallbackCover(theme),
          borderRadius: 0,
        );
      }
    }

    return _fallbackCover(theme);
  }

  Widget _fallbackCover(ThemeData theme) {
    final localAssetPath = _pickFallbackCoverAsset();
    return Container(
      color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
      child: Image.asset(
        localAssetPath,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  String _pickFallbackCoverAsset() {
    final localRaw = widget.item.genre.trim().toLowerCase();
    final localParts = localRaw
        .split(RegExp(r'[\/,;|]'))
        .map((e) => e.trim())
        .toList();
    final localHead = localParts.isNotEmpty ? localParts.first : '';
    final localRng = Random(widget.item.id);
    final localNormalized = localHead.replaceAll(RegExp(r'[^a-z0-9]'), '');
    const localGenreKeys = {
      'blues',
      'classical',
      'country',
      'gospel',
      'hiphop',
      'pop',
      'rock',
    };
    if (localNormalized.isNotEmpty &&
        localGenreKeys.contains(localNormalized)) {
      final localIdx = localRng.nextInt(6) + 1;
      return 'assets/music/musicCover/$localNormalized$localIdx.jpg';
    }
    final localIdx = localRng.nextInt(20) + 1;
    return 'assets/music/musicCover/other$localIdx.jpg';
  }

  void _openInFileBrowser(BuildContext context) {
    final item = widget.item;
    final base = item.path.trim();
    final localFull = item.fullPath.trim();
    final String target;
    if (item.isSeries) {
      final localRaw = localFull.isNotEmpty ? localFull : base;
      target = browseFolderPathMusic(localRaw);
    } else if (localFull.isNotEmpty) {
      target = browseFolderPathMusic(localFull);
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
