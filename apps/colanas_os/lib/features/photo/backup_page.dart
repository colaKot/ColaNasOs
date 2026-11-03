import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 手机相册备份（单向增量：本机 → NAS）。
///
/// 关键不是「上传」而是**去重**：先在服务端比对（MD5 优先、其次文件名+大小），
/// 只把缺失的传上去；每一步失败都单独计数，不因为一张照片失败而中止整批。
class PhotoBackupPage extends StatefulWidget {
  const PhotoBackupPage({super.key, this.embedded = false});

  /// 嵌入相册二级导航内容区时去掉自带 AppBar
  final bool embedded;

  @override
  State<PhotoBackupPage> createState() => _PhotoBackupPageState();
}

class _PhotoBackupPageState extends State<PhotoBackupPage> {
  bool _running = false;
  String _status = '';
  double _progress = 0;
  int _uploaded = 0;
  int _skipped = 0;
  int _failed = 0;
  int _total = 0;
  List<PhotoBackupJob> _jobs = const [];

  @override
  void initState() {
    super.initState();
    _loadJobs();
  }

  Future<void> _loadJobs() async {
    try {
      final res = await ApiSession.instance.client.photoBackupStatus();
      if (!mounted) return;
      setState(() => _jobs = res.items);
    } catch (_) {
      // 历史记录失败不影响备份
    }
  }

  String _targetPath(String name) {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    return 'photo-backup/${now.year}/$month/$name';
  }

  Future<void> _pickAndBackup() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('ui.photo.001'))));
      return;
    }
    final files = await openFiles();
    if (files.isEmpty) return;

    setState(() {
      _running = true;
      _uploaded = 0;
      _skipped = 0;
      _failed = 0;
      _progress = 0;
      _total = files.length;
      _status = tr('ui.photo.hf39ac5');
    });

    try {
      final entries = <({XFile file, String name, int size})>[];
      for (final f in files) {
        final size = await f.length();
        final name = f.name.isEmpty
            ? (f.path.split(RegExp(r'[\\/]')).last)
            : f.name;
        entries.add((file: f, name: name, size: size));
      }

      final check = await ApiSession.instance.client.photoBackupCheck(
        body: PhotoBackupCheckBody(
          files: [
            for (final e in entries)
              PhotoBackupCheckFile(name: e.name, size: e.size),
          ],
        ),
      );
      final missingNames = check.missing
          .map((m) => '${m.name}|${m.size}')
          .toSet();
      final toUpload = entries
          .where((e) => missingNames.contains('${e.name}|${e.size}'))
          .toList();
      _skipped = entries.length - toUpload.length;

      if (mounted) {
        setState(() => _status = tr('photo.backup.total', {'total': '$_total', 'count': '${toUpload.length}'}));
      }

      final client = ApiSession.instance.client;
      for (var i = 0; i < toUpload.length; i += 1) {
        final entry = toUpload[i];
        if (!mounted) return;
        setState(() {
          _progress = toUpload.isEmpty ? 1 : i / toUpload.length;
          _status = tr('photo.backup.uploading', {'index': '${i + 1}', 'total': '${toUpload.length}', 'name': entry.name});
        });
        try {
          await _uploadOne(
            client,
            entry.file,
            _targetPath(entry.name),
            entry.size,
          );
          _uploaded += 1;
        } catch (e) {
          _failed += 1;
          debugPrint('backup failed ${entry.name}: $e');
        }
      }

      final job = await client.photoBackupCommit(
        body: PhotoBackupCommitBody(
          source: 'mobile',
          total: entries.length,
          uploaded: _uploaded,
          skipped: _skipped,
          bytes: toUpload.fold<int>(0, (s, e) => s + e.size),
        ),
      );

      if (!mounted) return;
      setState(() {
        _progress = 1;
        _status = tr('photo.backup.done', {'uploaded': '$_uploaded', 'skipped': '$_skipped', 'failed': '$_failed'});
        _jobs = [job.job, ..._jobs];
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _status = tr('photo.backup.failed', {'error': '$e'});
      });
    }
  }

  Future<void> _uploadOne(
    ApiClient client,
    XFile file,
    String target,
    int size,
  ) async {
    final check = await client.filesCheck(
      body: FilesCheckBody(path: target, size: size),
    );
    if (check.exists) return;

    final chunkSize = check.chunkSize <= 0 ? 4 * 1024 * 1024 : check.chunkSize;
    final total = (size / chunkSize).ceil().clamp(1, 1 << 20);
    final handle = await File(file.path).open();
    try {
      for (var index = 0; index < total; index += 1) {
        await handle.setPosition(index * chunkSize);
        final bytes = await handle.read(chunkSize);
        if (bytes.isEmpty) break;
        await client.filesChunk(
          path: target,
          index: index,
          total: total,
          body: bytes,
        );
      }
    } finally {
      await handle.close();
    }
    await client.filesMerge(
      body: FilesMergeBody(path: target, total: total, size: size),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: Text(tr('ui.photo.002'))),
      body: ListView(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(NasTokens.spaceSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('ui.photo.003')),
                  const SizedBox(height: NasTokens.spaceSm),
                  if (_running) ...[
                    LinearProgressIndicator(
                      value: _progress == 0 ? null : _progress,
                    ),
                    const SizedBox(height: NasTokens.spaceXs),
                    Text(
                      _status,
                      style: const TextStyle(fontSize: NasTokens.fontCaption),
                    ),
                  ] else
                    Text(
                      _status,
                      style: TextStyle(
                        color: context.nasTextSecondary,
                        fontSize: NasTokens.fontCaption,
                      ),
                    ),
                  const SizedBox(height: NasTokens.spaceSm),
                  FilledButton.icon(
                    onPressed: _running ? null : _pickAndBackup,
                    icon: const Icon(Icons.upload_file),
                    label: Text(tr('ui.photo.004')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: NasTokens.spaceMd),
          Text(
            tr('ui.photo.005'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: NasTokens.spaceXs),
          for (final job in _jobs)
            ListTile(
              dense: true,
              leading: const Icon(Icons.backup_outlined),
              title: Text(
                tr('photo.backup.job', {'total': '${job.total}', 'uploaded': '${job.uploaded}', 'skipped': '${job.skipped}'}),
              ),
              subtitle: Text(
                '${formatDateTimeSec(job.createdAt)} · ${formatBytes(job.bytes)}',
                style: const TextStyle(fontSize: NasTokens.fontCaption),
              ),
            ),
          if (_jobs.isEmpty)
            NasEmptyState(
              title: tr('ui.photo.006'),
              message: tr('ui.photo.hc12c60'),
              icon: Icons.backup_outlined,
            ),
        ],
      ),
    );
  }
}
