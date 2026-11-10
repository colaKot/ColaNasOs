import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../../compat/sort_menu.dart';
import '../../controller/cola_list_controller.dart';

/// 主列表排序菜单：菜单内容由选项表生成，不逐个手写 MenuItemButton。
class MusicListSortMenu extends StatelessWidget {
  const MusicListSortMenu({super.key, required this.controller});

  final MusicListController controller;

  static const List<SortMenuChoice<MusicListSortBy, MusicListSortOrder>>
  _choices = <SortMenuChoice<MusicListSortBy, MusicListSortOrder>>[
    SortMenuChoice(
      MusicListSortBy.title,
      MusicListSortOrder.asc,
      'music_list_sort_title_asc',
    ),
    SortMenuChoice(
      MusicListSortBy.title,
      MusicListSortOrder.desc,
      'music_list_sort_title_desc',
    ),
    SortMenuChoice(
      MusicListSortBy.year,
      MusicListSortOrder.desc,
      'music_list_sort_year_desc',
      dividerBefore: true,
    ),
    SortMenuChoice(
      MusicListSortBy.year,
      MusicListSortOrder.asc,
      'music_list_sort_year_asc',
    ),
    SortMenuChoice(
      MusicListSortBy.duration,
      MusicListSortOrder.desc,
      'music_list_sort_duration_desc',
      dividerBefore: true,
    ),
    SortMenuChoice(
      MusicListSortBy.duration,
      MusicListSortOrder.asc,
      'music_list_sort_duration_asc',
    ),
    SortMenuChoice(
      MusicListSortBy.ctime,
      MusicListSortOrder.desc,
      'create_time_desc',
      dividerBefore: true,
    ),
    SortMenuChoice(
      MusicListSortBy.ctime,
      MusicListSortOrder.asc,
      'create_time_asc',
    ),
    SortMenuChoice(
      MusicListSortBy.favoriteTime,
      MusicListSortOrder.desc,
      'music_list_sort_favorite_time_desc',
      dividerBefore: true,
    ),
    SortMenuChoice(
      MusicListSortBy.favoriteTime,
      MusicListSortOrder.asc,
      'music_list_sort_favorite_time_asc',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final favoriteOnly = controller.isFavoriteList;
      final visible = <SortMenuChoice<MusicListSortBy, MusicListSortOrder>>[
        for (final choice in _choices)
          if (_isFavoriteOption(choice) ? favoriteOnly : true) choice,
      ];

      return CustomHoverMenuAnchor(
        menuChildren: buildSortMenuItems<MusicListSortBy, MusicListSortOrder>(
          currentBy: controller.sortBy.value,
          currentOrder: controller.sortOrder.value,
          choices: visible,
          onPick: controller.setSort,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.sort_by_alpha, size: 18.0),
            const SizedBox(width: 6.0),
            Text('sort'.tr),
          ],
        ),
      );
    });
  }

  static bool _isFavoriteOption(
    SortMenuChoice<MusicListSortBy, MusicListSortOrder> choice,
  ) => choice.by == MusicListSortBy.favoriteTime;
}
