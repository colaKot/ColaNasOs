import '../../../compat/base_components.dart';

import 'package:flutter/material.dart';

import '../../../compat/getx.dart';
import '../../../compat/host.dart';
import '../../../shared/music_dialogs.dart';
import '../../controller/cola_collection_controller.dart';
import '../../models/cola_collection_model.dart';

class MusicCollectionDialogs {
  static Widget buildCreateEditDialogContent({
    required BuildContext context,
    required List<String> pathList,
    required String nameValue,
    required ValueChanged<String> onNameChanged,
    required VoidCallback onChanged,
  }) {
    final frame = const BoxConstraints(minWidth: 360, maxWidth: 520);
    return ConstrainedBox(
      constraints: frame,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextFormField(
            autofocus: true,
            initialValue: nameValue,
            decoration: InputDecoration(
              labelText: 'name'.tr,
              border: const OutlineInputBorder(),
            ),
            onChanged: onNameChanged,
          ),
          const SizedBox(height: 12.0),
          Row(
            children: <Widget>[
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final picked = await showFolderPickerBottomSheet(
                      context,
                      multiSelect: true,
                      allowFileSelect: false,
                      sourceType: 'music',
                    );
                    if (picked == null || picked.isEmpty) return;
                    for (final path in picked) {
                      if (pathList.contains(path)) continue;
                      pathList.add(path);
                    }
                    onChanged();
                  },
                  label: Text('choose_path'.tr),
                  icon: const Icon(Icons.folder_open),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12.0),
          if (pathList.isNotEmpty) _buildPathList(context, pathList, onChanged),
        ],
      ),
    );
  }

  static Widget _buildPathList(
    BuildContext context,
    List<String> pathList,
    VoidCallback onChanged,
  ) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < pathList.length; i++) ...[
              _buildPathRow(context, pathList, i, onChanged),
              if (i != pathList.length - 1) const SizedBox(height: 6.0),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _buildPathRow(
    BuildContext context,
    List<String> pathList,
    int index,
    VoidCallback onChanged,
  ) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              pathList[index],
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18.0),
            onPressed: () {
              pathList.removeAt(index);
              onChanged();
            },
            tooltip: 'delete'.tr,
          ),
        ],
      ),
    );
  }

  /// 新建与编辑共用一套表单骨架：名称 + 目录清单，校验通过后回写并关闭。
  static Future<void> _presentEditor(
    BuildContext context, {
    required Widget title,
    required String nameValue,
    required List<String> pathList,
    required String confirmText,
    required Future<bool> Function(String name, List<String> paths) onSubmit,
  }) async {
    var draftName = nameValue;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final canSubmit =
                draftName.trim().isNotEmpty && pathList.isNotEmpty;
            return DialogUtil.createAlertDialog(
              title: title,
              content: buildCreateEditDialogContent(
                pathList: pathList,
                onNameChanged: (value) {
                  draftName = value;
                  setState(() {});
                },
                onChanged: () => setState(() {}),
                nameValue: draftName,
                context: context,
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('cancel'.tr),
                ),
                ElevatedButton(
                  onPressed: canSubmit
                      ? () async {
                          final ok = await onSubmit(draftName.trim(), pathList);
                          if (ok) {
                            Navigator.of(Get.context!).pop();
                          }
                        }
                      : null,
                  child: Text(confirmText),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<void> showCreateDialog(
    BuildContext context, {
    required MusicCollectionController controller,
  }) {
    return _presentEditor(
      context,
      title: Row(
        children: <Widget>[
          Text('music_create_collection'.tr),
          const SizedBox(width: 8.0),
          CustomIconButton(
            icon: Icons.info_outlined,
            onPressed: () => DialogUtil.showInfoDialog(
              title: 'music_create_collection'.tr,
              content: 'music_create_collection_alert'.tr,
            ),
          ),
        ],
      ),
      nameValue: '',
      pathList: <String>[],
      confirmText: 'create'.tr,
      onSubmit: (name, paths) =>
          controller.createCollection(name: name, pathList: paths),
    );
  }

  static Future<void> showEditDialog(
    BuildContext context, {
    required MusicCollectionController controller,
    required MusicCollectionItem collection,
  }) {
    return _presentEditor(
      context,
      title: Text('edit'.tr),
      nameValue: collection.name,
      pathList: collection.pathList.toList(),
      confirmText: 'ok'.tr,
      onSubmit: (name, paths) => controller.updateCollection(
        id: collection.id,
        name: name,
        pathList: paths,
      ),
    );
  }

  static Future<void> confirmDelete(
    BuildContext context, {
    required MusicCollectionController controller,
    required MusicCollectionItem collection,
  }) async {
    await showMusicConfirmDelete(
      title: 'need_confirm'.tr,
      content: "${'confirm_delete'.tr}[${collection.name}]",
      confirmText: 'confirm'.tr,
      cancelText: 'cancel'.tr,
      onConfirm: () async {
        await controller.deleteCollection(collection.id);
      },
    );
  }
}
