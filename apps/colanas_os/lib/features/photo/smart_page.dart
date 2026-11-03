import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';

/// 智能相册：场景 / 活动 / 人脸 / 语义搜索。
///
/// 数据来自离线分析（人脸 EdgeFace + 场景 places365 + 活动 SigLIP2 + OCR PP-OCRv6）。
/// 分析入口在右上角菜单，按能力分开跑：整批分析很贵，OCR / 活动可以单独推进度。
class PhotoSmartPage extends StatefulWidget {
  const PhotoSmartPage({
    super.key,
    this.embedded = false,
    this.section = 'faces',
  });

  /// 嵌入相册二级导航内容区时去掉自带 AppBar
  final bool embedded;

  /// 当前页签：scenes / activities / faces / rules / search（由左侧栏选择）
  final String section;

  @override
  State<PhotoSmartPage> createState() => _PhotoSmartPageState();
}

class _PhotoRef {
  const _PhotoRef(this.id, this.path);

  final String id;
  final String path;
}

class _PhotoSmartPageState extends State<PhotoSmartPage> {
  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  List<PhotoSceneTagSummaryItem> _scenes = const [];
  List<PhotoSceneSummaryItem> _activities = const [];
  List<PhotoFaceClusterItem> _clusters = const [];
  List<PhotoSmartRule> _rules = const [];

  /// 场景详情：photoId → gate（用于「只看高置信」过滤与角标）
  Map<String, String> _sceneGateOf = const {};
  bool _gateConfidentOnly = false;
  List<_PhotoRef> _photos = const [];
  String? _title;
  bool _loading = true;
  bool _analyzing = false;
  String? _error;

