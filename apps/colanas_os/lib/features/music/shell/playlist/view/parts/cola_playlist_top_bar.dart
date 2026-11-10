import '../../../compat/ui_kit.dart';
import '../../../compat/cola_custom_colors.dart';
import '../../../compat/host.dart';
import '../../../compat/cola_popup_menu_util.dart';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../controller/cola_playlist_controller.dart';
import 'cola_playlist_dialogs.dart';

class PlayListTopBar extends StatelessWidget {
  final PlayListController controller;
  final bool selectionMode;
  final _sortButtonKey = GlobalKey();
  PlayListTopBar({
    required this.selectionMode,
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final extendedPalette = Theme.of(context).extension<CustomColors>();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      height: 52.0,
      decoration: BoxDecoration(
        color: extendedPalette?.mainContentBgColor,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(selectionMode ? 30 : 0),
        ),
      ),
      child: Row(
        children: <Widget>[
          if (selectionMode)
            IconButton(
              tooltip: 'back'.tr,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          if (selectionMode)
            Expanded(
              child: Text(
                'music_playlist_select'.tr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Get.textTheme.titleMedium,
              ),
            )
          else ...[
            MusicSquareButton(
              icon: Icons.add,
              tooltip: 'create'.tr,
              onTap: () => PlayListDialogs.showCreateDialog(
                context,
                controller: controller,
              ),
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
          ],
        ],
      ),
    );
  }

  Widget _buildSortButton(BuildContext context) {
    return Obx(() {
      final isActive =
          controller.searchController.text.isNotEmpty ||
          controller.sortBy.value != 'create_time' ||
          controller.sortOrder.value != 'desc';

      return Container(
        key: _sortButtonKey,
        child: MusicSquareButton(
          tooltip: 'sort'.tr,
          onTap: () => _openSortMenu(context),
          icon: Icons.sort_by_alpha,
          active: isActive,
        ),
      );
    });
  }

  Future<void> _openSortMenu(BuildContext context) async {
    final currentOrder = controller.sortOrder.value;
    final currentBy = controller.sortBy.value;

    bool isSelected(String field, String order) =>
        currentBy == field && currentOrder == order;

    final selected = await PopupMenuUtil.showBelowButton<String>(
      items: [
        PopupMenuItem(
          value: 'name_asc',
          child: MusicSortMenuItem(
            icon: Icons.sort_by_alpha,
            label: 'name_asc'.tr,
            selected: isSelected('name', 'asc'),
          ),
        ),
        PopupMenuItem(
          value: 'name_desc',
          child: MusicSortMenuItem(
            icon: Icons.sort_by_alpha,
            label: 'name_desc'.tr,
            selected: isSelected('name', 'desc'),
          ),
        ),
        PopupMenuItem(
          value: 'create_time_asc',
          child: MusicSortMenuItem(
            icon: Icons.schedule,
            label: 'create_time_asc'.tr,
            selected: isSelected('create_time', 'asc'),
          ),
        ),
        PopupMenuItem(
          value: 'create_time_desc',
          child: MusicSortMenuItem(
            icon: Icons.schedule,
            label: 'create_time_desc'.tr,
            selected: isSelected('create_time', 'desc'),
          ),
        ),
      ],
      context: context,
      buttonKey: _sortButtonKey,
    );
    if (selected == null) return;
    final parts = selected.split('_');
    if (parts.isEmpty) return;
    final field = parts.sublist(0, parts.length - 1).join('_');
    final order = parts.last;
    controller.setSort(field: field, order: order);
  }
}

class AppPlayListTopBar extends StatelessWidget {
  final PlayListController controller;
  const AppPlayListTopBar({super.key, required this.controller});

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

  Widget _buildSortButton(BuildContext context) {
    return Obx(() {
      final isActive =
          controller.searchController.text.isNotEmpty ||
          controller.sortBy.value != 'create_time' ||
          controller.sortOrder.value != 'desc';

      return MusicSquareButton(
        tooltip: 'sort'.tr,
        onTap: () => _openSortSheet(context),
        icon: Icons.sort_by_alpha,
        active: isActive,
      );
    });
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
            bool isSelected(String field, String order) =>
                controller.sortBy.value == field &&
                controller.sortOrder.value == order;
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: <Widget>[
                ListTile(
                  dense: true,
                  leading: isSelected('name', 'asc')
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : const SizedBox(width: 24.0),
                  title: Text('name_asc'.tr),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    controller.setSort(field: 'name', order: 'asc');
                  },
                ),
                ListTile(
                  dense: true,
                  leading: isSelected('name', 'desc')
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : const SizedBox(width: 24.0),
                  title: Text('name_desc'.tr),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    controller.setSort(field: 'name', order: 'desc');
                  },
                ),
                ListTile(
                  dense: true,
                  leading: isSelected('create_time', 'asc')
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : const SizedBox(width: 24.0),
                  title: Text('create_time_asc'.tr),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    controller.setSort(field: 'create_time', order: 'asc');
                  },
                ),
                ListTile(
                  dense: true,
                  leading: isSelected('create_time', 'desc')
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : const SizedBox(width: 24.0),
                  title: Text('create_time_desc'.tr),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    controller.setSort(field: 'create_time', order: 'desc');
                  },
                ),
              ],
            );
          }),
        );
      },
    );
  }
}
