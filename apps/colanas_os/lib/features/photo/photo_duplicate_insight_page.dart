import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_panel.dart';

/// 重复照片洞察：先看清「有多少可回收」，再决定要不要去清理页动手。
///
/// 与 `cleanup_page.dart` 的区别：这里只读、不勾选、不执行，纯统计视角。
/// 数据全部来自现成的 `/photo/cleanup/preview` 与 `/photo/cleanup/phash/status`。
class PhotoDuplicateInsightPage extends StatefulWidget {
  const PhotoDuplicateInsightPage({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  State<PhotoDuplicateInsightPage> createState() => _PhotoDuplicateInsightPageState();
}

class _PhotoDuplicateInsightPageState extends State<PhotoDuplicateInsightPage> {
  bool _loading = true;
  PhotoCleanupPreviewResponse? _preview;
  PhotoPhashStatus? _phash;

  ApiClient get _client => ApiSession.instance.client;

  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final f1 = _client.photoCleanupPreview(
      body: const PhotoCleanupPreviewBody(limit: 50, includeSimilar: true),
    );
    final f2 = _client.photoPhashStatus();
    try {
      _preview = await f1;
    } catch (_) {}
    try {
      _phash = await f2;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  List<PhotoCleanupGroup> _groupsIn(Map<String, dynamic> section) {
    final raw = section['groups'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => PhotoCleanupGroup.fromJson(Map<String, dynamic>.from(e)))
        .toList();
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
    if (_loading) return const NasLoading();
    final groups = _allGroups;
    if (_preview == null && _phash == null) {
      return NasEmptyState(
        title: tr('photo.duplicate.empty'),
        icon: Icons.content_copy_outlined,
      );
    }
    final wasted = groups.fold<int>(0, (sum, g) => sum + g.wastedBytes);
    final similarCount = _preview == null
        ? 0
        : _groupsIn(_preview!.similar).length;
    final top = [...groups]..sort((a, b) => b.wastedBytes.compareTo(a.wastedBytes));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        children: [
          _header(),
          const SizedBox(height: NasTokens.spaceLg),
          PhotoPanel(
            title: tr('photo.duplicate.title'),
            child: Wrap(
              spacing: 18,
              runSpacing: 12,
              children: [
                _stat(tr('photo.duplicate.groups'), '${groups.length}'),
                _stat(tr('photo.duplicate.wasted'), formatBytes(wasted)),
                _stat(tr('photo.duplicate.missingMd5'), '${_preview?.missingMd5 ?? 0}'),
                _stat(tr('photo.duplicate.similarGroups'), '$similarCount'),
              ],
            ),
          ),
          const SizedBox(height: NasTokens.spaceLg),
          _phashCard(),
          if (top.isNotEmpty) ...[
            const SizedBox(height: NasTokens.spaceLg),
            PhotoPanel(
              title: tr('photo.duplicate.topWasted'),
              child: Column(
                children: [
                  for (final g in top.take(5)) _groupTile(g),
                ],
              ),
            ),
          ],
          const SizedBox(height: NasTokens.spaceLg),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => widget.onNavigate('cleanup'),
              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
              label: Text(tr('photo.duplicate.goCleanup')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('photo.duplicate.title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            tr('photo.duplicate.hint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return SizedBox(
      width: 128,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: context.nasTextSecondary)),
        ],
      ),
    );
  }

  Widget _phashCard() {
    final s = _phash;
    final running = s?.running == true;
    return PhotoPanel(
      title: tr('photo.duplicate.phashScan'),
      trailing: Text(
        running ? tr('photo.duplicate.scanRunning') : tr('photo.duplicate.scanIdle'),
        style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (running && s != null) ...[
            LinearProgressIndicator(
              value: s.total <= 0 ? null : s.done / s.total,
              minHeight: 4,
            ),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              _stat(tr('photo.duplicate.phashGroups'), '${s?.groups ?? 0}'),
              _stat(tr('photo.duplicate.md5Candidates'), '${_preview?.md5Candidates ?? 0}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _groupTile(PhotoCleanupGroup g) {
    final path = g.items.isEmpty ? '' : g.items.first.path;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        child: SizedBox(
          width: 44,
          height: 44,
          child: path.isEmpty
              ? const Icon(Icons.image_outlined)
              : NasCoverImage(
                  url: _media.thumbnail(path, size: 128),
                  headers: ApiSession.instance.authHeaders,
                  cacheWidth: 128,
                  icon: Icons.broken_image_outlined,
                ),
        ),
      ),
      title: Text('${g.count} · ${formatBytes(g.wastedBytes)}'),
      subtitle: Text(g.kind, style: TextStyle(fontSize: 11, color: context.nasTextSecondary)),
    );
  }
}
