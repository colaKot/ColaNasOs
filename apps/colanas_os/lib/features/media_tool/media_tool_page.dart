import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 媒体工具（SP3-10 / M1–M7）：左二级菜单 + 统一任务表（账号隔离 + 启停 + 统计）。
///
/// 五个工具共用 `/media-tool/tasks/*`；执行器是服务端单泵（ffmpeg sidecar）。
/// 除单图压缩外，写操作需要管理员（服务端 `scopes` 含 `*`），普通用户会收到 403。
class MediaToolPage extends StatefulWidget {
  const MediaToolPage({super.key});

  @override
  State<MediaToolPage> createState() => _MediaToolPageState();
}

class _MediaToolPageState extends State<MediaToolPage> {
  List<MediaToolTaskItem> _tasks = const [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  bool _collapsed = false;

  String _tool = 'videoTrans';

  static const _toolTitles = <String, String>{
    'singleCompress': 'media_tool.entry.singleCompress',
    'batchCompress': 'media_tool.entry.batchCompress',
    'videoTrans': 'media_tool.entry.videoTrans',
    'audioTrans': 'media_tool.entry.audioTrans',
    'arrange': 'media_tool.entry.arrange',
    'thumbnails': 'media_tool.entry.thumbnails',
    'tasks': 'media_tool.entry.tasks',
  };

  @override
  void initState() {
    super.initState();
    // 普通用户只开放单图压缩（服务端对批量工具 403，前端不摆入口）
    if (!ApiSession.instance.isAdmin) _tool = 'singleCompress';
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && _hasActive) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _hasActive =>
      _tasks.any((t) => t.status == 'pending' || t.status == 'running');

  String? get _kindFilter {
    switch (_tool) {
      case 'videoTrans':
        return 'video';
      case 'audioTrans':
        return 'audio';
      case 'arrange':
        return 'arrange';
      case 'thumbnails':
        return 'thumbnails';
      case 'singleCompress':
      case 'batchCompress':
        return 'image';
      case 'tasks':
        return null;
      default:
        return '__none__';
    }
  }

  List<MediaToolTaskItem> get _visibleJobs {
    final kind = _kindFilter;
    if (kind == null) return _tasks;
    return _tasks.where((t) => t.kind == kind).toList();
  }

  bool get _toolImplemented => _kindFilter != '__none__';

  String? _hint(Object e) {
    final text = e.toString();
    if (text.contains('403')) return tr('ui.media_tool.hb4c185');
    if (text.contains('503')) return tr('ui.media_tool.h32cef6');
    return null;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await ApiSession.instance.client.mediaToolTaskList(limit: '100');
      if (!mounted) return;
      setState(() {
        _tasks = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _hint(e) ?? e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _start(MediaToolTaskItem task) async {
    await _act(() => ApiSession.instance.client.mediaToolTaskStart(
          body: MediaToolTaskIdBody(id: task.id),
        ));
  }

  Future<void> _stop(MediaToolTaskItem task) async {
    await _act(() => ApiSession.instance.client.mediaToolTaskStop(
          body: MediaToolTaskIdBody(id: task.id),
        ));
  }

  Future<void> _delete(MediaToolTaskItem task) async {
    await _act(() => ApiSession.instance.client.mediaToolTaskDelete(
          body: MediaToolTaskIdBody(id: task.id),
        ));
  }

  Future<void> _act(Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(tr('common.errorWith', {'error': '${_hint(e) ?? e}'}))),
      );
    }
  }

  String _kindOfTool() {
    switch (_tool) {
      case 'videoTrans':
        return 'video';
      case 'audioTrans':
        return 'audio';
      case 'arrange':
        return 'arrange';
      case 'thumbnails':
        return 'thumbnails';
      case 'singleCompress':
      case 'batchCompress':
        return 'image';
      default:
        return 'video';
    }
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    bool number = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: TextField(
        controller: ctrl,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
      ),
    );
  }

