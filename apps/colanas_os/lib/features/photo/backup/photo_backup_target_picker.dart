import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import '../folder_picker.dart';

/// 备份目标选择器：列出当前账号的**相册源**，选一个就等于存到该源根目录。
///
/// 为什么不逐级浏览文件树：手机备份只需要决定「存进哪个库」。源本身就是 NAS 上
/// 的一个根目录（可能是 `D:/Photos` 这种整机绝对路径，也可能在 files 根内），
/// 再往下细分由「目录风格」（按相册 / 按月 / 按年）决定 —— 两件事拆开之后，
/// 用户不用再在手机上点五六层目录。
///
/// 返回选中的源根路径（绝对或相对，由源本身决定）；用户取消返回 null。
Future<String?> showPhotoBackupTargetPicker(
  BuildContext context, {
  String? initialPath,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => PhotoBackupTargetPicker(initialPath: initialPath),
  );
}

class PhotoBackupTargetPicker extends StatefulWidget {
  const PhotoBackupTargetPicker({super.key, this.initialPath});

  final String? initialPath;

  @override
  State<PhotoBackupTargetPicker> createState() =>
      _PhotoBackupTargetPickerState();
}

class _PhotoBackupTargetPickerState extends State<PhotoBackupTargetPicker> {
  List<PhotoLibraryItem> _sources = const <PhotoLibraryItem>[];
  String _selected = '';
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res = await ApiSession.instance.client.photoLibraryList();
      if (!mounted) return;
      final items = res.items;
      final start = (widget.initialPath ?? '').trim();
      // 默认选中：当前配置指向的那个源；对不上（老配置还在指 photo-backup）
      // 就落到第一个 —— 服务端按 created_at 排，第一个就是这个账号最早用的源。
      var selected = '';
      if (start.isNotEmpty && items.any((e) => e.path == start)) {
        selected = start;
      } else if (items.isNotEmpty) {
        selected = items.first.path;
      }
      setState(() {
        _sources = items;
        _selected = selected;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sources = const <PhotoLibraryItem>[];
        _loading = false;
        _error = tr('photo.backup.loadFailed', {
          'reason': e.toString().replaceFirst('ApiError', '').trim(),
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceMd,
                NasTokens.spaceSm,
                NasTokens.spaceSm,
                NasTokens.spaceSm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('photo.backup.pickSource'),
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          tr('photo.backup.pickSourceHint'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error.isNotEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(NasTokens.spaceMd),
                            child: Text(_error, textAlign: TextAlign.center),
                          ),
                        )
                      : _sources.isEmpty
                          ? Center(
                              child: Padding(
                                padding:
                                    const EdgeInsets.all(NasTokens.spaceMd),
                                child: Text(
                                  tr('photo.backup.noSource'),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _sources.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1, indent: 56),
                              itemBuilder: (context, i) {
                                final s = _sources[i];
                                final active = s.path == _selected;
                                return ListTile(
                                  leading: Icon(
                                    active
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: active
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.outline,
                                  ),
                                  title: Text(
                                    s.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  subtitle: Text(
                                    // 路径放次要位置：用户认的是库名，
                                    // 但换个盘/共享的时候得能看出到底在哪。
                                    '${s.path} · '
                                    '${tr('photo.backup.photoCount', {'count': '${s.items}'})}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () =>
                                      setState(() => _selected = s.path),
                                );
                              },
                            ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(NasTokens.spaceMd),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      // 除了选「源」，也能逐级浏览到任意子目录（能返回上一层）
                      final picked = await showFolderPicker(
                        context,
                        initialPath: _selected,
                      );
                      if (picked != null && context.mounted) {
                        Navigator.pop(context, picked);
                      }
                    },
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(tr('photo.source.pickTitle')),
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: FilledButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.pop(context, _selected),
                      child: Text(tr('photo.backup.pickHere')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
