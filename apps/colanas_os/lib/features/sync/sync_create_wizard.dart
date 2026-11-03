import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'sync_engine.dart';
import 'sync_fs.dart';
import 'sync_scheduler.dart';

/// 创建 / 编辑同步任务：设备确认 → 规则（名称/模式/按需/高级）→ 路径。
///
/// 与参考实现同顺序；「按需同步 / 冲突策略 / 删除传播」先以禁用态展示，
/// 待服务端 S-C 落地后打开（避免做成假开关）。
class SyncCreateWizard extends StatefulWidget {
  const SyncCreateWizard({
    super.key,
    this.editing,
    this.deviceId = '',
    this.deviceName = '',
  });

  final SyncTask? editing;
  final String deviceId;
  final String deviceName;

  @override
  State<SyncCreateWizard> createState() => _SyncCreateWizardState();
}

class _SyncCreateWizardState extends State<SyncCreateWizard> {
  static const _presetExcludes = <String>[
    'node_modules',
    '*.tmp',
    '*.log',
    '.git',
    '.DS_Store',
    'Thumbs.db',
    '@eaDir',
  ];

  late final TextEditingController _name;
  late final TextEditingController _deviceName;
  late final TextEditingController _localDir;
  late final TextEditingController _remoteDir;
  late final TextEditingController _include;
  late final TextEditingController _exclude;
  late final TextEditingController _intervalCtrl;

  int _step = 0;
  String _mode = 'bidirectional';
  late SyncFilterConfig _filter;
  late SyncTaskConfig _config;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _name = TextEditingController(text: e?.name ?? '');
    _deviceName = TextEditingController(
      text: e?.deviceName.isNotEmpty == true
          ? e!.deviceName
          : widget.deviceName,
    );
    _localDir = TextEditingController(text: e?.localDir ?? '');
    _remoteDir = TextEditingController(text: e?.remoteDir ?? '');
    _include = TextEditingController(text: (e?.include ?? const []).join('\n'));
    _exclude = TextEditingController(text: (e?.exclude ?? const []).join('\n'));
    _mode = e?.mode ?? 'bidirectional';
    _filter = e?.filterConfig ?? const SyncFilterConfig();
    _config = e?.syncConfig ??
        SyncTaskConfig(
          conflictStrategy: 'prefer_newer',
          intervalMinutes: SyncScheduler.instance.intervalMin,
        );
    _intervalCtrl = TextEditingController(
      text: (_config.intervalMinutes > 0) ? '${_config.intervalMinutes}' : '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _deviceName.dispose();
    _localDir.dispose();
    _remoteDir.dispose();
    _include.dispose();
    _exclude.dispose();
    _intervalCtrl.dispose();
    super.dispose();
  }

  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _pickLocal() async {
    final picked = await SyncEngine.instance.fs.pickDirectory();
    if (picked == null || picked.isEmpty) return;
    setState(() => _localDir.text = picked);
  }

  String _filterSummary() {
    final parts = <String>[];
    if (_filter.excludeSmallEnabled && _filter.excludeSmallSize > 0) {
      parts.add(
        '${tr('sync.wizard.filterSmall')} ${_filter.excludeSmallSize} ${_filter.excludeSmallUnit}',
      );
    }
    if (_filter.excludeLargeEnabled && _filter.excludeLargeSize > 0) {
      parts.add(
        '${tr('sync.wizard.filterLarge')} ${_filter.excludeLargeSize} ${_filter.excludeLargeUnit}',
      );
    }
    if (_filter.excludeHidden) parts.add(tr('sync.wizard.filterHidden'));
    if (_filter.excludeExtensionEnabled && _filter.excludeExtensions.isNotEmpty) {
      parts.add(
        '${tr('sync.wizard.filterExt')} ${_filter.excludeExtensions.join(', ')}',
      );
    }
    return parts.isEmpty
        ? tr('sync.wizard.filterNone')
        : tr('sync.wizard.filterSummary', {'summary': parts.join(' · ')});
  }

