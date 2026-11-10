import '../../compat/ui_kit.dart';
import '../../compat/cola_custom_colors.dart';

import 'package:flutter/material.dart';

import '../../compat/getx.dart';
import '../../compat/host.dart';
import '../../compat/cola_device_utils.dart';
import '../../detail/controller/music_detail_router.dart';
import '../../shared/music_paging.dart';
import '../controller/cola_album_artist_controller.dart';
import 'parts/cola_album_artist_grid.dart';
import 'parts/cola_album_artist_top_bar.dart';
import '../../sub_list/controller/cola_sub_list_controller.dart';
import '../../sub_list/view/cola_sub_list_overlay.dart';

class AlbumArtistListPage extends StatefulWidget {
  final String keyType;
  final AlbumArtistListSortOrder initialSortOrder;
  final AlbumArtistListSortBy initialSortBy;
  const AlbumArtistListPage({
    super.key,
    required this.keyType,
    this.initialSortBy = AlbumArtistListSortBy.count,
    this.initialSortOrder = AlbumArtistListSortOrder.desc,
  });

  @override
  State<AlbumArtistListPage> createState() => _AlbumArtistListPageState();
}

class _AlbumArtistListPageState extends State<AlbumArtistListPage> {
  final ScrollController _scrollController = ScrollController();
  late final String _controllerTag;

  @override
  void initState() {
    super.initState();
    _controllerTag =
        'music_key_list_${widget.keyType}_${widget.initialSortBy}_${widget.initialSortOrder}_${UniqueKey()}';
    if (!Get.isRegistered<AlbumArtistListController>(tag: _controllerTag)) {
      Get.put(
        AlbumArtistListController(
          keyType: widget.keyType,
          initialSortOrder: widget.initialSortOrder,
          initialSortBy: widget.initialSortBy,
        ),
        tag: _controllerTag,
      );
    }
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    if (Get.isRegistered<AlbumArtistListController>(tag: _controllerTag)) {
      Get.delete<AlbumArtistListController>(tag: _controllerTag);
    }
    if (Get.isRegistered<MusicSubListOverlayController>()) {
      final overlayCtrl = Get.find<MusicSubListOverlayController>();
      overlayCtrl.close();
    }
    super.dispose();
  }

  void _onScroll() {
    final listState =
        Get.isRegistered<AlbumArtistListController>(tag: _controllerTag)
        ? Get.find<AlbumArtistListController>(tag: _controllerTag)
        : null;
    if (listState == null) return;
    attachPagedScroll(
      _scrollController,
      loadMore: () => listState.loadMore(fromAuto: true).catchError((_) {}),
      threshold: 360,
    );
  }

  Widget _letterFilter(
    BuildContext context,
    AlbumArtistListController listState,
  ) => Obx(() {
    final rawSearch = listState.searchText.value.trim();
    final selectedLetter =
        rawSearch.length == 1 &&
            (rawSearch == '#' || RegExp(r'^[a-zA-Z]$').hasMatch(rawSearch))
        ? rawSearch.toUpperCase()
        : null;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: DeviceUtils.isPhone(context)
            ? const EdgeInsets.fromLTRB(0, 0, 10, 0)
            : const EdgeInsets.fromLTRB(0, 0, 10, 10),
        child: CustomLetterFilter(
          value: selectedLetter,
          onChanged: (v) => listState.setSearchImmediate(v ?? ''),
          centerWhenBoundedHeight: DeviceUtils.isPhone(context),
        ),
      ),
    );
  });

  @override
  Widget build(BuildContext context) {
    return GetBuilder<AlbumArtistListController>(
      tag: _controllerTag,
      builder: (listState) {
        final theme = Theme.of(context);
        final extendedPalette = theme.extension<CustomColors>();
        final barColor =
            extendedPalette?.oprationBarBgColor ?? theme.colorScheme.surface;
        final overlayCtrl = Get.isRegistered<MusicSubListOverlayController>()
            ? Get.find<MusicSubListOverlayController>()
            : Get.put(MusicSubListOverlayController());

        void openSubList(String name) {
          // 专辑 / 歌手改成三级详情页（留在右侧内容区、左栏不动、可返回）。
          // 以前这里是「桌面开 overlay、手机 push 整页」，两种形态都不符合要求。
          final keyType = widget.keyType.trim().toLowerCase();
          if (keyType == 'album' || keyType == 'artist') {
            MusicDetailRouter.instance.open(
              keyType == 'album'
                  ? MusicDetailTarget.album(name: name)
                  : MusicDetailTarget.artist(name),
            );
            return;
          }
          // 只剩「系列 / 其它聚合维度」走内容区遮罩；专辑与歌手已在上面转三级页。
          // 这里不再 `Navigator.push` 整页 —— 那会盖住左侧一二级栏。
          overlayCtrl.open(keyType: widget.keyType, name: name);
        }

        final list = Column(
          children: <Widget>[
            DeviceUtils.isPhone(context)
                ? ColoredBox(
                    color: barColor,
                    child: AppAlbumArtistListTopBar(controller: listState),
                  )
                : AlbumArtistListTopBar(controller: listState),
            Expanded(
              child: MusicAsyncListState(
                loading: listState.loading,
                isEmpty: () => listState.items.isEmpty,
                empty: const MusicEmptyState(),
                overlayOnEmpty: _letterFilter(context, listState),
                child: Stack(
                  children: <Widget>[
                    Scrollbar(
                      thumbVisibility: true,
                      controller: _scrollController,
                      child: CustomScrollView(
                        controller: _scrollController,
                        slivers: <Widget>[
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 28, 66),
                            sliver: AlbumArtistListGrid(
                              controller: listState,
                              onOpenSubList: openSubList,
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
                              child: AlbumArtistListFooter(
                                controller: listState,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _letterFilter(context, listState),
                  ],
                ),
              ),
            ),
          ],
        );

        return MusicOverlayHost<MusicSubListPayload>(
          active: overlayCtrl.active,
          overlayBuilder: (payload) => MusicSubListOverlay(
            onClose: overlayCtrl.close,
            name: payload.name,
            keyType: payload.keyType,
            key: ValueKey(
              'music_sub_list_${payload.keyType}_${payload.seriesIndexId ?? 0}_${payload.name}',
            ),
          ),
          child: list,
        );
      },
    );
  }
}
