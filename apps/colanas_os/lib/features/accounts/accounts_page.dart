import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import '../../shell/app_nav_shell.dart';

/// 用户与权限（SP3-01）：主从布局（用户列表 + 详情工作台）。
///
/// 参考实现是「左列表 + 右详情（信息卡 + 2FA / 登录记录 / 操作日志 / 权限）」；
/// 操作日志默认展示文件操作（`/files/op-logs`），账号审计作为第二个子页保留。
/// IP 黑名单保留为左下角弹窗，避免丢失现有能力。
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _users = const [];
  bool _loadingUsers = true;
  String? _usersError;
  String _keyword = '';
  String? _selectedId;

  List<Map<String, dynamic>> _rules = const [];
  bool _loadingRules = true;

  bool _policyLoading = false;
  String? _policyError;
  bool _appRestricted = false;
  final Set<String> _allowedApps = <String>{};
  List<Map<String, dynamic>> _policyPaths = const [];
  bool _policySaving = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadRules();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _hint(Object e) {
    final text = e.toString();
    if (text.contains('403')) return tr('ui.accounts.hcaaca9');
    return null;
  }

  List<Map<String, dynamic>> get _filteredUsers {
    final kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return _users;
    return _users
        .where((u) => '${u['username'] ?? ''}'.toLowerCase().contains(kw))
        .toList();
  }

  Map<String, dynamic>? get _selectedUser {
    if (_selectedId == null) return null;
    for (final u in _users) {
      if ('${u['id']}' == _selectedId) return u;
    }
    return null;
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loadingUsers = true;
      _usersError = null;
    });
    try {
      final res = await ApiSession.instance.client.userList();
      if (!mounted) return;
      final items = (res['items'] as List<dynamic>? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      setState(() {
        _users = items;
        _loadingUsers = false;
      });
      if (_selectedId != null &&
          !items.any((u) => '${u['id']}' == _selectedId)) {
        if (!mounted) return;
        setState(() => _selectedId = null);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usersError = _hint(e) ?? e.toString();
        _loadingUsers = false;
      });
    }
  }

  Future<void> _loadRules() async {
    setState(() => _loadingRules = true);
    try {
      final res = await ApiSession.instance.client.securityIpList();
      if (!mounted) return;
      setState(() {
        _rules = (res['items'] as List<dynamic>? ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loadingRules = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingRules = false);
    }
  }

  void _selectUser(Map<String, dynamic> user) {
    final uid = '${user['id']}';
    setState(() => _selectedId = uid);
    _loadPolicy(uid);
  }

  Future<void> _loadPolicy(String uid) async {
    setState(() {
      _policyLoading = true;
      _policyError = null;
    });
    try {
      final res = await ApiSession.instance.client.userPolicyGet(uid: uid);
      if (!mounted) return;
      final apps = res['allowedApps'];
      final paths = (res['paths'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _appRestricted = apps is List;
        _allowedApps
          ..clear()
          ..addAll(apps is List ? apps.map((e) => '$e') : const <String>[]);
        _policyPaths = paths;
        _policyLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _policyError = _hint(e) ?? '$e';
        _policyLoading = false;
      });
    }
  }

  Future<void> _savePolicy() async {
    final user = _selectedUser;
    if (user == null) return;
    if (_appRestricted && _allowedApps.isEmpty) {
      NasSnack.show(context, tr('accounts.policy.noApps'));
      return;
    }
    setState(() => _policySaving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.userPolicySet(
        body: <String, dynamic>{
          'uid': '${user['id']}',
          'allowedApps': _appRestricted ? _allowedApps.toList() : null,
          'paths': _policyPaths
              .where((p) => '${p['path'] ?? ''}'.trim().isNotEmpty)
              .map((p) => {
                    'path': '${p['path']}',
                    'access': p['access'] == 'rw' ? 'rw' : 'ro',
                  })
              .toList(),
        },
      );
      NasSnack.showOn(messenger, tr('accounts.policy.saved'));
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '${_hint(e) ?? e}'}));
    } finally {
      if (mounted) setState(() => _policySaving = false);
    }
  }

  Future<void> _createUser() async {
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final scopesCtrl = TextEditingController(text: 'files:read');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.accounts.001')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: tr('ui.accounts.002')),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: InputDecoration(labelText: tr('ui.accounts.003')),
            ),
            const SizedBox(height: NasTokens.spaceMd),
            TextField(
              controller: scopesCtrl,
              decoration: InputDecoration(
                labelText: tr('ui.accounts.004'),
                helperText: tr('ui.accounts.005'),
              ),
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
            child: Text(tr('common.create')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final scopes = scopesCtrl.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    try {
      await ApiSession.instance.client.userCreate(
        body: {
          'username': nameCtrl.text.trim(),
          'password': passCtrl.text,
          'scopes': scopes,
        },
      );
      await _loadUsers();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.createFailed', {'error': '$e'}));
    }
  }

  Future<void> _toggleDisabled(Map<String, dynamic> user) async {
    final disabled = user['disabled'] == true;
    try {
      await ApiSession.instance.client.userDisable(
        body: {'id': user['id'], 'disabled': !disabled},
      );
      await _loadUsers();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, 
            tr('accounts.toggleFailed', {'action': disabled ? tr('ui.accounts.007') : tr('ui.accounts.008'), 'error': '$e'}),
          );
    }
  }

  Future<void> _editUser(Map<String, dynamic> user) async {
    final nameCtrl = TextEditingController(text: '${user['username'] ?? ''}');
    final passCtrl = TextEditingController();
    final phoneCtrl = TextEditingController(text: '${user['phone'] ?? ''}');
    final remarkCtrl = TextEditingController(text: '${user['remark'] ?? ''}');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('accounts.editTitle')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: tr('ui.accounts.002')),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: InputDecoration(labelText: tr('accounts.passwordKeep')),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                TextField(
                  controller: phoneCtrl,
                  decoration: InputDecoration(labelText: tr('accounts.phone')),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                TextField(
                  controller: remarkCtrl,
                  decoration: InputDecoration(labelText: tr('accounts.remark')),
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
              child: Text(tr('common.save')),
            ),
          ],
        ),
      );
      if (ok != true) return;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ApiSession.instance.client.userUpdate(
          body: <String, dynamic>{
            'id': user['id'],
            'username': nameCtrl.text.trim(),
            if (passCtrl.text.isNotEmpty) 'password': passCtrl.text,
            'phone': phoneCtrl.text.trim(),
            'remark': remarkCtrl.text.trim(),
          },
        );
        await _loadUsers();
      } catch (e) {
        NasSnack.showOn(messenger, tr('common.saveFailed', {'error': '${_hint(e) ?? e}'}));
      }
    } finally {
      nameCtrl.dispose();
      passCtrl.dispose();
      phoneCtrl.dispose();
      remarkCtrl.dispose();
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final name = '${user['username'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('accounts.deleteTitle')),
        content: Text(tr('accounts.deleteConfirm', {'name': name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.userDelete(body: {'id': user['id']});
      setState(() => _selectedId = null);
      await _loadUsers();
    } catch (e) {
      NasSnack.showOn(messenger, tr('common.deleteFailed', {'error': '${_hint(e) ?? e}'}));
    }
  }

  Future<void> _enable2fa(Map<String, dynamic> user) async {
    try {
      final setup = await ApiSession.instance.client.userTotpSetup(
        body: {'id': user['id']},
      );
      final secret = setup['secret'] as String? ?? '';
      final uri = setup['uri'] as String? ?? '';
      if (!mounted) return;

      final codeCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('ui.accounts.009')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (uri.isNotEmpty) ...[
                Text(tr('accounts.twofa.scanHint')),
                const SizedBox(height: NasTokens.spaceSm),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(NasTokens.spaceSm),
                    color: Colors.white,
                    child: QrImageView(
                      data: uri,
                      version: QrVersions.auto,
                      size: 180,
                    ),
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                Text(tr('accounts.twofa.orManual')),
              ] else
                Text(tr('ui.accounts.010')),
              const SizedBox(height: NasTokens.spaceSm),
              SelectableText(
                secret,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              SelectableText(uri, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: NasTokens.spaceMd),
              TextField(
                controller: codeCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('ui.accounts.011')),
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
              child: Text(tr('ui.accounts.007')),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await ApiSession.instance.client.userTotpEnable(
        body: {'id': user['id'], 'code': codeCtrl.text.trim()},
      );
      await _loadUsers();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('accounts.enable2faFailed', {'error': '$e'}));
    }
  }

  Future<void> _disable2fa(Map<String, dynamic> user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.accounts.016')),
        content: Text(tr('accounts.twofa.disableConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.016')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      await ApiSession.instance.client.userTotpDisable(
        body: {'id': user['id']},
      );
      await _loadUsers();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('accounts.disable2faFailed', {'error': '$e'}));
    }
  }

  Future<void> _addPolicyPath() async {
    final ctrl = TextEditingController();
    var access = 'ro';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr('accounts.policy.addPath')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  labelText: tr('accounts.policy.path'),
                  hintText: tr('accounts.policy.pathHint'),
                ),
              ),
              const SizedBox(height: NasTokens.spaceMd),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'ro',
                    label: Text(tr('accounts.policy.access.ro')),
                  ),
                  ButtonSegment(
                    value: 'rw',
                    label: Text(tr('accounts.policy.access.rw')),
                  ),
                ],
                selected: {access},
                onSelectionChanged: (v) =>
                    setDialogState(() => access = v.first),
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
              child: Text(tr('common.save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final path = ctrl.text.trim();
    if (path.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _policyPaths = [
        ..._policyPaths,
        {'path': path, 'access': access},
      ];
    });
  }


  Widget _userList() {
    if (_loadingUsers) return const NasLoading();
    if (_usersError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceLg),
          child: Text(_usersError!, style: TextStyle(color: context.nasDanger)),
        ),
      );
    }
    final users = _filteredUsers;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('accounts.search'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                  onChanged: (v) => setState(() => _keyword = v),
                ),
              ),
              const SizedBox(width: NasTokens.spaceXs),
              IconButton(
                icon: const Icon(Icons.person_add_alt, size: 18),
                tooltip: tr('ui.accounts.001'),
                onPressed: _createUser,
              ),
            ],
          ),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Expanded(
          child: users.isEmpty
              ? NasEmptyState(
                  title: tr('ui.accounts.h00dbf4'),
                  icon: Icons.people_outline,
                )
              : ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, i) {
                    final user = users[i];
                    final selected = '${user['id']}' == _selectedId;
                    final disabled = user['disabled'] == true;
                    final totp = user['totpEnabled'] == true;
                    final scopes =
                        (user['scopes'] as List<dynamic>? ?? const [])
                            .map((e) => '$e')
                            .toList();
                    return ListTile(
                      selected: selected,
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.08),
                      leading: Icon(
                        disabled ? Icons.person_off : Icons.person,
                        size: 20,
                      ),
                      title: Text(
                        user['username'] as String? ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: disabled
                            ? const TextStyle(
                                decoration: TextDecoration.lineThrough)
                            : null,
                      ),
                      subtitle: Text(
                        [
                          if (totp) '2FA',
                          ...scopes.take(2),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                      onTap: () => _selectUser(user),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        ListTile(
          dense: true,
          leading: const Icon(Icons.block, size: 18),
          title: Text(tr('accounts.ipBlacklist')),
          subtitle: Text(
            tr('accounts.ipRulesCount', {'count': '${_rules.length}'}),
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _loadingRules ? null : _openIpRules,
        ),
      ],
    );
  }

  Widget _infoCard(Map<String, dynamic> user) {
    final disabled = user['disabled'] == true;
    final totp = user['totpEnabled'] == true;
    final scopes = (user['scopes'] as List<dynamic>? ?? const [])
        .map((e) => '$e')
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceLg,
        NasTokens.spaceMd,
        NasTokens.spaceLg,
        0,
      ),
      child: NasCard(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              child: Icon(disabled ? Icons.person_off : Icons.person, size: 20),
            ),
            const SizedBox(width: NasTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          user['username'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      _statusChip(
                        disabled
                            ? tr('accounts.disabledState')
                            : tr('accounts.active'),
                        disabled ? context.nasDanger : context.nasSuccess,
                      ),
                      if (totp) ...[
                        const SizedBox(width: NasTokens.spaceXs),
                        _statusChip('2FA', Theme.of(context).colorScheme.primary),
                      ],
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceXs),
                  Wrap(
                    spacing: NasTokens.spaceXs,
                    runSpacing: NasTokens.spaceXs,
                    children: [
                      for (final s in scopes)
                        Chip(
                          label: Text(s),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  if ((user['phone'] as String? ?? '').isNotEmpty ||
                      (user['remark'] as String? ?? '').isNotEmpty ||
                      user['lastLoginAt'] != null) ...[
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      [
                        if ((user['phone'] as String? ?? '').isNotEmpty)
                          '${tr('accounts.phone')}: ${user['phone']}',
                        if ((user['remark'] as String? ?? '').isNotEmpty)
                          '${tr('accounts.remark')}: ${user['remark']}',
                        if (user['lastLoginAt'] != null)
                          tr('accounts.lastLogin', {
                            'time': _fmtTime((user['lastLoginAt'] as num).toInt()),
                          }),
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            TextButton(
              onPressed: () => _toggleDisabled(user),
              child: Text(disabled ? tr('ui.accounts.007') : tr('ui.accounts.008')),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: tr('accounts.edit'),
              onPressed: () => _editUser(user),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: tr('common.delete'),
              onPressed: () => _deleteUser(user),
            ),
            NasRefreshButton(onPressed: _loadUsers),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: NasTokens.fontMicro,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _twoFaTab(Map<String, dynamic> user) {
    final totp = user['totpEnabled'] == true;
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            totp ? Icons.verified_user : Icons.shield_outlined,
            color: totp ? context.nasSuccess : context.nasTextSecondary,
          ),
          title: Text(tr('ui.accounts.009')),
          subtitle: Text(
            totp ? tr('accounts.twofa.on') : tr('accounts.twofa.off'),
          ),
          trailing: FilledButton(
            onPressed: () => totp ? _disable2fa(user) : _enable2fa(user),
            child: Text(
              totp ? tr('ui.accounts.016') : tr('ui.accounts.017'),
            ),
          ),
        ),
      ],
    );
  }


  String _fmtTime(int seconds) {
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _policyTab(Map<String, dynamic> user) {
    if (_policyLoading) return const NasLoading();
    if (_policyError != null) {
      return NasErrorState(
        message: _policyError!,
        onRetry: () => _loadPolicy('${user['id']}'),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('accounts.policy.apps'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(tr('accounts.policy.restrict')),
          value: _appRestricted,
          onChanged: (v) => setState(() => _appRestricted = v),
        ),
        if (_appRestricted)
          Wrap(
            spacing: NasTokens.spaceXs,
            runSpacing: NasTokens.spaceXs,
            children: [
              for (final app in AppRegistry.apps.where((a) => a.available))
                NasChip(
                  label: Text(tr(app.nameKey)),
                  selected: _allowedApps.contains(app.id),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _allowedApps.add(app.id);
                    } else {
                      _allowedApps.remove(app.id);
                    }
                  }),
                ),
            ],
          ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('accounts.policy.appsHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceMd),
        const Divider(height: 1),
        const SizedBox(height: NasTokens.spaceMd),
        Row(
          children: [
            Expanded(
              child: Text(
                tr('accounts.policy.paths'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: _addPolicyPath,
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('accounts.policy.addPath')),
            ),
          ],
        ),
        if (_policyPaths.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
            child: Text(
              tr('accounts.policy.pathHint'),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
          )
        else
          for (var i = 0; i < _policyPaths.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined, size: 18),
              title: Text(
                '${_policyPaths[i]['path'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NasDropdown<String>(
                    value: _policyPaths[i]['access'] == 'rw' ? 'rw' : 'ro',
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem(
                        value: 'ro',
                        child: Text(tr('accounts.policy.access.ro')),
                      ),
                      DropdownMenuItem(
                        value: 'rw',
                        child: Text(tr('accounts.policy.access.rw')),
                      ),
                    ],
                    onChanged: (v) => setState(() {
                      _policyPaths = [
                        for (var j = 0; j < _policyPaths.length; j++)
                          j == i
                              ? {..._policyPaths[j], 'access': v ?? 'ro'}
                              : _policyPaths[j],
                      ];
                    }),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: tr('ui.accounts.019'),
                    onPressed: () => setState(() {
                      _policyPaths = [
                        for (var j = 0; j < _policyPaths.length; j++)
                          if (j != i) _policyPaths[j],
                      ];
                    }),
                  ),
                ],
              ),
            ),
        const SizedBox(height: NasTokens.spaceMd),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _policySaving ? null : _savePolicy,
            child: Text(tr('common.save')),
          ),
        ),
      ],
    );
  }

  Widget _detail(Map<String, dynamic> user, {bool showBack = false}) {
    return Column(
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(
                left: NasTokens.spaceSm,
                top: NasTokens.spaceSm,
              ),
              child: TextButton.icon(
                onPressed: () => setState(() => _selectedId = null),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: Text(tr('accounts.mobileBack')),
              ),
            ),
          ),
        _infoCard(user),
        Expanded(
          child: DefaultTabController(
            key: ValueKey('${user['id']}'),
            length: 5,
            child: Column(
              children: [
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: tr('accounts.tab.twofa')),
                    Tab(text: tr('accounts.tab.logins')),
                    Tab(text: tr('accounts.tab.logs')),
                    Tab(text: tr('accounts.tab.policy')),
                    Tab(text: tr('accounts.tab.tokens')),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _twoFaTab(user),
                      _EventTab(key: ValueKey('login-${user['id']}'), uid: '${user['id']}', audit: false),
                      _LogsTab(key: ValueKey('logs-${user['id']}'), uid: '${user['id']}'),
                      _policyTab(user),
                      _TokensTab(key: ValueKey('tokens-${user['id']}'), uid: '${user['id']}'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openIpRules() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _IpRulesDialog(
        rules: _rules,
        onChanged: (rules) => setState(() => _rules = rules),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final user = _selectedUser;
    if (!wide) {
      return Scaffold(
        // 手机端单页模块：房子 + 标题，列表里点人进详情（详情自带返回）
        appBar: NasMobileAppBar(
          title: tr('app.accounts'),
          onHome: AppNavShell.onExitToHome,
        ),
        body: user == null
            ? _userList()
            : _detail(user, showBack: true),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 300,
            child: _userList(),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: user == null
                ? NasEmptyState(
                    title: tr('accounts.selectUser'),
                    icon: Icons.manage_accounts_outlined,
                  )
                : _detail(user),
          ),
        ],
      ),
    );
  }
}

/// 操作日志页签：文件操作（默认，`file_op_logs`）+ 账号审计（`auth_events`）。
///
/// 参考实现的「操作日志」就是文件操作日志（类型 / 状态 / 关键词 / 分页）；
/// 账号审计是本仓库额外能力，放在第二个子页，避免丢失。
class _LogsTab extends StatefulWidget {
  const _LogsTab({super.key, required this.uid});

  final String uid;

  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> {
  bool _files = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NasTokens.spaceLg,
            vertical: NasTokens.spaceSm,
          ),
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(tr('accounts.logs.files'))),
              ButtonSegment(value: false, label: Text(tr('accounts.logs.audit'))),
            ],
            selected: {_files},
            onSelectionChanged: (value) => setState(() => _files = value.first),
          ),
        ),
        Expanded(
          child: _files
              ? _FileLogTab(key: ValueKey('file-logs-${widget.uid}'), uid: widget.uid)
              : _EventTab(key: ValueKey('audit-${widget.uid}'), uid: widget.uid, audit: true),
        ),
      ],
    );
  }
}

