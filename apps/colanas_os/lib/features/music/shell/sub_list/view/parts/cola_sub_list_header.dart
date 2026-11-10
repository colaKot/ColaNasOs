import 'dart:math';

import 'package:flutter/material.dart';

import '../../../compat/base_components.dart';
import '../../../compat/getx.dart';
import '../../../compat/ui_kit.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_sub_list_controller.dart';
import 'cola_sub_list_sort_menu.dart';

class MusicSubListHeader extends StatelessWidget {
  final VoidCallback onClose;
  final double coverCenterAssetSize;
  final String? coverCenterAsset;
  final MusicSubListController controller;

  const MusicSubListHeader({
    super.key,
    required this.controller,
    required this.onClose,
    this.coverCenterAsset,
    this.coverCenterAssetSize = 42,
  });

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: localTheme.dividerColor)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cover(context),
            const SizedBox(width: 16.0),
            Expanded(child: _meta(context)),
          ],
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    final localTheme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      child: Container(
        width: 100.0,
        height: 100.0,
        color: localTheme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
        child: Obx(() {
          final localUrl = controller.headerCoverUrl.trim();
          final localCover = MusicCoverImage(url: localUrl);
          final localAsset = (coverCenterAsset ?? '').trim();
          if (localAsset.isEmpty) return localCover;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              localCover,
              Center(
                child: Image.asset(
                  localAsset,
                  width: coverCenterAssetSize,
                  height: coverCenterAssetSize,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _meta(BuildContext context) {
    final localTheme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          height: 40.0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (!controller.isFavorite && !controller.isHistory)
                IconButton(
                  tooltip: 'back'.tr,
                  onPressed: onClose,
                  icon: Icon(Icons.arrow_back_ios_outlined),
                ),
              if (!controller.isFavorite && !controller.isHistory)
                const SizedBox(width: 6.0),
              Expanded(
                child: Text(
                  controller.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: localTheme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12.0),
        LayoutBuilder(
          builder: (context, c) {
            final localSearchWidth = (c.maxWidth * 0.33)
                .clamp(110.0, 200.0)
                .toDouble();
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Obx(() {
                          final localDisabled = controller.items.isEmpty;
                          return CustomButton(
                            text:
                                "${'play'.tr}(${max(0, controller.total.value)})",
                            style: ElevatedButton.styleFrom(
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10.0,
                              ),
                            ),
                            onPressed: localDisabled
                                ? () {}
                                : () => controller.playAll(),
                            isPrimary: true,
                            icon: const Icon(Icons.play_arrow),
                            height: 35.0,
                          );
                        }),
                        const SizedBox(width: 10.0),
                        if (!controller.isHistory)
                          MusicSubListSortMenu(controller: controller),
                        if (!controller.isHistory) const SizedBox(width: 10.0),
                        Obx(() {
                          final localDisabled = controller.items.isEmpty;
                          return CustomIconButton(
                            tooltip: 'multi_select'.tr,
                            onPressed: localDisabled
                                ? null
                                : () => controller.toggleMultiSelectMode(),
                            icon: Icons.select_all,
                            borderSide: BorderSide(
                              color: localTheme.dividerColor,
                            ),
                            borderRadius: 999,
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10.0),
                SizedBox(
                  width: localSearchWidth,
                  child: MusicSubListSearchBar(
                    controller: controller,
                    height: 40.0,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class MusicSubListMobileHeader extends StatelessWidget {
  final bool showTitle;
  final bool showBackButton;
  final VoidCallback onClose;
  final double coverCenterAssetSize;
  final String? coverCenterAsset;
  final MusicSubListController controller;

  const MusicSubListMobileHeader({
    super.key,
    required this.controller,
    required this.onClose,
    this.coverCenterAsset,
    this.coverCenterAssetSize = 42,
    this.showTitle = true,
    this.showBackButton = true,
  });

  @override
  Widget build(BuildContext context) {
    final coverSize = 80.0;
    final localTheme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: localTheme.dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _cover(context, coverSize: coverSize),
          const SizedBox(width: 12.0),
          Expanded(child: _meta(context)),
        ],
      ),
    );
  }

  Widget _cover(BuildContext context, {required double coverSize}) {
    final localTheme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      child: Container(
        width: coverSize,
        height: coverSize,
        color: localTheme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
        child: Obx(() {
          final localUrl = controller.headerCoverUrl.trim();
          final localCover = MusicCoverImage(url: localUrl);
          final localAsset = (coverCenterAsset ?? '').trim();
          if (localAsset.isEmpty) return localCover;
          final localCenterSize = coverCenterAssetSize * 0.8;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              localCover,
              Center(
                child: Image.asset(
                  localAsset,
                  width: localCenterSize,
                  height: localCenterSize,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _meta(BuildContext context) {
    final localTheme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showTitle) ...[
          SizedBox(
            height: 38.0,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (showBackButton &&
                    !controller.isFavorite &&
                    !controller.isHistory)
                  IconButton(
                    tooltip: 'back'.tr,
                    onPressed: onClose,
                    icon: const Icon(Icons.arrow_back_ios_outlined, size: 18.0),
                  ),
                if (showBackButton &&
                    !controller.isFavorite &&
                    !controller.isHistory)
                  const SizedBox(width: 6.0),
                Expanded(
                  child: Text(
                    controller.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: localTheme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10.0),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Obx(() {
              final localDisabled = controller.items.isEmpty;
              return CustomIconButton(
                tooltip: 'play'.tr,
                onPressed: localDisabled ? null : controller.playAll,
                iconSize: 20,
                iconColor: localTheme.colorScheme.onPrimary,
                icon: Icons.play_arrow,
                buttonSize: 36,
                borderRadius: 999,
                backgroundColor: localTheme.colorScheme.primary,
              );
            }),
            const SizedBox(width: 10.0),
            if (!controller.isHistory)
              MusicSubListSortMenu(controller: controller),
            const Spacer(),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: MusicSubListMobileSearchBar(controller: controller),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class MusicSubListMobilePageHeader extends StatelessWidget {
  final MusicSubListController controller;

  const MusicSubListMobilePageHeader({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final localTheme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: context.musicBarColor,
        border: Border(bottom: BorderSide(color: localTheme.dividerColor)),
      ),
      child: Row(
        children: <Widget>[
          Obx(() {
            final localDisabled = controller.items.isEmpty;
            return CustomIconButton(
              tooltip: 'play'.tr,
              onPressed: localDisabled ? () {} : controller.playAll,
              iconSize: 20,
              iconColor: localTheme.colorScheme.onPrimary,
              icon: Icons.play_arrow,
              buttonSize: 36,
              borderRadius: 999,
              backgroundColor: localTheme.colorScheme.primary,
            );
          }),
          const SizedBox(width: 8.0),
          Expanded(child: MusicSubListMobileSearchBar(controller: controller)),
          if (!controller.isHistory) SizedBox(width: 8.0),
          if (!controller.isHistory) _SortButton(controller: controller),
        ],
      ),
    );
  }
}

class MusicSubListSearchBar extends StatelessWidget {
  final MusicSubListController controller;
  final double height;
  const MusicSubListSearchBar({
    super.key,
    required this.controller,
    this.height = 32,
  });

  @override
  Widget build(BuildContext context) => MusicSearchField(
    searchText: controller.searchText,
    onChanged: controller.onSearchChanged,
    onClear: controller.clearSearch,
    hintText: 'music_list_search_hint'.tr,
  );
}

class MusicSubListMobileSearchBar extends StatelessWidget {
  final MusicSubListController controller;
  final double height;
  const MusicSubListMobileSearchBar({
    super.key,
    required this.controller,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) => MusicSearchField(
    searchText: controller.searchText,
    onChanged: controller.onSearchChanged,
    onClear: controller.clearSearch,
    hintText: 'music_list_search_hint'.tr,
    defaultExpanded: true,
  );
}

class _SortButton extends StatelessWidget {
  final MusicSubListController controller;
  const _SortButton({required this.controller});

  List<_MusicSortEntry> _sortEntries(MusicSubListController c) {
    final base = <_MusicSortEntry>[];
    if (c.isFavorite) {
      base.addAll([
        _MusicSortEntry(
          order: MusicSubListSortOrder.desc,
          labelKey: 'music_list_sort_favorite_time_desc',
          by: MusicSubListSortBy.favoriteTime,
        ),
        _MusicSortEntry(
          order: MusicSubListSortOrder.asc,
          labelKey: 'music_list_sort_favorite_time_asc',
          by: MusicSubListSortBy.favoriteTime,
        ),
      ]);
    }
    base.addAll([
      _MusicSortEntry(
        order: MusicSubListSortOrder.asc,
        labelKey: 'music_list_sort_filename_asc',
        by: MusicSubListSortBy.filename,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.desc,
        labelKey: 'music_list_sort_filename_desc',
        by: MusicSubListSortBy.filename,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.asc,
        labelKey: 'music_list_sort_title_asc',
        by: MusicSubListSortBy.title,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.desc,
        labelKey: 'music_list_sort_title_desc',
        by: MusicSubListSortBy.title,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.desc,
        labelKey: 'music_list_sort_duration_desc',
        by: MusicSubListSortBy.duration,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.asc,
        labelKey: 'music_list_sort_duration_asc',
        by: MusicSubListSortBy.duration,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.desc,
        labelKey: 'create_time_desc',
        by: MusicSubListSortBy.ctime,
      ),
      _MusicSortEntry(
        order: MusicSubListSortOrder.asc,
        labelKey: 'create_time_asc',
        by: MusicSubListSortBy.ctime,
      ),
    ]);
    return base;
  }

  Future<void> _openSortSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      useSafeArea: true,
      showDragHandle: true,
      context: context,
      builder: (ctx) {
        final localEntries = _sortEntries(controller);
        final localTheme = Theme.of(ctx);
        return Material(
          color: localTheme.colorScheme.surface,
          child: Obx(() {
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: <Widget>[
                for (final e in localEntries)
                  ListTile(
                    dense: true,
                    leading:
                        controller.sortBy.value == e.by &&
                            controller.sortOrder.value == e.order
                        ? Icon(
                            Icons.check,
                            color: localTheme.colorScheme.primary,
                          )
                        : const SizedBox(width: 24.0),
                    title: Text(e.labelKey.tr),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      controller.setSort(e.by, e.order);
                    },
                  ),
              ],
            );
          }),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (controller.isHistory) {
      return MusicSquareButton(
        tooltip: 'sort'.tr,
        icon: Icons.sort_by_alpha,
        enabled: false,
        borderRadius: 999,
      );
    }

    return MusicSquareButton(
      tooltip: 'sort'.tr,
      onTap: () => _openSortSheet(context),
      icon: Icons.sort_by_alpha,
    );
  }
}

class _MusicSortEntry {
  final MusicSubListSortOrder order;
  final String labelKey;
  final MusicSubListSortBy by;
  const _MusicSortEntry({
    required this.order,
    required this.labelKey,
    required this.by,
  });
}
