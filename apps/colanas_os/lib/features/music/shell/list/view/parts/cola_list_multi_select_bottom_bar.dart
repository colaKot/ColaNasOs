import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../compat/getx.dart';
import '../../controller/cola_multi_select_controller.dart';

/// 音乐多选工具条（列表 / 专辑详情 / 歌手详情 / 歌单详情共用）。
///
/// 视觉与交互统一走 [NasSelectionBar]（与电视剧列表同一套选择态口径）：
/// 计数 + 全选 / 取消全选 + 业务动作 + 关闭。
/// 音乐壳把它放在**底部**（替掉播放条的位置），所以用 `dense` 让动作收成图标，
/// 否则手机端 390 宽放不下五个动作。
class MusicListMultiSelectBottomBar extends StatelessWidget {
  final ColaMusicMultiSelect controller;

  /// 是否显示「删除文件」。歌单详情页要关掉 —— 那里只说「移出歌单」，
  /// 误点垃圾桶就是删磁盘文件，太危险。
  final bool allowDeleteFile;

  const MusicListMultiSelectBottomBar({
    super.key,
    required this.controller,
    this.allowDeleteFile = true,
  });

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.primary.withValues(alpha: 0.08);
    return Obx(() {
      final allSelected = controller.allCurrentSelected;
      final count = controller.selectedItems.length;
      final disabled = count <= 0;
      return ColoredBox(
        color: tint,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 56,
            child: NasSelectionBar(
              dense: true,
              title: '$count ${'selected'.tr}',
              allSelected: allSelected,
              onToggleAll: controller.toggleSelectAll,
              onClose: controller.leaveMultiSelect,
              actions: [
                // 「加入歌单」放在收藏前面：多选最常用的动作是攒歌单
                NasSelectionAction(
                  label: 'add_to_play_list'.tr,
                  icon: Icons.playlist_add,
                  enabled: !disabled,
                  onPressed: controller.addSelectionToPlaylist,
                ),
                if (controller.insidePlaylist)
                  NasSelectionAction(
                    label: 'remove_from_play_list'.tr,
                    icon: Icons.playlist_remove,
                    enabled: !disabled,
                    onPressed: controller.removeSelectionFromPlaylist,
                  ),
                NasSelectionAction(
                  label: controller.allSelectedFavorited
                      ? 'unfavorite'.tr
                      : 'favorites'.tr,
                  icon: controller.allSelectedFavorited
                      ? Icons.favorite_border
                      : Icons.favorite,
                  enabled: !disabled,
                  onPressed: controller.switchSelectionFavorite,
                ),
                NasSelectionAction(
                  label: 'download'.tr,
                  icon: Icons.download_rounded,
                  enabled: !disabled,
                  onPressed: controller.downloadSelection,
                ),
                if (allowDeleteFile)
                  NasSelectionAction(
                    label: 'delete'.tr,
                    icon: Icons.delete_outline,
                    enabled: !disabled,
                    danger: true,
                    onPressed: controller.deleteSelection,
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
