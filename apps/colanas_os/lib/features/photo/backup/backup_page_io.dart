import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'photo_backup_album_picker.dart';
import 'cola_photo_backup_controller.dart';
import 'cola_photo_backup_models.dart';
import 'photo_backup_target_picker.dart';

/// 手机相册备份（单向增量：本机 → NAS）。
///
/// 整机只维护**一份**配置：进入即备份页，没有「+ 新建任务」。
/// 四张卡（状态 / 设置 / 开关 / 进度）+ 底栏「立即备份 / 停止」，
/// AppBar 提供「重新扫描全部」「查看备份记录」；记录可下钻到文件级明细。
///
/// 与「选几个文件传一下」的区别：开启后登录成功 / 回到 WiFi 自动跑一轮，
/// 已处理素材按 id 落盘做零 I/O 增量，内容级去重，单文件失败重试 3 次不中断整轮。
class PhotoBackupPage extends StatefulWidget {
  const PhotoBackupPage({super.key, this.embedded = false});

  /// 嵌入相册二级导航内容区时去掉自带 Scaffold / AppBar
  final bool embedded;

  @override
  State<PhotoBackupPage> createState() => _PhotoBackupPageState();
}

class _PhotoBackupPageState extends State<PhotoBackupPage> {
  /// 进程级单例：页面随便进出 / App 最小化，控制器和后台上传都不受影响。
  /// 早期这里是 `PhotoBackupController()` + dispose()，一离开页面备份就断。
  final PhotoBackupController _c = PhotoBackupController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_c.init());
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody(context);
    final bottom = _buildBottomBar();
    if (widget.embedded) {
      return Column(
        children: [
          Expanded(child: body),
          bottom,
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('photo.backup.title')),
        actions: [
          IconButton(
            tooltip: tr('photo.backup.rescanAll'),
            onPressed: _c.isRunning ? null : () => _rescanAll(context),
            icon: const Icon(Icons.restart_alt),
          ),
          IconButton(
            tooltip: tr('photo.backup.runs'),
            onPressed: () => _showRuns(context),
            icon: const Icon(Icons.history),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: bottom,
    );
  }

  Widget _buildBody(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (_c.loading && _c.task == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final task = _c.task;
        if (task == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(NasTokens.spaceLg),
              child: Text(
                tr('photo.backup.needLogin'),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            if (widget.embedded) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('photo.backup.title'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: tr('photo.backup.rescanAll'),
                    onPressed: _c.isRunning ? null : () => _rescanAll(context),
                    icon: const Icon(Icons.restart_alt),
                  ),
                  IconButton(
                    tooltip: tr('photo.backup.runs'),
                    onPressed: () => _showRuns(context),
                    icon: const Icon(Icons.history),
                  ),
                ],
              ),
              const SizedBox(height: NasTokens.spaceXs),
            ],
            if (kIsWeb)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(NasTokens.spaceMd),
                  child: Text(tr('photo.backup.webHint')),
                ),
              ),
            if (_c.permissionError.isNotEmpty)
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.no_photography_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(tr('photo.backup.permissionMissing')),
                  trailing: TextButton(
                    onPressed: () => _c.openPermissionSettings(),
                    child: Text(tr('photo.backup.openSettings')),
                  ),
                ),
              ),
            _statusCard(context, task),
            const SizedBox(height: 12),
            _settingsCard(context, task),
            const SizedBox(height: 12),
            _switchesCard(context, task),
            const SizedBox(height: 12),
            _progressCard(context),
          ],
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (_c.task == null) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: _c.isRunning
                ? OutlinedButton.icon(
                    onPressed: () => _c.cancelTask(),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(tr('photo.backup.stop')),
                  )
                : FilledButton.icon(
                    // 与总开关联动：没开启会先把开关打开再跑。
                    // 正在等 WiFi 时点了也没用（网络守卫会再次拦下），直接置灰。
                    onPressed: (kIsWeb || _c.waitingWifi)
                        ? null
                        : () => _c.requestBackupNow(),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: Text(
                      _c.waitingWifi
                          ? tr('photo.backup.waitingWifi')
                          : tr('photo.backup.backupNow'),
                    ),
                  ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ 状态卡

  Widget _statusCard(BuildContext context, BackupTask task) {
    final theme = Theme.of(context);
    final phase = _c.rt.phase;
    final Color iconColor;
    IconData? badge;
    Color badgeColor;
    switch (phase) {
      case BackupPhase.running:
        iconColor = theme.colorScheme.primary;
        badge = Icons.arrow_upward_rounded;
        badgeColor = theme.colorScheme.primary;
      case BackupPhase.done:
        iconColor = theme.colorScheme.primary;
        badge = Icons.check_rounded;
        badgeColor = Colors.green;
      case BackupPhase.error:
        iconColor = theme.colorScheme.error;
        badge = Icons.error_outline_rounded;
        badgeColor = theme.colorScheme.error;
      case BackupPhase.paused:
        iconColor = const Color(0xFFF59E0B);
        badge = Icons.pause_circle_outline_rounded;
        badgeColor = const Color(0xFFF59E0B);
      case BackupPhase.idle:
        iconColor = theme.colorScheme.onSurfaceVariant;
        badge = null;
        badgeColor = theme.colorScheme.onSurfaceVariant;
      case BackupPhase.off:
        iconColor = theme.colorScheme.outline;
        badge = null;
        badgeColor = theme.colorScheme.outline;
    }

    final rt = _c.rt;
    final String title;
    switch (phase) {
      case BackupPhase.running:
        title = tr('photo.backup.statusRunning', <String, Object>{
          'done': '${rt.done}',
          'total': '${rt.runTotal}',
        });
      case BackupPhase.done:
        title = tr('photo.backup.statusDone', {'count': '${rt.uploaded}'});
      case BackupPhase.paused:
        title = rt.error.trim().isEmpty
            ? tr('photo.backup.waitWifi')
            : _errorText(rt.error);
      case BackupPhase.error:
        title = rt.error.trim().isEmpty
            ? tr('photo.backup.statusError')
            : _errorText(rt.error);
      case BackupPhase.idle:
        title = tr('photo.backup.statusIdle');
      case BackupPhase.off:
        title = tr('photo.backup.statusOff');
    }

    return _sectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(Icons.photo_outlined, size: 44, color: iconColor),
                    if (badge != null)
                      Positioned(
                        right: 12,
                        bottom: 10,
                        child: Icon(badge, size: 18, color: badgeColor),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          value: task.enabled,
          onChanged: (v) => _c.setEnabled(v),
          title: Text(tr('photo.backup.enable')),
          subtitle: Text(
            tr('photo.backup.enableHint'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 设置卡

  Widget _settingsCard(BuildContext context, BackupTask task) {
    final albumsLabel = task.sourceIds.isEmpty
        ? tr('photo.backup.allAlbums')
        : tr('photo.backup.albumsSelected', {
            'count': '${task.sourceIds.length}',
          });
    // 目标只到「相册源」这一级：能对上源就显示源名（用户认的是库名），
    // 再把路径跟在后面 —— 换盘 / 换共享时得能看出照片到底落在哪。
    final targetPath = _c.effectiveTargetDir;
    final targetLabel = _c.targetLabel;
    final targetSub =
        targetLabel == targetPath ? targetPath : '$targetLabel · $targetPath';
    return _sectionCard(
      children: [
        _lineTile(
          context,
          icon: Icons.photo_library_outlined,
          title: tr('photo.backup.source'),
          subtitle: albumsLabel,
          onTap: _c.isRunning ? null : () => _pickAlbums(context, task),
        ),
        const Divider(height: 1, indent: 52),
        _lineTile(
          context,
          icon: Icons.folder_open_outlined,
          title: tr('photo.backup.target'),
          subtitle: targetSub,
          onTap: _c.isRunning ? null : () => _pickTargetDir(context),
        ),
        const Divider(height: 1, indent: 52),
        _lineTile(
          context,
          icon: Icons.account_tree_outlined,
          title: tr('photo.backup.dirStyle'),
          subtitle: _dirStyleSubtitle(task),
          onTap: _c.isRunning ? null : () => _pickDirStyle(context, task),
        ),
      ],
    );
  }

  String _dirStyleSubtitle(BackupTask task) => switch (task.dirStyle) {
        BackupDirStyle.byAlbum => tr('photo.backup.dirByAlbum'),
        BackupDirStyle.byMonth =>
          '${tr('photo.backup.dirByMonth')} · ${tr('photo.backup.dirExampleMonth')}',
        BackupDirStyle.byYear =>
          '${tr('photo.backup.dirByYear')} · ${tr('photo.backup.dirExampleYear')}',
      };

  String _dirStyleTitle(BackupDirStyle style) => switch (style) {
        BackupDirStyle.byAlbum => tr('photo.backup.dirByAlbum'),
        BackupDirStyle.byMonth => tr('photo.backup.dirByMonth'),
        BackupDirStyle.byYear => tr('photo.backup.dirByYear'),
      };

  String _dirStyleExample(BackupDirStyle style) => switch (style) {
        BackupDirStyle.byAlbum => tr('photo.backup.dirExampleAlbum'),
        BackupDirStyle.byMonth => tr('photo.backup.dirExampleMonth'),
        BackupDirStyle.byYear => tr('photo.backup.dirExampleYear'),
      };

  // ------------------------------------------------------------------ 开关卡

  Widget _switchesCard(BuildContext context, BackupTask task) {
    final theme = Theme.of(context);
    Widget sw({
      required String title,
      required String hint,
      required bool value,
      required ValueChanged<bool> onChanged,
      bool allowWhileRunning = false,
    }) {
      return SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        value: value,
        onChanged: (_c.isRunning && !allowWhileRunning) ? null : onChanged,
        title: Text(title),
        subtitle: Text(hint, style: theme.textTheme.bodySmall),
      );
    }

    return _sectionCard(
      children: [
        sw(
          title: tr('photo.backup.uploadLiveVideo'),
          hint: tr('photo.backup.uploadLiveVideoHint'),
          value: task.uploadLivePhotoVideo,
          onChanged: (v) => _c.setUploadLivePhotoVideo(v),
        ),
        sw(
          title: tr('photo.backup.onlyPhotos'),
          hint: tr('photo.backup.onlyPhotosHint'),
          value: task.onlyPhotos,
          onChanged: (v) => _c.setOnlyPhotos(v),
        ),
        sw(
          title: tr('photo.backup.renameByDate'),
          hint: tr('photo.backup.renameByDateHint'),
          value: task.renameByDate,
          onChanged: (v) => _c.setRenameByDate(v),
        ),
        sw(
          title: tr('photo.backup.useCellular'),
          hint: tr('photo.backup.useCellularHint'),
          value: task.useCellular,
          // 正用移动数据备份时关掉它必须立刻生效，不能等下一轮才停。
          allowWhileRunning: true,
          onChanged: (v) => _confirmCellular(context, v),
        ),
        sw(
          title: tr('photo.backup.savingMode'),
          hint: tr('photo.backup.savingModeHint'),
          value: task.savingMode,
          onChanged: (v) => _c.setSavingMode(v),
        ),
        sw(
          title: tr('photo.backup.keepScreenOn'),
          hint: tr('photo.backup.keepScreenOnHint'),
          value: task.keepScreenOn,
          onChanged: (v) => _c.setKeepScreenOn(v),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 进度卡

  Widget _progressCard(BuildContext context) {
    final rt = _c.rt;
    final active = _c.isRunning || rt.phase == BackupPhase.paused;
    if (!active && rt.runTotal <= 0 && rt.error.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return _sectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分母是扫描结束时一次定死的 runTotal，分子只增不减。
              // 旧版按「已完成字节 / 已加入字节」算，每批结束就 100%，
              // 下一批又撑大分母，进度条来回跳。
              if (active) ...[
                LinearProgressIndicator(value: rt.progress, minHeight: 6),
                const SizedBox(height: NasTokens.spaceSm),
              ],
              Text(
                tr('photo.backup.progressCount', <String, Object>{
                  'done': '${rt.done}',
                  'total': '${rt.runTotal}',
                }),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                '${tr('photo.backup.uploadedCount', {'count': '${rt.uploaded}'})} · '
                '${tr('photo.backup.skippedDup', {'count': '${rt.skipped}'})} · '
                '${tr('photo.backup.failedCount', {'count': '${rt.failed}'})}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                tr('photo.backup.totalBackedUp', <String, Object>{
                  'count': '${_c.totalBackedUp}',
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (rt.doneBytes > 0) ...[
                const SizedBox(height: 2),
                Text(
                  tr('photo.backup.bytesDone', <String, Object>{
                    'size': formatBytes(rt.doneBytes),
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (rt.currentFile.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  rt.currentFile.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (rt.error.trim().isNotEmpty) ...[
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  _errorText(rt.error),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 交互

  Future<void> _rescanAll(BuildContext context) async {
    final ok = await _confirm(
      context,
      tr('photo.backup.rescanAllConfirm'),
    );
    if (ok == true) await _c.startBackupAll();
  }

  Future<void> _confirmCellular(BuildContext context, bool value) async {
    if (value) {
      final ok = await _confirm(
        context,
        tr('photo.backup.cellularConfirm'),
      );
      if (ok != true) return;
    }
    await _c.setUseCellular(value);
  }

  Future<bool?> _confirm(BuildContext context, String content) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.confirm')),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.ok')),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAlbums(BuildContext context, BackupTask task) async {
    final picked = await PhotoBackupAlbumPicker.pick(context, task.sourceIds);
    if (picked == null) return;
    await _c.setSourceIds(picked.ids, picked.names);
  }

  Future<void> _pickTargetDir(BuildContext context) async {
    final picked = await showPhotoBackupTargetPicker(
      context,
      initialPath: _c.effectiveTargetDir,
    );
    if (picked == null) return;
    await _c.setTargetDir(picked);
  }

  Future<void> _pickDirStyle(BuildContext context, BackupTask task) async {
    final selected = await showModalBottomSheet<BackupDirStyle>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final style in BackupDirStyle.values)
              ListTile(
                leading: Icon(
                  style == task.dirStyle
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: style == task.dirStyle
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                title: Text(_dirStyleTitle(style)),
                subtitle: Text(
                  _dirStyleExample(style),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                onTap: () => Navigator.pop(ctx, style),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _c.setDirStyle(selected);
  }

  Future<void> _showRuns(BuildContext context) async {
    final runs = await _c.listRuns();
    if (!context.mounted) return;
    if (runs.isEmpty) {
      NasSnack.show(context, tr('photo.backup.noRuns'));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RunsSheet(controller: _c, runs: runs),
    );
  }

  // ------------------------------------------------------------------ 工具

  /// Controller 里存的是文案键（如 photo.backup.pausedMobile），异常对象是明文。
  String _errorText(String raw) {
    final s = raw.trim();
    if (s.startsWith('photo.backup.')) return tr(s);
    return s;
  }

  Widget _sectionCard({required List<Widget> children}) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _lineTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

String _fmtTime(int ms) {
  if (ms <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// 备份记录（一轮一条），可下钻文件级明细、删除单条记录。
class _RunsSheet extends StatefulWidget {
  const _RunsSheet({required this.controller, required this.runs});

  final PhotoBackupController controller;
  final List<BackupRun> runs;

  @override
  State<_RunsSheet> createState() => _RunsSheetState();
}

class _RunsSheetState extends State<_RunsSheet> {
  late final List<BackupRun> _runs = List<BackupRun>.of(widget.runs);

  Future<void> _showFiles(BackupRun run) async {
    final files = await widget.controller.fileRecords(run.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _RunFilesDialog(run: run, files: files),
    );
  }

  Future<void> _delete(BackupRun run) async {
    await widget.controller.deleteRun(run.id);
    if (!mounted) return;
    setState(() => _runs.removeWhere((r) => r.id == run.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('photo.backup.runs'),
                      style: theme.textTheme.titleMedium,
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
              child: _runs.isEmpty
                  ? Center(child: Text(tr('photo.backup.noRuns')))
                  : ListView.separated(
                      itemCount: _runs.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final run = _runs[i];
                        return ListTile(
                          title: Text(
                            tr('photo.backup.runItem', {
                              'success': '${run.successCount}',
                              'failed': '${run.failedCount}',
                              'skipped': '${run.skippedCount}',
                            }),
                          ),
                          subtitle: Text(
                            '${_fmtTime(run.startedAtMs)} - '
                            '${_fmtTime(run.finishedAtMs ?? 0)} · '
                            '${formatBytes(run.totalBytes)}',
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                tooltip: tr('photo.backup.fileLogs'),
                                onPressed: () => _showFiles(run),
                                icon: const Icon(Icons.list_alt_outlined),
                              ),
                              IconButton(
                                tooltip: tr('common.delete'),
                                onPressed: () => _delete(run),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件级明细：成功 / 跳过 / 失败三态，失败附带错误原因。
class _RunFilesDialog extends StatelessWidget {
  const _RunFilesDialog({required this.run, required this.files});

  final BackupRun run;
  final List<BackupFileRecord> files;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        tr('photo.backup.fileLogsTitle', {
          'time': _fmtTime(run.startedAtMs),
        }),
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: files.isEmpty
            ? Center(child: Text(tr('common.empty')))
            : ListView.separated(
                itemCount: files.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final item = files[i];
                  final failed =
                      item.status == BackupFileStatus.error;
                  final skipped =
                      item.status == BackupFileStatus.skipped;
                  final icon = failed
                      ? Icons.error_outline
                      : (skipped
                          ? Icons.content_copy_outlined
                          : Icons.check_circle_outline);
                  final color = failed
                      ? Colors.red
                      : (skipped ? Colors.orange : Colors.green);
                  return ListTile(
                    leading: Icon(icon, color: color),
                    title: Text(item.displayName),
                    subtitle: Text(
                      '${formatBytes(item.size)} · '
                      '${skipped ? tr('photo.backup.skip') : _fmtTime(item.atMs)}'
                      '${item.error.isEmpty ? '' : '\n${item.error}'}',
                    ),
                    isThreeLine: item.error.isNotEmpty,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('common.close')),
        ),
      ],
    );
  }
}
