import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import 'photo_panel.dart';

/// 智能发现：把首页看板 / 场景 / 活动 / 人物的汇总数据聚到一页。
///
/// 纯客户端聚合现成接口，服务端零改动。四个请求同时发出、各自容错，
/// 某个识别模块没跑过（或没权限）不会让整页白屏。
class PhotoDiscoverPage extends StatefulWidget {
  const PhotoDiscoverPage({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  State<PhotoDiscoverPage> createState() => _PhotoDiscoverPageState();
}

class _PhotoDiscoverPageState extends State<PhotoDiscoverPage> {
  bool _loading = true;
  PhotoHomeSummary? _summary;
  PhotoSceneSummary? _scenes;
  PhotoSceneSummary? _activities;
  PhotoFaceClusterList? _people;

  ApiClient get _client => ApiSession.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // 同时发起，再逐个收：既并行又能单独容错
    final f1 = _client.photoHomeSummary();
    final f2 = _client.photoSceneSummary();
    final f3 = _client.photoActivitySummary();
    final f4 = _client.photoFaceClusters(minCount: 3);
    try {
      _summary = await f1;
    } catch (_) {}
    try {
      _scenes = await f2;
    } catch (_) {}
    try {
      _activities = await f3;
    } catch (_) {}
    try {
      _people = await f4;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    final s = _summary;
    final hasData = s != null ||
        (_scenes?.items.isNotEmpty ?? false) ||
        (_activities?.items.isNotEmpty ?? false) ||
        (_people?.items.isNotEmpty ?? false);
    if (!hasData) {
      return NasEmptyState(
        title: tr('photo.discovery.empty'),
        icon: Icons.explore_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        children: [
          _header(),
          const SizedBox(height: NasTokens.spaceLg),
          if (s != null) ...[
            _libraryCard(s),
            const SizedBox(height: NasTokens.spaceLg),
            _footprintCard(s),
            const SizedBox(height: NasTokens.spaceLg),
          ],
          if (_scenes?.items.isNotEmpty ?? false) ...[
            _tagSection(tr('photo.discovery.topScenes'), _scenes!.items, 'scenes'),
            const SizedBox(height: NasTokens.spaceLg),
          ],
          if (_activities?.items.isNotEmpty ?? false) ...[
            _tagSection(tr('photo.discovery.topActivities'), _activities!.items, 'activities'),
            const SizedBox(height: NasTokens.spaceLg),
          ],
          if (_people?.items.isNotEmpty ?? false) ...[
            _peopleSection(_people!.items),
            const SizedBox(height: NasTokens.spaceLg),
          ],
          _shortcuts(),
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
            tr('photo.discovery.title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            tr('photo.discovery.hint'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return PhotoPanel(title: title, child: child);
  }

  Widget _stat(String label, String value) {
    return SizedBox(
      width: 108,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.nasTextSecondary),
          ),
        ],
      ),
    );
  }

  Widget _libraryCard(PhotoHomeSummary s) {
    return _card(
      title: tr('photo.discovery.library'),
      child: Wrap(
        spacing: 18,
        runSpacing: 12,
        children: [
          _stat(tr('photo.discovery.photos'), '${s.library.photos}'),
          _stat(tr('photo.discovery.videos'), '${s.library.videos}'),
          _stat(tr('photo.discovery.bytes'), formatBytes(s.library.bytes)),
          _stat(tr('photo.discovery.todayNew'), '${s.library.todayNew}'),
          _stat(tr('photo.discovery.activeDays'), '${s.heat.activeDays}'),
        ],
      ),
    );
  }

  Widget _footprintCard(PhotoHomeSummary s) {
    return _card(
      title: tr('photo.discovery.footprint'),
      child: Wrap(
        spacing: 18,
        runSpacing: 12,
        children: [
          _stat(tr('photo.discovery.cities'), '${s.footprint.cities}'),
          _stat(tr('photo.discovery.places'), '${s.footprint.places}'),
          _stat(tr('photo.discovery.travelDays'), '${s.footprint.days}'),
        ],
      ),
    );
  }

  Widget _tagSection(String title, List<PhotoSceneSummaryItem> items, String target) {
    return _card(
      title: title,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in items.take(12))
            ActionChip(
              label: Text('${item.label} · ${item.count}'),
              onPressed: () => widget.onNavigate(target),
            ),
        ],
      ),
    );
  }

  Widget _peopleSection(List<PhotoFaceClusterItem> items) {
    return _card(
      title: tr('photo.discovery.topPeople'),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in items.take(12))
            ActionChip(
              avatar: const Icon(Icons.face_retouching_natural_outlined, size: 16),
              label: Text('${p.name ?? p.id} · ${p.size}'),
              onPressed: () => widget.onNavigate('faces'),
            ),
        ],
      ),
    );
  }

  Widget _shortcuts() {
    const entries = <(String, String, IconData)>[
      ('memory', 'photo.nav.memory', Icons.auto_stories_outlined),
      ('dayFrame', 'photo.nav.dayFrame', Icons.auto_awesome_mosaic_outlined),
      ('tickets', 'photo.nav.tickets', Icons.confirmation_number_outlined),
      ('year', 'photo.nav.year', Icons.bar_chart),
      ('timeContrast', 'photo.nav.timeContrast', Icons.history),
      ('journey', 'photo.nav.journey', Icons.travel_explore_outlined),
      ('duplicateInsight', 'photo.nav.duplicateInsight', Icons.content_copy_outlined),
    ];
    return _card(
      title: tr('photo.discovery.quickEntries'),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in entries)
            ActionChip(
              avatar: Icon(e.$3, size: 16),
              label: Text(tr(e.$2)),
              onPressed: () => widget.onNavigate(e.$1),
            ),
        ],
      ),
    );
  }
}
