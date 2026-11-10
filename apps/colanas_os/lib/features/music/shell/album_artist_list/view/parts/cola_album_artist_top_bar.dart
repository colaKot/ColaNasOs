import 'package:flutter/material.dart';

import '../../../compat/ui_kit.dart';
import '../../../compat/host.dart';
import '../../../compat/getx.dart';
import '../../../compat/cola_device_utils.dart';
import '../../../shared/music_primitives.dart';
import '../../../shared/music_dialogs.dart';
import '../../../shared/music_sort.dart';
import '../../../list/models/cola_list_models.dart';
import '../../controller/cola_album_artist_controller.dart';

const _albumSortSpecs =
    <MusicSortSpec<AlbumArtistListSortBy, AlbumArtistListSortOrder>>[
      MusicSortSpec(
        by: AlbumArtistListSortBy.count,
        order: AlbumArtistListSortOrder.desc,
        labelKey: 'music_key_list_sort_count_desc',
        icon: Icons.tag,
      ),
      MusicSortSpec(
        by: AlbumArtistListSortBy.count,
        order: AlbumArtistListSortOrder.asc,
        labelKey: 'music_key_list_sort_count_asc',
        icon: Icons.tag,
      ),
      MusicSortSpec(
        by: AlbumArtistListSortBy.name,
        order: AlbumArtistListSortOrder.asc,
        labelKey: 'name_asc',
        icon: Icons.sort_by_alpha,
        dividerBefore: true,
      ),
      MusicSortSpec(
        by: AlbumArtistListSortBy.name,
        order: AlbumArtistListSortOrder.desc,
        labelKey: 'name_desc',
        icon: Icons.sort_by_alpha,
      ),
    ];

bool _albumSortIsDefault(
  AlbumArtistListSortBy by,
  AlbumArtistListSortOrder order,
) =>
    by == AlbumArtistListSortBy.count && order == AlbumArtistListSortOrder.desc;

class AppAlbumArtistListTopBar extends StatefulWidget {
  final AlbumArtistListController controller;
  const AppAlbumArtistListTopBar({super.key, required this.controller});

  @override
  State<AppAlbumArtistListTopBar> createState() =>
      _AppAlbumArtistListTopBarState();
}

class _AppAlbumArtistListTopBarState extends State<AppAlbumArtistListTopBar> {
  final _sourceKey = GlobalKey();
  final _sortKey = GlobalKey();

  AlbumArtistListController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    // ⭐ 右侧给窗口按钮组让位（2026-10-09）
    final localCtrlW = PcWindowScope.of(context)?.titleBarControlsWidth ?? 0;
    final localHintKey = controller.keyType.trim().toLowerCase() == 'artist'
        ? 'music_artist_list_search_hint'
        : 'music_album_list_search_hint';
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 16 + localCtrlW, 0),
      child: SizedBox(
        height: 60.0,
        child: Row(
          children: <Widget>[
            Expanded(
              child: MusicSearchField(
                searchText: controller.searchText,
                onChanged: controller.onSearchChanged,
                onClear: controller.clearSearch,
                hintText: localHintKey.tr,
                defaultExpanded: true,
              ),
            ),
            const SizedBox(width: 10.0),
            MusicSortButton<AlbumArtistListSortBy, AlbumArtistListSortOrder>(
              buttonKey: _sortKey,
              sortBy: controller.sortBy,
              sortOrder: controller.sortOrder,
              specs: _albumSortSpecs,
              onSort: controller.setSort,
              isDefault: _albumSortIsDefault,
            ),
            const SizedBox(width: 10.0),
            _buildSourceButton(context, _sourceKey, controller),
          ],
        ),
      ),
    );
  }
}

class AlbumArtistListTopBar extends StatefulWidget {
  final AlbumArtistListController controller;
  const AlbumArtistListTopBar({super.key, required this.controller});

  @override
  State<AlbumArtistListTopBar> createState() => _AlbumArtistListTopBarState();
}

class _AlbumArtistListTopBarState extends State<AlbumArtistListTopBar> {
  final _sourceKey = GlobalKey();
  final _sortKey = GlobalKey();

  AlbumArtistListController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    // ⭐ 右侧给窗口按钮组让位（2026-10-09）
    final localCtrlW = PcWindowScope.of(context)?.titleBarControlsWidth ?? 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 16 + localCtrlW, 0),
      child: SizedBox(
        height: 50.0,
        child: Row(
          children: <Widget>[
            _buildSourceButton(context, _sourceKey, controller),
            const SizedBox(width: 4.0),
            MusicSortButton<AlbumArtistListSortBy, AlbumArtistListSortOrder>(
              buttonKey: _sortKey,
              sortBy: controller.sortBy,
              sortOrder: controller.sortOrder,
              specs: _albumSortSpecs,
              onSort: controller.setSort,
              isDefault: _albumSortIsDefault,
            ),
            const SizedBox(width: 4.0),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: SizedBox(
                    width: double.infinity,
                    child: AlbumArtistListSearchBar(controller: controller),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildSourceButton(
  BuildContext context,
  GlobalKey sourceKey,
  AlbumArtistListController controller,
) {
  return Obx(() {
    final localCount = controller.selectedPaths.length;
    return MusicSquareButton(
      tooltip: 'source'.tr,
      onTap: () {
        if (DeviceUtils.isMobile) {
          _openSourceSheet(context, controller);
        } else {
          PopupMenuUtil.showBelowButton<void>(
            context: context,
            buttonKey: sourceKey,
            items: [
              PopupMenuItem(
                enabled: false,
                padding: EdgeInsets.fromLTRB(0, 0, 0, 0),
                child: SizedBox(
                  width: 350.0,
                  child: AlbumArtistListSourcePanel(controller: controller),
                ),
              ),
            ],
          );
        }
      },
      key: sourceKey,
      icon: Icons.source_outlined,
      active: localCount > 0,
    );
  });
}

Future<void> _openSourceSheet(
  BuildContext context,
  AlbumArtistListController controller,
) async {
  await showModalBottomSheet<void>(
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    context: context,
    builder: (ctx) {
      return DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.25,
        maxChildSize: 0.75,
        expand: false,
        builder: (context, scrollController) {
          return Material(
            color: Theme.of(context).colorScheme.surface,
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: AlbumArtistListSourcePanel(controller: controller),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class AlbumArtistListSourcePanel extends StatelessWidget {
  final AlbumArtistListController controller;
  const AlbumArtistListSourcePanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => MusicSourcePanel<MusicListPathItem>(
    availablePaths: controller.availablePaths,
    pathOf: (item) => item.path,
    isValid: (item) => item.valid,
    isSelected: (item) => controller.selectedPaths.contains(item.path),
    onToggle: (item, selected) {
      if (selected) {
        if (!controller.selectedPaths.contains(item.path)) {
          controller.selectedPaths.add(item.path);
        }
      } else {
        controller.selectedPaths.remove(item.path);
      }
      controller.refreshList(showLoading: false);
    },
    onReset: () {
      controller.selectedPaths.clear();
      controller.refreshList(showLoading: false);
    },
  );
}

class AlbumArtistListSearchBar extends StatelessWidget {
  final AlbumArtistListController controller;
  const AlbumArtistListSearchBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final localType = controller.keyType.trim().toLowerCase();
    final localHintKey = localType == 'artist'
        ? 'music_artist_list_search_hint'
        : 'music_album_list_search_hint';
    return MusicSearchField(
      searchText: controller.searchText,
      onChanged: controller.onSearchChanged,
      onClear: controller.clearSearch,
      hintText: localHintKey.tr,
    );
  }
}
