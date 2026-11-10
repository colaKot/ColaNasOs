import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/base_components.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../models/cola_collection_model.dart';

/// 卡片上可用的操作，同时供下拉菜单与右键菜单使用。
typedef _CardAction = ({
  String id,
  String label,
  IconData icon,
  VoidCallback run,
  bool dividerBefore,
});

class MusicCollectionCard extends StatelessWidget {
  const MusicCollectionCard({
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    super.key,
    required this.collection,
  });

  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final MusicCollectionItem collection;

  @override
  Widget build(BuildContext context) {
    final actions = _actions();
    return Tooltip(
      waitDuration: const Duration(milliseconds: 300),
      message: _pathsTooltip(),
      child: ContextMenuUtil.region(
        child: _album(actions),
        entries: _contextEntries(actions),
      ),
    );
  }

  List<_CardAction> _actions() => <_CardAction>[
    (
      id: 'open',
      label: 'open'.tr,
      icon: Icons.open_in_new,
      run: onOpen,
      dividerBefore: false,
    ),
    (
      id: 'edit',
      label: 'edit'.tr,
      icon: Icons.edit_outlined,
      run: onEdit,
      dividerBefore: true,
    ),
    (
      id: 'delete',
      label: 'delete'.tr,
      icon: Icons.delete_outline,
      run: onDelete,
      dividerBefore: false,
    ),
  ];

  String _pathsTooltip() {
    final paths = collection.pathList
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return 'no_path'.tr;
    return '${'path'.tr}:\n${paths.join('\n')}';
  }

  Widget _album(List<_CardAction> actions) => CustomAlbum(
    preview: MusicCollectionPreviewGrid(previews: collection.previews),
    onTap: onOpen,
    headerRight: _popup(actions),
    headerPosition: CustomAlbumHeaderPosition.bottom,
    headerLeft: _title(),
    headerHeight: 50,
  );

  Widget _title() => Row(
    children: <Widget>[
      Flexible(
        child: Text(
          collection.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            shadows: <Shadow>[
              Shadow(
                offset: Offset(0, 1),
                color: Colors.black54,
                blurRadius: 6,
              ),
            ],
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    ],
  );

  Widget _popup(List<_CardAction> actions) => PopupMenuButton<String>(
    tooltip: '',
    onSelected: (id) {
      for (final action in actions) {
        if (action.id == id) action.run();
      }
    },
    itemBuilder: (_) => <PopupMenuEntry<String>>[
      for (final action in actions)
        PopupMenuItem<String>(value: action.id, child: Text(action.label)),
    ],
    icon: const Icon(Icons.more_vert, color: Colors.white),
  );

  List<ContextMenuEntry> _contextEntries(List<_CardAction> actions) {
    final entries = <ContextMenuEntry>[];
    for (final action in actions) {
      if (action.dividerBefore) entries.add(const MenuDivider());
      entries.add(
        CustomContextMenuItem.create(
          value: action.id,
          onSelected: (_) => action.run(),
          label: Text(action.label),
          icon: Icon(action.icon, size: 18),
        ),
      );
    }
    return entries;
  }
}

/// 收藏夹卡片的四宫格封面。
class MusicCollectionPreviewGrid extends StatelessWidget {
  const MusicCollectionPreviewGrid({super.key, required this.previews});

  final List<MusicCollectionPreviewItem> previews;

  static const String _defaultCover = 'assets/music/icons/default_cover.jpg';

  static Widget placeholder({double? side}) => Image.asset(
    _defaultCover,
    fit: BoxFit.cover,
    width: side ?? double.infinity,
    height: side ?? double.infinity,
  );

  @override
  Widget build(BuildContext context) {
    final tiles = previews.take(4).toList(growable: false);
    if (tiles.isEmpty) return placeholder();

    final row = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      row.add(Expanded(child: _CollectionCover(preview: tiles[i])));
      if (i != tiles.length - 1) row.add(const SizedBox(width: 1));
    }
    return Row(children: row);
  }
}

class _CollectionCover extends StatelessWidget {
  const _CollectionCover({required this.preview});

  final MusicCollectionPreviewItem preview;

  @override
  Widget build(BuildContext context) {
    if (preview.hasInnerCover != 1) {
      return MusicCollectionPreviewGrid.placeholder();
    }

    final path =
        (preview.showType == 'series'
                ? preview.firstFilePath
                : preview.fullPath)
            .trim();
    if (path.isEmpty) return MusicCollectionPreviewGrid.placeholder();

    final url = ApiController.instance.getMusicCoverUrl(
      filePath: path,
      size: 500,
    );
    if (url.isEmpty) return MusicCollectionPreviewGrid.placeholder();

    return CustomExtendedImage(
      width: double.infinity,
      showLoading: false,
      imageUrl: url,
      height: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => MusicCollectionPreviewGrid.placeholder(),
      borderRadius: 0,
    );
  }
}
