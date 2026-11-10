import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../list/view/parts/cola_list_multi_select_bottom_bar.dart';
import '../../../music_main/controller/cola_main_controller.dart';
import '../../../play_service/controller/cola_player_controller.dart';
import '../../../shared/music_paging.dart';
import '../../controller/cola_sub_list_controller.dart';
import 'cola_sub_list_table.dart';

class MusicSubListOverlayBody extends StatefulWidget {
  final MusicSubListController controller;
  final ScrollController scrollController;

  const MusicSubListOverlayBody({
    required this.scrollController,
    super.key,
    required this.controller,
  });

  @override
  State<MusicSubListOverlayBody> createState() =>
      _MusicSubListOverlayBodyState();
}

class _MusicSubListOverlayBodyState extends State<MusicSubListOverlayBody> {
  bool? _lastShowMultiBar;

  MusicSubListController get _ctrl => widget.controller;

  /// 多选模式切换时联动主壳隐藏/恢复播放条，延后到本帧结束再改 Rx。
  void _syncPlayerBarVisibility(bool showMultiBar) {
    if (_lastShowMultiBar == showMultiBar) return;
    _lastShowMultiBar = showMultiBar;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !Get.isRegistered<MusicMainController>()) return;
      final mainCtrl = Get.find<MusicMainController>();
      if (mainCtrl.hidePlayerBar.value != showMultiBar) {
        mainCtrl.hidePlayerBar.value = showMultiBar;
      }
    });
  }

  /// 播放条可见时，给多选底栏预留底部空间。
  double _playerExtraSpace(BuildContext context, bool showMultiBar) {
    final playCtrl = Get.isRegistered<MusicPlayServiceController>()
        ? Get.find<MusicPlayServiceController>()
        : null;
    final showPlayerBar =
        !showMultiBar &&
        playCtrl != null &&
        playCtrl.isReady.value &&
        playCtrl.playlist.isNotEmpty;
    return showPlayerBar
        ? (112.0 + MediaQuery.of(context).padding.bottom)
        : 0.0;
  }

  /// 多选模式下的底部操作栏。
  Widget _multiSelectBottomBar(double extraSpace) => Positioned(
    right: 0.0,
    left: 0.0,
    bottom: extraSpace,
    child: MusicListMultiSelectBottomBar(controller: _ctrl),
  );

  /// 表格 + 可选多选底栏；所有 Rx 读取都在 MusicAsyncListState 的 Obx 内进行。
  Widget _content(BuildContext context) {
    final showMultiBar = _ctrl.isMultiSelectMode.value;
    _syncPlayerBarVisibility(showMultiBar);
    final extraSpace = _playerExtraSpace(context, showMultiBar);
    return Stack(
      children: <Widget>[
        MusicSubListTable(
          controller: _ctrl,
          scrollController: widget.scrollController,
        ),
        if (showMultiBar) _multiSelectBottomBar(extraSpace),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => MusicAsyncListState(
    loading: _ctrl.loading,
    // 子列表没有「占位空态」：loading 时转圈，其余情况（含空列表）都渲染表格。
    // 因此借用公共组件的 empty 分支输出正常内容，child 不会被用到。
    isEmpty: () => true,
    child: const SizedBox.shrink(),
    emptyBuilder: (ctx) => _content(ctx),
  );
}
