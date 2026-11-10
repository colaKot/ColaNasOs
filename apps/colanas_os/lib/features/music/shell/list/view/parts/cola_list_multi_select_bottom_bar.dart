import '../../../compat/cola_custom_colors.dart';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../controller/cola_multi_select_controller.dart';

class MusicListMultiSelectBottomBar extends StatelessWidget {
  final MusicMultiSelectController controller;

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
    final localExtendedPalette = Theme.of(context).extension<CustomColors>();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      height: 56.0,
      decoration: BoxDecoration(
        color: localExtendedPalette?.oprationBarBgColor,
        border: Border(
          top: BorderSide(color: Get.theme.dividerColor, width: 1.0),
        ),
      ),
      child: Obx(() {
        final localAllSelected = controller.isAllCurrentSelected;
        final localCount = controller.selectedItems.length;
        final localDisabled = localCount <= 0;
        return Row(
          children: <Widget>[
            Expanded(
              child: Row(
                children: <Widget>[
                  CustomCheckbox(
                    value: localAllSelected,
                    onChanged: (_) => controller.toggleSelectAllCurrent(),
                    isCircle: false,
                  ),
                  const SizedBox(width: 6.0),
                  Text(
                    localAllSelected
                        ? 'timeline_deselect_all'.tr
                        : 'timeline_select_all'.tr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(width: 12.0),
                  Text(
                    '$localCount ${'selected'.tr}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // IconButton(
                //   tooltip: 'play'.tr,
                //   onPressed: null,
                //   icon: const Icon(Icons.play_circle_fill_rounded),
                // ),
                // 「加入歌单」放在收藏前面：多选最常用的动作是攒歌单
                IconButton(
                  tooltip: 'add_to_play_list'.tr,
                  onPressed: localDisabled
                      ? null
                      : controller.addToPlayListSelected,
                  icon: Icon(Icons.playlist_add),
                ),
                if (controller.isInPlayList)
                  IconButton(
                    tooltip: 'remove_from_play_list'.tr,
                    onPressed: localDisabled
                        ? null
                        : controller.removeFromPlayListSelected,
                    icon: Icon(Icons.playlist_remove),
                  ),
                IconButton(
                  tooltip: controller.isSelectedAllFavorited
                      ? 'unfavorite'.tr
                      : 'favorites'.tr,
                  onPressed: localDisabled
                      ? null
                      : controller.toggleFavoriteSelected,
                  icon: Icon(
                    controller.isSelectedAllFavorited
                        ? Icons.favorite_border
                        : Icons.favorite,
                  ),
                ),
                IconButton(
                  tooltip: 'download'.tr,
                  onPressed: localDisabled ? null : controller.downloadSelected,
                  icon: const Icon(Icons.download_rounded),
                ),
                if (allowDeleteFile)
                  IconButton(
                    tooltip: 'delete'.tr,
                    onPressed: localDisabled ? null : controller.deleteSelected,
                    icon: Icon(
                      Icons.delete_outline,
                      color: localDisabled ? null : Colors.red,
                    ),
                  ),
                IconButton(
                  tooltip: 'cancel'.tr,
                  onPressed: controller.exitMultiSelectMode,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }
}
