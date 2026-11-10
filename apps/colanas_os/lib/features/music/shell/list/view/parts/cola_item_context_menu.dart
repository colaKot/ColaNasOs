import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';

/// 单条右键命令的声明式描述。
class _Command {
  const _Command({
    required this.id,
    required this.label,
    required this.icon,
    required this.action,
    this.dividerBefore = false,
    this.danger = false,
    this.iconColor,
  });

  final String label;
  final String id;
  final Color? iconColor;
  final IconData icon;
  final bool dividerBefore;
  final bool danger;
  final VoidCallback? action;

  ContextMenuEntry toEntry() => CustomContextMenuItem.create(
    value: id,
    onSelected: (_) => action?.call(),
    label: Text(
      label,
      style: danger ? const TextStyle(color: Colors.red) : null,
    ),
    icon: Icon(icon, size: 18.0, color: iconColor),
  );
}

/// 曲目右键菜单。
///
/// 菜单项按「命令描述」声明，再由 [_render] 统一插入分隔线并转成
/// `ContextMenuEntry`；系统级操作的服务端版本校验集中在一处。
class MusicItemContextMenu {
  const MusicItemContextMenu._();

  static List<ContextMenuEntry> buildEntries({
    required bool selectionMode,
    required bool isFavorite,
    required bool inPlayList,
    required bool isSameMachine,
    required VoidCallback onFileBrowse,
    required VoidCallback onToggleFavorite,
    required VoidCallback onDownload,
    required VoidCallback onAddToPlayList,
    required VoidCallback onRemoveFromPlayList,
    required VoidCallback onDelete,
    VoidCallback? onOpen,
    VoidCallback? onProperty,
    VoidCallback? onShowInSystem,
    VoidCallback? onOpenInSystem,
  }) {
    if (selectionMode) return const <ContextMenuEntry>[];

    final commands = <_Command>[
      _Command(
        label: 'open'.tr,
        id: 'open',
        icon: Icons.open_in_new,
        action: onOpen,
      ),
      _Command(
        label: 'file_browse'.tr,
        id: 'file_browse',
        icon: Icons.folder_open_outlined,
        action: onFileBrowse,
      ),
      _Command(
        label: (isFavorite ? 'unfavorite' : 'favorites').tr,
        id: 'favorite',
        iconColor: isFavorite ? Colors.red : null,
        icon: isFavorite ? Icons.favorite : Icons.favorite_border,
        dividerBefore: true,
        action: onToggleFavorite,
      ),
      _Command(
        label: 'download'.tr,
        id: 'download',
        icon: Icons.download_outlined,
        action: onDownload,
      ),
      _Command(
        label: 'add_to_play_list'.tr,
        id: 'add_to_play_list',
        icon: Icons.playlist_add,
        dividerBefore: true,
        action: onAddToPlayList,
      ),
      if (inPlayList)
        _Command(
          label: 'remove_from_play_list'.tr,
          id: 'remove_from_play_list',
          icon: Icons.playlist_remove,
          action: onRemoveFromPlayList,
        ),
      if (isSameMachine) ..._systemCommands(onShowInSystem, onOpenInSystem),
      _Command(
        label: 'delete'.tr,
        id: 'delete',
        iconColor: Colors.red,
        icon: Icons.delete_outline,
        dividerBefore: true,
        danger: true,
        action: onDelete,
      ),
    ];
    return _render(commands);
  }

  /// 同机时可用，且要求服务端版本 >= 8。
  static List<_Command> _systemCommands(
    VoidCallback? showInFolder,
    VoidCallback? openInSystem,
  ) => <_Command>[
    _Command(
      label: 'file_show_in_folder'.tr,
      id: 'show_in_system',
      icon: Icons.folder_open,
      dividerBefore: true,
      action: _requireServerV8(showInFolder),
    ),
    _Command(
      label: 'file_open_in_system'.tr,
      id: 'open_in_system',
      icon: Icons.launch,
      action: _requireServerV8(openInSystem),
    ),
  ];

  static VoidCallback _requireServerV8(VoidCallback? action) => () {
    if (!ApiController.instance.isServerVersionAtLeast(8)) {
      DialogUtil.showInfoDialog(
        title: 'tip'.tr,
        content: 'server_version_too_low'.tr,
      );
      return;
    }
    action?.call();
  };

  static List<ContextMenuEntry> _render(List<_Command> commands) {
    final entries = <ContextMenuEntry>[];
    for (final command in commands) {
      if (command.dividerBefore) entries.add(const MenuDivider());
      entries.add(command.toEntry());
    }
    return entries;
  }

  static Widget region({
    required Widget child,
    required List<ContextMenuEntry> entries,
  }) {
    if (entries.isEmpty) return child;
    return ContextMenuUtil.region(child: child, entries: entries);
  }
}