/// 文件操作日志：按用户查 `GET /files/op-logs`，支持类型 / 状态 / 关键词 / 分页。
class _FileLogTab extends StatefulWidget {
  const _FileLogTab({super.key, required this.uid});

  final String uid;

  @override
  State<_FileLogTab> createState() => _FileLogTabState();
}

class _FileLogTabState extends State<_FileLogTab> {
  static const _pageSize = 50;
  static const _actions = [
    'mkdir',
    'rename',
    'move',
    'copy',
    'upload',
    'download',
    'trash',
    'delete',
    'restore',
    'empty',
  ];

  final _queryCtrl = TextEditingController();
  bool _loading = true;
  String? _error;
  List<FilesOpLogItem> _items = const [];
  int _total = 0;
  int _offset = 0;
  String _action = '';
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keyword = _queryCtrl.text.trim();
      final res = await ApiSession.instance.client.filesOpLogs(
        uid: widget.uid,
        action: _action.isEmpty ? null : _action,
        status: _status.isEmpty ? null : _status,
        q: keyword.isEmpty ? null : keyword,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _total = res.total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _applyFilter() {
    _offset = 0;
    _load();
  }

  void _go(int offset) {
    _offset = offset < 0 ? 0 : offset;
    _load();
  }

  String _actionLabel(String action) {
    switch (action) {
      case 'mkdir':
        return tr('accounts.fileLog.action.mkdir');
      case 'rename':
        return tr('accounts.fileLog.action.rename');
      case 'move':
        return tr('accounts.fileLog.action.move');
      case 'copy':
        return tr('accounts.fileLog.action.copy');
      case 'upload':
        return tr('accounts.fileLog.action.upload');
      case 'download':
        return tr('accounts.fileLog.action.download');
      case 'trash':
        return tr('accounts.fileLog.action.trash');
      case 'delete':
        return tr('accounts.fileLog.action.delete');
      case 'restore':
        return tr('accounts.fileLog.action.restore');
      case 'empty':
        return tr('accounts.fileLog.action.empty');
      default:
        return action;
    }
  }

  String _time(int seconds) {
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceLg,
        vertical: NasTokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: NasTokens.spaceSm,
            runSpacing: NasTokens.spaceXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                tr('accounts.fileLog.action'),
                style: TextStyle(fontSize: NasTokens.fontCaption),
              ),
              NasDropdown<String>(
                value: _action,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: '', child: Text(tr('accounts.fileLog.anyAction'))),
                  ..._actions.map(
                    (a) => DropdownMenuItem(value: a, child: Text(_actionLabel(a))),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _action = value);
                  _applyFilter();
                },
              ),
              const SizedBox(width: NasTokens.spaceSm),
              Text(
                tr('accounts.fileLog.status'),
                style: TextStyle(fontSize: NasTokens.fontCaption),
              ),
              NasDropdown<String>(
                value: _status,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: '', child: Text(tr('accounts.fileLog.anyStatus'))),
                  DropdownMenuItem(value: 'ok', child: Text(tr('accounts.fileLog.ok'))),
                  DropdownMenuItem(value: 'failed', child: Text(tr('accounts.fileLog.failed'))),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _status = value);
                  _applyFilter();
                },
              ),
            ],
          ),
          const SizedBox(height: NasTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('accounts.fileLog.queryHint'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                  onSubmitted: (_) => _applyFilter(),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              TextButton(
                onPressed: _loading ? null : _applyFilter,
                child: Text(tr('common.search')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('accounts.fileLog.empty'),
        icon: Icons.receipt_long_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceLg,
        vertical: NasTokens.spaceXs,
      ),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final row = _items[i];
        final ok = row.status == 'ok';
        final detail = row.detail.trim();
        return ListTile(
          dense: true,
          leading: Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: ok ? context.nasSuccess : context.nasDanger,
          ),
          title: Text(
            '${_actionLabel(row.action)} · ${row.path}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (detail.isNotEmpty && detail != '{}') detail,
              if (row.ip.isNotEmpty) row.ip,
              _time(row.createdAt),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
        );
      },
    );
  }

  Widget _pager() {
    final from = _items.isEmpty ? 0 : _offset + 1;
    final to = _offset + _items.length;
    final caption = TextStyle(fontSize: NasTokens.fontCaption);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceLg,
        vertical: NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Text(tr('accounts.fileLog.total', {'count': '$_total'}), style: caption),
          if (to > 0) ...[
            const SizedBox(width: NasTokens.spaceSm),
            Text(tr('accounts.fileLog.range', {'from': '$from', 'to': '$to'}), style: caption),
          ],
          const Spacer(),
          IconButton(
            tooltip: tr('accounts.fileLog.prev'),
            onPressed: _loading || _offset == 0 ? null : () => _go(_offset - _pageSize),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: tr('accounts.fileLog.next'),
            onPressed: _loading || to >= _total ? null : () => _go(_offset + _pageSize),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _filters(),
        const Divider(height: 1),
        Expanded(child: _list()),
        _pager(),
      ],
    );
  }
}

