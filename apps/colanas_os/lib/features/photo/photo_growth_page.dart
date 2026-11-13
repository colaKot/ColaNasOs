import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_media/nas_media.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/settings_store.dart';
import '../../core/session.dart';
import 'photo_adaptive_image.dart';
import 'photo_viewer_page.dart';

/// 成长轨迹（相册 > 记忆）。
///
/// 服务端把某个人的人脸照片按「地点 × 时间窗」预计算成 Stage 并落库，这里只做展示：
/// 顶部人脸条 + 一句话看板 + 时间轴分段列表（游标分页）+ 阶段二级页 + 换封面纠错。
/// 所有 UI 文案走 i18n；服务端只给结构化数据（地点、时间、里程碑枚举）。
class PhotoGrowthTrackPage extends StatefulWidget {
  const PhotoGrowthTrackPage({super.key});

  @override
  State<PhotoGrowthTrackPage> createState() => _PhotoGrowthTrackPageState();
}

class _PhotoGrowthTrackPageState extends State<PhotoGrowthTrackPage> {
  static const _personKey = 'photo.growth.person';
  static const _orderKey = 'photo.growth.order';
  static const _granularityKey = 'photo.growth.granularity';
  static const _pageSize = 20;

  bool _loading = true;
  String? _error;
  List<PhotoGrowthPerson> _persons = const [];
  String? _personId;
  List<PhotoGrowthStage> _stages = const [];
  PhotoGrowthSummary? _summary;
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _asc = false;
  String _granularity = 'auto';
  final ScrollController _scroll = ScrollController();

  ApiClient get _client => ApiSession.instance.client;

  String _faceUrl(String id, {int size = 96}) =>
      '${ApiSession.instance.baseUrl}/api/v1/photo/face/image'
      '?id=${Uri.encodeComponent(id)}&size=$size';

