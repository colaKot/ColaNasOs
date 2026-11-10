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
    required String nameValue,
    required ValueChanged<String> onNameChanged,
    required VoidCallback onChanged,
    required List<String> pathList,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 360, maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextFormField(
            onChanged: (v) {
              onNameChanged(v);
            },
            initialValue: nameValue,
            decoration: InputDecoration(
              labelText: 'name'.tr,
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 12.0),
          Row(
            children: <Widget>[
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final selected = await showFolderPickerBottomSheet(
                      context,
                      multiSelect: true,
                      allowFileSelect: false,
                      sourceType: 'music',
                    );
                    if (selected == null || selected.isEmpty) return;
                    for (final p in selected) {
                      if (!pathList.contains(p)) {
                        pathList.add(p);
                      }
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
          if (pathList.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int index = 0; index < pathList.length; index++) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10.0,
                          vertical: 6.0,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                pathList[index],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: 'delete'.tr,
                              onPressed: () {
                                pathList.removeAt(index);
                                onChanged();
                              },
                              icon: const Icon(Icons.close, size: 18.0),
                            ),
                          ],
                        ),
                      ),
                      if (index != pathList.length - 1)
                        const SizedBox(height: 6.0),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 新建 / 编辑共用的表单弹窗骨架：StatefulBuilder + canSubmit + 成功后 pop。
  static Future<void> _showCreateEditDialog(
    BuildContext context, {
    required Widget title,
    required String nameValue,
    required List<String> pathList,
    required String confirmText,
    required Future<bool> Function(String name, List<String> paths) onSubmit,
  }) async {
    var localName = nameValue;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final localCanSubmit =
                localName.trim().isNotEmpty && pathList.isNotEmpty;
            return DialogUtil.createAlertDialog(
              title: title,
              content: buildCreateEditDialogContent(
                pathList: pathList,
                onNameChanged: (v) {
                  localName = v;
                  setState(() {});
                },
                onChanged: () => setState(() {}),
                nameValue: localName,
                context: context,
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text('cancel'.tr),
                ),
                ElevatedButton(
                  onPressed: localCanSubmit
                      ? () async {
                          final suc = await onSubmit(
                            localName.trim(),
                            pathList,
                          );
                          if (suc) {
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
    return _showCreateEditDialog(
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
    return _showCreateEditDialog(
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