  Future<void> _openFilterDialog() async {
    var f = _filter;
    final smallCtrl = TextEditingController(
      text: f.excludeSmallSize > 0 ? '${f.excludeSmallSize}' : '',
    );
    final largeCtrl = TextEditingController(
      text: f.excludeLargeSize > 0 ? '${f.excludeLargeSize}' : '',
    );
    final extCtrl = TextEditingController(text: f.excludeExtensions.join(', '));
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            Widget unitField(
              String value,
              ValueChanged<String> onChanged,
            ) {
              return SizedBox(
                width: 90,
                child: DropdownButtonFormField<String>(
                  initialValue: value,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'KB', child: Text('KB')),
                    DropdownMenuItem(value: 'MB', child: Text('MB')),
                    DropdownMenuItem(value: 'GB', child: Text('GB')),
                  ],
                  onChanged: (v) => setDialogState(() => onChanged(v ?? 'KB')),
                ),
              );
            }

            return AlertDialog(
              title: Text(tr('sync.wizard.filterTitle')),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(tr('sync.wizard.filterSmall')),
                        value: f.excludeSmallEnabled,
                        onChanged: (v) => setDialogState(
                          () => f = f.copyWith(excludeSmallEnabled: v),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: smallCtrl,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: tr('sync.wizard.filterSize'),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: NasTokens.spaceSm),
                          unitField(
                            f.excludeSmallUnit,
                            (v) => f = f.copyWith(excludeSmallUnit: v),
                          ),
                        ],
                      ),
                      const SizedBox(height: NasTokens.spaceMd),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(tr('sync.wizard.filterLarge')),
                        value: f.excludeLargeEnabled,
                        onChanged: (v) => setDialogState(
                          () => f = f.copyWith(excludeLargeEnabled: v),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: largeCtrl,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: tr('sync.wizard.filterSize'),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: NasTokens.spaceSm),
                          unitField(
                            f.excludeLargeUnit,
                            (v) => f = f.copyWith(excludeLargeUnit: v),
                          ),
                        ],
                      ),
                      const SizedBox(height: NasTokens.spaceMd),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(tr('sync.wizard.filterHidden')),
                        value: f.excludeHidden,
                        onChanged: (v) => setDialogState(
                          () => f = f.copyWith(excludeHidden: v),
                        ),
                      ),
                      const SizedBox(height: NasTokens.spaceMd),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(tr('sync.wizard.filterExt')),
                        value: f.excludeExtensionEnabled,
                        onChanged: (v) => setDialogState(
                          () => f = f.copyWith(excludeExtensionEnabled: v),
                        ),
                      ),
                      TextField(
                        controller: extCtrl,
                        decoration: const InputDecoration(
                          hintText: 'jpg, png, tmp',
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
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
            );
          },
        ),
      );
      if (ok != true) return;
      final next = f.copyWith(
        excludeSmallSize: int.tryParse(smallCtrl.text.trim()) ?? 0,
        excludeLargeSize: int.tryParse(largeCtrl.text.trim()) ?? 0,
        excludeExtensions: extCtrl.text
            .split(',')
            .map((e) => e.trim().replaceFirst(RegExp(r'^\.'), ''))
            .where((e) => e.isNotEmpty)
            .toList(),
      );
      if (!mounted) return;
      setState(() => _filter = next);
    } finally {
      smallCtrl.dispose();
      largeCtrl.dispose();
      extCtrl.dispose();
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final local = _localDir.text.trim();
    final remote = _remoteDir.text.trim().replaceAll(RegExp(r'^/+'), '');
    if (name.isEmpty) {
      setState(() {
        _step = 1;
        _error = tr('sync.wizard.nameRequired');
      });
      return;
    }
    if (local.isEmpty || remote.isEmpty) {
      setState(() {
        _step = 2;
        _error = tr('sync.wizard.required');
      });
      return;
    }
    // 建任务前先探测远端目录（不存在会在 upsert 时创建；只读则直接拦下）
    try {
      final probe = await ApiSession.instance.client.syncProbe(
        body: <String, dynamic>{'remoteDir': remote},
      );
      if (probe['allowed'] == false) {
        setState(() {
          _step = 2;
          _error = tr('sync.wizard.probeEscape');
        });
        return;
      }
      if (probe['exists'] == true && probe['writable'] != true) {
        setState(() {
          _step = 2;
          _error = tr('sync.wizard.probeReadonly');
        });
        return;
      }
    } catch (_) {
      // 旧服务端没有 probe：不阻断保存
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiSession.instance.client.syncTaskUpsert(
        body: <String, dynamic>{
          if (widget.editing != null) 'id': widget.editing!.id,
          'name': name,
          'deviceId': widget.editing?.deviceId.isNotEmpty == true
              ? widget.editing!.deviceId
              : (widget.deviceId.isEmpty ? 'desktop' : widget.deviceId),
          'deviceName': _deviceName.text.trim(),
          'mode': _mode,
          'localDir': local,
          'remoteDir': remote,
          'include': _lines(_include),
          'exclude': _lines(_exclude),
          'filterConfig': _filter.toJson(),
          'syncConfig': _config.toJson(),
        },
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.editing == null
        ? tr('sync.createTask')
        : tr('sync.editTask');
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _steps(),
              const SizedBox(height: NasTokens.spaceMd),
              switch (_step) {
                0 => _deviceStep(),
                1 => _rulesStep(),
                _ => _pathsStep(),
              },
              if (_error != null) ...[
                const SizedBox(height: NasTokens.spaceSm),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: Text(tr('common.cancel')),
        ),
        if (_step > 0)
          TextButton(
            onPressed: _saving ? null : () => setState(() => _step -= 1),
            child: Text(tr('sync.wizard.prev')),
          ),
        if (_step < 2)
          FilledButton(
            onPressed: () {
              if (_step == 1 && _name.text.trim().isEmpty) {
                setState(() => _error = tr('sync.wizard.nameRequired'));
                return;
              }
              setState(() {
                _error = null;
                _step += 1;
              });
            },
            child: Text(tr('sync.wizard.next')),
          )
        else
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr('common.save')),
          ),
      ],
    );
  }

  Widget _steps() {
    final scheme = Theme.of(context).colorScheme;
    const keys = [
      'sync.wizard.step.device',
      'sync.wizard.step.rules',
      'sync.wizard.step.paths',
    ];
    return Row(
      children: [
        for (var i = 0; i < keys.length; i += 1) ...[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= _step
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
            ),
            child: Text(
              '${i + 1}',
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                fontWeight: FontWeight.w700,
                color: i <= _step ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: NasTokens.spaceXs),
          Text(
            tr(keys[i]),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: i == _step ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: i == _step ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          if (i < keys.length - 1)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NasTokens.spaceSm,
                ),
                child: Divider(color: scheme.outlineVariant),
              ),
            ),
        ],
      ],
    );
  }

  Widget _badge(String text, Color color) {
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

  Widget _deviceCard({
    required IconData icon,
    required String title,
    required String badge,
    required Color badgeColor,
    required Widget child,
  }) {
    return NasCard(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: NasTokens.iconMd),
              const SizedBox(width: NasTokens.spaceXs),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _badge(badge, badgeColor),
            ],
          ),
          const SizedBox(height: NasTokens.spaceSm),
          child,
        ],
      ),
    );
  }

  Widget _deviceStep() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _deviceCard(
                icon: Icons.computer_outlined,
                title: tr('sync.wizard.deviceTitle'),
                badge: tr('sync.wizard.ready'),
                badgeColor: context.nasSuccess,
                child: TextField(
                  controller: _deviceName,
                  decoration: InputDecoration(
                    labelText: tr('sync.device'),
                    helperText: tr('sync.wizard.deviceHint'),
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            Expanded(
              child: _deviceCard(
                icon: Icons.dns_outlined,
                title: tr('sync.wizard.nasTitle'),
                badge: tr('sync.wizard.loggedIn'),
                badgeColor: scheme.primary,
                child: Text(
                  ApiSession.instance.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        Text(
          tr('sync.wizard.deviceConfirmHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _rulesStep() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _name,
          maxLength: 32,
          decoration: InputDecoration(
            labelText: tr('sync.wizard.name'),
            helperText: tr('sync.wizard.nameHint'),
          ),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'bidirectional',
              label: Text(tr('sync.modeBoth')),
              icon: const Icon(Icons.swap_horiz, size: 16),
            ),
            ButtonSegment(
              value: 'upload_only',
              label: Text(tr('sync.modeUp')),
              icon: const Icon(Icons.upload, size: 16),
            ),
            ButtonSegment(
              value: 'download_only',
              label: Text(tr('sync.modeDown')),
              icon: const Icon(Icons.download, size: 16),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (v) => setState(() => _mode = v.first),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        Text(
          tr('sync.wizard.modeHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(tr('sync.wizard.realtime')),
          subtitle: Text(
            tr('sync.wizard.realtimeHint'),
            style: TextStyle(fontSize: NasTokens.fontMicro),
          ),
          value: _config.realtime,
          onChanged: (v) => setState(() => _config = SyncTaskConfig(
            realtime: v,
            intervalMinutes: _config.intervalMinutes,
            conflictStrategy: _config.conflictStrategy,
            deleteExtra: _config.deleteExtra,
          )),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Row(
          children: [
            Expanded(
              child: Text(
                tr('sync.wizard.interval'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _intervalCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('sync.wizard.intervalMinutes'),
                  helperText: tr('sync.wizard.intervalHint'),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _config = SyncTaskConfig(
                  realtime: _config.realtime,
                  intervalMinutes: int.tryParse(v.trim()) ?? 0,
                  conflictStrategy: _config.conflictStrategy,
                  deleteExtra: _config.deleteExtra,
                )),
              ),
            ),
          ],
        ),
        const Divider(height: 1),
        const SizedBox(height: NasTokens.spaceSm),
        Text(
          tr('sync.wizard.advanced'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Row(
          children: [
            Expanded(
              child: Text(
                tr('sync.wizard.conflict'),
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceXs),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'prefer_newer',
              label: Text(tr('sync.wizard.conflictNewer')),
            ),
            ButtonSegment(
              value: 'prefer_local',
              label: Text(tr('sync.wizard.conflictLocal')),
            ),
            ButtonSegment(
              value: 'prefer_remote',
              label: Text(tr('sync.wizard.conflictRemote')),
            ),
            ButtonSegment(
              value: 'manual',
              label: Text(tr('sync.wizard.conflictManual')),
            ),
          ],
          selected: {_config.conflictStrategy},
          onSelectionChanged: (v) => setState(() => _config = SyncTaskConfig(
            realtime: _config.realtime,
            intervalMinutes: _config.intervalMinutes,
            conflictStrategy: v.first,
            deleteExtra: _config.deleteExtra,
          )),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(tr('sync.wizard.deleteExtra')),
          subtitle: Text(
            tr('sync.wizard.deleteExtraHint'),
            style: TextStyle(fontSize: NasTokens.fontMicro),
          ),
          value: _config.deleteExtra,
          onChanged: (v) => setState(() => _config = SyncTaskConfig(
            realtime: _config.realtime,
            intervalMinutes: _config.intervalMinutes,
            conflictStrategy: _config.conflictStrategy,
            deleteExtra: v,
          )),
        ),
        const Divider(height: 1),
        const SizedBox(height: NasTokens.spaceSm),
        Row(
          children: [
            Expanded(
              child: Text(
                tr('sync.wizard.filterTitle'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: _openFilterDialog,
              icon: const Icon(Icons.tune, size: 16),
              label: Text(tr('sync.wizard.editFilter')),
            ),
          ],
        ),
        Text(
          _filterSummary(),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('sync.wizard.ruleHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _include,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: tr('sync.wizard.include'),
                  hintText: '*',
                ),
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            Expanded(
              child: TextField(
                controller: _exclude,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: tr('sync.wizard.exclude'),
                  hintText: 'node_modules\n*.tmp',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        Wrap(
          spacing: NasTokens.spaceXs,
          runSpacing: NasTokens.spaceXs,
          children: [
            Text(
              '${tr('sync.wizard.rulePreset')}: ',
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                color: scheme.onSurfaceVariant,
              ),
            ),
            for (final rule in _presetExcludes)
              ActionChip(
                label: Text(rule),
                onPressed: () {
                  final list = _lines(_exclude);
                  if (list.contains(rule)) return;
                  list.add(rule);
                  setState(() => _exclude.text = list.join('\n'));
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _pathsStep() {
    final scheme = Theme.of(context).colorScheme;
    final local = _localDir.text.trim();
    final remote = _remoteDir.text.trim().replaceAll(RegExp(r'^/+'), '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _localDir,
                decoration: InputDecoration(
                  labelText: tr('sync.localDir'),
                  hintText: tr('sync.wizard.localHint'),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: NasTokens.spaceXs),
            IconButton(
              tooltip: tr('sync.wizard.pickDir'),
              onPressed: _pickLocal,
              icon: const Icon(Icons.folder_open_outlined),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        TextField(
          controller: _remoteDir,
          decoration: InputDecoration(
            labelText: tr('sync.remoteDir'),
            hintText: tr('sync.wizard.remoteHint'),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        NasCard(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('sync.wizard.pathSummary'),
                style: const TextStyle(
                  fontSize: NasTokens.fontCaption,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                local.isEmpty && remote.isEmpty
                    ? tr('sync.wizard.required')
                    : '${local.isEmpty ? '—' : local}  →  NAS: ${remote.isEmpty ? '—' : remote}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NasTokens.spaceSm),
        Text(
          tr('sync.wizard.safety'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}