import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart' show NasStyleContext;

import '../../../compat/cola_custom_colors.dart';
import '../../../compat/getx.dart';
import '../../../list/view/parts/cola_list_multi_select_bottom_bar.dart';
import '../../../music_main/controller/cola_main_controller.dart';
import '../../../sub_list/controller/cola_sub_list_controller.dart';

/// 专辑 / 歌手详情页的多选工具条（贴底 + 让播放条临时让位）。
///
/// 两个细节必须一起处理，否则就是「工具条浮在半空」：
/// 1. **贴底**：`bottom: 0`，底部安全区用自己的背景补满，不要留 112 的固定空隙
///    —— 那 112 是给底部播放条预留的，播放条没出现时就变成一条大缝。
/// 2. **让播放条让位**：进入多选后把 `MusicMainController.hidePlayerBar` 打开
///    （和 `MusicSubListOverlayBody` 的既有做法一致），退出多选 / 页面销毁时恢复。
///    不然工具条会压在播放条上，两个都点不准。
class MusicDetailSelectionBar extends StatefulWidget {
  const MusicDetailSelectionBar({
    super.key,
    required this.controller,
    this.allowDeleteFile = true,
  });

  final MusicSubListController controller;

  /// 歌单详情页传 false：那里只提供「移出歌单」，不给「删文件」入口
  final bool allowDeleteFile;

  @override
  State<MusicDetailSelectionBar> createState() =>
      _MusicDetailSelectionBarState();
}

class _MusicDetailSelectionBarState extends State<MusicDetailSelectionBar> {
  bool? _lastHidePlayerBar;

  /// 改 `hidePlayerBar` 必须推到帧后：这个调用常常发生在别的 widget 的 build 里，
  /// 同步改 Rx 会让外壳的 Obx 在 build 期间 markNeedsBuild。
  void _syncPlayerBar(bool hide) {
    if (_lastHidePlayerBar == hide) return;
    _lastHidePlayerBar = hide;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!Get.isRegistered<MusicMainController>()) return;
      final main = Get.find<MusicMainController>();
      if (main.hidePlayerBar.value != hide) main.hidePlayerBar.value = hide;
    });
  }

  @override
  void dispose() {
    final wasHiding = _lastHidePlayerBar == true;
    super.dispose();
    if (!wasHiding) return;
    // 页面没了（返回上一层 / 切菜单）必须把播放条放回来，否则整个音乐壳都没有播放条
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!Get.isRegistered<MusicMainController>()) return;
      final main = Get.find<MusicMainController>();
      if (main.hidePlayerBar.value) main.hidePlayerBar.value = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barColor =
        theme.extension<CustomColors>()?.oprationBarBgColor ??
        context.nasStyle.panelColor;
    return Obx(() {
      final selecting = widget.controller.isMultiSelectMode.value;
      _syncPlayerBar(selecting);
      if (!selecting) return const SizedBox.shrink();
      return ColoredBox(
        color: barColor,
        child: SafeArea(
          top: false,
          child: MusicListMultiSelectBottomBar(controller: widget.controller),
        ),
      );
    });
  }
}
