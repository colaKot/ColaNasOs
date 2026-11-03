import 'package:flutter/material.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';

/// 回收站：**按删除批次分组**（一次删除 = 一组），可整批还原或整批清空。
///
/// 此前是平铺列表：删了三批照片后，用户从一堆文件名里根本分不清哪些是一起删的，
/// 只能一张张勾。批次由服务端在 `POST /photo/delete?toTrash=1` 时落库，
/// 迁移前的历史数据与清理链路没有批次号，归到「历史清理」一组（batchId=null）。
class PhotoTrashPage extends StatefulWidget {
  const PhotoTrashPage({super.key});

  @override
  State<PhotoTrashPage> createState() => _PhotoTrashPageState();
}

class _TrashBatch {
  const _TrashBatch({
    required this.id,
    required this.count,
    required this.createdAt,
    required this.coverPath,
    required this.daysLeft,
  });

  /// null = 无批次号（历史数据 / 清理链路），查询时用 'none' 代替
  final String? id;
  final int count;
  final int? createdAt;
  final String? coverPath;
  final int? daysLeft;

  String get queryId => id ?? 'none';
}

class _PhotoTrashPageState extends State<PhotoTrashPage> {
  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  Map<String, String> get _imageHeaders {
    final token = ApiSession.instance.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  bool _loading = true;
  String? _error;
  int _total = 0;
  List<_TrashBatch> _batches = const [];
  String? _openBatch;
  List<Map<String, dynamic>> _items = const [];
  bool _loadingItems = false;
  final Set<String> _selected = <String>{};

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
      final res = await ApiSession.instance.client.photoTrashBatches();
      final raw = (res['items'] as List?) ?? const [];
      final batches = raw.whereType<Map>().map((e) {
        final m = Map<String, dynamic>.from(e);
        return _TrashBatch(
          id: m['batchId'] as String?,
          count: (m['count'] as num?)?.toInt() ?? 0,
          createdAt: (m['createdAt'] as num?)?.toInt(),
          coverPath: m['coverPath'] as String?,
          daysLeft: (m['daysLeft'] as num?)?.toInt(),
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _batches = batches;
        _total = (res['total'] as num?)?.toInt() ?? 0;
        _items = const [];
        _selected.clear();
        _loading = false;
        _openBatch = batches.isEmpty ? null : batches.first.queryId;
      });
      if (_openBatch != null) await _loadItems(_openBatch!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadItems(String batchId) async {
    setState(() => _loadingItems = true);
    try {
      final res = await ApiSession.instance.client.photoTrashList(
        limit: 200,
        batchId: batchId,
      );
      if (!mounted) return;
      final raw = (res['items'] as List?) ?? const [];
      setState(() {
        _items = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _selected.clear();
        _loadingItems = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingItems = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _toggleBatch(String batchId) async {
    if (_openBatch == batchId) {
      setState(() => _openBatch = null);
      return;
    }
    setState(() {
      _openBatch = batchId;
      _items = const [];
    });
    await _loadItems(batchId);
  }

  Future<void> _restore({List<String>? ids, String? batchId}) async {
    final body = <String, dynamic>{};
    if (batchId != null) body['batchId'] = batchId;
    if (ids != null && ids.isNotEmpty) body['ids'] = ids;
    if (body.isEmpty) return;
    try {
      final res = await ApiSession.instance.client.photoTrashRestore(body: body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('photo.trash.restored').replaceAll('{n}', '${res.restored}'))),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _empty({String? batchId}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.trash.clear')),
        content: Text(tr(batchId == null ? 'photo.trash.clearConfirm' : 'photo.trash.clearBatchConfirm')),
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
      final body = <String, dynamic>{};
      if (batchId != null) body['batchId'] = batchId;
      await ApiSession.instance.client.photoTrashEmpty(body: body);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('photo.trash.cleared'))));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
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
                child: Text(
                  tr('photo.trash.batches')
                      .replaceAll('{n}', '$_total')
                      .replaceAll('{b}', '${_batches.length}'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _selected.isEmpty ? null : () => _restore(ids: _selected.toList()),
                icon: const Icon(Icons.restore, size: 18),
                label: Text(tr('photo.trash.restore')),
              ),
              TextButton.icon(
                onPressed: _batches.isEmpty ? null : () => _empty(),
                icon: const Icon(Icons.delete_forever_outlined, size: 18),
                label: Text(tr('photo.trash.clear')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _batches.isEmpty
              ? ListView(
                  children: [
                    NasEmptyState(
                      title: tr('photo.trash.empty'),
                      icon: Icons.delete_outline,
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NasTokens.spaceSm,
                    vertical: NasTokens.spaceXs,
                  ),
                  itemCount: _batches.length,
                  itemBuilder: (context, i) => _batchCard(_batches[i]),
                ),
        ),
      ],
    );
  }

  Widget _batchCard(_TrashBatch batch) {
    final open = _openBatch == batch.queryId;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
      child: Column(
        children: [
          InkWell(
            onTap: () => _toggleBatch(batch.queryId),
            child: Padding(
              padding: const EdgeInsets.all(NasTokens.spaceSm),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: batch.coverPath == null
                        ? Icon(Icons.delete_outline, color: context.nasTextSecondary)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                            child: NasCoverImage(
                              url: _media.thumbnail(batch.coverPath!, size: 96),
                              headers: _imageHeaders,
                              cacheWidth: 96,
                              icon: Icons.broken_image_outlined,
                            ),
                          ),
                  ),
                  const SizedBox(width: NasTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          batch.createdAt == null
                              ? tr('photo.trash.legacy')
                              : formatDateTimeSec(batch.createdAt!),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('photo.trash.batchMeta')
                              .replaceAll('{n}', '${batch.count}')
                              .replaceAll(
                                '{days}',
                                batch.daysLeft == null ? '-' : '${batch.daysLeft}',
                              ),
                          style: TextStyle(
                            fontSize: NasTokens.fontCaption,
                            color: context.nasTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr('photo.trash.restoreBatch'),
                    icon: const Icon(Icons.restore),
                    onPressed: () => _restore(batchId: batch.queryId),
                  ),
                  IconButton(
                    tooltip: tr('photo.trash.clearBatch'),
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _empty(batchId: batch.queryId),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    color: context.nasTextSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            if (_loadingItems)
              const Padding(
                padding: EdgeInsets.all(NasTokens.spaceSm),
                child: LinearProgressIndicator(),
              )
            else
              Column(
                children: [
                  for (final item in _items)
                    Builder(
                      builder: (context) {
                        final id = '${item['id']}';
                        final deletedAt = (item['deletedAt'] as num?)?.toInt();
                        return CheckboxListTile(
                          value: _selected.contains(id),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selected.add(id);
                            } else {
                              _selected.remove(id);
                            }
                          }),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            '${item['path']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: NasTokens.fontBody,
                              color: scheme.onSurface,
                            ),
                          ),
                          subtitle: deletedAt == null
                              ? null
                              : Text(
                                  formatDateTimeSec(deletedAt),
                                  style: TextStyle(
                                    fontSize: NasTokens.fontCaption,
                                    color: context.nasTextSecondary,
                                  ),
                                ),
                          secondary: IconButton(
                            tooltip: tr('photo.trash.restore'),
                            icon: const Icon(Icons.restore),
                            onPressed: () => _restore(ids: [id]),
                          ),
                        );
                      },
                    ),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(NasTokens.spaceSm),
                      child: Text(
                        tr('photo.trash.batchEmpty'),
                        style: TextStyle(
                          fontSize: NasTokens.fontCaption,
                          color: context.nasTextSecondary,
                        ),
                      ),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}
