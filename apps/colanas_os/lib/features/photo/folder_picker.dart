import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 目录选择器：相册来源 / 影视建库 / 音乐来源 / 备份目标共用一套
/// 「此电脑 → 逐级进入 → 上一级 / 一键回根」逻辑。
///
/// 返回选中的**绝对路径**；取消返回 null。
Future<String?> showFolderPicker(
  BuildContext context, {
  String? initialPath,
  String? title,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => FolderPickerDialog(initialPath: initialPath, title: title),
  );
}

/// 多选版本：勾选若干目录后一次返回；取消返回 null。
Future<List<String>?> showFolderPickerMulti(
  BuildContext context, {
  String? initialPath,
  String? title,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => FolderPickerDialog(
      initialPath: initialPath,
      title: title,
      multiSelect: true,
    ),
  );
}

class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({
    super.key,
    this.initialPath,
    this.title,
    this.multiSelect = false,
  });

  /// 打开时定位到这个目录（「重新选择 / 迁移来源」用）
  final String? initialPath;
  final String? title;
  final bool multiSelect;

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  String _path = '';
  String? _parent;
  bool _loading = true;
  List<PhotoFsDirItem> _dirs = const [];
  final Set<String> _checked = <String>{};

  @override
  void initState() {
    super.initState();
    _load(widget.initialPath ?? '');
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _path = path;
    });
    try {
      final res = await ApiSession.instance.client.photoFsList(
        path: path.isEmpty ? null : path,
      );
      if (!mounted) return;
      setState(() {
        _dirs = res.dirs;
        _parent = res.parent;
        _path = res.path;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _parent = null;
        _loading = false;
      });
    }
  }

  void _up() {
    if (_path.isEmpty) return;
    _load(_parent ?? '');
  }

  void _submit() {
    if (widget.multiSelect) {
      if (_checked.isEmpty) return;
      Navigator.pop(context, _checked.toList());
      return;
    }
    if (_path.isEmpty) return;
    Navigator.pop(context, _path);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canSubmit =
        widget.multiSelect ? _checked.isNotEmpty : _path.isNotEmpty;
    return AlertDialog(
      backgroundColor: scheme.surface,
      title: Text(widget.title ?? tr('photo.source.pickTitle')),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // 除逐层「上一级」外，还能一步跳回根目录
                TextButton.icon(
                  onPressed: _path.isEmpty ? null : () => _load(''),
                  icon: const Icon(Icons.computer, size: 18),
                  label: Text(tr('photo.source.roots')),
                ),
                IconButton(
                  tooltip: tr('photo.source.up'),
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _path.isEmpty ? null : _up,
                ),
                Expanded(
                  child: Text(
                    _path.isEmpty ? '' : _path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: _dirs.length,
                      itemBuilder: (context, i) {
                        final dir = _dirs[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(dir.name),
                          trailing: widget.multiSelect
                              ? Checkbox(
                                  value: _checked.contains(dir.path),
                                  onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _checked.add(dir.path);
                                    } else {
                                      _checked.remove(dir.path);
                                    }
                                  }),
                                )
                              : null,
                          // 点行是「下钻」，勾选才把当前层目录加进结果
                          onTap: () => _load(dir.path),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: Text(
            widget.multiSelect
                ? '${tr('common.ok')} (${_checked.length})'
                : tr('photo.source.pickHere'),
          ),
        ),
      ],
    );
  }
}
