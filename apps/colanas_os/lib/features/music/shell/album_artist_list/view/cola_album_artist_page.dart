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
    this.initialSortOrder = AlbumArtistListSortOrder.desc,
    this.initialSortBy = AlbumArtistListSortBy.count,
  });

  @override
  State<AlbumArtistListPage> createState() => _AlbumArtistCollectionPageState();
}

class _AlbumArtistCollectionPageState extends State<AlbumArtistListPage> {
  final ScrollController _scroll = ScrollController();
  late final String _controllerTag = _buildTag();

  String _buildTag() =>
      'music_key_list_${widget.keyType}_${widget.initialSortBy}'
      '_${widget.initialSortOrder}_${UniqueKey()}';

  AlbumArtistListController? get _listController =>
      Get.isRegistered<AlbumArtistListController>(tag: _controllerTag)
      ? Get.find<AlbumArtistListController>(tag: _controllerTag)
      : null;

  @override
  void initState() {
    super.initState();
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
    _scroll.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_handleScroll);
    _scroll.dispose();
    if (Get.isRegistered<AlbumArtistListController>(tag: _controllerTag)) {
      Get.delete<AlbumArtistListController>(tag: _controllerTag);
    }
    if (Get.isRegistered<MusicSubListOverlayController>()) {
      Get.find<MusicSubListOverlayController>().close();
    }
    super.dispose();
  }

  void _handleScroll() {
    final controller = _listController;
    if (controller == null) return;
    attachPagedScroll(
      _scroll,
      loadMore: () => controller.loadMore(fromAuto: true).catchError((_) {}),
      threshold: 360,
    );
  }

  MusicSubListOverlayController _overlayController() =>
      Get.isRegistered<MusicSubListOverlayController>()
      ? Get.find<MusicSubListOverlayController>()
      : Get.put(MusicSubListOverlayController());

  /// 点开一个聚合分组：专辑/歌手交给三级详情路由，其余维度仍走内容区遮罩。
  void _openGroup(MusicSubListOverlayController overlay, String groupName) {
    final type = widget.keyType.trim().toLowerCase();
    if (type == 'album' || type == 'artist') {
      MusicDetailRouter.instance.open(
        type == 'album'
            ? MusicDetailTarget.album(name: groupName)
            : MusicDetailTarget.artist(groupName),
      );
      return;
    }
    overlay.open(keyType: widget.keyType, name: groupName);
  }

  @override
  Widget build(BuildContext context) {
    return GetBuilder<AlbumArtistListController>(
      tag: _controllerTag,
      builder: (controller) {
        final theme = Theme.of(context);
        final palette = theme.extension<CustomColors>();
        final overlay = _overlayController();
        return MusicOverlayHost<MusicSubListPayload>(
          active: overlay.active,
          overlayBuilder: (payload) => MusicSubListOverlay(
            key: ValueKey(
              'music_sub_list_${payload.keyType}_${payload.seriesIndexId ?? 0}_${payload.name}',
            ),
            name: payload.name,
            keyType: payload.keyType,
            onClose: overlay.close,
          ),
          child: _AlbumArtistListBody(
            controller: controller,
            barColor: palette?.oprationBarBgColor ?? theme.colorScheme.surface,
            scrollController: _scroll,
            onOpenGroup: (name) => _openGroup(overlay, name),
          ),
        );
      },
    );
  }
}

/// 顶栏 + 列表主体；窄屏顶栏铺一层底色，宽屏交给页面自身背景。
class _AlbumArtistListBody extends StatelessWidget {
  const _AlbumArtistListBody({
    required this.controller,
    required this.barColor,
    required this.scrollController,
    required this.onOpenGroup,
  });

  final AlbumArtistListController controller;
  final Color barColor;
  final ScrollController scrollController;
  final ValueChanged<String> onOpenGroup;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      if (DeviceUtils.isPhone(context))
        ColoredBox(
          color: barColor,
          child: AppAlbumArtistListTopBar(controller: controller),
        )
      else
        AlbumArtistListTopBar(controller: controller),
      Expanded(
        child: MusicAsyncListState(
          loading: controller.loading,
          isEmpty: () => controller.items.isEmpty,
          empty: const MusicEmptyState(),
          overlayOnEmpty: _LetterRail(controller: controller),
          child: Stack(
            children: <Widget>[
              _buildScrollView(),
              _LetterRail(controller: controller),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _buildScrollView() => Scrollbar(
    thumbVisibility: true,
    controller: scrollController,
    child: CustomScrollView(
      controller: scrollController,
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 28, 66),
          sliver: AlbumArtistListGrid(
            controller: controller,
            onOpenSubList: onOpenGroup,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: AlbumArtistListFooter(controller: controller),
          ),
        ),
      ],
    ),
  );
}

/// 右侧字母快捷筛选：只认单个字母或 `#`，点击即立刻搜索。
class _LetterRail extends StatelessWidget {
  const _LetterRail({required this.controller});

  final AlbumArtistListController controller;

  static final RegExp _latinLetter = RegExp(r'^[a-zA-Z]$');

  @override
  Widget build(BuildContext context) => Obx(() {
    final keyword = controller.searchText.value.trim();
    final occupied = _asLetter(keyword);
    final phone = DeviceUtils.isPhone(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: phone
            ? const EdgeInsets.fromLTRB(0, 0, 10, 0)
            : const EdgeInsets.fromLTRB(0, 0, 10, 10),
        child: CustomLetterFilter(
          value: occupied,
          onChanged: (letter) => controller.setSearchImmediate(letter ?? ''),
          centerWhenBoundedHeight: phone,
        ),
      ),
    );
  });

  String? _asLetter(String keyword) {
    if (keyword.length != 1) return null;
    if (keyword == '#' || _latinLetter.hasMatch(keyword)) {
      return keyword.toUpperCase();
    }
    return null;
  }
}
