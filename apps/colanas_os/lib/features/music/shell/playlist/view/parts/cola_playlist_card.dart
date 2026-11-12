import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/cola_device_utils.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../service/cola_playlist_api_service.dart';
import 'play_list_cover.dart';

/// 歌单卡片：封面宫格 + 底部标题 + 更多菜单。
///
/// 右键与「更多」按钮复用同一组菜单描述，避免两处各写一份条目。
class PlayListListCard extends StatelessWidget {
  const PlayListListCard({
    required this.selectionMode,
    required this.onRename,
    required this.onOpen,
    required this.onDelete,
    super.key,
    required this.item,
  });

  final bool selectionMode;
  final VoidCallback onRename;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final PlayListItem item;

  @override
  Widget build(BuildContext context) {
    final card = _album(context);
    if (!DeviceUtils.isDesktopOrWeb || selectionMode) return card;
    return ContextMenuUtil.region(child: card, entries: _menu());
  }

  Widget _album(BuildContext context) {
    final moreKey = GlobalKey();
    return CustomAlbum(
      preview: PlayListCoverGrid(previews: item.previews),
      onTap: onOpen,
      hoverEnabled: !selectionMode && DeviceUtils.isDesktopOrWeb,
      headerRight: selectionMode
          ? null
          : IconButton(
              tooltip: 'more'.tr,
              onPressed: () => _openMore(context, moreKey),
              key: moreKey,
              icon: const Icon(Icons.more_horiz, color: Colors.white),
            ),
      headerPosition: CustomAlbumHeaderPosition.bottom,
      headerLeft: _title(context),
      headerHeight: 50,
    );
  }

  Widget _title(BuildContext context) => Text(
    item.name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
  );

  List<ContextMenuEntry> _menu() => <ContextMenuEntry>[
    ColaContextMenuItem.create(
      value: 'rename',
      onSelected: (_) => onRename(),
      label: Text('rename'.tr),
      icon: const Icon(Icons.edit_outlined, size: 18.0),
    ),
    const MenuDivider(),
    ColaContextMenuItem.create(
      value: 'delete',
      onSelected: (_) => onDelete(),
      label: Text('delete'.tr),
      icon: const Icon(Icons.delete_outline, size: 18.0),
      color: Colors.red,
    ),
  ];

  void _openMore(BuildContext context, GlobalKey anchorKey) {
    final anchor = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null) return;

    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    ContextMenuUtil.showAtPosition(
      context,
      entries: _menu(),
      position: topLeft + Offset(0, anchor.size.height),
    );
  }
}
