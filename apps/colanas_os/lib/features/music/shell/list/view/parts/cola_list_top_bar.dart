import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart' show NasStyleContext;

import '../../../compat/ui_kit.dart';
import '../../../compat/host.dart';
import '../../../compat/getx.dart';
import '../../../shared/music_primitives.dart';
import '../../../shared/music_dialogs.dart';
import '../../../shared/music_sort.dart';
import '../../controller/cola_list_controller.dart';
import '../../models/cola_list_models.dart';

const _musicSortSpecs = <MusicSortSpec<MusicListSortBy, MusicListSortOrder>>[
  MusicSortSpec(
    by: MusicListSortBy.title,
    order: MusicListSortOrder.asc,
    labelKey: 'music_list_sort_title_asc',
    icon: Icons.sort_by_alpha_outlined,
  ),
  MusicSortSpec(
    by: MusicListSortBy.title,
    order: MusicListSortOrder.desc,
    labelKey: 'music_list_sort_title_desc',
    icon: Icons.sort_by_alpha_outlined,
  ),
  MusicSortSpec(
    by: MusicListSortBy.year,
    order: MusicListSortOrder.desc,
    labelKey: 'music_list_sort_year_desc',
    icon: Icons.calendar_today_outlined,
    dividerBefore: true,
  ),
  MusicSortSpec(
    by: MusicListSortBy.year,
    order: MusicListSortOrder.asc,
    labelKey: 'music_list_sort_year_asc',
    icon: Icons.calendar_today_outlined,
  ),
  MusicSortSpec(
    by: MusicListSortBy.duration,
    order: MusicListSortOrder.desc,
    labelKey: 'music_list_sort_duration_desc',
    icon: Icons.timer_outlined,
    dividerBefore: true,
  ),
  MusicSortSpec(
    by: MusicListSortBy.duration,
    order: MusicListSortOrder.asc,
    labelKey: 'music_list_sort_duration_asc',
    icon: Icons.timer_outlined,
  ),
  MusicSortSpec(
    by: MusicListSortBy.ctime,
    order: MusicListSortOrder.desc,
    labelKey: 'create_time_desc',
    icon: Icons.access_time_outlined,
    dividerBefore: true,
  ),
  MusicSortSpec(
    by: MusicListSortBy.ctime,
    order: MusicListSortOrder.asc,
    labelKey: 'create_time_asc',
    icon: Icons.access_time_outlined,
  ),
  MusicSortSpec(
    by: MusicListSortBy.favoriteTime,
    order: MusicListSortOrder.desc,
    labelKey: 'music_list_sort_favorite_time_desc',
    icon: Icons.favorite_outlined,
    dividerBefore: true,
  ),
  MusicSortSpec(
    by: MusicListSortBy.favoriteTime,
    order: MusicListSortOrder.asc,
    labelKey: 'music_list_sort_favorite_time_asc',
    icon: Icons.favorite_outlined,
  ),
];

bool _musicSortIsDefault(MusicListSortBy by, MusicListSortOrder order) =>
    by == MusicListSortBy.mtime && order == MusicListSortOrder.desc;

class AppMusicListTopBar extends StatefulWidget {
  final MusicListController controller;
  const AppMusicListTopBar({super.key, required this.controller});

  @override
  State<AppMusicListTopBar> createState() => _AppMusicListTopBarState();
}

class _AppMusicListTopBarState extends State<AppMusicListTopBar> {
  final _sourceKey = GlobalKey();
  final _sortKey = GlobalKey();

  MusicListController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    // ⭐ 右侧给窗口按钮组让位（2026-10-09）
    final localCtrlW = PcWindowScope.of(context)?.titleBarControlsWidth ?? 0;
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
                hintText: 'music_list_search_hint'.tr,
                onSubmitted: controller.setSearchImmediate,
                defaultExpanded: true,
                height: 38,
              ),
            ),
            const SizedBox(width: 8.0),
            MusicSortButton<MusicListSortBy, MusicListSortOrder>(
              buttonKey: _sortKey,
              sortBy: controller.sortBy,
              sortOrder: controller.sortOrder,
              specs: _musicSortSpecs,
              onSort: controller.setSort,
              isDefault: _musicSortIsDefault,
              onlyIf: (spec) =>
                  spec.by != MusicListSortBy.favoriteTime ||
                  controller.isFavoriteList,
            ),
            const SizedBox(width: 8.0),
            _buildSourceButton(context, _sourceKey, controller, useSheet: true),
          ],
        ),
      ),
    );
  }
}

class MusicListTopBar extends StatefulWidget {
  final MusicListController controller;
  const MusicListTopBar({super.key, required this.controller});

  @override
  State<MusicListTopBar> createState() => _MusicListTopBarState();
}

class _MusicListTopBarState extends State<MusicListTopBar> {
  final _sourceKey = GlobalKey();
  final _sortKey = GlobalKey();

  MusicListController get controller => widget.controller;

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
            MusicSortButton<MusicListSortBy, MusicListSortOrder>(
              buttonKey: _sortKey,
              sortBy: controller.sortBy,
              sortOrder: controller.sortOrder,
              specs: _musicSortSpecs,
              onSort: controller.setSort,
              isDefault: _musicSortIsDefault,
              onlyIf: (spec) =>
                  spec.by != MusicListSortBy.favoriteTime ||
                  controller.isFavoriteList,
            ),
            const SizedBox(width: 10.0),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  // 200 太窄（三四个字就溢出），420 仍嫌短；620 能放下整句歌名
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: SizedBox(
                    width: double.infinity,
                    child: MusicListSearchBar(controller: controller),
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
  MusicListController controller, {
  bool useSheet = false,
}) {
  return Obx(() {
    final localCount = controller.selectedPaths.length;
    return MusicSquareButton(
      tooltip: 'source'.tr,
      onTap: () {
        if (useSheet) {
          showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            useSafeArea: true,
            builder: (ctx) {
              return Material(
                color: Color.alphaBlend(
                  ctx.nasStyle.panelColor,
                  ctx.nasStyle.baseColor,
                ),
                child: MusicListSourcePanel(controller: controller),
              );
            },
          );
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
                  child: MusicListSourcePanel(controller: controller),
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

class MusicListSourcePanel extends StatelessWidget {
  final MusicListController controller;
  const MusicListSourcePanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => MusicSourcePanel<MusicListPathItem>(
    availablePaths: controller.availablePaths,
    pathOf: (item) => item.path,
    isValid: (item) => item.valid,
    isSelected: (item) => controller.selectedPaths.contains(item.path),
    onToggle: (item, selected) {
      if (selected) {
        controller.selectedPaths.add(item.path);
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

class MusicListSearchBar extends StatelessWidget {
  final MusicListController controller;
  const MusicListSearchBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => MusicSearchField(
    searchText: controller.searchText,
    onChanged: controller.onSearchChanged,
    onClear: controller.clearSearch,
    onSubmitted: controller.setSearchImmediate,
    hintText: 'music_list_search_hint'.tr,
    // 桌面端常显输入框（以前只显示一个搜索图标，点了才展开）
    defaultExpanded: true,
    height: 36,
  );
}
