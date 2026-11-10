import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../controller/cola_list_controller.dart';
import './cola_list_item.dart';

class MusicListGrid extends StatelessWidget {
  final MusicListController controller;
  const MusicListGrid({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final desiredWidth = 115.0;
        final maxWidth = constraints.crossAxisExtent;
        final spacing = 4.0;
        final crossAxisCount = (maxWidth / desiredWidth).floor().clamp(2, 10);
        final totalSpacing = spacing * (crossAxisCount - 1);
        final itemWidth = ((maxWidth - totalSpacing) / crossAxisCount)
            .floorToDouble();
        final coverSize = itemWidth * 1;
        final estimatedHeight = coverSize + 56;
        final aspectRatio = itemWidth / estimatedHeight;

        return SliverGrid(
          delegate: SliverChildBuilderDelegate((context, idx) {
            final item = controller.items[idx];
            return Obx(() {
              final selected = controller.selectedItems.contains(item.id);
              final selectionMode = controller.isMultiSelectMode.value;
              return MusicItemCard(
                width: itemWidth,
                selectionMode: selectionMode,
                selected: selected,
                onToggleSelected: () => controller.toggleSelection(item.id),
                key: ValueKey('music_item_${item.id}'),
                item: item,
                coverSize: coverSize,
                controller: controller,
              );
            });
          }, childCount: controller.items.length),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            crossAxisCount: crossAxisCount,
            childAspectRatio: aspectRatio,
          ),
        );
      },
    );
  }
}

class MusicListFooter extends StatelessWidget {
  final MusicListController controller;
  const MusicListFooter({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 翻页 / 自动加载过程中显示进度
      if (controller.loadingMore.value || controller.loading.value) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: CircularProgressIndicator(),
          ),
        );
      }

      final totalPages = controller.totalPages.value;
      final page = controller.page.value;
      // 只有一页（或还没拿到分页信息）时不显示翻页控件
      if (totalPages <= 1) {
        return const SizedBox.shrink();
      }

      final hasNext = page < totalPages;
      final hasPrev = page > 1;
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 第一页不显示「上一页」
            if (hasPrev)
              OutlinedButton.icon(
                onPressed: () => controller.prevPage().catchError((_) {}),
                label: Text('music_list_prev_page'.tr),
                icon: const Icon(Icons.chevron_left, size: 18.0),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: Text(
                'music_list_page_of'.trParams({
                  'page': '$page',
                  'total': '$totalPages',
                }),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            // 最后一页不显示「下一页」
            if (hasNext)
              OutlinedButton.icon(
                onPressed: () => controller.nextPage().catchError((_) {}),
                label: Text('music_list_next_page'.tr),
                icon: const Icon(Icons.chevron_right, size: 18.0),
              ),
          ],
        ),
      );
    });
  }
}
