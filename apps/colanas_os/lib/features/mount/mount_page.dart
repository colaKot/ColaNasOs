import 'dart:async';
import '../../shell/app_widgets.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/mount_transfer.dart';
import '../../core/session.dart';
import '../../shell/mobile_frame.dart';

/// 远程挂载：WebDAV / rclone（SMB·NFS·网盘）的配置与浏览。
///
/// 服务端代理读写（不做 FUSE 真挂载），跨端一致：浏览、复制下载直链、
/// 新建目录、删除文件、**上传文件**（原始流 + 进度条）。
class MountPage extends StatefulWidget {
  const MountPage({super.key});

  @override
  State<MountPage> createState() => _MountPageState();
}

class _MountPageState extends State<MountPage> {
  bool _loading = true;
  String? _error;
  List<MountItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.mountList();
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final nameCtrl = TextEditingController(text: tr('ui.mount.he48389'));
    final urlCtrl = TextEditingController(text: 'https://');
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final rootCtrl = TextEditingController();
    var kind = 'webdav';
    var readOnly = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr('ui.mount.001')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: tr('ui.book.004')),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                NasDropdown<String>(
                  initialValue: kind,
                  decoration: InputDecoration(labelText: tr('ui.mount.002')),
                  items: [
                    DropdownMenuItem(value: 'webdav', child: Text('WebDAV')),
                    DropdownMenuItem(
                      value: 'rclone',
                      child: Text(tr('ui.mount.003')),
                    ),
                  ],
                  onChanged: (v) => setDialogState(() => kind = v ?? 'webdav'),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                TextField(
                  controller: urlCtrl,
                  decoration: InputDecoration(
                    labelText: kind == 'webdav'
                        ? 'Base URL'
                        : tr('ui.mount.004'),
                    hintText: kind == 'webdav'
                        ? 'https://dav.example.com/'
                        : 'smb:share',
                  ),
                ),
                if (kind == 'webdav') ...[
                  const SizedBox(height: NasTokens.spaceSm),
                  TextField(
                    controller: userCtrl,
                    decoration: InputDecoration(
                      labelText: tr('ui.accounts.002'),
                    ),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(labelText: tr('ui.mount.005')),
                  ),
                ],
                const SizedBox(height: NasTokens.spaceSm),
                TextField(
                  controller: rootCtrl,
                  decoration: InputDecoration(labelText: tr('ui.mount.006')),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('ui.mount.007')),
                  value: readOnly,
                  onChanged: (v) => setDialogState(() => readOnly = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('common.create')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    try {
      await ApiSession.instance.client.mountCreate(
        body: MountCreateBody(
          name: nameCtrl.text.trim(),
          kind: kind,
          baseUrl: urlCtrl.text.trim(),
          username: kind == 'webdav' ? userCtrl.text.trim() : null,
          password: kind == 'webdav' && passCtrl.text.isNotEmpty
              ? passCtrl.text
              : null,
          rootPath: rootCtrl.text.trim(),
          readOnly: readOnly,
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _test(MountItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final fresh = await ApiSession.instance.client.mountTest(
        body: MountTestBody(id: item.id),
      );
      NasSnack.showOn(messenger, 
            fresh.status == 'ok'
                ? tr('ui.mount.008')
                : tr('mount.connectFailed', {'error': fresh.lastError ?? tr('ui.mount.009')}),
          );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, tr('mount.testFailed', {'error': '$e'}));
    }
  }

  Future<void> _remove(MountItem item) async {
    final ok = await NasConfirmDialog.show(
      context,
      title: tr('ui.mount.010'),
      message: tr('mount.deleteConfirm', {'name': item.name}),
      danger: true,
      confirmText: tr('ui.notes.017'),
    );
    if (!ok) return;
    try {
      await ApiSession.instance.client.mountRemove(
        body: MountRemoveBody(id: item.id),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  void _browse(MountItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _MountBrowsePage(mount: item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: tr('ui.mount.011'),
        actions: [
          IconButton(
            tooltip: tr('ui.mount.012'),
            icon: const Icon(Icons.add_link),
            onPressed: _create,
          ),
          NasRefreshButton(onPressed: _load),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('ui.mount.013'),
              message: tr('ui.mount.h11ed55'),
              icon: Icons.cloud_outlined,
              action: FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add_link),
                label: Text(tr('ui.mount.012')),
              ),
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = _items[i];
                final ok = item.status == 'ok';
                return ListTile(
                  leading: Icon(
                    item.kind == 'webdav' ? Icons.cloud_queue : Icons.sync_alt,
                    color: ok
                        ? Color(NasTokens.colorSuccess)
                        : item.status == 'error'
                        ? context.nasDanger
                        : null,
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    [
                      item.kind,
                      item.baseUrl,
                      if (item.rootPath.isNotEmpty) item.rootPath,
                      if (item.readOnly) tr('ui.mount.007'),
                      if (item.lastError != null) item.lastError!,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: tr('common.more'),
                    onSelected: (v) {
                      if (v == 'test') _test(item);
                      if (v == 'remove') _remove(item);
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'test',
                        child: Text(tr('ui.mount.015')),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(tr('common.delete')),
                      ),
                    ],
                  ),
                  onTap: () => _browse(item),
                );
              },
            ),
    );
  }
}

class _MountBrowsePage extends StatefulWidget {
  const _MountBrowsePage({required this.mount});

  final MountItem mount;

  @override
  State<_MountBrowsePage> createState() => _MountBrowsePageState();
}

class _MountBrowsePageState extends State<_MountBrowsePage> {
  String _path = '';
  bool _loading = true;
  String? _error;
  List<MountEntry> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.mountBrowse(
        id: widget.mount.id,
        path: _path.isEmpty ? null : _path,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _open(MountEntry entry) {
    if (!entry.dir) return;
    _path = entry.path;
    _load();
  }

  void _up() {
    if (_path.isEmpty) return;
    final idx = _path.lastIndexOf('/');
    _path = idx < 0 ? '' : _path.substring(0, idx);
    _load();
  }

  Future<void> _copyDownloadUrl(MountEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.mountDownloadUrl(
        id: widget.mount.id,
        path: entry.path,
      );
      await Clipboard.setData(
        ClipboardData(text: '${ApiSession.instance.baseUrl}${res.url}'),
      );
      NasSnack.showOn(messenger, tr('mount.downloadCopied', {'minutes': '${res.expiresInSec ~/ 60}'}));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.getFailed', {'error': '$e'}));
    }
  }

  Future<void> _mkdir() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.mount.016')),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(labelText: tr('ui.mount.017')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.create')),
          ),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    final name = ctrl.text.trim();
    try {
      await ApiSession.instance.client.mountMkdir(
        body: MountPathBody(
          id: widget.mount.id,
          path: _path.isEmpty ? name : '$_path/$name',
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _upload() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final picked = await openFile();
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    final target = joinRemotePath(_path, picked.name);
    final progress = ValueNotifier<(int, int)>((0, bytes.length));
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text(tr('ui.mount.022')),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: value.$2 == 0 ? null : value.$1 / value.$2,
                ),
                const SizedBox(height: NasTokens.spaceSm),
                Text('${formatBytes(value.$1)} / ${formatBytes(value.$2)}'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await MountUploader.upload(
        mountId: widget.mount.id,
        remotePath: target,
        bytes: bytes,
        onProgress: (sent, total) => progress.value = (sent, total),
      );
      if (mounted && navigator.canPop()) navigator.pop();
      await _load();
      NasSnack.showOn(messenger, tr('ui.mount.023'));
    } catch (e) {
      if (mounted && navigator.canPop()) navigator.pop();
      NasSnack.showOn(messenger, '${tr('ui.mount.024')}：$e');
    } finally {
      progress.dispose();
    }
  }

  Future<void> _delete(MountEntry entry) async {
    final ok = await NasConfirmDialog.show(
      context,
      title: tr('ui.mount.018'),
      message: tr('mount.deleteEntryConfirm', {'name': entry.name}),
      danger: true,
      confirmText: tr('ui.notes.017'),
    );
    if (!ok) return;
    try {
      await ApiSession.instance.client.mountDelete(
        body: MountPathBody(id: widget.mount.id, path: entry.path),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final readonly = widget.mount.readOnly;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _path.isEmpty
              ? widget.mount.name
              : '${widget.mount.name} / ${_path.split('/').last}',
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: Icon(_path.isEmpty ? Icons.arrow_back : Icons.arrow_upward),
          tooltip: _path.isEmpty ? tr('ui.mount.019') : tr('ui.files.001'),
          onPressed: () => _path.isEmpty ? Navigator.of(context).pop() : _up(),
        ),
        actions: [
          if (!readonly)
            IconButton(
              tooltip: tr('ui.mount.021'),
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: _upload,
            ),
          if (!readonly)
            IconButton(
              tooltip: tr('ui.mount.016'),
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _mkdir,
            ),
          NasRefreshButton(onPressed: _load),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
          ? NasErrorState(message: _error!, onRetry: _load)
          : _items.isEmpty
          ? NasEmptyState(
              title: tr('ui.files.002'),
              message: tr('ui.mount.h8da879'),
              icon: Icons.folder_open,
            )
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final entry = _items[i];
                return ListTile(
                  leading: Icon(
                    entry.dir ? Icons.folder : Icons.insert_drive_file,
                  ),
                  title: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: entry.dir
                      ? null
                      : Text(
                          [
                            formatBytes(entry.size),
                            if (entry.mtime != null)
                              formatDateTimeSec(entry.mtime!),
                          ].join(' · '),
                          style: const TextStyle(
                            fontSize: NasTokens.fontCaption,
                          ),
                        ),
                  trailing: entry.dir
                      ? const Icon(Icons.chevron_right)
                      : PopupMenuButton<String>(
                          tooltip: tr('common.more'),
                          onSelected: (v) {
                            if (v == 'url') _copyDownloadUrl(entry);
                            if (v == 'delete') _delete(entry);
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'url',
                              child: Text(tr('ui.mount.020')),
                            ),
                            if (!readonly)
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(tr('common.delete')),
                              ),
                          ],
                        ),
                  onTap: () => _open(entry),
                );
              },
            ),
    );
  }
}
