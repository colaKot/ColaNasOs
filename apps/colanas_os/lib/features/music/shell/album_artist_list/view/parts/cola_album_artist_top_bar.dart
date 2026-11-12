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

typedef _SortBy = AlbumArtistListSortBy;
typedef _SortOrder = AlbumArtistListSortOrder;

/// 排序菜单的候选表。顺序即弹出菜单里的顺序，`dividerBefore` 控制分组横线。
const List<MusicSortSpec<_SortBy, _SortOrder>> _sortMenu =
    <MusicSortSpec<_SortBy, _SortOrder>>[
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

bool _isDefaultSort(_SortBy by, _SortOrder order) =>
    by == AlbumArtistListSortBy.count && order == AlbumArtistListSortOrder.desc;

/// 顶栏尾部的操作入口，按枚举顺序声明即可调整排布。
enum _ToolbarEntry { sort, source }

const List<_ToolbarEntry> _phoneEntries = <_ToolbarEntry>[
  _ToolbarEntry.sort,
  _ToolbarEntry.source,
];

const List<_ToolbarEntry> _wideEntries = <_ToolbarEntry>[
  _ToolbarEntry.source,
  _ToolbarEntry.sort,
];

Widget _entryOf(AlbumArtistListController controller, _ToolbarEntry entry) =>
    switch (entry) {
      _ToolbarEntry.sort => _SortEntry(controller: controller),
      _ToolbarEntry.source => _SourceEntry(controller: controller),
    };

List<Widget> _entryStrip(
  AlbumArtistListController controller,
  List<_ToolbarEntry> order,
  double gap,
) {
  final strip = <Widget>[];
  for (final entry in order) {
    if (strip.isNotEmpty) strip.add(SizedBox(width: gap));
    strip.add(_entryOf(controller, entry));
  }
  return strip;
}

/// 顶栏外壳：统一处理窗口按钮让位与固定高度。
class _TopBarFrame extends StatelessWidget {
  const _TopBarFrame({required this.height, required this.children});

  final double height;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final controlsWidth = PcWindowScope.of(context)?.titleBarControlsWidth ?? 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 16 + controlsWidth, 0),
      child: SizedBox(
        height: height,
        child: Row(children: children),
      ),
    );
  }
}

/// 手机端顶栏：搜索框占满剩余宽度，操作入口靠右。
class AppAlbumArtistListTopBar extends StatelessWidget {
  final AlbumArtistListController controller;
  const AppAlbumArtistListTopBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => _TopBarFrame(
    height: 60.0,
    children: <Widget>[
      Expanded(child: _SearchField(controller: controller, expanded: true)),
      const SizedBox(width: 10.0),
      ..._entryStrip(controller, _phoneEntries, 10.0),
    ],
  );
}

/// 桌面前顶栏：入口在左，搜索框限制最大宽度后贴右。
class AlbumArtistListTopBar extends StatelessWidget {
  final AlbumArtistListController controller;
  const AlbumArtistListTopBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => _TopBarFrame(
    height: 50.0,
    children: <Widget>[
      ..._entryStrip(controller, _wideEntries, 4.0),
      const SizedBox(width: 4.0),
      Expanded(
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 200.0,
            child: _SearchField(controller: controller),
          ),
        ),
      ),
    ],
  );
}

/// 排序入口：选中项与默认值不一致时高亮。
class _SortEntry extends StatefulWidget {
  const _SortEntry({required this.controller});

  final AlbumArtistListController controller;

  @override
  State<_SortEntry> createState() => _SortEntryState();
}

class _SortEntryState extends State<_SortEntry> {
  final GlobalKey _anchor = GlobalKey();

  @override
  Widget build(BuildContext context) => MusicSortButton<_SortBy, _SortOrder>(
    buttonKey: _anchor,
    sortBy: widget.controller.sortBy,
    sortOrder: widget.controller.sortOrder,
    specs: _sortMenu,
    onSort: widget.controller.setSort,
    isDefault: _isDefaultSort,
  );
}

/// 来源筛选入口：桌面弹菜单、手机弹底部抽屉，两者共用同一份面板内容。
class _SourceEntry extends StatefulWidget {
  const _SourceEntry({required this.controller});

  final AlbumArtistListController controller;

  @override
  State<_SourceEntry> createState() => _SourceEntryState();
}

class _SourceEntryState extends State<_SourceEntry> {
  final GlobalKey _anchor = GlobalKey();

  AlbumArtistListController get controller => widget.controller;

  @override
  Widget build(BuildContext context) => Obx(() {
    final picked = controller.selectedPaths.isNotEmpty;
    return MusicSquareButton(
      key: _anchor,
      icon: Icons.source_outlined,
      tooltip: 'source'.tr,
      active: picked,
      onTap: () => _show(context),
    );
  });

  void _show(BuildContext context) {
    if (DeviceUtils.isMobile) {
      showModalBottomSheet<void>(
        useSafeArea: true,
        showDragHandle: true,
        isScrollControlled: true,
        context: context,
        builder: (_) => _SourceSheet(controller: controller),
      );
      return;
    }
    PopupMenuUtil.showBelowButton<void>(
      context: context,
      buttonKey: _anchor,
      items: <PopupMenuEntry<void>>[
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: 350.0,
            child: _SourcePanel(controller: controller),
          ),
        ),
      ],
    );
  }
}

/// 窄屏底部抽屉：高度可拖拽，内容居中并限制最大宽度。
class _SourceSheet extends StatelessWidget {
  const _SourceSheet({required this.controller});

  final AlbumArtistListController controller;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.45,
    minChildSize: 0.25,
    maxChildSize: 0.75,
    expand: false,
    builder: (sheetContext, sheetScroll) => Material(
      color: Theme.of(sheetContext).colorScheme.surface,
      child: ListView(
        controller: sheetScroll,
        padding: const EdgeInsets.only(bottom: 12),
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: _SourcePanel(controller: controller),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 来源面板：把多选、重置与刷新时机收在一处，弹菜单和抽屉都复用它。
class _SourcePanel extends StatelessWidget {
  const _SourcePanel({required this.controller});

  final AlbumArtistListController controller;

  @override
  Widget build(BuildContext context) => MusicSourcePanel<MusicListPathItem>(
    availablePaths: controller.availablePaths,
    pathOf: (item) => item.path,
    isValid: (item) => item.valid,
    isSelected: (item) => controller.selectedPaths.contains(item.path),
    onToggle: _toggle,
    onReset: _reset,
  );

  void _toggle(MusicListPathItem item, bool selected) {
    final picked = controller.selectedPaths;
    if (selected) {
      if (!picked.contains(item.path)) picked.add(item.path);
    } else {
      picked.remove(item.path);
    }
    controller.refreshList(showLoading: false);
  }

  void _reset() {
    controller.selectedPaths.clear();
    controller.refreshList(showLoading: false);
  }
}

/// 搜索框：提示文案随聚合维度切换。
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, this.expanded = false});

  final AlbumArtistListController controller;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final hintKey = controller.keyType.trim().toLowerCase() == 'artist'
        ? 'music_artist_list_search_hint'
        : 'music_album_list_search_hint';
    return MusicSearchField(
      searchText: controller.searchText,
      onChanged: controller.onSearchChanged,
      onClear: controller.clearSearch,
      hintText: hintKey.tr,
      defaultExpanded: expanded,
    );
  }
}