/// 登录记录 / 账号审计页签：选中用户后按需加载（切换用户时由 Key 重建）。
class _EventTab extends StatefulWidget {
  const _EventTab({super.key, required this.uid, required this.audit});

  final String uid;
  final bool audit;

  @override
  State<_EventTab> createState() => _EventTabState();
}

class _EventTabState extends State<_EventTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

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
      final client = ApiSession.instance.client;
      final res = widget.audit
          ? await client.userAuditLogs(uid: widget.uid, limit: '100')
          : await client.userLoginRecords(uid: widget.uid, limit: '100');
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _label(String type) {
    if (!widget.audit) {
      return type == 'login'
          ? tr('accounts.loginOk')
          : tr('accounts.loginFailed');
    }
    switch (type) {
      case 'user_create':
        return tr('accounts.audit.userCreate');
      case 'user_update':
        return tr('accounts.audit.userUpdate');
      case 'user_delete':
        return tr('accounts.audit.userDelete');
      case '2fa_enable':
        return tr('accounts.audit.2faEnable');
      case '2fa_disable':
        return tr('accounts.audit.2faDisable');
      case 'policy_update':
        return tr('accounts.audit.policyUpdate');
      default:
        return type;
    }
  }

  String _time(int seconds) {
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: widget.audit ? tr('accounts.auditEmpty') : tr('accounts.loginEmpty'),
        icon: widget.audit ? Icons.receipt_long_outlined : Icons.login_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceLg,
        vertical: NasTokens.spaceXs,
      ),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final row = _items[i];
        final type = '${row['type'] ?? ''}';
        final ok = type == 'login';
        final ip = '${row['ip'] ?? ''}';
        final detail = '${row['detail'] ?? ''}';
        final at = (row['createdAt'] as num?)?.toInt() ?? 0;
        return ListTile(
          dense: true,
          leading: Icon(
            widget.audit
                ? Icons.receipt_long_outlined
                : (ok ? Icons.check_circle_outline : Icons.error_outline),
            size: 18,
            color: widget.audit
                ? null
                : (ok ? context.nasSuccess : context.nasDanger),
          ),
          title: Text(
            [
              _label(type),
              if ('${row['username'] ?? ''}'.isNotEmpty) '${row['username']}',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (ip.isNotEmpty) ip,
              if (detail.isNotEmpty && detail != '{}') detail,
              _time(at),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
        );
      },
    );
  }
}

