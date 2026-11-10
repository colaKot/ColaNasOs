import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';

import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../../compat/cola_device_utils.dart';
import '../../../shared/music_item_logic.dart';
import '../../../shared/music_paging.dart';
import '../../controller/cola_album_artist_controller.dart';
import 'cola_album_artist_item.dart';

class AlbumArtistListGrid extends StatelessWidget {
  final AlbumArtistListController controller;
  final void Function(String name) onOpenSubList;
  const AlbumArtistListGrid({
    required this.onOpenSubList,
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final metrics = GridMetrics.forWidth(constraints.crossAxisExtent);
        return SliverGrid(
          delegate: SliverChildBuilderDelegate((context, idx) {
            final item = controller.items[idx];
            final card = AlbumArtistItemCard(
              width: metrics.itemWidth,
              onTap: () => onOpenSubList(item.name),
              item: item,
              coverSize: metrics.coverSize,
              badgeLabel: controller.badgeLabel,
            );
            final menuEntries = <ContextMenuEntry>[
              CustomContextMenuItem.create(
                value: 'open',
                onSelected: (_) => onOpenSubList(item.name),
                label: Text('open'.tr),
                icon: const Icon(Icons.open_in_new, size: 18.0),
              ),
              const MenuDivider(),
              CustomContextMenuItem.create(
                value: 'add_to_play_list',
                onSelected: (_) => controller.addToPlayList(item, context),
                label: Text('add_to_play_list'.tr),
                icon: const Icon(Icons.playlist_add, size: 18.0),
              ),
            ];

            if (DeviceUtils.isDesktop || DeviceUtils.isWeb) {
              return ContextMenuUtil.region(child: card, entries: menuEntries);
            }

            return GestureDetector(
              onLongPressStart: (d) {
                ContextMenuUtil.showAtPosition(
                  context,
                  entries: menuEntries,
                  position: d.globalPosition,
                );
              },
              child: card,
            );
          }, childCount: controller.items.length),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            mainAxisSpacing: metrics.spacing,
            crossAxisSpacing: metrics.spacing,
            crossAxisCount: metrics.crossAxisCount,
            childAspectRatio: metrics.aspectRatio,
          ),
        );
      },
    );
  }
}

class AlbumArtistListFooter extends StatelessWidget {
  final AlbumArtistListController controller;
  const AlbumArtistListFooter({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => MusicPagedListFooter(
    isLoading: controller.loadingMore,
    hasMore: controller.hasMore,
    autoLoadFailed: controller.autoLoadFailed,
    onLoadMore: () => controller.loadMore(fromAuto: false).catchError((_) {}),
    noMoreText: 'music_list_no_more'.tr,
    loadMoreText: 'music_list_load_more'.tr,
  );
}
