import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 安全中心：备份 / 加密空间（SP3-09 的客户端页面）。
///
/// 服务端已提供备份（sha256 清单 + 篡改校验）与加密空间（scrypt + AES-256-GCM）。
/// 加密空间密码只保存在内存，锁定或离开页面即清空，不落盘。
class SafetyPage extends StatefulWidget {
  const SafetyPage({super.key});

  @override
  State<SafetyPage> createState() => _SafetyPageState();
}

class _SafetyPageState extends State<SafetyPage> {
  int _tab = 0; // 0 备份 / 1 加密空间
  bool _navCollapsed = false;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _backups = const [];

  // 加密空间
  final _vaultIdCtrl = TextEditingController();
  final _vaultPassCtrl = TextEditingController();
  bool _unlocked = false;
  List<Map<String, dynamic>> _vaultItems = const [];

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  @override
  void dispose() {
    _vaultIdCtrl.dispose();
    _vaultPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBackups() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.backupList();
      final items = (res['items'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() {
        _backups = items;
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

  Future<void> _runBackup() async {
    final sourceCtrl = TextEditingController(text: 'photos');
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.safety.001')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: sourceCtrl,
              decoration: InputDecoration(
                labelText: tr('ui.safety.002'),
                hintText: 'photos',
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: tr('ui.safety.003')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.media_tool.007')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.backupRun(
        body: {
          'source': sourceCtrl.text.trim(),
          if (nameCtrl.text.trim().isNotEmpty) 'name': nameCtrl.text.trim(),
        },
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('safety.backupDone', {'files': '${res['files'] ?? 0}', 'bytes': formatBytes((res['bytes'] as num?)?.toInt() ?? 0)}),
          ),
        ),
      );
      await _loadBackups();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('safety.backupFailed', {'error': '$e'}))));
    }
  }

  Future<void> _restore(Map<String, dynamic> job) async {
    final targetCtrl = TextEditingController(text: 'restored');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('safety.restoreTitle', {'id': '${job['id']}'})),
        content: TextField(
          controller: targetCtrl,
          decoration: InputDecoration(
            labelText: tr('ui.safety.004'),
            hintText: 'restored',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.notes.011')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.backupRestore(
        body: {'id': job['id'], 'target': targetCtrl.text.trim()},
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('safety.restoreDone', {'restored': '${res['restored'] ?? 0}', 'skipped': '${res['skipped'] ?? 0}'}),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('safety.restoreFailed', {'error': '$e'}))));
    }
  }

  Future<void> _unlockVault({bool create = false}) async {
    final id = _vaultIdCtrl.text.trim();
    final password = _vaultPassCtrl.text;
    if (id.isEmpty || password.length < 6) {
      NasSnack.show(context, tr('ui.safety.h2c65a2'), error: true);
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (create) {
        await ApiSession.instance.client.vaultCreate(
          body: {'id': id, 'password': password},
        );
      }
      final res = await ApiSession.instance.client.vaultList(
        body: {'id': id, 'password': password},
      );
      final items = (res['items'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() {
        _vaultItems = items;
        _unlocked = true;
      });
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr(create ? 'common.createFailed' : 'safety.unlockFailed', {'error': '$e'}))),
      );
    }
  }

  void _lockVault() {
    setState(() {
      _unlocked = false;
      _vaultItems = const [];
      _vaultPassCtrl.clear();
    });
  }

  Future<void> _putVaultEntry() async {
    final pathCtrl = TextEditingController();
    final dataCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.safety.006')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pathCtrl,
              decoration: InputDecoration(
                labelText: tr('ui.safety.007'),
                hintText: 'secret.txt',
              ),
            ),
            const SizedBox(height: NasTokens.spaceSm),
            TextField(
              controller: dataCtrl,
              maxLines: 4,
              decoration: InputDecoration(labelText: tr('ui.safety.008')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.safety.009')),
          ),
        ],
      ),
    );
    if (ok != true || pathCtrl.text.trim().isEmpty) return;

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.vaultPut(
        body: {
          'id': _vaultIdCtrl.text.trim(),
          'path': pathCtrl.text.trim(),
          'data': base64Encode(utf8.encode(dataCtrl.text)),
          'password': _vaultPassCtrl.text,
        },
      );
      messenger.showSnackBar(SnackBar(content: Text(tr('ui.safety.010'))));
      await _unlockVault();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('safety.writeFailed', {'error': '$e'}))));
    }
  }

  Future<void> _readVaultEntry(Map<String, dynamic> item) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ApiSession.instance.client.vaultGet(
        body: {
          'id': _vaultIdCtrl.text.trim(),
          'path': item['path'],
          'password': _vaultPassCtrl.text,
        },
      );
      final raw = '${res['data'] ?? ''}';
      final bytes = base64Decode(raw);
      String preview;
      try {
        preview = utf8.decode(bytes);
      } catch (_) {
        preview = tr('safety.binary', {'bytes': formatBytes(bytes.length)});
      }
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${item['path']}'),
          content: SingleChildScrollView(child: SelectableText(preview)),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: preview));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(tr('common.copy')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.close')),
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('safety.readFailed', {'error': '$e'}))));
    }
  }

  Future<void> _deleteVaultEntry(Map<String, dynamic> item) async {
    final ok = await NasConfirmDialog.show(
      context,
      title: tr('ui.safety.011'),
      message: tr('safety.deleteConfirm', {'path': '${item['path']}'}),
      danger: true,
      confirmText: tr('ui.notes.017'),
    );
    if (!ok) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.vaultDelete(
        body: {
          'id': _vaultIdCtrl.text.trim(),
          'path': item['path'],
          'password': _vaultPassCtrl.text,
        },
      );
      await _unlockVault();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('common.deleteFailed', {'error': '$e'}))));
    }
  }

  Widget _actionBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_tab == 0)
            IconButton(
              tooltip: tr('ui.safety.001'),
              icon: const Icon(Icons.backup_outlined, size: 18),
              onPressed: _runBackup,
            ),
          if (_tab == 0)
            IconButton(
              tooltip: tr('ui.accounts.021'),
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _loadBackups,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NasSideNav(
            width: _navCollapsed ? 56 : 128,
            iconOnly: _navCollapsed,
            header: Padding(
              padding: const EdgeInsets.fromLTRB(
                NasTokens.spaceSm,
                NasTokens.spaceSm,
                NasTokens.spaceXs,
                NasTokens.spaceXs,
              ),
              child: Row(
                children: [
                  if (!_navCollapsed)
                    Expanded(
                      child: Text(
                        tr('ui.safety.012'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: _navCollapsed ? tr('nav.expand') : tr('nav.collapse'),
                    icon: Icon(
                      _navCollapsed
                          ? Icons.keyboard_double_arrow_right
                          : Icons.keyboard_double_arrow_left,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _navCollapsed = !_navCollapsed),
                  ),
                ],
              ),
            ),
            selectedId: _tab == 0 ? 'backup' : 'vault',
            onSelect: (id) => setState(() => _tab = id == 'vault' ? 1 : 0),
            groups: [
              NasNavGroup(
                title: tr('ui.settings.017'),
                entries: [
                  NasNavEntry(
                    id: 'backup',
                    label: tr('ui.safety.013'),
                    icon: Icons.backup_outlined,
                  ),
                  NasNavEntry(
                    id: 'vault',
                    label: tr('ui.safety.014'),
                    icon: Icons.lock_outline,
                  ),
                ],
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _actionBar(),
                Expanded(child: _tab == 0 ? _backupPane() : _vaultPane()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _backupPane() {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _loadBackups);
    }
    if (_backups.isEmpty) {
      return NasEmptyState(
        title: tr('ui.safety.015'),
        message: tr('ui.safety.h468120'),
        icon: Icons.backup_outlined,
        action: FilledButton.icon(
          onPressed: _runBackup,
          icon: const Icon(Icons.backup_outlined),
          label: Text(tr('ui.safety.001')),
        ),
      );
    }
    return ListView.separated(
      itemCount: _backups.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final job = _backups[i];
        final createdAt = (job['createdAt'] as num?)?.toInt() ?? 0;
        return ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text('${job['id'] ?? ''}'),
          subtitle: Text(
            [
              tr('safety.source', {'source': '${job['source'] ?? '-'}'}),
              tr('safety.files', {'count': '${job['files'] ?? 0}'}),
              formatBytes((job['bytes'] as num?)?.toInt() ?? 0),
              if (createdAt > 0) formatDateTimeSec(createdAt),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: tr('ui.safety.016'),
            icon: const Icon(Icons.restore),
            onPressed: () => _restore(job),
          ),
        );
      },
    );
  }

  Widget _vaultPane() {
    if (!_unlocked) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(NasTokens.spaceLg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: context.nasTextSecondary,
                ),
                const SizedBox(height: NasTokens.spaceMd),
                Text(
                  tr('ui.safety.014'),
                  style: TextStyle(fontSize: NasTokens.fontTitle),
                ),
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  tr('ui.safety.h9f82f5'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
                const SizedBox(height: NasTokens.spaceLg),
                TextField(
                  controller: _vaultIdCtrl,
                  decoration: InputDecoration(
                    labelText: tr('ui.safety.017'),
                    hintText: 'vault1',
                  ),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                TextField(
                  controller: _vaultPassCtrl,
                  obscureText: true,
                  decoration: InputDecoration(labelText: tr('ui.safety.018')),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _unlockVault(),
                        child: Text(tr('ui.safety.019')),
                      ),
                    ),
                    const SizedBox(width: NasTokens.spaceSm),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _unlockVault(create: true),
                        child: Text(tr('ui.safety.020')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          child: Row(
            children: [
              const Icon(Icons.lock_open, color: Color(NasTokens.colorSuccess)),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Text(
                  tr('safety.unlocked', {'id': _vaultIdCtrl.text}),
                  style: const TextStyle(fontSize: NasTokens.fontBody),
                ),
              ),
              TextButton.icon(
                onPressed: _putVaultEntry,
                icon: const Icon(Icons.upload_file),
                label: Text(tr('ui.safety.009')),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              OutlinedButton.icon(
                onPressed: _lockVault,
                icon: const Icon(Icons.lock),
                label: Text(tr('ui.safety.021')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _vaultItems.isEmpty
              ? NasEmptyState(
                  title: tr('ui.safety.022'),
                  message: tr('ui.safety.h393f28'),
                  icon: Icons.folder_open,
                )
              : ListView.separated(
                  itemCount: _vaultItems.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = _vaultItems[i];
                    return ListTile(
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(
                        '${item['path'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        formatBytes((item['size'] as num?)?.toInt() ?? 0),
                        style: const TextStyle(fontSize: NasTokens.fontCaption),
                      ),
                      onTap: () => _readVaultEntry(item),
                      trailing: IconButton(
                        tooltip: tr('ui.notes.017'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteVaultEntry(item),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
