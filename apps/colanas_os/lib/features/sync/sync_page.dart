import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'sync_autostart.dart';
import 'sync_create_wizard.dart';
import 'sync_engine.dart';
import 'sync_record_dialog.dart';
import 'sync_scheduler.dart';
import 'sync_task_card.dart';

/// 目录同步：左侧二级菜单 + 任务列表。
///
/// 与旧页面的区别：旧页面是「选两个目录 → 立即合并」的一次性操作；
/// 这里是持久化任务（设备 / 模式 / 本地与 NAS 目录 / include-exclude）+
/// 三向比对执行 + 运行记录。服务端负责扫远端与基线，客户端负责本地扫描与传输。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final _engine = SyncEngine.instance;
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  List<SyncTask> _tasks = const [];
  String _keyword = '';
  String _page = 'tasks';
  bool _collapsed = false;
  String _deviceId = '';
  String _deviceName = '';

  @override
  void initState() {
    super.initState();
    _engine.revision.addListener(_onEngine);
    _searchCtrl.addListener(_onSearch);
    // 按需同步（每任务 realtime）依赖调度器的目录监听，进入页面即启动
    SyncScheduler.instance.start();
    _initDevice();
    _load();
  }

  @override
  void dispose() {
    // 页面打开的按需同步随页面关掉；用户若开了「后台自动同步」则保持调度
    // （以前这里不停，没开自动同步的用户也会每分钟空转一次直到退出应用）。
    if (!SyncScheduler.instance.enabled) SyncScheduler.instance.stop();
    _engine.revision.removeListener(_onEngine);
    _searchCtrl.removeListener(_onSearch);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch() {
    if (mounted) setState(() => _keyword = _searchCtrl.text);
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _initDevice() async {
    try {
      final id = await _engine.fs.resolveDeviceId();
      final name = await _engine.fs.resolveDeviceName();
      if (!mounted) return;
      setState(() {
        _deviceId = id;
        _deviceName = name;
      });
      await _claimLegacy(id);
    } catch (_) {
      // 设备标识解析失败不阻断页面：创建任务时再兜底
    }
  }

  /// 升级用户的旧任务（uid 为空）归到当前账号；失败不影响页面
  Future<void> _claimLegacy(String deviceId) async {
    if (deviceId.isEmpty || !_engine.fs.canSync) return;
    try {
      final res = await ApiSession.instance.client.syncClaimLegacy(
        body: <String, dynamic>{'deviceId': deviceId},
      );
      final claimed = (res['claimed'] as num?)?.toInt() ?? 0;
      if (claimed > 0 && mounted) await _load();
    } catch (_) {
      // 老服务端没有该接口 / 无权限：忽略
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.syncTaskList();
      final raw = (res['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _tasks = raw
            .whereType<Map>()
            .map((e) => SyncTask.fromJson(Map<String, dynamic>.from(e)))
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

  Future<void> _openWizard({SyncTask? editing}) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SyncCreateWizard(
        editing: editing,
        deviceId: _deviceId,
        deviceName: _deviceName,
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _delete(SyncTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('sync.delete.title')),
        content: Text(tr('sync.delete.body')),
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
    try {
      await ApiSession.instance.client.syncTaskDelete(
        body: {'id': task.id},
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _run(SyncTask task) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await _engine.run(task);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? tr('sync.run.ok', {
                  'up': result.uploaded,
                  'down': result.downloaded,
                  'del': result.deleted,
                  'skip': result.skipped,
                })
              : tr('sync.run.failed', {
                  'error': result.error ??
                      (result.errors.isEmpty ? '' : result.errors.first),
                }),
        ),
      ),
    );
    await _load();
  }

  /// 自动同步设置：开关 + 间隔（应用运行期间生效）+ 开机自启（桌面独立端）。
  Future<void> _openAutoSync() async {
    var enabled = SyncScheduler.instance.enabled;
    var interval = SyncScheduler.instance.intervalMin;
    final autoStart = createSyncAutoStart();
    var autoStartEnabled = autoStart.enabled;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('sync.auto.title')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('sync.auto.enable')),
                  value: enabled,
                  onChanged: (v) => setLocal(() => enabled = v),
                ),
                Text(
                  tr('sync.auto.hint'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                DropdownButtonFormField<int>(
                  initialValue: interval,
                  decoration: InputDecoration(
                    labelText: tr('sync.auto.interval'),
                  ),
                  items: [
                    for (final m in syncIntervalOptions)
                      DropdownMenuItem(
                        value: m,
                        child: Text(tr('sync.auto.minutes', {'n': m})),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => interval = v ?? interval),
                ),
                const SizedBox(height: NasTokens.spaceSm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('sync.autostart.enable')),
                  subtitle: Text(
                    autoStart.supported
                        ? tr('sync.autostart.hint')
                        : tr(autoStart.unsupportedReasonKey),
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: autoStartEnabled,
                  onChanged: autoStart.supported
                      ? (v) => setLocal(() => autoStartEnabled = v)
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await SyncScheduler.instance.tickNow();
                messenger.showSnackBar(
                  SnackBar(content: Text(tr('sync.auto.checkNow'))),
                );
              },
              child: Text(tr('sync.auto.runCheck')),
            ),
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
    await SyncScheduler.instance.setIntervalMinutes(interval);
    await SyncScheduler.instance.setEnabled(enabled);
    if (autoStart.supported && autoStartEnabled != autoStart.enabled) {
      final changed = await autoStart.setEnabled(autoStartEnabled);
      if (!changed) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('sync.autostart.failed'))),
        );
      }
    }
  }

  List<SyncTask> get _visible {
    final k = _keyword.trim().toLowerCase();
    if (k.isEmpty) return _tasks;
    return _tasks.where((t) {
      return t.deviceName.toLowerCase().contains(k) ||
          t.localDir.toLowerCase().contains(k) ||
          t.remoteDir.toLowerCase().contains(k);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final canSync = _engine.fs.canSync;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final help = _page == 'help';
    return Scaffold(
      appBar: AppBar(
        title: Text(help ? tr('sync.menu.help') : tr('app.sync')),
        actions: [
          if (!wide)
            IconButton(
              tooltip: help ? tr('sync.menu.tasks') : tr('sync.menu.help'),
              icon: Icon(help ? Icons.sync_outlined : Icons.help_outline),
              onPressed: () => setState(() => _page = help ? 'tasks' : 'help'),
            ),
          if (!wide && canSync)
            IconButton(
              tooltip: tr('sync.createTask'),
              onPressed: () => _openWizard(),
              icon: const Icon(Icons.add),
            ),
          if (!wide)
            IconButton(
              tooltip: tr('common.refresh'),
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          if (wide)
            IconButton(
              tooltip: _collapsed
                  ? tr('nav.expand')
                  : tr('nav.collapse'),
              icon: Icon(
                _collapsed
                    ? Icons.keyboard_double_arrow_right
                    : Icons.keyboard_double_arrow_left,
              ),
              onPressed: () => setState(() => _collapsed = !_collapsed),
            ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                _nav(canSync),
                const VerticalDivider(width: 1),
                Expanded(child: help ? _help() : _tasksView(canSync)),
              ],
            )
          : (help ? _help() : _tasksView(canSync)),
    );
  }

  Widget _nav(bool canSync) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _collapsed ? 56 : 176,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: NasTokens.spaceXs,
                vertical: NasTokens.spaceSm,
              ),
              children: [
                _navTile(
                  icon: Icons.sync_outlined,
                  labelKey: 'sync.menu.tasks',
                  selected: _page == 'tasks',
                  onTap: () => setState(() => _page = 'tasks'),
                ),
                _navTile(
                  icon: Icons.help_outline,
                  labelKey: 'sync.menu.help',
                  selected: _page == 'help',
                  onTap: () => setState(() => _page = 'help'),
                ),
              ],
            ),
          ),
          if (canSync)
            Padding(
              padding: const EdgeInsets.all(NasTokens.spaceSm),
              child: _collapsed
                  ? IconButton.filled(
                      tooltip: tr('sync.createTask'),
                      onPressed: () => _openWizard(),
                      icon: const Icon(Icons.add, size: 18),
                    )
                  : FilledButton.icon(
                      onPressed: () => _openWizard(),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(
                        tr('sync.createTask'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
          const SizedBox(height: NasTokens.spaceXs),
        ],
      ),
    ).withColor(scheme);
  }

  Widget _navTile({
    required IconData icon,
    required String labelKey,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.74);
    final tile = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: Container(
        height: 42,
        padding: EdgeInsets.symmetric(
          horizontal: _collapsed ? 0 : NasTokens.spaceSm,
        ),
        alignment: _collapsed ? Alignment.center : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        ),
        child: _collapsed
            ? Icon(icon, size: NasTokens.iconMd, color: fg)
            : Row(
                children: [
                  Icon(icon, size: NasTokens.iconMd, color: fg),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: Text(
                      tr(labelKey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontBody,
                        color: fg,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    return _collapsed ? Tooltip(message: tr(labelKey), child: tile) : tile;
  }

  Widget _tasksView(bool canSync) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final items = _visible;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('sync.taskCount', {'count': items.length}),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                    if (!canSync)
                      Text(
                        tr('sync.webUnsupported'),
                        style: TextStyle(
                          fontSize: NasTokens.fontMicro,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              if (wide)
                SizedBox(
                  width: 220,
                  child: NasSearchField(
                    controller: _searchCtrl,
                    hintText: tr('common.search'),
                  ),
                ),
              const SizedBox(width: NasTokens.spaceXs),
              if (canSync)
                IconButton(
                  tooltip: tr('sync.auto.title'),
                  onPressed: _openAutoSync,
                  icon: const Icon(Icons.schedule),
                ),
              if (wide)
                IconButton(
                  tooltip: tr('common.refresh'),
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
        if (!wide)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceXs,
              NasTokens.spaceMd,
              0,
            ),
            child: NasSearchField(
              controller: _searchCtrl,
              hintText: tr('common.search'),
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: NasTokens.spaceXl),
                    NasEmptyState(
                      title: tr('sync.emptyTasks'),
                      icon: Icons.sync,
                    ),
                    if (canSync)
                      Center(
                        child: FilledButton.icon(
                          onPressed: () => _openWizard(),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(tr('sync.createTask')),
                        ),
                      ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NasTokens.spaceMd,
                      vertical: NasTokens.spaceSm,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final task = items[i];
                      return SyncTaskCard(
                        task: task,
                        engine: _engine,
                        canRun: canSync,
                        onRun: () => _run(task),
                        onEdit: () => _openWizard(editing: task),
                        onDelete: () => _delete(task),
                        onRecords: () => showDialog<void>(
                          context: context,
                          builder: (_) => SyncRecordDialog(task: task),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _help() {
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('sync.help.title'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: NasTokens.spaceSm),
        for (final line in tr('sync.help.body').split('\n'))
          Padding(
            padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
            child: Text(line),
          ),
      ],
    );
  }
}

extension on Widget {
  /// 左栏底色：桌面形态下与内容区区分
  Widget withColor(ColorScheme scheme) {
    return Container(color: scheme.surfaceContainerLow, child: this);
  }
}
