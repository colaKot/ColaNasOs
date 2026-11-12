import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../../shared/music_dialogs.dart';
import '../../controller/cola_playlist_controller.dart';
import '../../service/cola_playlist_api_service.dart';

class PlayListDialogs {
  static Future<void> showCreateDialog(
    BuildContext context, {
    required PlayListController controller,
  }) async {
    await showMusicNameFormDialog<bool>(
      context: context,
      title: 'create'.tr,
      hintText: 'name'.tr,
      confirmText: 'confirm'.tr,
      cancelText: 'cancel'.tr,
      failureMessage: 'operation_failed'.tr,
      onSubmit: (name) async {
        final created = await controller.createList(name);
        return created ? true : null;
      },
    );
  }

  /// 选择歌单时列表为空：先走「新建」表单，再把新建项作为选择结果返回。
  static Future<PlayListItem?> showCreateForSelection(
    BuildContext context, {
    required PlayListController controller,
  }) {
    return showMusicNameFormDialog<PlayListItem>(
      context: context,
      title: 'create'.tr,
      hintText: 'name'.tr,
      confirmText: 'confirm'.tr,
      cancelText: 'cancel'.tr,
      failureMessage: 'operation_failed'.tr,
      onSubmit: (name) => controller.createListReturnItem(name),
    );
  }

  static Future<void> showRenameDialog(
    BuildContext context, {
    required PlayListController controller,
    required PlayListItem item,
  }) async {
    await showMusicNameFormDialog<bool>(
      context: context,
      title: 'rename'.tr,
      hintText: 'name'.tr,
      confirmText: 'confirm'.tr,
      cancelText: 'cancel'.tr,
      failureMessage: 'operation_failed'.tr,
      initialValue: item.name,
      onSubmit: (name) async {
        final renamed = await controller.updateList(id: item.id, name: name);
        return renamed ? true : null;
      },
    );
  }

  static Future<void> confirmDelete(
    BuildContext context, {
    required PlayListController controller,
    required PlayListItem item,
  }) async {
    await showMusicConfirmDelete(
      title: 'need_confirm'.tr,
      content: '${'delete'.tr} "${item.name}" ?',
      confirmText: 'confirm'.tr,
      cancelText: 'cancel'.tr,
      onConfirm: () async {
        final deleted = await controller.deleteList(item.id);
        ToastUtil.show(deleted ? 'delete_success'.tr : 'delete_failed'.tr);
      },
    );
  }
}
