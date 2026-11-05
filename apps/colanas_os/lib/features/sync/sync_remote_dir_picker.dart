import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 选择 NAS 上的同步远端目录。
///
/// 两段式（对齐 Windows「我的电脑」的用法）：
/// 先列**可浏览的根**（各盘符 / 文件根 / 已登记的 SMB 共享），点进去再逐层选目录。
///
/// 之前只能从文件根（默认是 C 盘用户目录）往下走 —— 因为 `files/list` 走的是
/// `resolveInRoot` 的越界保护；现在服务端对绝对路径放行（`/files/roots` 给出根列表），
/// 选中的就是绝对路径，同步侧也用 `resolveRemoteDir` 解析。
///
/// 返回值是 POSIX 风格的绝对路径（`D:/Photos`、`//host/share/movies`），
/// 根视图（未选目录）返回 null。
Future<String?> showSyncRemoteDirPicker(
  BuildContext context, {
  String initialPath = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RemoteDirDialog(initialPath: initialPath),
  );
}

/// `D:/x`、`\\\\host\\share`、`//host/share` 都算绝对路径
bool _isAbsolutePath(String raw) {
  final t = raw.trim();
  if (t.startsWith('\\\\') || t.startsWith('//')) return true;
  return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(t);
}

/// 统一成 POSIX 风格（`D:\\Photos` → `D:/Photos`），去掉尾斜杠（盘符根除外）
String _toPosix(String raw) {
  var p = raw.trim().replaceAll('\\', '/');
  p = p.replaceAll(RegExp(r'/+$'), '');
  if (RegExp(r'^[a-zA-Z]:$').hasMatch(p)) return '$p/';
  return p;
}

class _RemoteDirDialog extends StatefulWidget {
  const _RemoteDirDialog({required this.initialPath});

  final String initialPath;

  @override
  State<_RemoteDirDialog> createState() => _RemoteDirDialogState();
}

class _RemoteDirDialogState extends State<_RemoteDirDialog> {
  /// 当前目录（POSIX 绝对路径）；根视图时为 null
  String? _path;

  /// 「我的电脑」视图：盘符 / 文件根 / 共享
  List<FilesRootItem> _roots = const [];
  List<FilesListItem> _dirs = const [];
  bool _loading = true;
  String? _error;

  bool get _atRoots => _path == null;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final roots = await ApiSession.instance.client.filesRoots();
      if (!mounted) return;
      _roots = roots.roots;

      final init = widget.initialPath.trim();
      if (init.isEmpty) {
        setState(() {
          _loading = false;
          _path = null;
        });
        return;
      }
      // 老任务可能是相对文件根的路径，先展开成绝对再浏览
      final abs = _isAbsolutePath(init)
          ? _toPosix(init)
          : _join(roots.home, init.replaceAll(RegExp(r'^/+'), ''));
      await _loadDir(abs, keepLoading: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(e);
      });
    }
  }

  String _join(String parent, String name) {
    final base = parent.replaceAll(RegExp(r'/+$'), '');
    return base.isEmpty ? name : '$base/$name';
  }

  Future<void> _loadDir(String path, {bool keepLoading = false}) async {
    if (!keepLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await ApiSession.instance.client.filesList(path: path);
      if (!mounted) return;
      setState(() {
        _path = _toPosix(res.path);
        _dirs = res.items.where((e) => e.dir).toList(growable: false);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(e);
      });
    }
  }

  String _describe(Object e) => tr('sync.picker.loadFailed', {
        'reason': e.toString().replaceFirst('ApiError', '').trim(),
      });

  void _backToRoots() {
    setState(() {
      _path = null;
      _dirs = const [];
      _error = null;
      _loading = false;
    });
  }

  IconData _rootIcon(FilesRootItem r) => switch ('${r.kind}') {
        'home' => Icons.folder_special_outlined,
        'share' => Icons.lan_outlined,
        _ => Icons.storage_outlined,
      };

  String _rootSubtitle(FilesRootItem r) => switch ('${r.kind}') {
        'home' => tr('sync.picker.root'),
        'share' => r.path,
        _ => tr('sync.picker.drive'),
      };

  /// 面包屑：我的电脑 / D: / Photos …
  Widget _crumbs(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nodes = <Widget>[
      TextButton(
        onPressed: (_atRoots || _loading) ? null : _backToRoots,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceXs),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          tr('sync.picker.computer'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            fontWeight: _atRoots ? FontWeight.w600 : FontWeight.w400,
            color: _atRoots ? scheme.onSurface : context.nasTextSecondary,
          ),
        ),
      ),
    ];

    final path = _path;
    if (path != null) {
      final parts = path.split('/').where((e) => e.isNotEmpty).toList();
      var acc = '';
      for (var i = 0; i < parts.length; i += 1) {
        acc = acc.isEmpty ? '${parts[i]}/' : _join(acc, parts[i]);
        final target = acc;
        final isLast = i == parts.length - 1;
        nodes.add(
          Icon(Icons.chevron_right, size: 16, color: context.nasTextSecondary),
        );
        nodes.add(
          isLast
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NasTokens.spaceXs,
                    vertical: 4,
                  ),
                  child: Text(
                    parts[i],
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                )
              : TextButton(
                  onPressed: _loading ? null : () => _loadDir(target),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NasTokens.spaceXs,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    parts[i],
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
        );
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: nodes),
    );
  }

  Widget _rootsView(BuildContext context) {
    if (_roots.isEmpty) {
      return Center(
        child: Text(
          tr('sync.picker.empty'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _roots.length,
      itemBuilder: (ctx, i) {
        final r = _roots[i];
        return ListTile(
          dense: true,
          leading: Icon(_rootIcon(r), size: 20),
          title: Text(r.label),
          subtitle: Text(
            _rootSubtitle(r),
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _loadDir(r.path),
        );
      },
    );
  }

  Widget _dirsView(BuildContext context) {
    if (_dirs.isEmpty) {
      return Center(
        child: Text(
          tr('sync.picker.empty'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _dirs.length,
      itemBuilder: (ctx, i) {
        final d = _dirs[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined, size: 20),
          title: Text(d.name),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _loadDir(_join(_path!, d.name)),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasDanger,
                ),
              ),
              const SizedBox(height: NasTokens.spaceXs),
              TextButton.icon(
                onPressed: () => _atRoots ? _boot() : _loadDir(_path!),
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(tr('common.refresh')),
              ),
            ],
          ),
        ),
      );
    }
    return _atRoots ? _rootsView(context) : _dirsView(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('sync.picker.title')),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _crumbs(context)),
                if (!_loading && _error == null)
                  IconButton(
                    tooltip: tr('common.refresh'),
                    onPressed: () => _atRoots ? _boot() : _loadDir(_path!),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
              ],
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: NasTokens.spaceXs),
            Expanded(child: _body(context)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.cancel')),
        ),
        FilledButton(
          // 根视图没有「当前目录」，不能选
          onPressed: (_loading || _atRoots) ? null : () => Navigator.pop(context, _path),
          child: Text(tr('sync.picker.choose')),
        ),
      ],
    );
  }
}