  Widget _choice<T>(
    String label,
    T value,
    List<(T, String)> options,
    ValueChanged<T> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isDense: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          for (final o in options)
            DropdownMenuItem<T>(value: o.$1, child: Text(o.$2)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  /// 批量压缩：多选本地图片 → 分块上传到 files 根 → 自动带出压缩表单（默认勾选 zip）
  Future<void> _uploadImages() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'images',
          extensions: [
            'jpg',
            'jpeg',
            'png',
            'webp',
            'gif',
            'bmp',
            'tif',
            'tiff',
            'avif',
            'heic',
            'heif',
          ],
        ),
      ],
    );
    if (files.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final client = ApiSession.instance.client;
    final dir = 'media-uploads/${DateTime.now().millisecondsSinceEpoch}';
    var uploaded = 0;
    try {
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final target = '$dir/${file.name}';
        final check = await client.filesCheck(
          body: FilesCheckBody(path: target, size: bytes.length),
        );
        if (!check.exists) {
          final chunkSize =
              check.chunkSize <= 0 ? 4 * 1024 * 1024 : check.chunkSize;
          final total = (bytes.length / chunkSize).ceil().clamp(1, 1 << 20);
          for (var index = 0; index < total; index += 1) {
            final start = index * chunkSize;
            final end = (start + chunkSize).clamp(0, bytes.length);
            await client.filesChunk(
              path: target,
              index: index,
              total: total,
              body: bytes.sublist(start, end),
            );
          }
          await client.filesMerge(
            body: FilesMergeBody(
              path: target,
              total: total,
              size: bytes.length,
            ),
          );
        }
        uploaded += 1;
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('media_tool.uploaded', {'count': '$uploaded'})),
        ),
      );
      if (uploaded > 0) {
        await _openEditor(presetSource: dir, presetZip: true);
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('media_tool.uploadFailed', {'error': '$e'})),
        ),
      );
    }
  }

  Future<void> _openEditor({
    MediaToolTaskItem? editing,
    String? presetSource,
    bool presetZip = false,
  }) async {
    final kind = editing?.kind ?? _kindOfTool();
    final cfg = editing?.config ?? const <String, dynamic>{};
    final src = TextEditingController(
      text: editing?.source ?? presetSource ?? '',
    );
    final dst = TextEditingController(
      text: editing?.target ?? (kind == 'thumbnails' ? 'media-thumbnails' : ''),
    );

    var format = '${cfg['format'] ?? (kind == 'audio' ? 'mp3' : kind == 'image' ? 'jpeg' : 'mp4')}';
    var vcodec = '${cfg['vcodec'] ?? 'h264'}';
    var acodec = '${cfg['acodec'] ?? 'aac'}';
    var resolution = '${cfg['resolution'] ?? 'source'}';
    var policy = '${cfg['policy'] ?? 'skip'}';
    var by = '${cfg['by'] ?? 'year'}';
    var sameName = '${cfg['sameName'] ?? 'skip'}';
    var channels = '${cfg['channels'] ?? 'source'}';
    var zip = presetZip || cfg['zip'] == true;

    final vbitrate = TextEditingController(text: '${cfg['vbitrateKbps'] ?? 0}');
    final abrate = TextEditingController(text: '${cfg['abrateKbps'] ?? 0}');
    final fps = TextEditingController(text: '${cfg['fps'] ?? 0}');
    final threads = TextEditingController(text: '${cfg['threads'] ?? 0}');
    final quality = TextEditingController(text: '${cfg['quality'] ?? 80}');
    final size = TextEditingController(
      text: '${cfg['size'] ?? (kind == 'thumbnails' ? 256 : 0)}',
    );
    final sampleRate = TextEditingController(text: '${cfg['sampleRate'] ?? 0}');
    final bitrate = TextEditingController(text: '${cfg['bitrateKbps'] ?? 0}');

    int intOf(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            final children = <Widget>[
              _field(tr('media_tool.field.source'), src,
                  hint: '/media/movies/a.mkv'),
              _field(tr('media_tool.field.target'), dst,
                  hint: '/media/out'),
            ];

            if (kind == 'video') {
              children.addAll([
                _choice(
                  tr('media_tool.field.format'),
                  format,
                  const [
                    ('mp4', 'MP4'),
                    ('mov', 'MOV'),
                    ('avi', 'AVI'),
                    ('mkv', 'MKV'),
                    ('webm', 'WEBM'),
                    ('gif', 'GIF'),
                    ('webp', 'WEBP'),
                  ],
                  (v) => setDialogState(() => format = v),
                ),
                _choice(
                  tr('media_tool.field.vcodec'),
                  vcodec,
                  const [('h264', 'H.264'), ('h265', 'H.265'), ('copy', 'copy')],
                  (v) => setDialogState(() => vcodec = v),
                ),
                _choice(
                  tr('media_tool.field.acodec'),
                  acodec,
                  const [('aac', 'AAC'), ('mp3', 'MP3'), ('copy', 'copy')],
                  (v) => setDialogState(() => acodec = v),
                ),
                _choice(
                  tr('media_tool.field.resolution'),
                  resolution,
                  const [
                    ('source', 'source'),
                    ('4k', '4K'),
                    ('1080p', '1080p'),
                    ('720p', '720p'),
                    ('480p', '480p'),
                    ('320p', '320p'),
                    ('240p', '240p'),
                  ],
                  (v) => setDialogState(() => resolution = v),
                ),
                _field(tr('media_tool.field.vbitrate'), vbitrate, number: true),
                _field(tr('media_tool.field.abrate'), abrate, number: true),
                _field(tr('media_tool.field.fps'), fps, number: true),
                _field(tr('media_tool.field.threads'), threads, number: true),
              ]);
            } else if (kind == 'audio') {
              children.addAll([
                _choice(
                  tr('media_tool.field.format'),
                  format,
                  const [
                    ('mp3', 'MP3'),
                    ('m4a', 'M4A'),
                    ('aac', 'AAC'),
                    ('flac', 'FLAC'),
                    ('ogg', 'OGG'),
                    ('wav', 'WAV'),
                    ('opus', 'OPUS'),
                    ('wma', 'WMA'),
                  ],
                  (v) => setDialogState(() => format = v),
                ),
                _field(tr('media_tool.field.sampleRate'), sampleRate, number: true),
                _choice(
                  tr('media_tool.field.channels'),
                  channels,
                  [
                    ('source', tr('media_tool.field.channelsSource')),
                    ('stereo', tr('media_tool.field.channelsStereo')),
                    ('mono', tr('media_tool.field.channelsMono')),
                  ],
                  (v) => setDialogState(() => channels = v),
                ),
                _field(tr('media_tool.field.abrate'), bitrate, number: true),
                _field(tr('media_tool.field.threads'), threads, number: true),
              ]);
            } else if (kind == 'image') {
              children.addAll([
                _choice(
                  tr('media_tool.field.format'),
                  format,
                  const [('jpeg', 'JPEG'), ('png', 'PNG'), ('webp', 'WEBP')],
                  (v) => setDialogState(() => format = v),
                ),
                _field(tr('media_tool.field.quality'), quality, number: true),
                _field(tr('media_tool.field.size'), size, number: true),
                _choice(
                  tr('media_tool.field.policy'),
                  policy,
                  [
                    ('skip', tr('media_tool.field.policySkip')),
                    ('copy', tr('media_tool.field.policyCopy')),
                  ],
                  (v) => setDialogState(() => policy = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(tr('media_tool.zip')),
                  subtitle: Text(
                    tr('media_tool.zipHint'),
                    style: TextStyle(fontSize: NasTokens.fontMicro),
                  ),
                  value: zip,
                  onChanged: (v) => setDialogState(() => zip = v),
                ),
              ]);
            } else if (kind == 'arrange') {
              children.addAll([
                _choice(
                  tr('media_tool.field.by'),
                  by,
                  [
                    ('year', tr('media_tool.field.byYear')),
                    ('month', tr('media_tool.field.byMonth')),
                    ('day', tr('media_tool.field.byDay')),
                  ],
                  (v) => setDialogState(() => by = v),
                ),
                _choice(
                  tr('media_tool.field.sameName'),
                  sameName,
                  [
                    ('skip', tr('media_tool.field.sameSkip')),
                    ('rename', tr('media_tool.field.sameRename')),
                    ('overwrite', tr('media_tool.field.sameOverwrite')),
                  ],
                  (v) => setDialogState(() => sameName = v),
                ),
              ]);
            } else if (kind == 'thumbnails') {
              children.add(_field(tr('media_tool.field.thumbSize'), size, number: true));
            }

            return AlertDialog(
              title: Text(
                editing == null
                    ? tr('media_tool.action.new')
                    : tr('media_tool.action.edit'),
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
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
      if (!mounted) return;
      final config = <String, dynamic>{
        if (kind == 'video') ...{
          'format': format,
          'vcodec': vcodec,
          'acodec': acodec,
          'resolution': resolution,
          'vbitrateKbps': intOf(vbitrate),
          'abrateKbps': intOf(abrate),
          'fps': intOf(fps),
          'threads': intOf(threads),
        },
        if (kind == 'audio') ...{
          'format': format,
          'sampleRate': intOf(sampleRate),
          'channels': channels,
          'bitrateKbps': intOf(bitrate),
          'threads': intOf(threads),
        },
        if (kind == 'image') ...{
          'format': format,
          'quality': intOf(quality).clamp(1, 100),
          'size': intOf(size),
          'policy': policy,
          'zip': zip,
        },
        if (kind == 'arrange') ...{
          'by': by,
          'sameName': sameName,
        },
        if (kind == 'thumbnails') 'size': intOf(size).clamp(32, 2048),
      };

      final messenger = ScaffoldMessenger.of(context);
      try {
        await ApiSession.instance.client.mediaToolTaskUpsert(
          body: MediaToolTaskUpsertBody(
            id: editing?.id,
            kind: kind,
            source: src.text.trim(),
            target: dst.text.trim(),
            config: config,
          ),
        );
        await _load();
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text(tr('common.createFailed', {'error': '${_hint(e) ?? e}'}))),
        );
      }
    } finally {
      src.dispose();
      dst.dispose();
      vbitrate.dispose();
      abrate.dispose();
      fps.dispose();
      threads.dispose();
      quality.dispose();
      size.dispose();
      sampleRate.dispose();
      bitrate.dispose();
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'done':
        return context.nasSuccess;
      case 'failed':
        return context.nasDanger;
      case 'running':
        return Theme.of(context).colorScheme.primary;
      default:
        return context.nasTextSecondary;
    }
  }

  String _statusText(MediaToolTaskItem task) {
    return switch (task.status) {
      'pending' => tr('ui.media_tool.h4dcbbc'),
      'running' => tr('ui.media_tool.h1f425b'),
      'done' => tr('ui.media_tool.he99b48'),
      'failed' => tr('ui.media_tool.h3e3c80'),
      'canceled' => tr('ui.media_tool.ha5ffdc'),
      'stopped' => tr('media_tool.status.stopped'),
      _ => task.status,
    };
  }

  Widget _navHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceSm,
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          if (!_collapsed)
            Expanded(
              child: Text(
                tr('ui.media_tool.014'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          IconButton(
            tooltip: _collapsed
                ? tr('nav.expand')
                : tr('nav.collapse'),
            icon: Icon(
              _collapsed
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
              size: 18,
            ),
            onPressed: () => setState(() => _collapsed = !_collapsed),
          ),
        ],
      ),
    );
  }

  Widget _toolBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        6,
        NasTokens.spaceXs,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr(_toolTitles[_tool] ?? 'ui.media_tool.014'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_tool == 'batchCompress')
            TextButton.icon(
              onPressed: _uploadImages,
              icon: const Icon(Icons.upload_file, size: 16),
              label: Text(tr('media_tool.upload')),
            ),
          if (_toolImplemented)
            TextButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, size: 16),
              label: Text(tr('media_tool.action.new')),
            ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: tr('ui.accounts.021'),
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _emptyComingSoon() {
    return NasEmptyState(
      title: tr('media_tool.comingSoon'),
      message: tr('media_tool.comingSoonHint'),
      icon: Icons.construction_outlined,
    );
  }

  Widget _jobTile(MediaToolTaskItem task) {
    final active = task.status == 'pending' || task.status == 'running';
    final progress =
        task.total > 0 ? (task.done / task.total).clamp(0.0, 1.0).toDouble() : 0.0;
    return ListTile(
      leading: Icon(
        task.kind == 'image'
            ? Icons.image_outlined
            : task.kind == 'audio'
                ? Icons.audiotrack_outlined
                : task.kind == 'arrange'
                    ? Icons.drive_file_move_outline
                    : task.kind == 'thumbnails'
                        ? Icons.photo_size_select_large_outlined
                        : Icons.movie_outlined,
      ),
      title: Text(
        '${task.source} → ${task.target}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            '${_statusText(task)} · ${tr('media_tool.stats', {
              'done': '${task.processed}',
              'total': '${task.total}',
              'skipped': '${task.skipped}',
              'failed': '${task.failed}',
            })}',
            style: TextStyle(color: _statusColor(task.status)),
          ),
          if (task.inBytes > 0 || task.outBytes > 0)
            Text(
              '${formatBytes(task.inBytes)} → ${formatBytes(task.outBytes)}',
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                color: context.nasTextSecondary,
              ),
            ),
          if (task.lastError != null && task.lastError!.isNotEmpty)
            Text(
              task.lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.nasDanger),
            ),
          if (active) ...[
            const SizedBox(height: NasTokens.spaceXs),
            LinearProgressIndicator(value: progress),
          ],
        ],
      ),
      isThreeLine: true,
      trailing: Wrap(
        spacing: NasTokens.spaceXs,
        children: [
          if (active)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
              tooltip: tr('media_tool.action.stop'),
              onPressed: () => _stop(task),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.play_arrow, size: 20),
              tooltip: tr('media_tool.action.start'),
              onPressed: () => _start(task),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: tr('media_tool.action.edit'),
              onPressed: () => _openEditor(editing: task),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: tr('common.delete'),
              onPressed: () => _delete(task),
            ),
          ],
        ],
      ),
    );
  }

  Widget _content() {
    if (_loading) return const NasLoading();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceLg),
          child: Text(
            _error!,
            style: TextStyle(color: context.nasDanger),
          ),
        ),
      );
    }
    if (!_toolImplemented) {
      return _emptyComingSoon();
    }
    final jobs = _visibleJobs;
    if (jobs.isEmpty) {
      return NasEmptyState(
        title: tr('media_tool.empty'),
        icon: Icons.playlist_play_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _jobTile(jobs[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final admin = ApiSession.instance.isAdmin;
    return Scaffold(
      body: Row(
        children: [
          NasSideNav(
            width: _collapsed ? 56 : 176,
            iconOnly: _collapsed,
            selectedId: _tool,
            onSelect: (id) => setState(() => _tool = id),
            header: _navHeader(),
            groups: [
              NasNavGroup(
                title: tr('media_tool.group.image'),
                entries: [
                  NasNavEntry(
                    id: 'singleCompress',
                    label: tr('media_tool.entry.singleCompress'),
                    icon: Icons.image_outlined,
                  ),
                  if (admin)
                    NasNavEntry(
                      id: 'batchCompress',
                      label: tr('media_tool.entry.batchCompress'),
                      icon: Icons.photo_library_outlined,
                    ),
                ],
              ),
              if (admin)
                NasNavGroup(
                  title: tr('media_tool.group.video'),
                  entries: [
                    NasNavEntry(
                      id: 'videoTrans',
                      label: tr('media_tool.entry.videoTrans'),
                      icon: Icons.movie_filter_outlined,
                    ),
                  ],
                ),
              if (admin)
                NasNavGroup(
                  title: tr('media_tool.group.audio'),
                  entries: [
                    NasNavEntry(
                      id: 'audioTrans',
                      label: tr('media_tool.entry.audioTrans'),
                      icon: Icons.audiotrack_outlined,
                    ),
                  ],
                ),
              NasNavGroup(
                title: tr('media_tool.group.other'),
                entries: [
                  if (admin)
                    NasNavEntry(
                      id: 'arrange',
                      label: tr('media_tool.entry.arrange'),
                      icon: Icons.drive_file_move_outline,
                    ),
                  if (admin)
                    NasNavEntry(
                      id: 'thumbnails',
                      label: tr('media_tool.entry.thumbnails'),
                      icon: Icons.photo_size_select_large_outlined,
                    ),
                  NasNavEntry(
                    id: 'tasks',
                    label: tr('media_tool.entry.tasks'),
                    icon: Icons.history,
                  ),
                ],
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _toolBar(),
                const Divider(height: 1),
                Expanded(child: _content()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}