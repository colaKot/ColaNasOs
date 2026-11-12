import 'dart:async';

import '../../compat/ui_kit.dart';
import '../../compat/cola_custom_colors.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../detail/controller/music_detail_router.dart';
import '../../compat/base_components.dart';
import '../../sub_list/view/cola_sub_list_overlay.dart';
import '../../compat/cola_device_utils.dart';
import '../../shared/music_paging.dart';
import '../../shared/music_primitives.dart';
import '../controller/cola_playlist_controller.dart';
import 'parts/cola_playlist_dialogs.dart';
import 'parts/cola_playlist_card.dart';
import 'parts/cola_playlist_top_bar.dart';

class PlayListListView extends StatefulWidget {
  final bool selectionMode;
  const PlayListListView({super.key, this.selectionMode = false});

  @override
  State<PlayListListView> createState() => _PlayListListViewState();
}

class _PlayListListViewState extends State<PlayListListView> {
  /// controller 的 tag 必须**整个生命周期不变**。
  ///
  /// 以前是 `'music_play_list_${DateTime.now().microsecondsSinceEpoch}'` 写在
  /// `build()` 里：每次重建都生成新 tag ⇒ GetBuilder 建一个新 controller、
  /// 把旧的 dispose 掉。旧 controller 的 RxList 一旦 close，内层 Obx 就再也
  /// 订阅不上，直接抛「improper use of a GetX」；顺带还丢滚动位置、重复拉列表。
  final String _tag =
      'music_play_list_${DateTime.now().microsecondsSinceEpoch}';

  bool get selectionMode => widget.selectionMode;

  /// 详情页关掉时刷新列表：歌单详情里「移出歌单」会改曲目数，不刷新的话
  /// 返回后卡片上的数字还是旧的。
  void _onDetailStackChanged() {
    if (MusicDetailRouter.instance.active || !mounted) return;
    if (!Get.isRegistered<PlayListController>(tag: _tag)) return;
    unawaited(Get.find<PlayListController>(tag: _tag).refreshLists());
  }

  /// RxList 不是 ChangeNotifier，只能用 GetX 的 ever 订阅
  Worker? _routerWorker;

  @override
  void initState() {
    super.initState();
    _routerWorker = ever<List<MusicDetailTarget>>(
      MusicDetailRouter.instance.stack,
      (_) => _onDetailStackChanged(),
    );
  }

  @override
  void dispose() {
    _routerWorker?.dispose();
    _routerWorker = null;
    super.dispose();
  }

  /// 选择模式的头部：窄屏用「关闭 + 标题」，宽屏交给完整工具条。
  Widget _selectionHeader(
    BuildContext context,
    PlayListController ctrl, {
    required bool compact,
  }) {
    if (!compact) {
      return PlayListTopBar(controller: ctrl, selectionMode: true);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 44,
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: 'back'.tr,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                'music_playlist_select'.tr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Get.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 普通浏览模式的头部：窄屏叠一层与系统状态栏同色的底。
  Widget _browseHeader(
    PlayListController ctrl, {
    required bool compact,
    required Color barColor,
  }) {
    if (!compact) {
      return PlayListTopBar(controller: ctrl, selectionMode: false);
    }
    return ColoredBox(
      color: barColor,
      child: SafeArea(
        bottom: false,
        child: AppPlayListTopBar(controller: ctrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localCompactLayout = DeviceUtils.isPhone(context);
    return GetBuilder<PlayListController>(
      tag: _tag,
      init: PlayListController(),
      dispose: (_) => Get.delete<PlayListController>(tag: _tag),
      builder: (ctrl) {
        final localTheme = Theme.of(context);
        final localExtendedPalette = localTheme.extension<CustomColors>();
        final localBarColor =
            localExtendedPalette?.oprationBarBgColor ??
            localTheme.colorScheme.surface;
        final localOverlayCtrl = selectionMode
            ? null
            : (Get.isRegistered<PlayListOverlayController>()
                  ? Get.find<PlayListOverlayController>()
                  : Get.put(PlayListOverlayController()));

        final localGrid = MusicCardGrid(
          items: ctrl.items,
          compact: localCompactLayout,
          itemBuilder: (context, item, index) => PlayListListCard(
            item: item,
            selectionMode: selectionMode,
            // 点歌单进三级页（右侧内容区，左栏不动），和专辑详情同形态
            onOpen: selectionMode
                ? () => Navigator.of(context).pop(item)
                : () => MusicDetailRouter.instance.open(
                    MusicDetailTarget.playlist(
                      listId: item.id,
                      name: item.name,
                    ),
                  ),
            onRename: () => PlayListDialogs.showRenameDialog(
              context,
              controller: ctrl,
              item: item,
            ),
            onDelete: () => PlayListDialogs.confirmDelete(
              context,
              controller: ctrl,
              item: item,
            ),
          ),
          footer: MusicPagedListFooter(
            isLoading: ctrl.isLoading,
            hasMore: ctrl.hasMore,
            onLoadMore: ctrl.loadMore,
            noMoreText: 'music_playlist_no_more'.tr,
            loadMoreText: 'music_playlist_load_more'.tr,
          ).padded,
        );

        final localList = Column(
          children: <Widget>[
            selectionMode
                ? _selectionHeader(
                    context,
                    ctrl,
                    compact: localCompactLayout,
                  )
                : _browseHeader(
                    ctrl,
                    compact: localCompactLayout,
                    barColor: localBarColor,
                  ),
            Expanded(
              child: SafeArea(
                top: false,
                child: MusicAsyncListState(
                  loading: ctrl.isLoading,
                  isEmpty: () => ctrl.items.isEmpty,
                  empty: const MusicEmptyState(),
                  emptyBuilder: selectionMode
                      ? (_) => Center(
                          child: CustomButton(
                            text: 'create'.tr,
                            icon: const Icon(Icons.add),
                            onPressed: () async {
                              final localItem =
                                  await PlayListDialogs.showCreateForSelection(
                                    context,
                                    controller: ctrl,
                                  );
                              if (localItem != null && context.mounted) {
                                Navigator.of(context).pop(localItem);
                              }
                            },
                          ),
                        )
                      : null,
                  // ⚠️ 这个 Obx 必须**自己**读一个 observable。
                  // slivers() 内部只在「有数据」时才真的读 items[i]；列表为空时
                  // 整条链上一个 Rx 都没读到，GetX 就会抛「improper use of a GetX」。
                  // 这里先把 length 读出来并用它决定 slivers，订阅点就稳了。
                  child: Obx(() {
                    final count = ctrl.items.length;
                    return CustomScrollView(
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

        if (selectionMode) return localList;
        final localBody = MusicOverlayHost(
          backgroundColor: localExtendedPalette?.mainContentBgColor,
          active: localOverlayCtrl!.active,
          overlayBuilder: (payload) => MusicSubListOverlay(
            onClose: ctrl.closeList,
            name: '${'music_menu_library_playlists'.tr}-${payload.name}',
            listId: payload.listId,
            keyType: 'playlist',
            key: ValueKey('playlist_music_list_${payload.listId}'),
          ),
          child: localList,
        );
        if (!localCompactLayout) return localBody;
        return MusicSystemUiOverlay(barColor: localBarColor, child: localBody);
      },
    );
  }
}
