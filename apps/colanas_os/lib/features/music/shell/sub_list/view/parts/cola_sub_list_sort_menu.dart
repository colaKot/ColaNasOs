import 'dart:async';

import 'package:flutter/material.dart';

import '../../../compat/base_components.dart';
import '../../../compat/getx.dart';
import '../../../compat/sort_menu.dart';
import '../../controller/cola_sub_list_controller.dart';

/// 子列表排序菜单。收藏页额外显示「收藏时间」两项。
class MusicSubListSortMenu extends StatelessWidget {
  const MusicSubListSortMenu({super.key, required this.controller});

  final MusicSubListController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final favorite = controller.isFavorite;
      final choices =
          <SortMenuChoice<MusicSubListSortBy, MusicSubListSortOrder>>[
            SortMenuChoice(
              MusicSubListSortBy.favoriteTime,
              MusicSubListSortOrder.desc,
              'music_list_sort_favorite_time_desc',
              enabled: favorite,
            ),
            SortMenuChoice(
              MusicSubListSortBy.favoriteTime,
              MusicSubListSortOrder.asc,
              'music_list_sort_favorite_time_asc',
              enabled: favorite,
            ),
            SortMenuChoice(
              MusicSubListSortBy.filename,
              MusicSubListSortOrder.asc,
              'music_list_sort_filename_asc',
              dividerBefore: true,
            ),
            SortMenuChoice(
              MusicSubListSortBy.filename,
              MusicSubListSortOrder.desc,
              'music_list_sort_filename_desc',
            ),
            SortMenuChoice(
              MusicSubListSortBy.title,
              MusicSubListSortOrder.asc,
              'music_list_sort_title_asc',
              dividerBefore: true,
            ),
            SortMenuChoice(
              MusicSubListSortBy.title,
              MusicSubListSortOrder.desc,
              'music_list_sort_title_desc',
            ),
            SortMenuChoice(
              MusicSubListSortBy.duration,
              MusicSubListSortOrder.desc,
              'music_list_sort_duration_desc',
              dividerBefore: true,
            ),
            SortMenuChoice(
              MusicSubListSortBy.duration,
              MusicSubListSortOrder.asc,
              'music_list_sort_duration_asc',
            ),
            SortMenuChoice(
              MusicSubListSortBy.ctime,
              MusicSubListSortOrder.desc,
              'create_time_desc',
              dividerBefore: true,
            ),
            SortMenuChoice(
              MusicSubListSortBy.ctime,
              MusicSubListSortOrder.asc,
              'create_time_asc',
            ),
          ];

      return _HoverCircleMenuAnchor(
        tooltip: '',
        menuChildren:
            buildSortMenuItems<MusicSubListSortBy, MusicSubListSortOrder>(
              currentBy: controller.sortBy.value,
              currentOrder: controller.sortOrder.value,
              choices: choices,
              onPick: controller.setSort,
            ),
        icon: Icons.sort_by_alpha,
      );
    });
  }
}

/// 悬停开关：按钮与菜单任一侧仍处于悬停状态时不关闭菜单。
class _HoverGate {
  _HoverGate(this.menu);

  final MenuController menu;
  Timer? _pendingClose;
  bool _onButton = false;
  bool _onMenu = false;

  static const Duration _grace = Duration(milliseconds: 160);

  void enterButton() {
    _onButton = true;
    _cancelClose();
    menu.open();
  }

  void leaveButton() {
    _onButton = false;
    _scheduleClose();
  }

  void enterMenu() {
    _onMenu = true;
    _cancelClose();
  }

  void leaveMenu() {
    _onMenu = false;
    _scheduleClose();
  }

  void _cancelClose() {
    _pendingClose?.cancel();
    _pendingClose = null;
  }

  void _scheduleClose() {
    _cancelClose();
    _pendingClose = Timer(_grace, () {
      if (_onButton || _onMenu) return;
      menu.close();
    });
  }

  void dispose() => _cancelClose();
}

class _HoverCircleMenuAnchor extends StatefulWidget {
  const _HoverCircleMenuAnchor({
    required this.tooltip,
    required this.menuChildren,
    required this.icon,
  });

  final String tooltip;
  final List<Widget> menuChildren;
  final IconData icon;

  @override
  State<_HoverCircleMenuAnchor> createState() => _HoverCircleMenuAnchorState();
}

class _HoverCircleMenuAnchorState extends State<_HoverCircleMenuAnchor> {
  _HoverGate? _gate;

  @override
  void dispose() {
    _gate?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context);
    return MenuAnchor(
      style: _menuStyle(palette),
      menuChildren: <Widget>[
        for (final item in widget.menuChildren)
          MouseRegion(
            onEnter: (_) => _gate?.enterMenu(),
            onExit: (_) => _gate?.leaveMenu(),
            child: item,
          ),
      ],
      builder: (context, menuController, child) {
        final gate = _gate ??= _HoverGate(menuController);
        return MouseRegion(
          onEnter: (_) => gate.enterButton(),
          onExit: (_) => gate.leaveButton(),
          child: CustomIconButton(
            borderRadius: 999,
            borderSide: BorderSide(color: palette.dividerColor),
            icon: widget.icon,
            onPressed: () => menuController.isOpen
                ? menuController.close()
                : menuController.open(),
          ),
        );
      },
      alignmentOffset: const Offset(0, 6),
    );
  }

  static MenuStyle _menuStyle(ThemeData palette) => MenuStyle(
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: palette.dividerColor, width: 1.0),
      ),
    ),
    padding: const WidgetStatePropertyAll(EdgeInsets.fromLTRB(0, 0, 0, 0)),
    backgroundColor: WidgetStatePropertyAll(palette.colorScheme.surface),
  );
}