  final _searchCtrl = TextEditingController();
  String _searchHint = '';
  List<PhotoSemanticTag> _searchTags = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = ApiSession.instance.client;
      final scenes = await c.photoSceneTagSummary();
      final activities = await c.photoActivitySummary();
      final clusters = await c.photoFaceClusters(minCount: 1);
      final rules = await c.photoSmartRuleList();
      if (!mounted) return;
      setState(() {
        _scenes = scenes.items;
        _activities = activities.items;
        _clusters = clusters.items;
        _rules = rules.items;
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

  Future<void> _openLabel(String label) async {
    setState(() {
      _title = label;
      _gateConfidentOnly = false;
    });
    try {
      final res = await ApiSession.instance.client.photoSceneTags(
        label: label,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _photos = res.items.map((i) => _PhotoRef(i.id, i.path)).toList();
        _sceneGateOf = {for (final i in res.items) i.id: (i.gate ?? '')};
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.loadFailed', {'error': '$e'}))));
    }
  }

  Future<void> _openActivity(String label) async {
    setState(() => _title = label);
    try {
      final res = await ApiSession.instance.client.photoActivities(
        label: label,
        limit: 60,
      );
      if (!mounted) return;
      setState(
        () => _photos = res.items.map((i) => _PhotoRef(i.id, i.path)).toList(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.loadFailed', {'error': '$e'}))));
    }
  }

  Future<void> _openCluster(PhotoFaceClusterItem cluster) async {
    setState(
      () => _title = cluster.name ?? tr('photo.faceCluster.unnamed', {'id': cluster.id.substring(0, 6)}),
    );
    try {
      final res = await ApiSession.instance.client.photoFaces(id: cluster.id);
      if (!mounted) return;
      setState(
        () => _photos = res.items
            .map((i) => _PhotoRef(i.photoId, i.path))
            .toList(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.loadFailed', {'error': '$e'}))));
    }
  }

  Future<void> _openRule(PhotoSmartRule rule) async {
    setState(() => _title = rule.name);
    try {
      final res = await ApiSession.instance.client.photoSmartRuleItems(
        id: rule.id,
        limit: 60,
      );
      if (!mounted) return;
      setState(
        () => _photos = res.items.map((i) => _PhotoRef(i.id, i.path)).toList(),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('${tr('common.error')}: $e');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _conditionsText(PhotoSmartRuleConditions c) {
    final parts = <String>[];
    if ((c.scene ?? '').isNotEmpty) parts.add(c.scene!);
    if ((c.activity ?? '').isNotEmpty) parts.add(c.activity!);
    if ((c.faceClusterId ?? '').isNotEmpty) {
      final matched = _clusters.where((x) => x.id == c.faceClusterId);
      final name = matched.isEmpty ? null : matched.first.name;
      parts.add(
        name ??
            '${tr('photo.smartRule.person')} ${c.faceClusterId!.substring(0, 6)}',
      );
    }
    if (c.place != null) {
      final p = c.place!;
      parts.add(
        '${p.latitude.toStringAsFixed(3)}, ${p.longitude.toStringAsFixed(3)} · '
        '${(p.radiusKm ?? 10).toStringAsFixed(1)} km',
      );
    }
    if (c.from != null || c.to != null) {
      final from = c.from == null
          ? tr('photo.smartRule.anyTime')
          : _fmtDate(DateTime.fromMillisecondsSinceEpoch(c.from! * 1000));
      final to = c.to == null
          ? tr('photo.smartRule.anyTime')
          : _fmtDate(DateTime.fromMillisecondsSinceEpoch(c.to! * 1000));
      parts.add(tr('photo.smartRule.range', {'from': from, 'to': to}));
    }
    if (c.favorite == true) parts.add(tr('photo.nav.favorites'));
    return parts.join(' · ');
  }

  Future<void> _deleteRule(PhotoSmartRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.smartRule.delete')),
        content: Text(
          tr('photo.smartRule.deleteConfirm', {'name': rule.name}),
        ),
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
      await ApiSession.instance.client.photoSmartRuleDelete(
        body: PhotoSmartRuleDeleteBody(id: rule.id),
      );
      await _load();
      _toast(tr('photo.smartRule.deleted'));
    } catch (e) {
      _toast('${tr('common.error')}: $e');
    }
  }

  Future<void> _editRule([PhotoSmartRule? rule]) async {
    final cond = rule?.conditions;
    final place = cond?.place;
    final nameCtrl = TextEditingController(text: rule?.name ?? '');
    final latCtrl = TextEditingController(
      text: place == null ? '' : place.latitude.toString(),
    );
    final lngCtrl = TextEditingController(
      text: place == null ? '' : place.longitude.toString(),
    );
    final radiusCtrl = TextEditingController(
      text: (place?.radiusKm ?? 10).toStringAsFixed(1),
    );

    var scene = cond?.scene ?? '';
    var activity = cond?.activity ?? '';
    var person = cond?.faceClusterId ?? '';
    var favorite = cond?.favorite == true;
    var from = cond?.from == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(cond!.from! * 1000);
    var to = cond?.to == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(cond!.to! * 1000);

    final payload = await showDialog<(String, PhotoSmartRuleConditions)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
            rule == null ? tr('photo.smartRule.new') : tr('photo.smartRule.edit'),
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: tr('photo.smartRule.name'),
                      hintText: tr('photo.smartRule.nameHint'),
                    ),
                  ),
                  const SizedBox(height: NasTokens.spaceMd),
                  DropdownButtonFormField<String>(
                    initialValue: scene,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('photo.smartRule.scene'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(tr('photo.smartRule.anyScene')),
                      ),
                      for (final s in _scenes)
                        DropdownMenuItem(value: s.label, child: Text(s.label)),
                    ],
                    onChanged: (v) => setLocal(() => scene = v ?? ''),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  DropdownButtonFormField<String>(
                    initialValue: activity,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('photo.smartRule.activity'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(tr('photo.smartRule.anyActivity')),
                      ),
                      for (final a in _activities)
                        DropdownMenuItem(value: a.label, child: Text(a.label)),
                    ],
                    onChanged: (v) => setLocal(() => activity = v ?? ''),
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  DropdownButtonFormField<String>(
                    initialValue: person,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('photo.smartRule.person'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(tr('photo.smartRule.anyPerson')),
                      ),
                      for (final c in _clusters)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.name ??
                                '${tr('photo.smartRule.person')} ${c.id.substring(0, 6)}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setLocal(() => person = v ?? ''),
                  ),
                  const SizedBox(height: NasTokens.spaceMd),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.event_outlined),
                          label: Text(
                            from == null
                                ? tr('photo.smartRule.from')
                                : _fmtDate(from!),
                          ),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: from ?? DateTime.now(),
                              firstDate: DateTime(1970),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) {
                              setLocal(() => from = picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.event_available_outlined),
                          label: Text(
                            to == null
                                ? tr('photo.smartRule.to')
                                : _fmtDate(to!),
                          ),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: to ?? from ?? DateTime.now(),
                              firstDate: DateTime(1970),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) setLocal(() => to = picked);
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: tr('photo.smartRule.anyTime'),
                        icon: const Icon(Icons.clear),
                        onPressed: from == null && to == null
                            ? null
                            : () => setLocal(() {
                                from = null;
                                to = null;
                              }),
                      ),
                    ],
                  ),
                  const SizedBox(height: NasTokens.spaceSm),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: latCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: tr('photo.smartRule.latitude'),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      Expanded(
                        child: TextField(
                          controller: lngCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: tr('photo.smartRule.longitude'),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: NasTokens.spaceSm),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: radiusCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: tr('photo.smartRule.radiusKm'),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('photo.smartRule.favorite')),
                    value: favorite,
                    onChanged: (v) => setLocal(() => favorite = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  _toast(tr('photo.smartRule.needName'));
                  return;
                }
                final lat = double.tryParse(latCtrl.text.trim());
                final lng = double.tryParse(lngCtrl.text.trim());
                final hasPlace = lat != null && lng != null;
                final conditions = PhotoSmartRuleConditions(
                  scene: scene.isEmpty ? null : scene,
                  activity: activity.isEmpty ? null : activity,
                  faceClusterId: person.isEmpty ? null : person,
                  place: hasPlace
                      ? PhotoSmartRulePlace(
                          latitude: lat,
                          longitude: lng,
                          radiusKm:
                              double.tryParse(radiusCtrl.text.trim()) ?? 10,
                        )
                      : null,
                  from: from == null
                      ? null
                      : from!.millisecondsSinceEpoch ~/ 1000,
                  to: to == null
                      ? null
                      : (to!
                                    .add(const Duration(days: 1))
                                    .millisecondsSinceEpoch ~/
                                1000) -
                            1,
                  favorite: favorite ? true : null,
                );
                final hasAny =
                    conditions.scene != null ||
                    conditions.activity != null ||
                    conditions.faceClusterId != null ||
                    conditions.place != null ||
                    conditions.from != null ||
                    conditions.to != null ||
                    conditions.favorite == true;
                if (!hasAny) {
                  _toast(tr('photo.smartRule.needCondition'));
                  return;
                }
                Navigator.pop(ctx, (name, conditions));
              },
              child: Text(tr('common.save')),
            ),
          ],
        ),
      ),
    );
    if (payload == null) return;
    try {
      final c = ApiSession.instance.client;
      if (rule == null) {
        await c.photoSmartRuleCreate(
          body: PhotoSmartRuleCreateBody(name: payload.$1, conditions: payload.$2),
        );
      } else {
        await c.photoSmartRuleUpdate(
          body: PhotoSmartRuleUpdateBody(
            id: rule.id,
            name: payload.$1,
            conditions: payload.$2,
          ),
        );
      }
      await _load();
      _toast(tr('photo.smartRule.saved'));
    } catch (e) {
      _toast('${tr('common.error')}: $e');
    }
  }

  Widget _rulesPane() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('photo.smartRule.hint'),
                  style: TextStyle(
                    color: context.nasTextSecondary,
                    fontSize: NasTokens.fontCaption,
                  ),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              FilledButton.icon(
                onPressed: () => _editRule(),
                icon: const Icon(Icons.add),
                label: Text(tr('photo.smartRule.new')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _rules.isEmpty
              ? NasEmptyState(
                  title: tr('photo.smartRule.empty'),
                  message: tr('photo.smartRule.emptyHint'),
                  icon: Icons.auto_awesome,
                )
              : ListView.separated(
                  itemCount: _rules.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = _rules[i];
                    return ListTile(
                      leading: const Icon(Icons.rule),
                      title: Text(r.name),
                      subtitle: Text(
                        '${_conditionsText(r.conditions)} · '
                        '${tr('photo.smartRule.count', {'count': '${r.items}'})}',
                      ),
                      onTap: () => _openRule(r),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: tr('photo.smartRule.edit'),
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _editRule(r),
                          ),
                          IconButton(
                            tooltip: tr('common.delete'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteRule(r),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _analyze(String kind) async {
    setState(() => _analyzing = true);
    try {
      final c = ApiSession.instance.client;
      late String text;
      if (kind == 'ocr') {
        final res = await c.photoAiOcr(body: const PhotoAiBatchBody(limit: 20));
        text = tr('photo.analyzeOcr', {'count': '${res.ocr}', 'remaining': '${res.remaining}'});
      } else if (kind == 'activity') {
        final res = await c.photoAiActivities(
          body: const PhotoAiBatchBody(limit: 20),
        );
        text = tr('photo.analyzeActivity', {'count': '${res.processed}', 'remaining': '${res.remaining}'});
      } else {
        final res = await c.photoAiAnalyze(
          body: const PhotoAiAnalyzeBody(limit: 20),
        );
        text =
            tr('photo.analyzeAll', {'count': '${res.processed}', 'faces': '${res.faces}', 'scenes': '${res.scenes}', 'remaining': '${res.remaining}'});
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('photo.analyzeFailed', {'error': '$e'}))));
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _renameCluster(PhotoFaceClusterItem cluster) async {
    final ctrl = TextEditingController(text: cluster.name ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('ui.photo.063')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('ui.photo.064')),
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
      ),
    );
    if (ok != true) return;
    try {
      await ApiSession.instance.client.photoFaceName(
        body: PhotoFaceNameBody(clusterId: cluster.id, name: ctrl.text.trim()),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('photo.nameFailed', {'error': '$e'}))));
    }
  }

  Future<void> _mergeCluster(PhotoFaceClusterItem cluster) async {
    final targets = _clusters.where((c) => c.id != cluster.id).toList();
    if (targets.isEmpty) return;
    final picked = await showDialog<PhotoFaceClusterItem>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('ui.photo.065')),
        children: [
          for (final t in targets.take(30))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t),
              child: Text(
                '${t.name ?? tr('photo.faceCluster.unnamed', {'id': t.id.substring(0, 6)})} · ${tr('photo.count', {'count': '${t.size}'})}',
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    try {
      final res = await ApiSession.instance.client.photoFaceMerge(
        body: PhotoFaceMergeBody(fromId: cluster.id, toId: picked.id),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('photo.merged', {'moved': '${res.moved}'}))));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('photo.mergeFailed', {'error': '$e'}))));
    }
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _title = tr('photo.searchTitle', {'q': q}));
    try {
      final c = ApiSession.instance.client;
      final parsed = await c.photoSemanticParse(q: q);
      final res = await c.photoSemanticSearch(q: q);
      if (!mounted) return;
      final unmatched = parsed.unmatched;
      setState(() {
        _searchTags = res.tags;
        _searchHint = unmatched.isEmpty
            ? (res.tags.isEmpty
                  ? tr('ui.photo.hfe6c48')
                  : tr('photo.searchRecognized', {'labels': res.tags.map((t) => t.label).join(' + ')}))
            : tr('photo.searchRecognizedUnmatched', {'labels': res.tags.map((t) => t.label).join(' + '), 'unmatched': unmatched.join(tr('photo.searchUnmatchedSeparator'))});
        _photos = res.items.map((i) => _PhotoRef(i.id, i.path)).toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('common.searchFailed', {'error': '$e'}))));
    }
  }

  /// 一个场景标签：封面缩略图 + 名称 + 张数 + 置信度分布。
  ///
  /// 为什么要有封面：纯文字列表看不出「这个标签到底装了什么」，
  /// 而场景标签最容易出现的疑问恰恰是"这个'客厅'里都是些什么照片"。
  Widget _sceneTile(PhotoSceneTagSummaryItem s) {
    final scheme = Theme.of(context).colorScheme;
    final coverPath = s.coverPath;
    final confident = s.confident;
    final total = s.count;
    return InkWell(
      onTap: () => _openLabel(s.label),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceMd,
          vertical: NasTokens.spaceXs,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              child: SizedBox(
                width: 56,
                height: 56,
                child: coverPath == null
                    ? Container(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.landscape_outlined, color: context.nasTextSecondary),
                      )
                    : NasCoverImage(
                        url: _media.thumbnail(coverPath, size: 160),
                        headers: ApiSession.instance.authHeaders,
                        icon: Icons.landscape_outlined,
                      ),
              ),
            ),
            const SizedBox(width: NasTokens.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    tr('photo.scene.gateCount', {
                      'cl': '$confident',
                      'total': '$total',
                    }),
                    style: TextStyle(fontSize: NasTokens.fontMicro, color: context.nasTextSecondary),
                  ),
                  if (total > 0) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: (confident / total).clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }

  /// 人脸簇：**头像墙**。
  ///
  /// 旧实现是一个 ListTile 列表：通用人脸图标 + "未命名 · ab12cd" + 张数。
  /// 面对一屏这样的条目，用户根本没法认人 —— 必须点开照片墙去猜。
  /// 头像来自 `/photo/face/image`（服务端按 bbox 裁出来的正方形人脸图）。
  Widget _faceGrid() {
    if (_clusters.isEmpty) {
      return Center(
        child: Text(
          tr('ui.photo.hfadc6b'),
          style: TextStyle(color: context.nasTextSecondary),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(NasTokens.spaceSm),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisSpacing: NasTokens.spaceSm,
        crossAxisSpacing: NasTokens.spaceSm,
        childAspectRatio: 0.82,
      ),
      itemCount: _clusters.length,
      itemBuilder: (context, i) => _faceTile(_clusters[i]),
    );
  }

  Widget _faceTile(PhotoFaceClusterItem c) {
    final scheme = Theme.of(context).colorScheme;
    final named = (c.name ?? '').trim().isNotEmpty;
    final label = named
        ? c.name!
        : tr('photo.faceCluster.unnamed', {'id': c.id.substring(0, 6)});
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusMd),
      onTap: () => _openCluster(c),
      onLongPress: () => _faceActions(c),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: named ? scheme.primary.withValues(alpha: 0.6) : scheme.outlineVariant,
                      width: named ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: c.coverFaceId == null
                      ? Icon(Icons.face_outlined, color: context.nasTextSecondary)
                      : Image.network(
                          '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
                          '?id=${Uri.encodeComponent(c.coverFaceId!)}&size=200',
                          headers: ApiSession.instance.authHeaders,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.face_outlined,
                            color: context.nasTextSecondary,
                          ),
                        ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(
                      '${c.size}',
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                // 命名入口放右上角，避免长按才想得起来
                Positioned(
                  right: -2,
                  top: -2,
                  child: IconButton(
                    tooltip: tr('ui.photo.074'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    onPressed: () => _renameCluster(c),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              fontWeight: named ? FontWeight.w700 : FontWeight.w400,
              color: named ? null : context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// 长按：改名 / 合并 / 隐藏
  Future<void> _faceActions(PhotoFaceClusterItem c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(tr('ui.photo.074')),
              onTap: () => Navigator.pop(ctx, 'name'),
            ),
            ListTile(
              leading: const Icon(Icons.merge_type),
              title: Text(tr('ui.photo.075')),
              onTap: () => Navigator.pop(ctx, 'merge'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: Text(tr('photo.face.dissolve')),
              onTap: () => Navigator.pop(ctx, 'dissolve'),
            ),
            ListTile(
              leading: const Icon(Icons.people_outline),
              title: Text(tr('photo.face.manage')),
              onTap: () => Navigator.pop(ctx, 'manage'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'name':
        await _renameCluster(c);
      case 'merge':
        await _mergeCluster(c);
      case 'dissolve':
        await _dissolveCluster(c);
      case 'manage':
        await _manageFaces(c);
    }
  }

  /// 簇成员管理：单张脸移出 / 移到别簇。
  ///
  /// 整簇合并解决不了「这一张认错了」——那是单张归属问题。
  Future<void> _manageFaces(PhotoFaceClusterItem cluster) async {
    List<PhotoFaceItem> faces;
    try {
      final res = await ApiSession.instance.client.photoFaces(id: cluster.id);
      faces = res.items;
    } catch (e) {
      _toast(tr('common.loadFailed', {'error': '$e'}));
      return;
    }
    if (!mounted) return;
    if (faces.isEmpty) {
      _toast(tr('photo.face.noFaces'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          tr('photo.face.manageTitle', {
            'name': cluster.name ??
                tr('photo.faceCluster.unnamed', {'id': cluster.id.substring(0, 6)}),
          }),
        ),
        content: SizedBox(
          width: 520,
          height: 420,
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 96,
              mainAxisSpacing: NasTokens.spaceSm,
              crossAxisSpacing: NasTokens.spaceSm,
            ),
            itemCount: faces.length,
            itemBuilder: (c, i) {
              final face = faces[i];
              return InkWell(
                onLongPress: () async {
                  Navigator.pop(ctx);
                  await _faceMemberActions(face, cluster);
                },
                child: ClipOval(
                  child: Image.network(
                    '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
                    '?id=${Uri.encodeComponent(face.id)}&size=160',
                    headers: ApiSession.instance.authHeaders,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.face_outlined,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.close'))),
        ],
      ),
    );
    await _load();
  }

  Future<void> _faceMemberActions(PhotoFaceItem face, PhotoFaceClusterItem cluster) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.move_up),
              title: Text(tr('photo.face.moveTo')),
              onTap: () => Navigator.pop(ctx, 'to'),
            ),
            ListTile(
              leading: const Icon(Icons.person_off_outlined),
              title: Text(tr('photo.face.moveOut')),
              onTap: () => Navigator.pop(ctx, 'out'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    String? target;
    if (action == 'to') {
      final others = _clusters.where((x) => x.id != cluster.id).toList();
      if (others.isEmpty) {
        _toast(tr('photo.face.noOtherCluster'));
        return;
      }
      final picked = await showDialog<PhotoFaceClusterItem>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(tr('photo.face.moveTo')),
          children: [
            for (final t in others.take(40))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, t),
                child: Text(
                  '${t.name ?? tr('photo.faceCluster.unnamed', {'id': t.id.substring(0, 6)})}'
                  ' · ${tr('photo.count', {'count': '${t.size}'})}',
                ),
              ),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      target = picked.id;
    }

    try {
      await ApiSession.instance.client.photoFaceMove(
        body: PhotoFaceMoveBody(faceId: face.id, toClusterId: target),
      );
      if (!mounted) return;
      _toast(tr('photo.face.moved'));
      await _load();
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  /// 跨照片二次合并候选：先看再合，不再"一键全合"。
  /// 候选阈值：跟聚类参数 mergeClusterSim 对齐（默认 0.76），可在弹窗里就地调
  static const _mergeSimKey = 'photo.face.mergeSim';

  double get _mergeSim =>
      double.tryParse(SettingsStore.instance.getString(_mergeSimKey) ?? '') ?? 0.76;

  Future<void> _openMergeCandidates() async {
    final sim = _mergeSim;
    PhotoFaceMergeCandidateList res;
    try {
      res = await ApiSession.instance.client.photoFaceMergeCandidates(
        body: PhotoFaceMergeCandidateBody(minSim: sim, minEvidence: 2, limit: 20),
      );
    } catch (e) {
      _toast('$e');
      return;
    }
    if (!mounted) return;
    final pending = List<PhotoFaceMergeCandidate>.from(res.items);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(tr('photo.face.candidatesTitle')),
              ),
              // 阈值就地可调：不同人像库的分布差很多，写死一个数不可能都对
              for (final s in const [0.70, 0.76, 0.85])
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(s.toStringAsFixed(2)),
                    selected: (sim - s).abs() < 0.001,
                    onSelected: (_) async {
                      await SettingsStore.instance.setString(_mergeSimKey, '$s');
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      await _openMergeCandidates();
                    },
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: 460,
            child: pending.isEmpty
                ? Center(child: Text(tr('photo.face.noCandidates')))
                : ListView.separated(
                    itemCount: pending.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final p = pending[i];
                      return ListTile(
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _faceAvatar(p.fromCoverFaceId, 34),
                            const SizedBox(width: 2),
                            _faceAvatar(p.toCoverFaceId, 34),
                          ],
                        ),
                        title: Text(
                          '${p.fromName ?? tr('photo.faceCluster.unnamed', {'id': p.fromId.substring(0, 6)})}'
                          ' → ${p.toName ?? tr('photo.faceCluster.unnamed', {'id': p.toId.substring(0, 6)})}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          tr('photo.face.candidateMeta', {
                            'sim': p.sim.toStringAsFixed(2),
                            'evidence': '${p.evidence}',
                            'a': '${p.fromSize}',
                            'b': '${p.toSize}',
                          }),
                        ),
                        trailing: FilledButton(
                          onPressed: () async {
                            try {
                              await ApiSession.instance.client.photoFaceMerge(
                                body: PhotoFaceMergeBody(fromId: p.fromId, toId: p.toId),
                              );
                              if (!ctx.mounted) return;
                              setLocal(() => pending.removeAt(i));
                              await _load();
                            } catch (e) {
                              _toast('$e');
                            }
                          },
                          child: Text(tr('photo.face.mergeOne')),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('common.close'))),
          ],
        ),
      ),
    );
  }

  /// 撤消最近几次合并（审计表里逐条回滚）
  Future<void> _undoMerge() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.face.mergeUndo')),
        content: Text(tr('photo.face.mergeUndoBody')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.ok'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await ApiSession.instance.client.photoFaceMergeUndo(
        body: const PhotoFaceMergeUndoBody(limit: 3),
      );
      if (!mounted) return;
      _toast(tr('photo.face.mergeUndone', {
        'restored': '${res.restored}',
        'faces': '${res.faces}',
      }));
      await _load();
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  Widget _faceAvatar(String? faceId, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: faceId == null
            ? Icon(Icons.face_outlined, size: size * 0.8, color: context.nasTextSecondary)
            : Image.network(
                '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
                '?id=${Uri.encodeComponent(faceId)}&size=200',
                headers: ApiSession.instance.authHeaders,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.face_outlined, size: size * 0.8, color: context.nasTextSecondary),
              ),
      ),
    );
  }

  /// 人脸区顶栏：候选合并与撤消（比藏在长按里好找）
  Widget _faceToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceXs,
        NasTokens.spaceSm,
        0,
      ),
      child: Row(
        children: [
          Text(
            tr('photo.face.clusterCount', {'count': '${_clusters.length}'}),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _openMergeCandidates,
            icon: const Icon(Icons.auto_fix_high, size: 18),
            label: Text(tr('photo.face.candidates')),
          ),
          IconButton(
            tooltip: tr('photo.face.mergeUndo'),
            icon: const Icon(Icons.undo, size: 20),
            onPressed: _undoMerge,
          ),
        ],
      ),
    );
  }

  /// 解散簇：脸放回未分组（不删人脸数据，可再被归属投票重新聚起来）
  Future<void> _dissolveCluster(PhotoFaceClusterItem c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('photo.face.dissolve')),
        content: Text(tr('photo.face.dissolveBody', {'count': '${c.size}'})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('common.ok'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ApiSession.instance.client.photoFaceDissolve(
        body: PhotoFaceDissolveBody(clusterId: c.id),
      );
      if (!mounted) return;
      _toast(tr('photo.face.dissolved'));
      await _load();
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  Widget _photoGrid() {
    final sceneMode = _sceneGateOf.isNotEmpty;
    final visible = sceneMode && _gateConfidentOnly
        ? _photos.where((p) => _sceneGateOf[p.id] == 'confident').toList()
        : _photos;
    if (visible.isEmpty) return Center(child: Text(tr('ui.photo.066')));
    return Column(
      children: [
        if (sceneMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceSm,
              NasTokens.spaceMd,
              0,
            ),
            child: Row(
              children: [
                FilterChip(
                  label: Text(tr('photo.scene.confidentOnly')),
                  selected: _gateConfidentOnly,
                  onSelected: (v) => setState(() => _gateConfidentOnly = v),
                ),
                const SizedBox(width: NasTokens.spaceXs),
                Text(
                  tr('photo.scene.gateCount', {
                    'cl': '${_sceneGateOf.values.where((g) => g == 'confident').length}',
                    'total': '${_sceneGateOf.length}',
                  }),
                  style: TextStyle(
                    fontSize: NasTokens.fontMicro,
                    color: context.nasTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        if (_searchHint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceSm,
              NasTokens.spaceMd,
              0,
            ),
            child: Row(
              children: [
                if (_searchTags.isNotEmpty) ...[
                  Expanded(
                    child: Wrap(
                      spacing: NasTokens.spaceXs,
                      children: [
                        for (final t in _searchTags) Chip(label: Text(t.label)),
                      ],
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
        if (_searchHint.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _searchHint,
                style: TextStyle(
                  color: context.nasTextSecondary,
                  fontSize: NasTokens.fontCaption,
                ),
              ),
            ),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(NasTokens.spaceSm),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: NasTokens.spaceSm,
              crossAxisSpacing: NasTokens.spaceSm,
            ),
            itemCount: visible.length,
            itemBuilder: (context, i) => NasCoverImage(
              url: _media.thumbnail(visible[i].path, size: 320),
              headers: ApiSession.instance.authHeaders,
              icon: Icons.image_outlined,
            ),
          ),
        ),
      ],
    );
  }

  Widget _searchPane() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(NasTokens.spaceMd),
          child: Row(
            children: [
              Expanded(
                child: NasSearchField(
                  controller: _searchCtrl,
                  hintText: tr('ui.photo.067'),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: NasTokens.spaceSm),
              FilledButton(
                onPressed: _search,
                child: Text(tr('common.search')),
              ),
            ],
          ),
        ),
        Expanded(
          child: _title == null
              ? NasEmptyState(
                  title: tr('ui.photo.068'),
                  message: tr('ui.photo.h242e8b'),
                  icon: Icons.search,
                )
              : _photoGrid(),
        ),
      ],
    );
  }

  Widget _listPane(List<Widget> tiles, String emptyHint) {
    if (tiles.isEmpty) return Center(child: Text(emptyHint));
    return ListView.separated(
      itemCount: tiles.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => tiles[i],
    );
  }

  @override
  Widget build(BuildContext context) {
    final showingPhotos = _title != null;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(
        title: Text(showingPhotos ? _title! : tr('ui.photo.069')),
        leading: showingPhotos
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _title = null;
                  _photos = const [];
                  _searchHint = '';
                  _searchTags = const [];
                }),
              )
            : null,
        actions: [
          if (!showingPhotos && _analyzing)
            Padding(
              padding: EdgeInsets.only(right: NasTokens.spaceMd),
              child: Center(
                child: SizedBox(
                  width: NasTokens.iconSm,
                  height: NasTokens.iconSm,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (!showingPhotos)
            PopupMenuButton<String>(
              icon: Icon(Icons.auto_awesome),
              tooltip: tr('ui.photo.070'),
              onSelected: _analyze,
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'all', child: Text(tr('ui.photo.071'))),
                PopupMenuItem(value: 'ocr', child: Text(tr('ui.photo.072'))),
                PopupMenuItem(
                  value: 'activity',
                  child: Text(tr('ui.photo.073')),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(NasTokens.spaceLg),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.nasDanger),
                ),
              ),
            )
          : showingPhotos && _title!.startsWith(tr('ui.photo.h567da6'))
          ? _photoGrid()
          : showingPhotos
          ? _photoGrid()
          : switch (widget.section) {
              'scenes' => _listPane([
                  for (final s in _scenes) _sceneTile(s),
                ], tr('ui.photo.h531110')),
              'activities' => _listPane([
                  for (final a in _activities)
                    ListTile(
                      leading: const Icon(
                        Icons.sports_handball_outlined,
                      ),
                      title: Text(a.label),
                      subtitle: Text(tr('photo.count', {'count': '${a.count}'})),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openActivity(a.label),
                    ),
                ], tr('ui.photo.h6a8cef')),
              'rules' => _rulesPane(),
              'search' => _searchPane(),
              _ => Column(
                  children: [
                    if (_clusters.isNotEmpty) _faceToolbar(),
                    Expanded(child: _faceGrid()),
                  ],
                ),
            },
    );
  }
}
