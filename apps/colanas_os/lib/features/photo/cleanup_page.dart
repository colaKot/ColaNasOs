import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 重复与相似清理：**先预演、再执行、可撤销**。
///
/// 页面上永远先给「将要发生什么」，用户勾选后再执行；执行会写一个批次，
/// 撤销按批次精确还原回收站状态（从属关系的合并不回滚，界面会说明）。
class PhotoCleanupPage extends StatefulWidget {
  const PhotoCleanupPage({super.key, this.embedded = false});

  /// 嵌入相册二级导航内容区时去掉自带 AppBar
  final bool embedded;

  @override
  State<PhotoCleanupPage> createState() => _PhotoCleanupPageState();
}

class _PhotoCleanupPageState extends State<PhotoCleanupPage> {
  bool _loading = false;
  String? _error;
  PhotoCleanupPreviewResponse? _preview;

  /// 已勾选要执行的组：groupKey -> 保留的照片 id
  final Map<String, String> _picked = {};

  List<PhotoCleanupBatch> _batches = const [];
  int _trashTotal = 0;
  String _lastBatchId = '';
  int _lastTrashed = 0;

  final double _similarity = 0.92;
  bool _includeSimilar = true;
  PhotoPhashStatus? _phash;
  Timer? _poll;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);
  String _thumb(String path) => _media.thumbnail(path, size: 240);

  @override
  void initState() {
    super.initState();
    _loadBatches();
    _loadTrashCount();
    _loadPhash();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadPhash() async {
    try {
      final status = await ApiSession.instance.client.photoPhashStatus();
      if (!mounted) return;
      setState(() => _phash = status);
    } catch (_) {
      // 进度读取失败不影响页面
    }
  }

  Future<void> _scanPhash() async {
    try {
      await ApiSession.instance.client.photoPhashScan();
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
        final status = await ApiSession.instance.client.photoPhashStatus();
        if (!mounted) return;
        setState(() => _phash = status);
        if (!status.running) {
          timer.cancel();
          await _previewNow();
        }
      });
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _loadBatches() async {
    try {
      final res = await ApiSession.instance.client.photoCleanupBatches();
      if (!mounted) return;
      setState(() => _batches = res.items);
    } catch (_) {
      // 批次列表失败不影响预演
    }
  }

  Future<void> _loadTrashCount() async {
    try {
      final res = await ApiSession.instance.client.photoTrashList(limit: 1);
      if (!mounted) return;
      setState(() => _trashTotal = (res['total'] as num?)?.toInt() ?? 0);
    } catch (_) {
      // 回收站计数失败静默
    }
  }

  Future<void> _previewNow() async {
    setState(() {
      _loading = true;
      _error = null;
      _picked.clear();
      _lastBatchId = '';
      _lastTrashed = 0;
    });
    try {
      final res = await ApiSession.instance.client.photoCleanupPreview(
        body: PhotoCleanupPreviewBody(
          limit: 50,
          similarity: _similarity,
          includeSimilar: _includeSimilar,
        ),
      );
      if (!mounted) return;
      setState(() {
        _preview = res;
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

  List<PhotoCleanupGroup> _groupsIn(Map<String, dynamic> section) {
    final raw = section['groups'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(PhotoCleanupGroup.fromJson)
        .toList();
  }

  Future<void> _apply() async {
    if (_picked.isEmpty) return;
    final groups = _picked.entries.map((e) {
      final group = _allGroups.firstWhere((g) => g.key == e.key);
      return PhotoCleanupApplyGroup(
        key: e.key,
        keepId: e.value,
        removeIds: group.ids.where((id) => id != e.value).toList(),
      );
    }).toList();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.photo.007')),
        content: Text(
          tr('photo.cleanupConfirm', {'groups': '${groups.length}'}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('ui.photo.008')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final res = await ApiSession.instance.client.photoCleanupApply(
        body: PhotoCleanupApplyBody(
          kind: _picked.keys.any((k) => k.startsWith('similar:')) ? 'similar' : 'duplicate',
          groups: groups,
        ),
      );
      if (!mounted) return;
      setState(() {
        _lastBatchId = res.batchId;
        _lastTrashed = res.trashed;
        _picked.clear();
      });
      await _previewNow();
      await _loadBatches();
      await _loadTrashCount();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.errorWith', {'error': '$e'}));
    }
  }

  Future<void> _undo(String batchId) async {
    try {
      final res = await ApiSession.instance.client.photoCleanupUndo(
        body: PhotoCleanupUndoBody(batchId: batchId),
      );
      if (!mounted) return;
      NasSnack.show(context, tr('photo.cleanupRestored', {'count': '${res.restored}'}));
      await _loadBatches();
      await _loadTrashCount();
      await _previewNow();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('photo.undoFailed', {'error': '$e'}));
    }
  }

  Future<void> _backfillMd5() async {
    try {
      final res = await ApiSession.instance.client.photoCleanupBackfillMd5(
        body: const PhotoCleanupBackfillBody(limit: 500),
      );
      if (!mounted) return;
      NasSnack.show(context, tr('photo.md5Progress', {'hashed': '${res.hashed}', 'remaining': '${res.remaining}'}));
      await _previewNow();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('photo.md5Failed', {'error': '$e'}));
    }
  }

  List<PhotoCleanupGroup> get _allGroups {
    final p = _preview;
    if (p == null) return const [];
    return [
      ..._groupsIn(p.duplicate),
      ..._groupsIn(p.nameDuplicate),
      ..._groupsIn(p.similar),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(
        title: Text(tr('photo.nav.similarCleanup')),
        actions: [
          IconButton(
            tooltip: tr('ui.photo.010'),
            icon: const Icon(Icons.fingerprint),
            onPressed: _backfillMd5,
          ),
          IconButton(
            tooltip: tr('ui.photo.011'),
            icon: const Icon(Icons.visibility_outlined),
            onPressed: _previewNow,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(NasTokens.spaceMd),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(NasTokens.spaceSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('photo.cleanup.phash')),
                            const SizedBox(height: 2),
                            Text(
                              _phash == null
                                  ? tr('photo.cleanup.phashUnknown')
                                  : _phash!.running
                                      ? tr('photo.cleanup.phashRunning', {
                                          'phase': _phash!.phase,
                                          'percent': '${_phash!.percent}',
                                        })
                                      : tr('photo.cleanup.phashDone', {
                                          'groups': '${_phash!.groups}',
                                          'threshold': '${_phash!.threshold}',
                                        }),
                              style: TextStyle(
                                color: context.nasTextSecondary,
                                fontSize: NasTokens.fontCaption,
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _phash?.running == true ? null : _scanPhash,
                        child: Text(tr('photo.cleanup.phashScan')),
                      ),
                    ],
                  ),
                  if (_phash != null && _phash!.running) ...[
                    const SizedBox(height: NasTokens.spaceSm),
                    LinearProgressIndicator(
                      value: _phash!.total <= 0 ? null : _phash!.done / _phash!.total,
                      minHeight: 4,
                    ),
                  ],
                  const SizedBox(height: NasTokens.spaceSm),
                  Row(
                    children: [
                      Switch(
                        value: _includeSimilar,
                        onChanged: (v) => setState(() => _includeSimilar = v),
                      ),
                      Text(tr('ui.photo.014')),
                      const Spacer(),
                      Text(
                        tr('photo.cleanup.trashCount', {'count': '$_trashTotal'}),
                        style: TextStyle(
                          color: context.nasTextSecondary,
                          fontSize: NasTokens.fontCaption,
                        ),
                      ),
                    ],
                  ),
                  if (preview != null)
                    Text(
                      tr('photo.cleanup.md5Hint', {
                        'missing': '${preview.missingMd5}',
                        'candidates': '${preview.md5Candidates}',
                      }),
                      style: TextStyle(
                        color: context.nasTextSecondary,
                        fontSize: NasTokens.fontCaption,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_lastBatchId.isNotEmpty)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text(tr('photo.cleanupDone', {'count': '$_lastTrashed'})),
                subtitle: Text(tr('photo.cleanupBatch', {'id': _lastBatchId})),
                trailing: TextButton(
                  onPressed: () => _undo(_lastBatchId),
                  child: Text(tr('ui.photo.015')),
                ),
              ),
            ),
          const SizedBox(height: NasTokens.spaceSm),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            NasErrorState(message: _error!, onRetry: _previewNow),
          if (!_loading && preview == null && _error == null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(tr('ui.photo.016')),
                    const SizedBox(height: NasTokens.spaceSm),
                    FilledButton(
                      onPressed: _previewNow,
                      child: Text(tr('ui.photo.017')),
                    ),
                  ],
                ),
              ),
            ),
          if (preview != null) ...[
            _section(tr('ui.photo.h5d432d'), _groupsIn(preview.duplicate)),
            _section(tr('ui.photo.h2644db'), _groupsIn(preview.nameDuplicate)),
            _section(
              tr('ui.photo.h93fa35'),
              _groupsIn(preview.similar),
              note: preview.similar['note'] as String?,
            ),
            const SizedBox(height: NasTokens.spaceMd),
            Text(
              tr('ui.photo.018'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: NasTokens.spaceXs),
            for (final b in _batches)
              ListTile(
                dense: true,
                leading: Icon(b.undoneAt == null ? Icons.history : Icons.undo),
                title: Text('${b.kind} · ${b.summary}'),
                subtitle: Text(
                  b.undoneAt == null ? tr('ui.photo.019') : tr('ui.photo.020'),
                ),
                trailing: b.undoneAt == null
                    ? TextButton(
                        onPressed: () => _undo(b.id),
                        child: Text(tr('ui.photo.015')),
                      )
                    : null,
              ),
          ],
        ],
      ),
      bottomNavigationBar: _picked.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(NasTokens.spaceSm),
                child: FilledButton(
                  onPressed: _apply,
                  child: Text(tr('photo.cleanupPick', {'count': '${_picked.length}'})),
                ),
              ),
            ),
    );
  }

  Widget _section(
    String title,
    List<PhotoCleanupGroup> groups, {
    String? note,
  }) {
    if (groups.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: NasTokens.spaceMd),
        Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: NasTokens.spaceSm),
            Text(
              tr('photo.groupCount', {'count': '${groups.length}'}),
              style: TextStyle(color: context.nasTextSecondary),
            ),
          ],
        ),
        if (note != null && note.isNotEmpty)
          Text(
            note,
            style: TextStyle(
              color: context.nasTextSecondary,
              fontSize: NasTokens.fontCaption,
            ),
          ),
        const SizedBox(height: NasTokens.spaceXs),
        for (final g in groups) _groupCard(g),
      ],
    );
  }

  Widget _groupCard(PhotoCleanupGroup group) {
    final picked = _picked.containsKey(group.key);
    final keepId = _picked[group.key] ?? group.keepId;
    return Card(
      margin: const EdgeInsets.only(bottom: NasTokens.spaceSm),
      child: Padding(
        padding: const EdgeInsets.all(NasTokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: picked,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _picked[group.key] = keepId;
                    } else {
                      _picked.remove(group.key);
                    }
                  }),
                ),
                Expanded(
                  child: Text(
                    tr('photo.groupWasted', {'count': '${group.count}', 'bytes': formatBytes(group.wastedBytes)}),
                    style: const TextStyle(fontSize: NasTokens.fontCaption),
                  ),
                ),
                Text(
                  tr('photo.keepLabel', {
                    'value': group.items.any((i) => i.id == keepId)
                        ? tr('photo.keepSelected', {
                            'index': '${group.items.indexWhere((i) => i.id == keepId) + 1}',
                          })
                        : tr('ui.photo.hc8d09c'),
                  }),
                  style: TextStyle(
                    color: context.nasTextSecondary,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: group.items.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: NasTokens.spaceXs),
                itemBuilder: (context, i) {
                  final item = group.items[i];
                  final isKeep = item.id == keepId;
                  return GestureDetector(
                    onTap: () => setState(() => _picked[group.key] = item.id),
                    child: Container(
                      width: 90,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                        border: Border.all(
                          color: isKeep
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                        child: NasCoverImage(
                          url: _thumb(item.path),
                          headers: ApiSession.instance.authHeaders,
                          cacheWidth: 200,
                          icon: Icons.broken_image_outlined,
                        ),
                      ),
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
