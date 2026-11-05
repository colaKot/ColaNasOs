import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'sync_engine.dart';

/// 单个同步任务卡片：状态 / 目录 / 过滤规则 / 进度 / 操作。
class SyncTaskCard extends StatelessWidget {
  const SyncTaskCard({
    super.key,
    required this.task,
    required this.engine,
    required this.canRun,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
    required this.onRecords,
  });

  final SyncTask task;
  final SyncEngine engine;
  final bool canRun;
  final VoidCallback onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRecords;

  bool get _running => engine.isRunning(task.id);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = engine.progressOf(task.id);
    final active = _running || (progress != null && !progress.finished);

    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: NasCard(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.devices_outlined, size: NasTokens.iconMd, color: scheme.primary),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Text(
                  task.name.isNotEmpty
                      ? task.name
                      : (task.deviceName.isEmpty ? task.deviceId : task.deviceName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontSubtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _chip(context, _modeLabel(task.mode), scheme.primary),
              const SizedBox(width: NasTokens.spaceXs),
              _chip(context, _statusLabel(task.status), _statusColor(scheme, task.status)),
            ],
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            '${task.localDir}  →  NAS: ${task.remoteDir}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Wrap(
            spacing: NasTokens.spaceXs,
            runSpacing: NasTokens.spaceXs,
            children: [
              if (task.syncConfig.realtime)
                _ruleChip(context, tr('sync.summary.realtime'), scheme.primary),
              _ruleChip(
                context,
                task.syncConfig.intervalMinutes > 0
                    ? tr('sync.summary.interval', {
                        'n': '${task.syncConfig.intervalMinutes}',
                      })
                    : tr('sync.summary.manualSchedule'),
                context.nasTextSecondary,
              ),
              _ruleChip(
                context,
                _conflictLabel(task.syncConfig.conflictStrategy),
                scheme.tertiary,
              ),
              _ruleChip(
                context,
                task.syncConfig.deleteExtra
                    ? tr('sync.summary.deleteExtra')
                    : tr('sync.summary.noDeleteExtra'),
                task.syncConfig.deleteExtra
                    ? scheme.error
                    : context.nasTextSecondary,
              ),
            ],
          ),
          if (task.include.isNotEmpty || task.exclude.isNotEmpty) ...[
            const SizedBox(height: NasTokens.spaceXs),
            Wrap(
              spacing: NasTokens.spaceXs,
              runSpacing: NasTokens.spaceXs,
              children: [
                for (final rule in task.exclude.take(3))
                  _ruleChip(context, '-$rule', scheme.error),
                for (final rule in task.include.take(3))
                  _ruleChip(context, '+$rule', scheme.primary),
                if (task.exclude.length + task.include.length > 6)
                  Text(
                    tr('sync.rulesMore', {
                      'count': task.exclude.length + task.include.length - 6,
                    }),
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      color: context.nasTextSecondary,
                    ),
                  ),
              ],
            ),
          ],
          if (active && progress != null) ...[
            const SizedBox(height: NasTokens.spaceSm),
            LinearProgressIndicator(value: progress.percent, minHeight: 4),
            const SizedBox(height: NasTokens.spaceXs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${tr(_phaseKey(progress.phase))}'
                    '${progress.totalActions > 0 ? ' ${progress.doneActions}/${progress.totalActions}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NasTokens.fontCaption,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
                if (progress.currentPath.isNotEmpty)
                  Flexible(
                    child: Text(
                      progress.currentPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: NasTokens.fontMicro,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (task.lastError != null && task.lastError!.isNotEmpty) ...[
            const SizedBox(height: NasTokens.spaceXs),
            Text(
              task.lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
            ),
          ],
          const SizedBox(height: NasTokens.spaceSm),
          Row(
            children: [
              Text(
                task.lastRunAt == null
                    ? tr('sync.neverRun')
                    : tr('sync.lastRunAt', {'time': _time(task.lastRunAt!)}),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: context.nasTextSecondary,
                ),
              ),
              const Spacer(),
              if (active)
                TextButton.icon(
                  onPressed: () => engine.cancel(task.id),
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: Text(tr('sync.cancelRun')),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: canRun ? onRun : null,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(tr('sync.runNow')),
                ),
              IconButton(
                tooltip: tr('sync.editTask'),
                onPressed: _running ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
              IconButton(
                tooltip: tr('sync.records'),
                onPressed: onRecords,
                icon: const Icon(Icons.history, size: 18),
              ),
              IconButton(
                tooltip: tr('common.delete'),
                onPressed: _running ? null : onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _chip(BuildContext context, String text, Color color) {
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

  Widget _ruleChip(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NasTokens.spaceXs + 2,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: NasTokens.fontMicro, color: color),
      ),
    );
  }

  static String _conflictLabel(String strategy) {
    switch (strategy) {
      case 'prefer_newer':
        return tr('sync.summary.preferNewer');
      case 'prefer_local':
        return tr('sync.summary.preferLocal');
      case 'prefer_remote':
        return tr('sync.summary.preferRemote');
      default:
        return tr('sync.summary.manual');
    }
  }

  static String _modeLabel(String mode) {
    switch (mode) {
      case 'upload_only':
        return tr('sync.modeUp');
      case 'download_only':
        return tr('sync.modeDown');
      default:
        return tr('sync.modeBoth');
    }
  }

  static Color _statusColor(ColorScheme scheme, String status) {
    switch (status) {
      case 'running':
        return scheme.primary;
      case 'error':
        return scheme.error;
      default:
        return scheme.tertiary;
    }
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'running':
        return tr('sync.status.running');
      case 'error':
        return tr('sync.status.error');
      default:
        return tr('sync.status.idle');
    }
  }

  static String _phaseKey(String phase) {
    switch (phase) {
      case SyncPhase.scanning:
        return 'sync.phase.scanning';
      case SyncPhase.planning:
        return 'sync.phase.planning';
      case SyncPhase.transferring:
        return 'sync.phase.transferring';
      case SyncPhase.cleaning:
        return 'sync.phase.cleaning';
      case SyncPhase.reporting:
        return 'sync.phase.reporting';
      case SyncPhase.failed:
        return 'sync.phase.failed';
      default:
        return 'sync.phase.done';
    }
  }

  /// `sync_tasks.last_run_at` 是 Unix 秒，乘 1000 再格式化（以前当毫秒 → 1970）
  static String _time(int seconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
