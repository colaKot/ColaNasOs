import 'dart:async';
import 'dart:typed_data';
import '../../shell/app_widgets.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';

/// 传输中心（附录 B.2 / D「文件 → 传输中心」）：分片上传队列。
///
/// 协议：`filesCheck`（秒传 + 已收分片）→ `filesChunk`（4 MB 原始字节）→ `filesMerge`（幂等）。
/// 断点续传靠 `check.uploaded`，同一文件重复加入会跳过已收分片；已存在且同尺寸的文件直接秒传。
/// 队列并发 2 —— 与服务端缩略图闸门一致，避免小机器被打满。
class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

enum _Status { queued, uploading, done, skipped, failed, canceled }

class _Task {
  _Task({required this.file, required this.targetDir});

  final XFile file;
  final String targetDir;

  int size = 0;
  int sent = 0;
  int totalChunks = 1;
  _Status status = _Status.queued;
  String? error;

  String get name => file.name;

  String get remotePath {
    final dir = targetDir.replaceAll(RegExp(r'/+$'), '');
    return '$dir/$name';
  }

  double get progress => size <= 0 ? 0 : (sent / size).clamp(0, 1);
}

class _TransferPageState extends State<TransferPage> {
  static const _concurrency = 2;
  static const _fallbackChunk = 4 * 1024 * 1024;

  final List<_Task> _tasks = [];
  final TextEditingController _dirCtrl = TextEditingController(text: '/');
  bool _pumping = false;

  @override
  void dispose() {
    _dirCtrl.dispose();
    super.dispose();
  }

  void _notify() {
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    final dir = _dirCtrl.text.trim().isEmpty ? '/' : _dirCtrl.text.trim();
    if (!mounted) return;
    setState(() {
      for (final f in files) {
        _tasks.add(_Task(file: f, targetDir: dir));
      }
    });
    _pump();
  }

  /// 队列泵：每批取 [_concurrency] 个等待项并发上传，全部结束再取下一批。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final batch = _tasks
            .where((t) => t.status == _Status.queued)
            .take(_concurrency)
            .toList();
        if (batch.isEmpty) break;
        for (final t in batch) {
          t.status = _Status.uploading;
        }
        _notify();
        await Future.wait(batch.map(_upload));
      }
    } finally {
      _pumping = false;
      _notify();
    }
  }

  Future<void> _upload(_Task task) async {
    try {
      final client = ApiSession.instance.client;
      task.size = await task.file.length();
      _notify();

      final check = await client.filesCheck(
        body: FilesCheckBody(path: task.remotePath, size: task.size),
      );
      if (check.exists) {
        task.sent = task.size;
        task.status = _Status.skipped;
        _notify();
        return;
      }

      final chunkSize = check.chunkSize > 0 ? check.chunkSize : _fallbackChunk;
      task.totalChunks = task.size <= 0
          ? 1
          : ((task.size + chunkSize - 1) ~/ chunkSize);
      final have = check.uploaded.toSet();

      for (var i = 0; i < task.totalChunks; i++) {
        if (task.status == _Status.canceled) return;
        final start = i * chunkSize;
        final end = start + chunkSize > task.size
            ? task.size
            : start + chunkSize;
        if (!have.contains(i)) {
          final bytes = await _readRange(task.file, start, end);
          await client.filesChunk(
            path: task.remotePath,
            index: i,
            total: task.totalChunks,
            body: bytes,
          );
        }
        task.sent = end;
        _notify();
      }

      await client.filesMerge(
        body: FilesMergeBody(
          path: task.remotePath,
          total: task.totalChunks,
          size: task.size,
        ),
      );
      task.sent = task.size;
      task.status = _Status.done;
      _notify();
    } catch (e) {
      if (task.status == _Status.canceled) return;
      task.status = _Status.failed;
      task.error = e.toString();
      _notify();
    }
  }

  /// 跨平台读取区间（`XFile.openRead` 在桌面 / 移动 / Web 都可用，不引入 `dart:io`）
  Future<Uint8List> _readRange(XFile file, int start, int end) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, end)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _cancel(_Task task) {
    task.status = _Status.canceled;
    _notify();
  }

  void _retry(_Task task) {
    task.status = _Status.queued;
    task.sent = 0;
    task.error = null;
    _notify();
    _pump();
  }

  void _clearFinished() {
    setState(() {
      _tasks.removeWhere(
        (t) =>
            t.status == _Status.done ||
            t.status == _Status.skipped ||
            t.status == _Status.canceled,
      );
    });
  }

  String _statusText(_Task t) {
    switch (t.status) {
      case _Status.queued:
        return tr('ui.transfer.hbd3488');
      case _Status.uploading:
        return tr('transfer.uploading', {'percent': (t.progress * 100).toStringAsFixed(0)});
      case _Status.done:
        return tr('ui.media_tool.he99b48');
      case _Status.skipped:
        return tr('ui.transfer.ha1bb0d');
      case _Status.failed:
        return tr('transfer.failed', {'error': t.error ?? ''});
      case _Status.canceled:
        return tr('ui.media_tool.ha5ffdc');
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _tasks.where((t) => t.status == _Status.uploading).length;
    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: active > 0
            ? tr('transfer.titleActive', {'count': '$active'})
            : tr('ui.transfer.001'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: tr('ui.transfer.002'),
            onPressed: _pick,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: tr('ui.transfer.003'),
            onPressed: _tasks.isEmpty ? null : _clearFinished,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceMd,
              NasTokens.spaceMd,
              NasTokens.spaceSm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dirCtrl,
                    decoration: InputDecoration(
                      labelText: tr('ui.transfer.004'),
                      helperText: tr('ui.transfer.005'),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: NasTokens.spaceSm),
                FilledButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.upload_file),
                  label: Text(tr('ui.transfer.006')),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _tasks.isEmpty
                ? Center(child: Text(tr('ui.transfer.007')))
                : ListView.separated(
                    itemCount: _tasks.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final t = _tasks[i];
                      final failed = t.status == _Status.failed;
                      final finished =
                          t.status == _Status.done ||
                          t.status == _Status.skipped ||
                          t.status == _Status.canceled;
                      return ListTile(
                        leading: Icon(
                          finished
                              ? Icons.check_circle_outline
                              : failed
                              ? Icons.error_outline
                              : Icons.upload_file,
                        ),
                        title: Text(t.name, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(height: NasTokens.spaceXs),
                            Text(
                              _statusText(t),
                              style: TextStyle(
                                color: failed ? context.nasDanger : null,
                              ),
                            ),
                            if (!finished && !failed) ...[
                              const SizedBox(height: NasTokens.spaceXs),
                              LinearProgressIndicator(
                                value: t.size > 0 ? t.progress : null,
                              ),
                            ],
                          ],
                        ),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (t.status == _Status.uploading ||
                                t.status == _Status.queued)
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: tr('ui.media_tool.017'),
                                onPressed: () => _cancel(t),
                              ),
                            if (failed || t.status == _Status.canceled)
                              NasRefreshButton(tooltip: tr('ui.transfer.008'), onPressed: () => _retry(t)),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
