import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart' show NasStyleContext;

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
    required this.onClose,
    required this.controller,
    this.coverCenterAssetSize = 42,
    this.coverCenterAsset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Border(bottom: BorderSide(color: theme.dividerColor));

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(border: divider),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SubListCover(
              controller: controller,
              size: 100.0,
              radius: 14,
              centerAsset: coverCenterAsset,
              centerSize: coverCenterAssetSize,
            ),
            const SizedBox(width: 16.0),
            Expanded(child: _buildMeta(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildMeta(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          height: 40.0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (!controller.isFavorite && !controller.isHistory) ...[
                IconButton(
                  icon: Icon(Icons.arrow_back_ios_outlined),
                  onPressed: onClose,
                  tooltip: 'back'.tr,
                ),
                const SizedBox(width: 6.0),
              ],
              Expanded(
                child: Text(
                  controller.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12.0),
        LayoutBuilder(
          builder: (context, box) {
            final searchWidth = (box.maxWidth * 0.33)
                .clamp(110.0, 200.0)
                .toDouble();
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: _buildToolbar(theme)),
                const SizedBox(width: 10.0),
                SizedBox(
                  width: searchWidth,
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

  Widget _buildToolbar(ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildPlayAllButton(),
          const SizedBox(width: 10.0),
          if (!controller.isHistory)
            MusicSubListSortMenu(controller: controller),
          if (!controller.isHistory) const SizedBox(width: 10.0),
          _buildMultiSelectButton(theme),
        ],
      ),
    );
  }

  Widget _buildPlayAllButton() {
    return Obx(() {
      final disabled = controller.items.isEmpty;
      return CustomButton(
        text: "${'play'.tr}(${max(0, controller.total.value)})",
        style: ElevatedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 10.0),
        ),
        onPressed: disabled ? () {} : () => controller.playAll(),
        isPrimary: true,
        icon: const Icon(Icons.play_arrow),
        height: 35.0,
      );
    });
  }

  Widget _buildMultiSelectButton(ThemeData theme) {
    return Obx(() {
      final disabled = controller.items.isEmpty;
      return CustomIconButton(
        tooltip: 'multi_select'.tr,
        onPressed: disabled ? null : () => controller.toggleMultiSelectMode(),
        icon: Icons.select_all,
        borderSide: BorderSide(color: theme.dividerColor),
        borderRadius: 999,
      );
    });
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
    required this.onClose,
    required this.controller,
    this.coverCenterAssetSize = 42,
    this.coverCenterAsset,
    this.showTitle = true,
    this.showBackButton = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Border(bottom: BorderSide(color: theme.dividerColor));

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(border: divider),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SubListCover(
            controller: controller,
            size: 80.0,
            radius: 12,
            centerAsset: coverCenterAsset,
            centerSize: coverCenterAssetSize * 0.8,
          ),
          const SizedBox(width: 12.0),
          Expanded(child: _buildMeta(theme)),
        ],
      ),
    );
  }

  Widget _buildMeta(ThemeData theme) {
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
                    !controller.isHistory) ...[
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_outlined, size: 18.0),
                    onPressed: onClose,
                    tooltip: 'back'.tr,
                  ),
                  const SizedBox(width: 6.0),
                ],
                Expanded(
                  child: Text(
                    controller.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
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
            _buildPlayAllButton(theme),
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

  Widget _buildPlayAllButton(ThemeData theme) {
    return Obx(() {
      final disabled = controller.items.isEmpty;
      return CustomIconButton(
        tooltip: 'play'.tr,
        onPressed: disabled ? null : controller.playAll,
        iconSize: 20,
        iconColor: theme.colorScheme.onPrimary,
        icon: Icons.play_arrow,
        buttonSize: 36,
        borderRadius: 999,
        backgroundColor: theme.colorScheme.primary,
      );
    });
  }
}

class MusicSubListMobilePageHeader extends StatelessWidget {
  final MusicSubListController controller;

  const MusicSubListMobilePageHeader({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: context.musicBarColor,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: <Widget>[
          Obx(() {
            final disabled = controller.items.isEmpty;
            return CustomIconButton(
              tooltip: 'play'.tr,
              onPressed: disabled ? () {} : controller.playAll,
              iconSize: 20,
              iconColor: theme.colorScheme.onPrimary,
              icon: Icons.play_arrow,
              buttonSize: 36,
              borderRadius: 999,
              backgroundColor: theme.colorScheme.primary,
            );
          }),
          const SizedBox(width: 8.0),
          Expanded(child: MusicSubListMobileSearchBar(controller: controller)),
          if (!controller.isHistory) SizedBox(width: 8.0),
          if (!controller.isHistory) _SortTrigger(controller: controller),
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

class _SubListCover extends StatelessWidget {
  final MusicSubListController controller;
  final double size;
  final double radius;
  final String? centerAsset;
  final double centerSize;

  const _SubListCover({
    required this.controller,
    required this.size,
    required this.radius,
    required this.centerSize,
    this.centerAsset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      child: Container(
        width: size,
        height: size,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: Obx(() {
          final cover = MusicCoverImage(url: controller.headerCoverUrl.trim());
          final asset = (centerAsset ?? '').trim();
          if (asset.isEmpty) return cover;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              cover,
              Center(
                child: Image.asset(
                  asset,
                  fit: BoxFit.contain,
                  width: centerSize,
                  height: centerSize,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

const List<_SortChoice> _baseSortChoices = <_SortChoice>[
  _SortChoice(
    by: MusicSubListSortBy.filename,
    order: MusicSubListSortOrder.asc,
    labelKey: 'music_list_sort_filename_asc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.filename,
    order: MusicSubListSortOrder.desc,
    labelKey: 'music_list_sort_filename_desc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.title,
    order: MusicSubListSortOrder.asc,
    labelKey: 'music_list_sort_title_asc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.title,
    order: MusicSubListSortOrder.desc,
    labelKey: 'music_list_sort_title_desc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.duration,
    order: MusicSubListSortOrder.desc,
    labelKey: 'music_list_sort_duration_desc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.duration,
    order: MusicSubListSortOrder.asc,
    labelKey: 'music_list_sort_duration_asc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.ctime,
    order: MusicSubListSortOrder.desc,
    labelKey: 'create_time_desc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.ctime,
    order: MusicSubListSortOrder.asc,
    labelKey: 'create_time_asc',
  ),
];

const List<_SortChoice> _favoriteSortChoices = <_SortChoice>[
  _SortChoice(
    by: MusicSubListSortBy.favoriteTime,
    order: MusicSubListSortOrder.desc,
    labelKey: 'music_list_sort_favorite_time_desc',
  ),
  _SortChoice(
    by: MusicSubListSortBy.favoriteTime,
    order: MusicSubListSortOrder.asc,
    labelKey: 'music_list_sort_favorite_time_asc',
  ),
];

class _SortTrigger extends StatelessWidget {
  final MusicSubListController controller;
  const _SortTrigger({required this.controller});

  List<_SortChoice> _choices() => controller.isFavorite
      ? <_SortChoice>[..._favoriteSortChoices, ..._baseSortChoices]
      : _baseSortChoices;

  Future<void> _openSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      useSafeArea: true,
      showDragHandle: true,
      context: context,
      builder: (ctx) {
        final choices = _choices();
        final theme = Theme.of(ctx);
        return Material(
          color: Color.alphaBlend(
            ctx.nasStyle.panelColor,
            ctx.nasStyle.baseColor,
          ),
          child: Obx(() {
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: <Widget>[
                for (final choice in choices) _buildTile(ctx, theme, choice),
              ],
            );
          }),
        );
      },
    );
  }

  Widget _buildTile(BuildContext ctx, ThemeData theme, _SortChoice choice) {
    final active =
        controller.sortBy.value == choice.by &&
        controller.sortOrder.value == choice.order;
    return ListTile(
      dense: true,
      leading: active
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : const SizedBox(width: 24.0),
      title: Text(choice.labelKey.tr),
      onTap: () {
        Navigator.of(ctx).pop();
        controller.setSort(choice.by, choice.order);
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
      onTap: () => _openSheet(context),
      icon: Icons.sort_by_alpha,
    );
  }
}

class _SortChoice {
  final MusicSubListSortOrder order;
  final String labelKey;
  final MusicSubListSortBy by;
  const _SortChoice({
    required this.order,
    required this.labelKey,
    required this.by,
  });
}