  @override
  void initState() {
    super.initState();
    _asc = SettingsStore.instance.getString(_orderKey) == 'asc';
    final g = SettingsStore.instance.getString(_granularityKey);
    _granularity = (g == 'month' || g == 'quarter' || g == 'year') ? g! : 'auto';
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scroll.position.extentAfter < 320) _loadStages(reset: false);
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _client.photoGrowthPersons(limit: 20);
      if (!mounted) return;
      final saved = SettingsStore.instance.getString(_personKey);
      var selected = saved;
      if (selected == null || !res.items.any((p) => p.id == selected)) {
        selected = null;
        for (final p in res.items) {
          if ((p.name ?? '').isNotEmpty) {
            selected = p.id;
            break;
          }
        }
        selected ??= res.items.isNotEmpty ? res.items.first.id : null;
      }
      setState(() {
        _persons = res.items;
        _personId = selected;
      });
      if (selected != null) await _loadStages(reset: true);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadStages({required bool reset}) async {
    final person = _personId;
    if (person == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final res = await _client.photoGrowthItems(
        person: person,
        order: _asc ? 'asc' : 'desc',
        granularity: _granularity,
        cursor: reset ? null : _cursor,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _stages = reset ? List<PhotoGrowthStage>.from(res.items) : [..._stages, ...res.items];
        _cursor = res.nextCursor;
        _hasMore = res.nextCursor != null;
        _summary = res.summary;
        _loadingMore = false;
      });
      if (reset && _scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _selectPerson(String id) async {
    if (id == _personId) return;
    await SettingsStore.instance.setString(_personKey, id);
    if (!mounted) return;
    setState(() {
      _personId = id;
      _stages = const [];
      _cursor = null;
      _hasMore = false;
      _summary = null;
    });
    await _loadStages(reset: true);
  }

  Future<void> _setAsc(bool asc) async {
    if (asc == _asc) return;
    await SettingsStore.instance.setString(_orderKey, asc ? 'asc' : 'desc');
    if (!mounted) return;
    setState(() => _asc = asc);
    await _loadStages(reset: true);
  }

  Future<void> _setGranularity(String g) async {
    if (g == _granularity) return;
    await SettingsStore.instance.setString(_granularityKey, g);
    if (!mounted) return;
    setState(() => _granularity = g);
    await _loadStages(reset: true);
  }

  Future<void> _rebuild() async {
    final person = _personId;
    if (person == null) return;
    try {
      final res = await _client.photoGrowthRebuild(
        body: PhotoGrowthRebuildBody(person: person, granularity: _granularity),
      );
      if (!mounted) return;
      NasSnack.show(context, tr('photo.growth.rebuilt', {'stages': '${res.stages}'}));
      await _loadStages(reset: true);
      final persons = await _client.photoGrowthPersons(limit: 20);
      if (mounted) setState(() => _persons = persons.items);
    } catch (e) {
      if (mounted) NasSnack.show(context, '$e');
    }
  }

  Future<void> _repin(PhotoGrowthStage stage) async {
    final updated = await showDialog<PhotoGrowthStage>(
      context: context,
      builder: (_) => GrowthRepinDialog(stage: stage),
    );
    if (updated != null && mounted) await _loadStages(reset: true);
  }

  Future<void> _openStage(PhotoGrowthStage stage) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGrowthStagePage(stage: stage),
      ),
    );
    // 二级页里可能换过封面，回来统一刷一次，避免两页状态不一致
    if (mounted) await _loadStages(reset: true);
  }

  Future<void> _showPersonPicker() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _PersonPickerDialog(persons: _persons),
    );
    if (picked != null) await _selectPerson(picked);
  }

  String _date(int sec, {bool short = false}) {
    if (sec <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    final m = d.month.toString().padLeft(2, '0');
    return short ? '${d.year}.$m' : '${d.year}-$m-${d.day.toString().padLeft(2, '0')}';
  }

  String _spanLabel(String kind) {
    switch (kind) {
      case 'month':
        return tr('photo.growth.spanMonth');
      case 'quarter':
        return tr('photo.growth.spanQuarter');
      case 'halfYear':
        return tr('photo.growth.spanHalfYear');
      case 'year':
        return tr('photo.growth.spanYear');
      default:
        return tr('photo.growth.auto');
    }
  }

  String _milestoneLabel(String m) {
    if (m == 'firstPlace') return tr('photo.growth.milestoneFirstPlace');
    if (m == 'firstScene') return tr('photo.growth.milestoneFirstScene');
    return '';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _bootstrap);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      controller: _scroll,
      // 右边不留 padding：卡片自己留 16，让滚动条/内容更贴窗口右边
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('photo.growth.title'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 3),
                  Text(
                    tr('photo.growth.subtitle'),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _bootstrap,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _personBar(),
        const SizedBox(height: 10),
        _summaryLine(),
        const SizedBox(height: 10),
        _controls(scheme),
        const SizedBox(height: 16),
        if (_personId == null || _persons.isEmpty)
          NasEmptyState(
            title: tr('photo.growth.noPerson'),
            message: tr('photo.growth.noPersonHint'),
            icon: Icons.face_retouching_natural_outlined,
          )
        else if (_stages.isEmpty && !_loadingMore)
          NasEmptyState(
            title: tr('photo.growth.noStages'),
            message: tr('photo.growth.noStagesHint'),
            icon: Icons.timeline_outlined,
          )
        else
          for (var i = 0; i < _stages.length; i++) _timelineRow(_stages[i]),
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ],
    );
  }

  Widget _personBar() {
    return SizedBox(
      // 头像(56+4) + 间距 + 名字 + 张数实测约 88~93px，给到 104 免得
      // 不同字体下顶部人脸条反复报 "RenderFlex overflowed by 1 pixel"
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _persons.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          if (i == _persons.length) {
            return GestureDetector(
              onTap: _showPersonPicker,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: const Icon(Icons.add),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('photo.growth.personPicker'),
                    style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
                  ),
                ],
              ),
            );
          }
          final p = _persons[i];
          final active = p.id == _personId;
          return GestureDetector(
            onTap: () => _selectPerson(p.id),
            child: SizedBox(
              width: 74,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: active
                          ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
                          : null,
                    ),
                    child: CircleAvatar(
                      radius: 26,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                      backgroundImage: p.coverFaceId == null
                          ? null
                          : NetworkImage(
                              _faceUrl(p.coverFaceId!),
                              headers: ApiSession.instance.authHeaders,
                            ),
                      child: p.coverFaceId == null
                          ? const Icon(Icons.person_outline, size: 24)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (p.name ?? '').isNotEmpty ? p.name! : tr('photo.growth.unnamed'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  Text(
                    '${p.size}',
                    style: TextStyle(fontSize: 9, color: context.nasTextSecondary),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _summaryLine() {
    final s = _summary;
    if (s == null) return const SizedBox.shrink();
    return Text(
      tr('photo.growth.summary', {
        'first': _date(s.firstAt, short: true),
        'last': _date(s.lastAt, short: true),
        'cities': '${s.cityCount}',
        'stages': '${s.stageCount}',
      }),
      style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
    );
  }

  Widget _controls(ColorScheme scheme) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: () => _setAsc(!_asc),
          icon: Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
          label: Text(_asc ? tr('photo.growth.asc') : tr('photo.growth.desc')),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _granularity,
              isDense: true,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(tr('photo.growth.auto'))),
                DropdownMenuItem(value: 'month', child: Text(tr('photo.growth.month'))),
                DropdownMenuItem(value: 'quarter', child: Text(tr('photo.growth.quarter'))),
                DropdownMenuItem(value: 'year', child: Text(tr('photo.growth.year'))),
              ],
              onChanged: (v) {
                if (v != null) _setGranularity(v);
              },
            ),
          ),
        ),
        Text(
          tr('photo.growth.granularity'),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: _rebuild,
          icon: const Icon(Icons.auto_awesome_outlined, size: 16),
          label: Text(tr('photo.growth.rebuild')),
        ),
      ],
    );
  }

  Widget _timelineRow(PhotoGrowthStage s) {
    final scheme = Theme.of(context).colorScheme;
    // 不再用 IntrinsicHeight：固有高度测量会和竖线的 Expanded 形成循环，
    // 遇到 LayoutBuilder 更会直接抛 computeMaxIntrinsicHeight 异常，
    // 连锁把 sliver 布局链打断（2026-11-13 点成长轨迹浏览器卡死）。
    // 改成 Stack + Positioned：高度由卡片一次布局决定，竖线自动填满。
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: _stageCard(s),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 26,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: s.milestone.isNotEmpty ? scheme.primary : scheme.outlineVariant,
                  border: Border.all(color: scheme.surface, width: 2),
                ),
              ),
              Expanded(
                child: Container(
                  width: 2,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stageCard(PhotoGrowthStage s) {
    final scheme = Theme.of(context).colorScheme;
    final milestone = _milestoneLabel(s.milestone);
    return Container(
      // 右侧留 16，配合列表右边 padding 0，让滚动条尽量贴窗口右边
      margin: const EdgeInsets.only(right: 16, bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${_date(s.startAt)} — ${_date(s.endAt)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              Text(
                s.placeName.isEmpty ? tr('photo.growth.unknownPlace') : s.placeName,
                style: TextStyle(fontSize: 12, color: context.nasTextSecondary),
              ),
              Text(
                _spanLabel(s.spanKind),
                style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
              ),
              if (milestone.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(milestone, style: const TextStyle(fontSize: 10)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) {
              final photos = _stageImages(s);
              final story = _stageStory(s);
              // 卡片够宽时把右边的空位利用起来：照片在左，一段小文案在右
              if (c.maxWidth >= 640) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: photos),
                    const SizedBox(width: 14),
                    SizedBox(width: 210, child: story),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [photos, const SizedBox(height: 10), story],
              );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                tr('photo.growth.stageIndex', {'seq': '${s.seq}'}),
                style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
              ),
              Text(
                tr('photo.growth.photoCount', {'count': '${s.photoCount}'}),
                style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
              ),
              if (s.locked)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.push_pin, size: 12),
                    const SizedBox(width: 2),
                    Text(tr('photo.growth.pinned'), style: const TextStyle(fontSize: 10)),
                  ],
                ),
              if (s.hint == 'noScenePortrait')
                Text(
                  tr('photo.growth.hintNoScenePortrait'),
                  style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageImages(PhotoGrowthStage s) {
    final secondary = s.secondaryPath;
    final extras = s.extraPaths
        .where((p) => p.isNotEmpty && p != s.coverPath && p != secondary)
        .take(2)
        .toList();
    // 服务端选片已保证：有横屏就只出一张横图（跨整行、完整显示）；
    // 实在没有横屏时凑两张竖图并排，避免单张竖图把卡片撑得又高又空。
    final main = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PhotoAdaptiveImage(
            path: s.coverPath,
            width: s.coverWidth?.toDouble(),
            height: s.coverHeight?.toDouble(),
            minHeight: 160,
            maxHeight: 420,
            onTap: () => _openStage(s),
            onLongPress: () => _repin(s),
          ),
        ),
        if (secondary != null) ...[
          const SizedBox(width: 6),
          Expanded(
            child: PhotoAdaptiveImage(
              path: secondary,
              width: s.secondaryWidth?.toDouble(),
              height: s.secondaryHeight?.toDouble(),
              minHeight: 160,
              maxHeight: 420,
              thumbSize: 512,
              onTap: () => _openStage(s),
            ),
          ),
        ],
      ],
    );
    if (extras.isEmpty) return main;
    // 同一段的另外两张：让「这个时期」不只有一张封面，也更容易看到景
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        main,
        const SizedBox(height: 6),
        SizedBox(
          height: 118,
          child: Row(
            children: [
              for (var i = 0; i < extras.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: PhotoAdaptiveImage(
                    path: extras[i],
                    thumbSize: 320,
                    minHeight: 80,
                    maxHeight: 160,
                    onTap: () => _openStage(s),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 照片右边那段小文案：按阶段轮换 6 句，避免同屏重复。
  ///
  /// 服务端没有 VLM 阶段文案，这里用 i18n 模板 + 地点/年月拼；
  /// 诗在数据之外，UI 文案仍全部走契约。
  Widget _stageStory(PhotoGrowthStage s) {
    final scheme = Theme.of(context).colorScheme;
    final d = DateTime.fromMillisecondsSinceEpoch(s.startAt * 1000);
    final place = s.placeName.isEmpty ? tr('photo.growth.somewhere') : s.placeName;
    final args = {
      'place': place,
      'year': '${d.year}',
      'month': '${d.month}',
    };
    final line = switch (s.seq % 6) {
      0 => tr('photo.growth.poem1', args),
      1 => tr('photo.growth.poem2', args),
      2 => tr('photo.growth.poem3', args),
      3 => tr('photo.growth.poem4', args),
      4 => tr('photo.growth.poem5', args),
      _ => tr('photo.growth.poem6', args),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${d.year}.${d.month.toString().padLeft(2, '0')}',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.6,
              color: scheme.primary.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            line,
            style: const TextStyle(fontSize: 13, height: 1.75, letterSpacing: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            tr('photo.growth.photoCount', {'count': '${s.photoCount}'}),
            style: TextStyle(fontSize: 10, color: context.nasTextSecondary),
          ),
        ],
      ),
    );
  }
}

/// 阶段二级页：这个时期的全部照片（真分页）+ 换封面。
class PhotoGrowthStagePage extends StatefulWidget {
  const PhotoGrowthStagePage({super.key, required this.stage});

  final PhotoGrowthStage stage;

  @override
  State<PhotoGrowthStagePage> createState() => _PhotoGrowthStagePageState();
}

class _PhotoGrowthStagePageState extends State<PhotoGrowthStagePage> {
  static const _pageSize = 60;

  late PhotoGrowthStage _stage;
  bool _loading = true;
  String? _error;
  List<PhotoItem> _photos = const [];
  int _total = 0;
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  final ScrollController _scroll = ScrollController();

  ApiClient get _client => ApiSession.instance.client;
  MediaUrls get _media => MediaUrls(ApiSession.instance.baseUrl);

  String _thumb(String path, {int size = 320}) => _media.thumbnail(path, size: size);

  @override
  void initState() {
    super.initState();
    _stage = widget.stage;
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scroll.position.extentAfter < 360) _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      if (reset) _loading = true;
      _error = null;
    });
    try {
      final res = await _client.photoGrowthStagePhotos(
        stageId: _stage.id,
        cursor: reset ? null : _cursor,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _photos = reset ? List<PhotoItem>.from(res.items) : [..._photos, ...res.items];
        _total = res.total;
        _cursor = res.nextCursor;
        _hasMore = res.nextCursor != null;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _repin() async {
    final updated = await showDialog<PhotoGrowthStage>(
      context: context,
      builder: (_) => GrowthRepinDialog(stage: _stage),
    );
    if (updated == null || !mounted) return;
    setState(() => _stage = updated);
    NasSnack.show(context, tr('photo.growth.repinDone'));
  }

  String _date(int sec) {
    if (sec <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > 1100 ? 6 : width > 800 ? 5 : width > 560 ? 4 : 3;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _stage.placeName.isEmpty ? tr('photo.growth.unknownPlace') : _stage.placeName,
        ),
        actions: [
          TextButton.icon(
            onPressed: _repin,
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: Text(tr('photo.growth.repin')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const NasLoading()
          : _error != null
              ? NasErrorState(message: _error!, onRetry: () => _load(reset: true))
              : CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_date(_stage.startAt)} — ${_date(_stage.endAt)}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tr('photo.growth.stagePhotos', {'count': '$_total'}),
                              style: TextStyle(
                                fontSize: NasTokens.fontCaption,
                                color: context.nasTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            final item = _photos[i];
                            return GestureDetector(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => PhotoViewerPage(items: _photos, initialIndex: i),
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: NasCoverImage(
                                  url: _thumb(item.path),
                                  headers: ApiSession.instance.authHeaders,
                                  cacheWidth: 320,
                                ),
                              ),
                            );
                          },
                          childCount: _photos.length,
                        ),
                      ),
                    ),
                    if (_loadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// 「换一张」：列出服务端候选池里的 3 张，选中后写 manual_pin。
class GrowthRepinDialog extends StatefulWidget {
  const GrowthRepinDialog({super.key, required this.stage});

  final PhotoGrowthStage stage;

  @override
  State<GrowthRepinDialog> createState() => _GrowthRepinDialogState();
}

class _GrowthRepinDialogState extends State<GrowthRepinDialog> {
  bool _loading = true;
  String? _error;
  List<PhotoGrowthCandidate> _items = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiSession.instance.client.photoGrowthStageCandidates(
        stageId: widget.stage.id,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
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

  Future<void> _pick(String assetId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await ApiSession.instance.client.photoGrowthStageRepin(
        body: PhotoGrowthRepinBody(stageId: widget.stage.id, assetId: assetId),
      );
      if (mounted) Navigator.of(context).pop(res.stage);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      NasSnack.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('photo.growth.repinTitle')),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(height: 160, child: Center(child: NasLoading()))
            : _error != null
                ? SizedBox(height: 120, child: Center(child: Text(_error!)))
                : _items.isEmpty
                    ? SizedBox(
                        height: 120,
                        child: Center(child: Text(tr('photo.growth.noCandidates'))),
                      )
                    : SizedBox(
                        height: 170,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (_, i) {
                            final c = _items[i];
                            return GestureDetector(
                              onTap: () => _pick(c.assetId),
                              child: Stack(
                                children: [
                                  SizedBox(
                                    width: 150,
                                    child: PhotoAdaptiveImage(
                                      path: c.path,
                                      minHeight: 100,
                                      maxHeight: 170,
                                      thumbSize: 320,
                                      borderRadius: 8,
                                    ),
                                  ),
                                  if (_busy)
                                    const Positioned.fill(
                                      child: ColoredBox(color: Colors.black26),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.cancel')),
        ),
      ],
    );
  }
}

/// 人脸选择器：列出全部已命名 / 未命名聚类，支持按名字搜索。
class _PersonPickerDialog extends StatefulWidget {
  const _PersonPickerDialog({required this.persons});

  final List<PhotoGrowthPerson> persons;

  @override
  State<_PersonPickerDialog> createState() => _PersonPickerDialogState();
}

class _PersonPickerDialogState extends State<_PersonPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final items = widget.persons
        .where((p) => q.isEmpty || (p.name ?? '').toLowerCase().contains(q))
        .toList();
    return AlertDialog(
      title: Text(tr('photo.growth.personPicker')),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          children: [
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final p = items[i];
                  final named = (p.name ?? '').isNotEmpty;
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_outline),
                    title: Text(named ? p.name! : tr('photo.growth.unnamed')),
                    subtitle: Text(
                      named
                          ? tr('photo.growth.photoCount', {'count': '${p.size}'})
                          : tr('photo.growth.namedHint'),
                    ),
                    onTap: () => Navigator.of(context).pop(p.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('common.cancel')),
        ),
      ],
    );
  }
}