/// 访问令牌（U-H）：列表 / 新建 / 复制 / 撤销；明文只在创建时显示一次。
class _TokensTab extends StatefulWidget {
  const _TokensTab({super.key, required this.uid});

  final String uid;

  @override
  State<_TokensTab> createState() => _TokensTabState();
}

class _TokensTabState extends State<_TokensTab> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _time(Object? value) {
    final seconds = (value as num?)?.toInt() ?? 0;
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.apiTokenList(
        uid: widget.uid,
      );
      if (!mounted) return;
      setState(() {
        _items = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _showSecret(String token) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('accounts.tokens.secretTitle')),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                token,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: NasTokens.spaceSm),
              Text(
                tr('accounts.tokens.secretHint'),
                style: TextStyle(fontSize: NasTokens.fontCaption),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: token));
              if (!ctx.mounted) return;
              NasSnack.show(ctx, tr('accounts.tokens.copied'));
            },
            icon: const Icon(Icons.copy, size: 16),
            label: Text(tr('accounts.tokens.copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final nameCtrl = TextEditingController();
    final scopeCtrl = TextEditingController(text: 'files:read');
    final daysCtrl = TextEditingController(text: '30');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('accounts.tokens.new')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: tr('accounts.tokens.name'),
                    helperText: tr('accounts.tokens.nameHint'),
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                TextField(
                  controller: scopeCtrl,
                  decoration: InputDecoration(
                    labelText: tr('accounts.tokens.scopes'),
                    helperText: 'files:read, video:read',
                  ),
                ),
                const SizedBox(height: NasTokens.spaceMd),
                TextField(
                  controller: daysCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr('accounts.tokens.expires'),
                  ),
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
      );
      if (ok != true) return;
      if (!mounted) return;
      final name = nameCtrl.text.trim();
      final scopes = scopeCtrl.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final messenger = ScaffoldMessenger.of(context);
      try {
        final res = await ApiSession.instance.client.apiTokenCreate(
          body: <String, dynamic>{
            'uid': widget.uid,
            'name': name,
            'scopes': scopes,
            'expiresInDays': int.tryParse(daysCtrl.text.trim()) ?? 0,
          },
        );
        await _load();
        if (!mounted) return;
        final token = '${res['token'] ?? ''}';
        if (token.isNotEmpty) await _showSecret(token);
      } catch (e) {
        NasSnack.showOn(messenger, tr('common.createFailed', {'error': '$e'}));
      }
    } finally {
      nameCtrl.dispose();
      scopeCtrl.dispose();
      daysCtrl.dispose();
    }
  }

  Future<void> _revoke(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('accounts.tokens.revoke')),
        content: Text('${item['name'] ?? ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('accounts.tokens.revoke')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.apiTokenRevoke(
        body: <String, dynamic>{'id': '${item['id']}', 'uid': widget.uid},
      );
      await _load();
    } catch (e) {
      NasSnack.showOn(messenger, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceLg,
            NasTokens.spaceXs,
            NasTokens.spaceSm,
            NasTokens.spaceXs,
          ),
          child: Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.key, size: 16),
                label: Text(tr('accounts.tokens.new')),
              ),
              NasRefreshButton(onPressed: _load),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('accounts.tokens.empty'),
        icon: Icons.key_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceLg,
        vertical: NasTokens.spaceXs,
      ),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = _items[i];
        final revoked = item['revoked'] == true;
        final scopes = (item['scopes'] as List?) ?? const [];
        final expiresAt = item['expiresAt'];
        final lastUsedAt = item['lastUsedAt'];
        return ListTile(
          dense: true,
          leading: Icon(
            revoked ? Icons.block : Icons.key_outlined,
            size: 18,
            color: revoked ? context.nasTextSecondary : null,
          ),
          title: Text(
            '${item['name'] ?? ''}${revoked ? ' · ${tr('accounts.tokens.revoked')}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              scopes.map((e) => '$e').join(', '),
              tr('accounts.tokens.created', {'time': _time(item['createdAt'])}),
              lastUsedAt == null
                  ? tr('accounts.tokens.neverUsed')
                  : tr('accounts.tokens.lastUsed', {'time': _time(lastUsedAt)}),
              if (expiresAt != null)
                tr('accounts.tokens.expiresAt', {'time': _time(expiresAt)}),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
          trailing: revoked
              ? null
              : TextButton(
                  onPressed: () => _revoke(item),
                  child: Text(tr('accounts.tokens.revoke')),
                ),
        );
      },
    );
  }
}

