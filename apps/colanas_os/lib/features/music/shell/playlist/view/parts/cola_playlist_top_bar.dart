import '../../../compat/ui_kit.dart';
import '../../../compat/cola_custom_colors.dart';
import '../../../compat/host.dart';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../controller/cola_playlist_controller.dart';
import 'cola_playlist_dialogs.dart';

class _PlayListSort {
  final String field;
  final String order;
  final String labelKey;
  final IconData icon;

  const _PlayListSort({
    required this.field,
    required this.order,
    required this.labelKey,
    required this.icon,
  });

  String get value => '${field}_$order';
}

const List<_PlayListSort> _playListSorts = <_PlayListSort>[
  _PlayListSort(
    field: 'name',
    order: 'asc',
    labelKey: 'name_asc',
    icon: Icons.sort_by_alpha,
  ),
  _PlayListSort(
    field: 'name',
    order: 'desc',
    labelKey: 'name_desc',
    icon: Icons.sort_by_alpha,
  ),
  _PlayListSort(
    field: 'create_time',
    order: 'asc',
    labelKey: 'create_time_asc',
    icon: Icons.schedule,
  ),
  _PlayListSort(
    field: 'create_time',
    order: 'desc',
    labelKey: 'create_time_desc',
    icon: Icons.schedule,
  ),
];

class PlayListTopBar extends StatelessWidget {
  final PlayListController controller;
  final bool selectionMode;
  final _sortButtonKey = GlobalKey();
  PlayListTopBar({
    required this.selectionMode,
    super.key,
    required this.controller,
  });

  bool _isSelected(_PlayListSort sort) =>
      controller.sortBy.value == sort.field &&
      controller.sortOrder.value == sort.order;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<CustomColors>();
    final radius = BorderRadius.vertical(
      top: Radius.circular(selectionMode ? 30 : 0),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      height: 52.0,
      decoration: BoxDecoration(
        color: palette?.mainContentBgColor,
        borderRadius: radius,
      ),
      child: Row(
        children: selectionMode
            ? _selectionChildren(context)
            : _browseChildren(context),
      ),
    );
  }

  List<Widget> _selectionChildren(BuildContext context) => <Widget>[
    IconButton(
      tooltip: 'back'.tr,
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(Icons.close),
    ),
    Expanded(
      child: Text(
        'music_playlist_select'.tr,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Get.textTheme.titleMedium,
      ),
    ),
  ];

  List<Widget> _browseChildren(BuildContext context) => <Widget>[
    MusicSquareButton(
      icon: Icons.add,
      tooltip: 'create'.tr,
      onTap: () =>
          PlayListDialogs.showCreateDialog(context, controller: controller),
    ),
    const SizedBox(width: 4.0),
    _buildSortButton(context),
    const SizedBox(width: 4.0),
    const Expanded(child: SizedBox()),
    ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: SizedBox(
        width: double.infinity,
        child: CustomExpandableSearchBar(
          onClear: controller.clearSearch,
          onChanged: controller.onSearchChanged,
          hintText: 'music_playlist_search_hint'.tr,
          controller: controller.searchController,
        ),
      ),
    ),
  ];

  bool get _sortDirty {
    if (controller.searchController.text.isNotEmpty) return true;
    if (controller.sortBy.value != 'create_time') return true;
    return controller.sortOrder.value != 'desc';
  }

  Widget _buildSortButton(BuildContext context) {
    return Obx(
      () => Container(
        key: _sortButtonKey,
        child: MusicSquareButton(
          tooltip: 'sort'.tr,
          onTap: () => _openSortMenu(context),
          icon: Icons.sort_by_alpha,
          active: _sortDirty,
        ),
      ),
    );
  }

  Future<void> _openSortMenu(BuildContext context) async {
    final selected = await PopupMenuUtil.showBelowButton<String>(
      items: <PopupMenuEntry<String>>[
        for (final sort in _playListSorts)
          PopupMenuItem<String>(
            value: sort.value,
            child: MusicSortMenuItem(
              icon: sort.icon,
              label: sort.labelKey.tr,
              selected: _isSelected(sort),
            ),
          ),
      ],
      context: context,
      buttonKey: _sortButtonKey,
    );
    if (selected == null) return;
    for (final sort in _playListSorts) {
      if (sort.value == selected) {
        controller.setSort(field: sort.field, order: sort.order);
        return;
      }
    }
  }
}

class AppPlayListTopBar extends StatelessWidget {
  final PlayListController controller;
  const AppPlayListTopBar({super.key, required this.controller});

  bool _isSelected(_PlayListSort sort) =>
      controller.sortBy.value == sort.field &&
      controller.sortOrder.value == sort.order;

  @override
  Widget build(BuildContext context) {
    // ⭐ 右侧给窗口按钮组让位（2026-10-09）
    final ctrlW = PcWindowScope.of(context)?.titleBarControlsWidth ?? 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12 + ctrlW, 0),
      child: SizedBox(
        height: 60.0,
        child: Row(
          children: <Widget>[
            Expanded(
              child: CustomExpandableSearchBar(
                onClear: controller.clearSearch,
                onChanged: controller.onSearchChanged,
                hintText: 'music_playlist_search_hint'.tr,
                defaultExpanded: true,
                controller: controller.searchController,
              ),
            ),
            const SizedBox(width: 10.0),
            _buildSortButton(context),
            const SizedBox(width: 10.0),
            MusicSquareButton(
              tooltip: 'create'.tr,
              onTap: () => PlayListDialogs.showCreateDialog(
                context,
                controller: controller,
              ),
              icon: Icons.add,
            ),
          ],
        ),
      ),
    );
  }

  bool get _sortDirty {
    if (controller.searchController.text.isNotEmpty) return true;
    if (controller.sortBy.value != 'create_time') return true;
    return controller.sortOrder.value != 'desc';
  }

  Widget _buildSortButton(BuildContext context) {
    return Obx(
      () => MusicSquareButton(
        tooltip: 'sort'.tr,
        onTap: () => _openSortSheet(context),
        icon: Icons.sort_by_alpha,
        active: _sortDirty,
      ),
    );
  }

  Future<void> _openSortSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      useSafeArea: true,
      showDragHandle: true,
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Material(
          color: theme.colorScheme.surface,
          child: Obx(() {
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: <Widget>[
                for (final sort in _playListSorts) _buildTile(ctx, theme, sort),
              ],
            );
          }),
        );
      },
    );
  }

  Widget _buildTile(BuildContext ctx, ThemeData theme, _PlayListSort sort) {
    return ListTile(
      dense: true,
      leading: _isSelected(sort)
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : const SizedBox(width: 24.0),
      title: Text(sort.labelKey.tr),
      onTap: () {
        Navigator.of(ctx).pop();
        controller.setSort(field: sort.field, order: sort.order);
      },
    );
  }
}
