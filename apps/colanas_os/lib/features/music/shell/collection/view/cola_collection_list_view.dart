import '../../compat/ui_kit.dart';
import '../../compat/cola_custom_colors.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../sub_list/view/cola_sub_list_overlay.dart';
import '../../compat/cola_device_utils.dart';
import '../../shared/music_paging.dart';
import '../../shared/music_primitives.dart';
import '../controller/cola_collection_controller.dart';
import 'parts/cola_collection_card.dart';
import 'parts/cola_collection_dialogs.dart';
import 'parts/cola_collection_top_bar.dart';

class MusicCollectionListView extends StatelessWidget {
  const MusicCollectionListView({super.key});

  @override
  Widget build(BuildContext context) {
    final localCompactLayout = DeviceUtils.isPhone(context);
    const localTag = 'music_collection';
    return GetBuilder<MusicCollectionController>(
      tag: localTag,
      init: MusicCollectionController(),
      dispose: (_) => Get.delete<MusicCollectionController>(tag: localTag),
      builder: (ctrl) {
        final localTheme = Theme.of(context);
        final localExtendedPalette = localTheme.extension<CustomColors>();
        final localBarColor =
            localExtendedPalette?.oprationBarBgColor ??
            localTheme.colorScheme.surface;

        final localGrid = MusicCardGrid(
          items: ctrl.items,
          compact: localCompactLayout,
          itemBuilder: (context, item, index) => MusicCollectionCard(
            collection: item,
            // 统一走内容区遮罩，不再整页 push（会盖住左侧栏）
            onOpen: () => ctrl.openCollection(item),
            onEdit: () => MusicCollectionDialogs.showEditDialog(
              context,
              controller: ctrl,
              collection: item,
            ),
            onDelete: () => MusicCollectionDialogs.confirmDelete(
              context,
              controller: ctrl,
              collection: item,
            ),
          ),
          footer: MusicPagedListFooter(
            isLoading: ctrl.isLoading,
            hasMore: ctrl.hasMore,
            onLoadMore: ctrl.loadMore,
            noMoreText: 'no_more'.tr,
            loadMoreText: 'load_more'.tr,
            textStyle: Theme.of(context).textTheme.bodySmall,
          ).padded,
        );

        final localList = Column(
          children: <Widget>[
            localCompactLayout
                ? ColoredBox(
                    color: localBarColor,
                    child: SafeArea(
                      bottom: false,
                      child: AppMusicCollectionTopBar(controller: ctrl),
                    ),
                  )
                : MusicCollectionTopBar(controller: ctrl),
            Expanded(
              child: SafeArea(
                top: false,
                child: MusicAsyncListState(
                  loading: ctrl.isLoading,
                  isEmpty: () => ctrl.items.isEmpty,
                  empty: const MusicEmptyState(),
                  // 同上：Obx 自己先读一次 length 建立订阅，
                  // 空列表时也不会因为「一个 Rx 都没读到」而抛 improper use。
                  child: Obx(() {
                    final count = ctrl.items.length;
                    return CustomScrollView(
                      controller: ctrl.scrollController,
                      slivers: count == 0
                          ? const <Widget>[]
                          : localGrid.slivers(context),
                    );
                  }),
                ),
              ),
            ),
          ],
        );
        final localBody = MusicOverlayHost(
          backgroundColor: localExtendedPalette?.mainContentBgColor,
          active: ctrl.activeCollection,
          overlayBuilder: (collection) => MusicSubListOverlay(
            onClose: ctrl.closeCollection,
            name: "${'music_collection_title'.tr}-${collection.name}",
            keyType: 'collection',
            key: ValueKey('collection_music_list_${collection.id}'),
            collectionId: collection.id,
          ),
          child: localList,
        );
        if (!localCompactLayout) return localBody;
        return MusicSystemUiOverlay(barColor: localBarColor, child: localBody);
      },
    );
  }
}
