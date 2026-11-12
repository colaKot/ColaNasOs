// ignore_for_file: library_private_types_in_public_api

import '../../compat/cola_custom_colors.dart';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../compat/getx.dart';
import '../controller/cola_sub_list_controller.dart';
import 'parts/cola_sub_list_header.dart';
import 'parts/cola_sub_list_overlay_body.dart';
import '../../music_main/controller/cola_main_controller.dart';
import '../../compat/cola_device_utils.dart';
import '../../play_service/app_components/cola_player_floating_bar.dart';
import '../../play_service/play_ctrl_fullscreen/cola_stage_sheet.dart';
import '../../shared/music_paging.dart';

/// 两个子列表容器共用的构造参数契约：字段仍各自声明在 public 类里，
/// 这里只暴露读取接口，让共享的 [_SubListPageState] 能统一取参数。
abstract class _SubListBase extends StatefulWidget {
  const _SubListBase({super.key});

  int? get seriesIndexId;
  String get name;
  String? get listType;
  int? get listId;
  String get keyType;
  bool get isHistory;
  bool get isFavorite;
  MusicSubListSortOrder get initialSortOrder;
  MusicSubListSortBy get initialSortBy;
  double get coverCenterAssetSize;
  String? get coverCenterAsset;
  int? get collectionId;
}

/// 统一拼 GetX tag。含 [UniqueKey]，只在 State 初始化时调用一次，
/// 保证 controller 生命周期内 tag 稳定。
String _pagedTag(String prefix, _SubListBase v) =>
    '${prefix}_${v.keyType}_${v.name}_${v.isFavorite}_${v.isHistory}_'
    '${v.listType ?? ''}_${v.listId ?? 0}_${v.seriesIndexId ?? 0}_'
    '${v.collectionId ?? 0}_${v.initialSortBy}_${v.initialSortOrder}_'
    '${UniqueKey()}';

/// 按统一契约创建 controller，两个 public 类不再各写一份 Get.put。
MusicSubListController _createController(_SubListBase v) =>
    MusicSubListController(
      seriesIndexId: v.seriesIndexId,
      name: v.name,
      listType: v.listType,
      listId: v.listId,
      keyType: v.keyType,
      isHistory: v.isHistory,
      isFavorite: v.isFavorite,
      initialSortOrder: v.initialSortOrder,
      initialSortBy: v.initialSortBy,
      collectionId: v.collectionId,
    );

/// 公共骨架：Stack(Material(SafeArea(Column(header, body))))。
/// 本身**不带 Positioned**：调用方（shell 的 Positioned.fill / MusicOverlayHost /
/// 手机整页）已经负责铺满，这里再包一层 Positioned.fill 会让同一个 RenderStack
/// 被两个 Positioned 同时写 StackParentData，debug 下直接抛 ParentDataWidget 冲突。
class _SubListScaffold extends StatelessWidget {
  const _SubListScaffold({
    required this.backgroundColor,
    required this.header,
    required this.controller,
    required this.scrollController,
  });