/// IP 黑名单弹窗：加入 / 移除规则，成功后回写主页面计数。
class _IpRulesDialog extends StatefulWidget {
  const _IpRulesDialog({required this.rules, required this.onChanged});

  final List<Map<String, dynamic>> rules;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;

  @override
  State<_IpRulesDialog> createState() => _IpRulesDialogState();
}

class _IpRulesDialogState extends State<_IpRulesDialog> {
  late List<Map<String, dynamic>> _rules;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rules = widget.rules;
  }

  Future<void> _reload() async {
    final res = await ApiSession.instance.client.securityIpList();
    final items = (res['items'] as List<dynamic>? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    if (!mounted) return;
    setState(() => _rules = items);
    widget.onChanged(items);
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.accounts.012')),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: tr('ui.accounts.013'),
            helperText: tr('ui.accounts.014'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.accounts.015')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final rule = ctrl.text.trim();
    if (rule.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.securityIpAdd(body: {'rule': rule});
      await _reload();
    } catch (e) {
      NasSnack.showOn(messenger, tr('accounts.joinFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String rule) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiSession.instance.client.securityIpRemove(body: {'rule': rule});
      await _reload();
    } catch (e) {
      NasSnack.showOn(messenger, tr('accounts.removeFailed', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(tr('accounts.ipBlacklist'))),
          Text(
            tr('accounts.ipRulesCount', {'count': '${_rules.length}'}),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 380,
        child: _rules.isEmpty
            ? Center(child: Text(tr('ui.accounts.h2476e7')))
            : ListView.separated(
                itemCount: _rules.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final rule = _rules[i]['rule'] as String? ?? '';
                  return ListTile(
                    leading: const Icon(Icons.block, size: 18),
                    title: Text(rule),
                    subtitle: Text(tr('ui.accounts.018')),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: tr('ui.accounts.019'),
                      onPressed: rule.isEmpty || _busy
                          ? null
                          : () => _remove(rule),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.add, size: 16),
          label: Text(tr('ui.accounts.012')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }
}