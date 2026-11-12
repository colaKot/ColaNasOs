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
  static const Set<String> _coverGenres = <String>{
    'blues',
    'classical',
    'country',
    'gospel',
    'hiphop',
    'pop',
    'rock',
  };

  bool _hovered = false;
  bool _favBusy = false;
  bool? _favOverride;

  bool get _favorite => _favOverride ?? widget.item.isFavorite;

  MusicListItem? _playingEntry(MusicPlayServiceController ctrl) {
    final index = ctrl.currentIndex.value;
    if (index < 0 || index >= ctrl.playlist.length) return null;
    return ctrl.playlist[index];
  }

  String _playablePath(MusicListItem item) {
    final seriesEntry = item.isSeries ? item.firstFilePath.trim() : '';
    if (seriesEntry.isNotEmpty) return seriesEntry;
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return full;
    final base = item.path.trim();
    final name = item.filename.trim();
    if (base.isEmpty) return '';
    return name.isEmpty ? base : '$base/$name';
  }

  String _fullPathOf(MusicListItem item) {
    final full = item.fullPath.trim();
    if (full.isNotEmpty) return full;
    final base = item.path.trim();
    final name = item.filename.trim();
    if (base.isNotEmpty && name.isNotEmpty) return '$base/$name';
    return base;
  }

  bool _isCurrentTrack(MusicPlayServiceController ctrl, MusicListItem item) {
    final playing = _playingEntry(ctrl);
    if (playing == null) return false;
    final now = _playablePath(playing);
    return now.isNotEmpty && now == _playablePath(item);
  }

  List<AppItemActionSheetEntry> _mobileSheetEntries(BuildContext context) {
    if (widget.selectionMode) return const <AppItemActionSheetEntry>[];
    final inPlayList = (widget.controller.listId ?? 0) > 0;
    return <AppItemActionSheetEntry>[
      AppItemActionSheetAction(
        onTap: _activate,
        title: 'open'.tr,
        icon: const Icon(Icons.open_in_new),
      ),
      AppItemActionSheetAction(
        onTap: () => _browseFile(context),
        title: 'file_browse'.tr,
        icon: const Icon(Icons.folder_open_outlined),
      ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        onTap: _switchFavorite,
        title: _favorite ? 'unfavorite'.tr : 'favorites'.tr,
        icon: Icon(
          _favorite ? Icons.favorite : Icons.favorite_border,
          color: _favorite ? Colors.red : null,
        ),
      ),
      AppItemActionSheetAction(
        onTap: () => widget.controller.downloadItem(widget.item),
        title: 'download'.tr,
        icon: const Icon(Icons.download_outlined),
      ),
      const AppItemActionSheetDivider(),
      AppItemActionSheetAction(
        onTap: () => _pickPlaylist(context),
        title: 'add_to_play_list'.tr,
        icon: const Icon(Icons.playlist_add),
      ),
      if (inPlayList)
        AppItemActionSheetAction(
          onTap: _dropFromPlaylist,
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

  Future<void> _openMobileSheet(BuildContext context) async {
    final theme = Theme.of(context);
    await AppItemActionSheet.show(
      context,
      headerLeading: ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        child: SizedBox(width: 52, height: 52, child: _cover(theme)),
      ),
      headerTitle: widget.item.displayTitle,
      entries: _mobileSheetEntries(context),
    );
  }

  void _activate() {
    if (widget.item.isSeries) {
      _enterSeries();
      return;
    }
    final ctrl = MusicPlayServiceController.instance;
    if (_isCurrentTrack(ctrl, widget.item)) {
      ctrl.isPlaying.value ? ctrl.pause() : ctrl.play();
      return;
    }
    final queue = <MusicListItem>[];
    for (final entry in widget.controller.items) {
      if (!entry.isSeries) queue.add(entry);
    }
    if (queue.isEmpty) return;
    ctrl.playFromList(
      startItem: widget.item,
      paging: MusicPlaylistPaging.fromQuery(
        widget.controller.buildPagingQuery(),
      ),
      items: queue,
    );
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

  @override
  void didUpdateWidget(covariant MusicItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _hovered = false;
      _favBusy = false;
      _favOverride = null;
      return;
    }
    if (oldWidget.item.isFavorite != widget.item.isFavorite &&
        _favOverride != null) {
      _favOverride = null;
    }
  }

  Future<void> _runSystemCall(
    Future<ApiResult> Function(String path) call,
  ) async {
    final path = _fullPathOf(widget.item);
    if (path.isEmpty) return;
    final result = await call(path);
    if (!result.success) {
      ToastUtil.show(result.message ?? 'operation_failed'.tr);
    }
  }

  List<ContextMenuEntry> _contextEntries(BuildContext context) {
    final sameMachine =
        DeviceUtils.isDesktopOrWeb && ApiController.instance.isSameMachine;
    return MusicItemContextMenu.buildEntries(
      selectionMode: widget.selectionMode,
      onToggleFavorite: _switchFavorite,
      onShowInSystem: () =>
          _runSystemCall((path) => FileApiService.instance.showInSystem(path)),
      onRemoveFromPlayList: _dropFromPlaylist,
      onOpenInSystem: () =>
          _runSystemCall((path) => FileApiService.instance.openInSystem(path)),
      onOpen: _activate,
      onFileBrowse: () => _browseFile(context),
      onDownload: () => widget.controller.downloadItem(widget.item),
      onDelete: () => widget.controller.deleteItem(widget.item),
      onAddToPlayList: () => _pickPlaylist(context),
      isSameMachine: sameMachine,
      isFavorite: _favorite,
      inPlayList: (widget.controller.listId ?? 0) > 0,
    );
  }

  Future<bool> _writeFavorite(int id, bool makeFavorite) {
    final service = MusicFavoriteApiService.instance;
    return makeFavorite ? service.addFavorite(id) : service.removeFavorite(id);
  }

  Future<void> _switchFavorite() async {
    if (_favBusy) return;
    final id = widget.item.id;
    if (id <= 0) return;

    final before = _favorite;
    final after = !before;
    setState(() {
      _favBusy = true;
      _favOverride = after;
    });

    final ok = await _writeFavorite(id, after);
    if (!mounted) return;
    if (ok) {
      widget.controller.updateFavoriteState(id, after);
      setState(() => _favBusy = false);
    } else {
      setState(() {
        _favOverride = before;
        _favBusy = false;
      });
    }
  }

  Future<void> _pickPlaylist(BuildContext context) async {
    final indexId = widget.item.id;
    if (indexId <= 0) return;
    try {
      final picked = await showDialog<PlayListItem>(
        context: context,
        barrierDismissible: true,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
            child: const PlayListListView(selectionMode: true),
          ),
        ),
      );
      if (picked == null) return;
      final reply = await PlayListApiService.instance.addIndexes(
        listId: picked.id,
        indexIds: <int>[indexId],
      );
      ToastUtil.show(
        reply.success
            ? 'operation_success'.tr
            : (reply.message ?? 'operation_failed'.tr),
      );
    } catch (_) {
      ToastUtil.show('operation_failed'.tr);
    }
  }

  Future<void> _dropFromPlaylist() =>
      widget.controller.removeFromPlayListItem(widget.item);

  String _captionText() {
    final item = widget.item;
    if (item.isSeries) {
      final count = item.musicCount < 0 ? 0 : item.musicCount;
      return '$count首';
    }
    final artist = item.artist.trim();
    final album = item.album.trim();
    return <String>[
      if (artist.isNotEmpty) artist,
      if (album.isNotEmpty) album,
    ].join(' · ');
  }

  Widget _wave(double size, {Color? color}) => SpinKitWave(
    size: size,
    itemCount: 6,
    color: (color ?? Colors.white).withValues(alpha: 0.9),
  );

  String _formatBadge() {
    final item = widget.item;
    if (item.isSeries) return 'series'.tr;
    var ext = item.ext.trim();
    if (ext.isEmpty) {
      final name = item.filename.trim();
      final dot = name.lastIndexOf('.');
      ext = (dot >= 0 && dot < name.length - 1) ? name.substring(dot + 1) : '';
    }
    ext = ext.replaceAll('.', '').trim();
    return ext.isEmpty ? '' : ext.toUpperCase();
  }

  BoxDecoration _bubbleDecoration(ThemeData theme) => BoxDecoration(
    color: theme.colorScheme.surface.withValues(alpha: 0.75),
    borderRadius: const BorderRadius.all(Radius.circular(999)),
    border: Border.all(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
    ),
  );

  Widget _bubbleIcon({
    required ThemeData theme,
    required Widget icon,
    required VoidCallback onTap,
    Key? containerKey,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        child: Container(
          key: containerKey,
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: _bubbleDecoration(theme),
          child: icon,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _contextEntries(context);
    final badge = _formatBadge();

    final body = Column(
      children: <Widget>[
        SizedBox(
          width: widget.coverSize,
          height: widget.coverSize,
          child: CustomAlbum(preview: _buildCoverStack(theme, entries, badge)),
        ),
        const SizedBox(height: 6),
        _buildCaption(theme),
      ],
    );

    final tapTarget = widget.selectionMode && widget.onToggleSelected != null
        ? GestureDetector(onTap: widget.onToggleSelected, child: body)
        : GestureDetector(onTap: _activate, child: body);

    if (!DeviceUtils.isDesktop && !DeviceUtils.isWeb) return tapTarget;

    final hoverTarget = MouseRegion(
      onEnter: (_) {
        if (widget.controller.isScrolling.value) return;
        if (_hovered) return;
        setState(() => _hovered = true);
      },
      onExit: (_) {
        if (!_hovered) return;
        setState(() => _hovered = false);
      },
      cursor: SystemMouseCursors.basic,
      child: tapTarget,
    );

    if (entries.isEmpty) return hoverTarget;
    return ContextMenuUtil.region(child: hoverTarget, entries: entries);
  }

  Widget _buildCoverStack(
    ThemeData theme,
    List<ContextMenuEntry> entries,
    String badge,
  ) {
    final showMore = _hovered && entries.isNotEmpty;
    final showFavorite = (_hovered || _favorite) && !widget.selectionMode;
    final showSelectBox = widget.selectionMode || _hovered || widget.selected;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _cover(theme),
        if (_hovered) Container(color: Colors.black.withValues(alpha: 0.2)),
        if (!widget.selectionMode) _buildPlayOverlay(theme),
        if (showFavorite)
          Positioned(
            top: 4,
            left: 6,
            child: _bubbleIcon(
              theme: theme,
              onTap: _switchFavorite,
              icon: Icon(
                _favorite ? Icons.favorite : Icons.favorite_border,
                size: 18,
                color: _favorite ? Colors.red : theme.colorScheme.onSurface,
              ),
            ),
          ),
        if (showMore)
          Positioned(
            top: 4,
            right: 6,
            child: Builder(
              builder: (context) {
                final anchor = GlobalKey();
                return _bubbleIcon(
                  theme: theme,
                  containerKey: anchor,
                  onTap: () => _showMenuAt(context, anchor, entries),
                  icon: Icon(
                    Icons.more_horiz,
                    color: theme.colorScheme.onSurface,
                    size: 18,
                  ),
                );
              },
            ),
          ),
        if (!showMore && badge.isNotEmpty)
          Positioned(top: 6, right: 6, child: _buildBadge(theme, badge)),
        if (DeviceUtils.isMobile && entries.isNotEmpty)
          Positioned(
            left: 6,
            bottom: 6,
            child: Builder(
              builder: (context) => _bubbleIcon(
                theme: theme,
                onTap: () => _openMobileSheet(context),
                icon: Icon(
                  Icons.more_horiz,
                  color: theme.colorScheme.onSurface,
                  size: 18,
                ),
              ),
            ),
          ),
        if (showSelectBox)
          Positioned(
            right: 0,
            bottom: 0,
            child: CustomCheckbox(
              side: const BorderSide(color: Colors.white, width: 2.0),
              onChanged: (_) => widget.onToggleSelected?.call(),
              isCircle: true,
              value: widget.selected,
            ),
          ),
      ],
    );
  }

  void _showMenuAt(
    BuildContext context,
    GlobalKey anchor,
    List<ContextMenuEntry> entries,
  ) {
    final box = anchor.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    ContextMenuUtil.showAtPosition(
      context,
      entries: entries,
      position:
          box.localToGlobal(Offset.zero, ancestor: overlay) +
          const Offset(0, 30),
    );
  }

  Widget _buildBadge(ThemeData theme, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.all(Radius.circular(6)),
    ),
    child: Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _buildPlayOverlay(ThemeData theme) {
    return Obx(() {
      final ctrl = MusicPlayServiceController.instance;
      final current = _isCurrentTrack(ctrl, widget.item);
      final playing = current && ctrl.isPlaying.value;
      if (!_hovered && !playing) return const SizedBox.shrink();
      if (!_hovered) {
        return Positioned.fill(child: Center(child: _wave(26)));
      }
      return Positioned.fill(
        child: Center(
          child: Material(
            shape: const CircleBorder(),
            color: Colors.black.withValues(alpha: 0.45),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _activate,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  widget.item.isSeries
                      ? Icons.folder_open
                      : (playing ? Icons.pause : Icons.play_arrow),
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildCaption(ThemeData theme) {
    final titleStyle = theme.textTheme.bodySmall;
    final subtitleStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    final subtitle = _captionText();

    return SizedBox(
      height: 46,
      child: Column(
        children: <Widget>[
          Obx(() {
            final ctrl = MusicPlayServiceController.instance;
            final current = _isCurrentTrack(ctrl, widget.item);
            final style = current
                ? (titleStyle ?? const TextStyle()).copyWith(
                    color: theme.colorScheme.primary,
                  )
                : titleStyle;
            return Tooltip(
              message: widget.item.displayTitle,
              child: Text(
                widget.item.displayTitle,
                style: style,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          }),
          const SizedBox(height: 4),
          if (subtitle.isNotEmpty)
            Tooltip(
              message: widget.item.isSeries ? "" : subtitle,
              child: Text(
                subtitle,
                style: subtitleStyle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _cover(ThemeData theme) {
    final item = widget.item;
    final coverPath = item.isSeries
        ? item.firstFilePath.trim()
        : _fullPathOf(item);
    // 不依赖 hasInnerCover 提前返回：旧库里该标记常为空，直接跳过会让
    // 所有曲目都落到占位图；是否内嵌封面交给封面接口判断即可。
    if (coverPath.isNotEmpty) {
      final url = ApiController.instance.getMusicCoverUrl(
        filePath: coverPath,
        size: 200,
      );
      if (url.isNotEmpty) {
        return CustomExtendedImage(
          showLoading: false,
          imageUrl: url,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _placeholder(theme),
          borderRadius: 0,
        );
      }
    }
    return _placeholder(theme);
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Image.asset(
        _pickPlaceholderAsset(),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  String _pickPlaceholderAsset() {
    final item = widget.item;
    final head = item.genre
        .trim()
        .toLowerCase()
        .split(RegExp(r'[\/,;|]'))
        .first;
    final key = head.trim().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final rng = Random(item.id);
    if (key.isNotEmpty && _coverGenres.contains(key)) {
      return 'assets/music/musicCover/$key${rng.nextInt(6) + 1}.jpg';
    }
    return 'assets/music/musicCover/other${rng.nextInt(20) + 1}.jpg';
  }

  void _browseFile(BuildContext context) {
    final item = widget.item;
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
}
