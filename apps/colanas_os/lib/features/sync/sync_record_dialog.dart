import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'sync_engine.dart';

/// 同步运行记录（服务端 `sync_runs`）。
class SyncRecordDialog extends StatefulWidget {
  const SyncRecordDialog({super.key, required this.task});

  final SyncTask task;

  @override
  State<SyncRecordDialog> createState() => _SyncRecordDialogState();
}

class _SyncRecordDialogState extends State<SyncRecordDialog> {
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
      final res = await ApiSession.instance.client.syncRuns(
        taskId: widget.task.id,
        limit: '50',
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('sync.records')),
      content: SizedBox(
        width: 720,
        height: 440,
        child: _loading
            ? const NasLoading()
            : _error != null
                ? NasErrorState(message: _error!, onRetry: _load)
                : _items.isEmpty
                    ? Center(child: Text(tr('sync.emptyRuns')))
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) =>
                            _row(context, _items[i]),
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

  Widget _row(BuildContext context, Map<String, dynamic> run) {
    final status = '${run['status'] ?? ''}';
    final finishedAt = (run['finishedAt'] as num?)?.toInt() ?? 0;
    final uploaded = (run['uploaded'] as num?)?.toInt() ?? 0;
    final downloaded = (run['downloaded'] as num?)?.toInt() ?? 0;
    final deleted =
        ((run['deletedLocal'] as num?)?.toInt() ?? 0) +
            ((run['deletedRemote'] as num?)?.toInt() ?? 0);
    final skipped = (run['skipped'] as num?)?.toInt() ?? 0;
    final conflicts = (run['conflicts'] as num?)?.toInt() ?? 0;
    final failed = (run['failed'] as num?)?.toInt() ?? 0;
    final bytes = (run['bytes'] as num?)?.toInt() ?? 0;
    final error = '${run['error'] ?? ''}'.trim();
    return ListTile(
      dense: true,
      isThreeLine: error.isNotEmpty,
      leading: Icon(
        status == 'failed'
            ? Icons.error_outline
            : status == 'partial'
                ? Icons.warning_amber_outlined
                : Icons.check_circle_outline,
        size: 18,
        color: status == 'failed'
            ? Theme.of(context).colorScheme.error
            : null,
      ),
      title: Text(
        '${tr('sync.stat.upload')} $uploaded · '
        '${tr('sync.stat.download')} $downloaded · '
        '${tr('sync.stat.delete')} $deleted · '
        '${tr('sync.stat.skip')} $skipped'
        '${failed > 0 ? ' · ${tr('sync.stat.failed')} $failed' : ''}',
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_time(finishedAt)} · ${formatBytes(bytes)}'
            '${conflicts > 0 ? ' · ${tr('sync.stat.conflict')} $conflicts' : ''}',
          ),
          // 失败原因就写在这一轮下面：之前只存 applied，红了也看不出为什么
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Tooltip(
                message: error,
                child: Text(
                  error,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 服务端 `sync_runs.finished_at` 是 **Unix 秒**（不是毫秒）。
  /// 以前直接丢进 `fromMillisecondsSinceEpoch`，1.79e9 毫秒 = 1970-01-21，
  /// 记录里那行「1970-01-22 02:16」就是这么来的。
  static String _time(int seconds) {
    if (seconds <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