  final Color? backgroundColor;
  final Widget header;
  final MusicSubListController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 遮罩必须自己铺一层背景：它盖在列表页上面，
        // 透明的话会看见底下列表的文字/图片（`backgroundColor` 现在是透明色）。
        context.nasStyle.background,
        Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Column(
              children: <Widget>[
                header,
                Expanded(
                  child: MusicSubListOverlayBody(
                    controller: controller,
                    scrollController: scrollController,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 承载两个容器共享的 State 逻辑：controller 注册/销毁、分页滚动、
/// 关闭时复位 hidePlayerBar、GetBuilder 包装、全屏播放器开关。
/// 子类只覆写 [tagPrefix] / [buildFullscreen] / [buildList] 描述容器差异。
abstract class _SubListPageState<W extends _SubListBase> extends State<W> {
  final ScrollController _scrollController = ScrollController();
  late final String _controllerTag;
  MusicSubListController? _controller;
  bool _showFullPlayer = false;

  String get tagPrefix;

  void _openFullscreen() {
    if (_showFullPlayer) return;
    setState(() => _showFullPlayer = true);
  }

  void _closeFullscreen() {
    if (!_showFullPlayer) return;
    setState(() => _showFullPlayer = false);
  }

  @override
  void initState() {
    super.initState();
    _controllerTag = _pagedTag(tagPrefix, widget);
    if (!Get.isRegistered<MusicSubListController>(tag: _controllerTag)) {
      Get.put(_createController(widget), tag: _controllerTag);
    }
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    if (Get.isRegistered<MusicMainController>()) {
      final mainCtrl = Get.find<MusicMainController>();
      if (mainCtrl.hidePlayerBar.value) {
        mainCtrl.hidePlayerBar.value = false;
      }
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    if (Get.isRegistered<MusicSubListController>(tag: _controllerTag)) {
      Get.delete<MusicSubListController>(tag: _controllerTag);
    }
    super.dispose();
  }

  void _onScroll() {
    final listState =
        _controller ??
        (Get.isRegistered<MusicSubListController>(tag: _controllerTag)
            ? Get.find<MusicSubListController>(tag: _controllerTag)
            : null);
    if (listState == null) return;
    attachPagedScroll(
      _scrollController,
      loadMore: () => listState.loadMore(fromAuto: true).catchError((_) {}),
      onScrolling: listState.markScrolling,
      threshold: 360,
    );
  }

  /// 全屏播放器由 MobilePage 覆写；Overlay 恒返回 null。
  Widget? buildFullscreen(BuildContext context) => null;

  /// 非全屏时的容器差异（Overlay / MobilePage 各自实现）。
  Widget buildList(
    BuildContext context,
    MusicSubListController controller,
    ScrollController scrollController,
    Color? backgroundColor,
  );

  @override
  Widget build(BuildContext context) {
    final fullscreen = buildFullscreen(context);
    if (fullscreen != null) return fullscreen;
    final backgroundColor = Theme.of(context)
        .extension<CustomColors>()
        ?.mainContentBgColor;
    return GetBuilder<MusicSubListController>(
      tag: _controllerTag,
      builder: (listState) {
        _controller = listState;
        return buildList(
          context,
          listState,
          _scrollController,
          backgroundColor,
        );
      },
    );
  }
}

class MusicSubListOverlay extends _SubListBase {
  @override
  final int? seriesIndexId;
  final VoidCallback onClose;
  @override
  final String name;
  @override
  final String? listType;
  @override
  final int? listId;
  @override
  final String keyType;
  @override
  final bool isHistory;
  @override
  final bool isFavorite;
  @override
  final MusicSubListSortOrder initialSortOrder;
  @override
  final MusicSubListSortBy initialSortBy;
  @override
  final double coverCenterAssetSize;
  @override
  final String? coverCenterAsset;
  @override
  final int? collectionId;

  const MusicSubListOverlay({
    super.key,
    required this.keyType,
    required this.name,
    this.isFavorite = false,
    this.isHistory = false,
    this.listId,
    this.seriesIndexId,
    this.collectionId,
    this.listType,
    this.initialSortBy = MusicSubListSortBy.filename,
    this.initialSortOrder = MusicSubListSortOrder.asc,
    this.coverCenterAsset,
    this.coverCenterAssetSize = 42,
    required this.onClose,
  });

  @override
  State<MusicSubListOverlay> createState() => _MusicSubListOverlayState();
}

class _MusicSubListOverlayState extends _SubListPageState<MusicSubListOverlay> {
  @override
  String get tagPrefix => 'music_sub_list';

  @override
  Widget buildList(
    BuildContext context,
    MusicSubListController controller,
    ScrollController scrollController,
    Color? backgroundColor,
  ) {
    return _SubListScaffold(
      backgroundColor: backgroundColor,
      controller: controller,
      scrollController: scrollController,
      header: (DeviceUtils.isMobile || DeviceUtils.isPhone(context))
          ? MusicSubListMobileHeader(
              onClose: widget.onClose,
              coverCenterAssetSize: widget.coverCenterAssetSize,
              coverCenterAsset: widget.coverCenterAsset,
              controller: controller,
            )
          : MusicSubListHeader(
              onClose: widget.onClose,
              coverCenterAssetSize: widget.coverCenterAssetSize,
              coverCenterAsset: widget.coverCenterAsset,
              controller: controller,
            ),
    );
  }
}

class MusicSubListMobilePage extends _SubListBase {
  @override
  final int? seriesIndexId;
  @override
  final String name;
  @override
  final String? listType;
  @override
  final int? listId;
  @override
  final String keyType;
  @override
  final bool isHistory;
  @override
  final bool isFavorite;
  @override
  final MusicSubListSortOrder initialSortOrder;
  @override
  final MusicSubListSortBy initialSortBy;
  @override
  final double coverCenterAssetSize;
  @override
  final String? coverCenterAsset;
  @override
  final int? collectionId;

  const MusicSubListMobilePage({
    super.key,
    required this.keyType,
    required this.name,
    this.isFavorite = false,
    this.isHistory = false,
    this.listId,
    this.seriesIndexId,
    this.collectionId,
    this.listType,
    this.initialSortBy = MusicSubListSortBy.filename,
    this.initialSortOrder = MusicSubListSortOrder.asc,
    this.coverCenterAsset,
    this.coverCenterAssetSize = 42,
  });

  @override
  State<MusicSubListMobilePage> createState() => _MusicSubListMobilePageState();
}

class _MusicSubListMobilePageState
    extends _SubListPageState<MusicSubListMobilePage> {
  @override
  String get tagPrefix => 'music_sub_list_page';

  @override
  Widget? buildFullscreen(BuildContext context) {
    if (!_showFullPlayer) return null;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: ColaMusicStageSheet(onClose: _closeFullscreen),
    );
  }

  @override
  Widget buildList(
    BuildContext context,
    MusicSubListController controller,
    ScrollController scrollController,
    Color? backgroundColor,
  ) {
    return Scaffold(
      // 手机端整页 push 时不带音乐壳的 Theme 扩展，自己铺背景
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(widget.name)),
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: context.nasStyle.background),
          Positioned.fill(
            child: _SubListScaffold(
              backgroundColor: backgroundColor,
              controller: controller,
              scrollController: scrollController,
              header: MusicSubListMobilePageHeader(controller: controller),
            ),
          ),
          Positioned(
            right: 12.0,
            left: 12.0,
            bottom: 35.0,
            child: ColaMusicFloatingBar(
              onOpenFullscreen: _openFullscreen,
            ),
          ),
        ],
      ),
    );
  }
}
