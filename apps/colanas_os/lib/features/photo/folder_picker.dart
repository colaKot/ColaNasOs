import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 目录选择器：相册来源与影视建库共用（同一套「此电脑 → 逐级进入」逻辑）。
///
/// 返回选中的**绝对路径**；取消返回 null。
Future<String?> showFolderPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const FolderPickerDialog(),
  );
}

class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({super.key});

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  String _path = '';
  String? _parent;
  bool _loading = true;
  List<PhotoFsDirItem> _dirs = const [];

  @override
  void initState() {
    super.initState();
    _load('');
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: scheme.surface,
      title: Text(tr('photo.source.pickTitle')),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: tr('photo.source.up'),
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _path.isEmpty ? null : _up,
                ),
                Expanded(
                  child: Text(
                    _path.isEmpty ? tr('photo.source.roots') : _path,
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
          onPressed: _path.isEmpty
              ? null
              : () => Navigator.pop(context, _path),
          child: Text(tr('photo.source.pickHere')),
        ),
      ],
    );
  }
}