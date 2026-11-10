/// 表单弹窗、确认删除与来源路径面板的公共骨架。
library;

import 'package:flutter/material.dart';

import '../compat/getx.dart';
import '../compat/host.dart';

/// 单字段命名弹窗（新建 / 重命名 / 选择模式下新建）。
///
/// [onSubmit] 返回 null 表示业务失败，此时统一弹失败提示。文案一律由调用方
/// 传入已翻译字符串，避免组件内部硬编码 i18n key。
///
/// ⚠️ controller 由 [_MusicNameForm] 自己持有。
/// 以前是在这里 `final editing = TextEditingController(...)`，`await showDialog`
/// 一返回就 `editing.dispose()` —— 但 `pop` 之后对话框还有约 200ms 的**退场动画**，
/// 这期间 `TextFormField` 仍在 rebuild 并给 controller 注册监听，直接报
/// 「A TextEditingController was used after being disposed」（2026-11-09 新建歌单必现）。
Future<T?> showMusicNameFormDialog<T>({
  required BuildContext context,
  required String title,
  required String hintText,
  required String confirmText,
  required String cancelText,
  required String failureMessage,
  required Future<T?> Function(String name) onSubmit,
  String initialValue = '',
}) async {
  final formKey = GlobalKey<_MusicNameFormState>();
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => DialogUtil.createAlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: _MusicNameForm(
          key: formKey,
          initialValue: initialValue,
          hintText: hintText,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(cancelText),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext)
                  .pop(formKey.currentState?.value ?? initialValue),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  if (name == null) return null;

  final result = await onSubmit(name);
  if (result == null) ToastUtil.show(failureMessage);
  return result;
}

/// 命名输入框：controller 生命周期跟着对话框走，随 widget 一起销毁。
class _MusicNameForm extends StatefulWidget {
  const _MusicNameForm({
    super.key,
    required this.initialValue,
    required this.hintText,
    required this.onSubmitted,
  });

  final String initialValue;
  final String hintText;
  final ValueChanged<String> onSubmitted;

  @override
  State<_MusicNameForm> createState() => _MusicNameFormState();
}

class _MusicNameFormState extends State<_MusicNameForm> {
  late final TextEditingController _editing = TextEditingController(
    text: widget.initialValue,
  );

  String get value => _editing.text;

  @override
  void dispose() {
    _editing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: _editing,
    autofocus: true,
    decoration: InputDecoration(hintText: widget.hintText),
    onFieldSubmitted: widget.onSubmitted,
  );
}

/// 删除确认 + 执行。
Future<bool> showMusicConfirmDelete({
  required String title,
  required String content,
  required String confirmText,
  required String cancelText,
  required Future<void> Function() onConfirm,
}) async {
  final agreed = await DialogUtil.showConfirmDialog(
    title: title,
    content: content,
    confirmText: confirmText,
    cancelText: cancelText,
  );
  if (!agreed) return false;
  await onConfirm();
  return true;
}

/// 来源路径勾选面板：主列表与专辑/歌手列表的同构 UI。
class MusicSourcePanel<T> extends StatelessWidget {
  const MusicSourcePanel({
    super.key,
    required this.availablePaths,
    required this.pathOf,
    required this.isValid,
    required this.isSelected,
    required this.onToggle,
    required this.onReset,
    this.height = 150,
  });

  final RxList<T> availablePaths;
  final String Function(T item) pathOf;
  final bool Function(T item) isValid;
  final bool Function(T item) isSelected;
  final void Function(T item, bool selected) onToggle;
  final VoidCallback onReset;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 500),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: <Widget>[
                Text('source'.tr, style: palette.textTheme.titleSmall),
                const Spacer(),
                TextButton(onPressed: onReset, child: Text('reset'.tr)),
              ],
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: height,
            child: Obx(() {
              final paths = availablePaths;
              if (paths.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('no_path'.tr),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                itemCount: paths.length,
                itemBuilder: (context, index) {
                  final entry = paths[index];
                  final path = pathOf(entry);
                  final valid = isValid(entry);
                  final selected = isSelected(entry);
                  return CheckboxListTile(
                    value: selected,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(path, style: palette.textTheme.bodySmall),
                        ),
                        Icon(
                          valid ? Icons.check_circle : Icons.cancel,
                          size: 16,
                          color: valid ? Colors.green : Colors.red,
                        ),
                      ],
                    ),
                    onChanged: (value) => onToggle(entry, value ?? false),
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }
}
